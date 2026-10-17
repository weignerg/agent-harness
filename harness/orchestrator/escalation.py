"""Escalation DAG + circuit breakers: no unbounded retries or debate loops.

* Worker double-failure -> immediate Architect escalation (no third worker run).
* Critic loop: hard cap of 3 rounds, then a human gate (step BLOCKED).
* Structural anti-sycophancy/deadlock guards: a verdict must be internally
  consistent and actionable; repeated identical critiques or an unchanged
  revision end the loop (human gate). All loops are iterative and bounded.
"""
from __future__ import annotations

from dataclasses import dataclass, field
from enum import Enum
from typing import Awaitable, Callable

from pydantic import BaseModel, ConfigDict, model_validator

from .models import StepResult, StepState
from .state_machine import Handler, StateMachine

MAX_WORKER_FAILURES = 2
MAX_CRITIC_ROUNDS = 3


class BreakerOpen(RuntimeError):
    pass


@dataclass
class CircuitBreaker:
    """Global budget of handler invocations for one escalation scope."""
    max_calls: int = 10
    calls: int = 0

    def hit(self) -> None:
        self.calls += 1
        if self.calls > self.max_calls:
            raise BreakerOpen(f"circuit breaker open after {self.max_calls} calls")


class Verdict(BaseModel):
    model_config = ConfigDict(extra="forbid")
    approved: bool
    issues: list[str] = []

    @model_validator(mode="after")
    def _consistent(self) -> "Verdict":
        if self.approved and self.issues:
            raise ValueError("approved verdict must not list open issues (sycophancy guard)")
        if not self.approved and not [i for i in self.issues if i.strip()]:
            raise ValueError("rejection must list at least one concrete issue")
        return self


class Outcome(str, Enum):
    APPROVED = "approved"
    HUMAN_GATE = "human_gate"


@dataclass
class CriticResult:
    outcome: Outcome
    rounds: int
    draft: str
    reason: str = ""


def critic_loop(draft: str, critic: Callable[[str], dict | Verdict], reviser: Callable[[str, list[str]], str],
                max_rounds: int = MAX_CRITIC_ROUNDS) -> CriticResult:
    max_rounds = min(max_rounds, MAX_CRITIC_ROUNDS)  # hard ceiling cannot be raised
    seen: set[frozenset[str]] = set()
    for rnd in range(1, max_rounds + 1):
        try:
            raw = critic(draft)
            verdict = raw if isinstance(raw, Verdict) else Verdict.model_validate(raw)
        except Exception as exc:
            return CriticResult(Outcome.HUMAN_GATE, rnd, draft, f"invalid critic verdict: {exc}")
        if verdict.approved:
            return CriticResult(Outcome.APPROVED, rnd, draft)
        key = frozenset(i.strip().lower() for i in verdict.issues)
        if key in seen:
            return CriticResult(Outcome.HUMAN_GATE, rnd, draft, "repeated critique (debate deadlock)")
        seen.add(key)
        if rnd == max_rounds:
            break
        new = reviser(draft, verdict.issues)
        if new == draft:
            return CriticResult(Outcome.HUMAN_GATE, rnd, draft, "reviser made no change")
        draft = new
    return CriticResult(Outcome.HUMAN_GATE, max_rounds, draft, f"critic iteration limit ({max_rounds}) exhausted")


async def run_with_escalation(sm: StateMachine, run_id: str, step_id: str, worker: Handler, architect: Handler,
                              validate: Callable[[StepResult], str | None] | None = None,
                              breaker: CircuitBreaker | None = None) -> StepState:
    """Worker gets MAX_WORKER_FAILURES tries; then the Architect gets exactly one; then a human gate."""
    breaker = breaker or CircuitBreaker()

    def wrap(h: Handler) -> Handler:
        async def inner(env):
            breaker.hit()
            res = await h(env)
            if res.ok and validate and (err := validate(res)):
                return StepResult(ok=False, output=res.output, error=f"validation failed: {err}")
            return res
        return inner

    try:
        for _ in range(MAX_WORKER_FAILURES):
            if await sm.run_step(run_id, step_id, wrap(worker)) is StepState.SUCCEEDED:
                return StepState.SUCCEEDED
        sm.transition(run_id, step_id, StepState.ESCALATED, detail={"to": "architect"})
        if await sm.run_step(run_id, step_id, wrap(architect)) is StepState.SUCCEEDED:
            return StepState.SUCCEEDED
    except BreakerOpen as exc:
        _gate(sm, run_id, step_id, str(exc))
        return StepState.BLOCKED
    _gate(sm, run_id, step_id, "architect failed")
    return StepState.BLOCKED


def _gate(sm: StateMachine, run_id: str, step_id: str, why: str) -> None:
    cur = sm.state(run_id, step_id)
    if cur is StepState.RUNNING:  # handler aborted mid-run by the breaker
        sm.transition(run_id, step_id, StepState.FAILED, detail={"reason": why})
    sm.transition(run_id, step_id, StepState.BLOCKED, detail={"awaiting_human": True, "reason": why})


def resolve_gate(sm: StateMachine, run_id: str, step_id: str, approve: bool) -> StepState:
    """Human decision on a BLOCKED step: approve -> re-run allowed, reject -> cancelled."""
    to = StepState.RUNNING if approve else StepState.CANCELLED
    sm.transition(run_id, step_id, to, detail={"human": "approved" if approve else "rejected"})
    if approve:
        sm.transition(run_id, step_id, StepState.SUCCEEDED, detail={"human_override": True})
        return StepState.SUCCEEDED
    return StepState.CANCELLED
