"""Strict Pydantic schemas for orchestration payloads, envelopes and events."""
from __future__ import annotations

import time
from enum import Enum
from typing import Any

from pydantic import BaseModel, ConfigDict, Field, model_validator


class StepState(str, Enum):
    PENDING = "pending"
    RUNNING = "running"
    SUCCEEDED = "succeeded"
    FAILED = "failed"
    ESCALATED = "escalated"      # handed to a higher-tier node (e.g. Architect)
    BLOCKED = "blocked"          # waiting on a human gate
    ROLLED_BACK = "rolled_back"
    CANCELLED = "cancelled"


TERMINAL = {StepState.SUCCEEDED, StepState.CANCELLED, StepState.ROLLED_BACK}

ALLOWED: dict[StepState, set[StepState]] = {
    StepState.PENDING: {StepState.RUNNING, StepState.CANCELLED, StepState.BLOCKED},
    StepState.RUNNING: {StepState.SUCCEEDED, StepState.FAILED, StepState.BLOCKED, StepState.CANCELLED},
    StepState.FAILED: {StepState.RUNNING, StepState.ESCALATED, StepState.ROLLED_BACK, StepState.BLOCKED, StepState.CANCELLED},
    StepState.ESCALATED: {StepState.RUNNING, StepState.BLOCKED, StepState.CANCELLED},
    StepState.BLOCKED: {StepState.RUNNING, StepState.CANCELLED, StepState.PENDING},
    StepState.SUCCEEDED: set(),
    StepState.CANCELLED: set(),
    StepState.ROLLED_BACK: {StepState.PENDING},
}


class Strict(BaseModel):
    model_config = ConfigDict(extra="forbid", frozen=False, validate_assignment=True)


class StepSpec(Strict):
    id: str = Field(pattern=r"^[A-Za-z0-9_.:-]{1,64}$")
    deps: list[str] = Field(default_factory=list)
    kind: str = "task"
    payload: dict[str, Any] = Field(default_factory=dict)
    max_attempts: int = Field(default=3, ge=1, le=20)


class DagSpec(Strict):
    run_id: str = Field(pattern=r"^[A-Za-z0-9_.:-]{1,64}$")
    steps: list[StepSpec]

    @model_validator(mode="after")
    def _validate_dag(self) -> "DagSpec":
        ids = [s.id for s in self.steps]
        if len(set(ids)) != len(ids):
            raise ValueError("duplicate step ids")
        known = set(ids)
        for s in self.steps:
            for d in s.deps:
                if d not in known:
                    raise ValueError(f"step {s.id} depends on unknown step {d}")
        # cycle check (Kahn)
        indeg = {s.id: len(s.deps) for s in self.steps}
        out: dict[str, list[str]] = {i: [] for i in ids}
        for s in self.steps:
            for d in s.deps:
                out[d].append(s.id)
        q = [i for i, n in indeg.items() if n == 0]
        seen = 0
        while q:
            n = q.pop()
            seen += 1
            for m in out[n]:
                indeg[m] -= 1
                if indeg[m] == 0:
                    q.append(m)
        if seen != len(ids):
            raise ValueError("dependency cycle detected")
        return self


class Envelope(Strict):
    """Message passed to/from a step handler."""
    run_id: str
    step_id: str
    attempt: int = Field(ge=1)
    payload: dict[str, Any] = Field(default_factory=dict)
    hints: list[str] = Field(default_factory=list)


class StepResult(Strict):
    ok: bool
    output: dict[str, Any] = Field(default_factory=dict)
    error: str | None = None


class Event(Strict):
    seq: int
    run_id: str
    step_id: str
    from_state: StepState | None
    to_state: StepState
    ts: float = Field(default_factory=time.time)
    detail: dict[str, Any] = Field(default_factory=dict)
