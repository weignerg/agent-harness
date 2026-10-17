import asyncio, os, sys, tempfile, unittest
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
from harness.orchestrator.escalation import *
from harness.orchestrator.models import DagSpec, StepResult, StepSpec, StepState
from harness.orchestrator.state_machine import StateMachine


class E(unittest.TestCase):
    def setUp(self):
        self.t = tempfile.TemporaryDirectory(); self.sm = StateMachine(os.path.join(self.t.name, "h.db"))
        self.sm.create_run(DagSpec(run_id="r", steps=[StepSpec(id="s", max_attempts=10)])); self.calls = []

    def tearDown(self): self.sm.close(); self.t.cleanup()

    def h(self, name, results):
        it = iter(results)
        async def f(env): self.calls.append(name); return next(it)
        return f

    def test_two_worker_failures_escalate_to_architect_immediately(self):
        st = asyncio.run(run_with_escalation(self.sm, "r", "s", self.h("w", [StepResult(ok=False, error="a")] * 5),
                                             self.h("arch", [StepResult(ok=True)])))
        self.assertEqual(self.calls, ["w", "w", "arch"]); self.assertIs(st, StepState.SUCCEEDED)
        self.assertIn(StepState.ESCALATED, [e.to_state for e in self.sm.events("r")])

    def test_worker_success_first_try_no_escalation(self):
        asyncio.run(run_with_escalation(self.sm, "r", "s", self.h("w", [StepResult(ok=True)]), self.h("arch", [])))
        self.assertEqual(self.calls, ["w"])

    def test_validation_failure_counts_as_failure(self):
        v = lambda r: "bad output" if r.output.get("bad") else None
        asyncio.run(run_with_escalation(self.sm, "r", "s", self.h("w", [StepResult(ok=True, output={"bad": 1}), StepResult(ok=True)]),
                                        self.h("arch", []), validate=v))
        self.assertEqual(self.calls, ["w", "w"]); self.assertEqual(self.sm.hints("r", "s"), ["validation failed: bad output"])

    def test_architect_failure_yields_human_gate_not_loop(self):
        st = asyncio.run(run_with_escalation(self.sm, "r", "s", self.h("w", [StepResult(ok=False, error="x")] * 2),
                                             self.h("arch", [StepResult(ok=False, error="y")])))
        self.assertIs(st, StepState.BLOCKED); self.assertEqual(len(self.calls), 3)
        self.assertTrue(self.sm.events("r")[-1].detail["awaiting_human"])

    def test_circuit_breaker_trips_to_human_gate(self):
        st = asyncio.run(run_with_escalation(self.sm, "r", "s", self.h("w", [StepResult(ok=False, error="x")] * 5),
                                             self.h("arch", []), breaker=CircuitBreaker(max_calls=1)))
        self.assertIs(st, StepState.BLOCKED); self.assertIs(self.sm.state("r", "s"), StepState.BLOCKED)

    def test_human_gate_resolution(self):
        asyncio.run(run_with_escalation(self.sm, "r", "s", self.h("w", [StepResult(ok=False, error="x")] * 2),
                                        self.h("arch", [StepResult(ok=False, error="y")])))
        self.assertIs(resolve_gate(self.sm, "r", "s", False), StepState.CANCELLED)

    def test_critic_approves(self):
        r = critic_loop("d", lambda d: {"approved": True}, lambda d, i: d + "!")
        self.assertEqual((r.outcome, r.rounds), (Outcome.APPROVED, 1))

    def test_critic_hard_limit_3_rounds_then_human(self):
        n = []
        def critic(d): n.append(1); return {"approved": False, "issues": [f"issue {len(n)}"]}
        r = critic_loop("d", critic, lambda d, i: d + "+", max_rounds=99)
        self.assertEqual(len(n), 3); self.assertEqual(r.outcome, Outcome.HUMAN_GATE); self.assertIn("limit", r.reason)

    def test_repeated_critique_is_deadlock(self):
        r = critic_loop("d", lambda d: {"approved": False, "issues": ["Same"]}, lambda d, i: d + "x")
        self.assertEqual((r.outcome, r.rounds), (Outcome.HUMAN_GATE, 2)); self.assertIn("deadlock", r.reason)

    def test_no_progress_revision_and_invalid_verdicts(self):
        self.assertIn("no change", critic_loop("d", lambda d: {"approved": False, "issues": ["a"]}, lambda d, i: d).reason)
        self.assertIn("invalid", critic_loop("d", lambda d: {"approved": True, "issues": ["sycophant"]}, lambda d, i: d).reason)
        self.assertIn("invalid", critic_loop("d", lambda d: {"approved": False, "issues": []}, lambda d, i: d).reason)
        self.assertIn("invalid", critic_loop("d", lambda d: 1 / 0, lambda d, i: d).reason)


if __name__ == "__main__":
    unittest.main()
