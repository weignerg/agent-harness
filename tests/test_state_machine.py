import asyncio, os, subprocess, sys, tempfile, time, unittest
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
from pydantic import ValidationError
from harness.orchestrator.models import ALLOWED, DagSpec, StepResult, StepSpec, StepState
from harness.orchestrator.state_machine import InvalidTransition, StateMachine


def dag(run="r1", steps=None):
    return DagSpec(run_id=run, steps=steps or [StepSpec(id="a"), StepSpec(id="b", deps=["a"]), StepSpec(id="c", deps=["a"]), StepSpec(id="d", deps=["b", "c"])])


async def ok(env): return StepResult(ok=True, output={"step": env.step_id})


class Base(unittest.TestCase):
    def setUp(self):
        self.t = tempfile.TemporaryDirectory(); self.db = os.path.join(self.t.name, "harness.db")
        self.sm = StateMachine(self.db)

    def tearDown(self): self.sm.close(); self.t.cleanup()


class SchemaTests(unittest.TestCase):
    def test_cycle_unknown_dup_extra(self):
        with self.assertRaises(ValidationError): dag(steps=[StepSpec(id="a", deps=["b"]), StepSpec(id="b", deps=["a"])])
        with self.assertRaises(ValidationError): dag(steps=[StepSpec(id="a", deps=["zz"])])
        with self.assertRaises(ValidationError): dag(steps=[StepSpec(id="a"), StepSpec(id="a")])
        with self.assertRaises(ValidationError): StepSpec(id="bad id!")
        with self.assertRaises(ValidationError): StepSpec(id="a", bogus=1)


class TransitionTests(Base):
    def test_every_state_pair(self):
        """100% of (from,to) pairs: allowed ones succeed, others raise."""
        for frm in StepState:
            for to in StepState:
                sm_dag = dag(run=f"{frm.value}-{to.value}", steps=[StepSpec(id="x", max_attempts=20)])
                self.sm.create_run(sm_dag)
                path = {StepState.PENDING: [], StepState.RUNNING: [StepState.RUNNING], StepState.SUCCEEDED: [StepState.RUNNING, StepState.SUCCEEDED],
                        StepState.FAILED: [StepState.RUNNING, StepState.FAILED], StepState.ESCALATED: [StepState.RUNNING, StepState.FAILED, StepState.ESCALATED],
                        StepState.BLOCKED: [StepState.BLOCKED], StepState.CANCELLED: [StepState.CANCELLED],
                        StepState.ROLLED_BACK: [StepState.RUNNING, StepState.FAILED, StepState.ROLLED_BACK]}[frm]
                for p in path: self.sm.transition(sm_dag.run_id, "x", p)
                self.assertIs(self.sm.state(sm_dag.run_id, "x"), frm)
                if to in ALLOWED[frm]:
                    self.sm.transition(sm_dag.run_id, "x", to); self.assertIs(self.sm.state(sm_dag.run_id, "x"), to)
                else:
                    with self.assertRaises(InvalidTransition): self.sm.transition(sm_dag.run_id, "x", to)
                    self.assertIs(self.sm.state(sm_dag.run_id, "x"), frm)  # unchanged on failure

    def test_unknown_step(self):
        self.sm.create_run(dag())
        with self.assertRaises(KeyError): self.sm.transition("r1", "nope", StepState.RUNNING)
        with self.assertRaises(KeyError): self.sm.state("r1", "nope")

    def test_events_log_and_hints(self):
        self.sm.create_run(dag(steps=[StepSpec(id="a")]))
        self.sm.transition("r1", "a", StepState.RUNNING); self.sm.transition("r1", "a", StepState.FAILED, hint="boom")
        ev = self.sm.events("r1"); self.assertEqual([e.to_state for e in ev], [StepState.RUNNING, StepState.FAILED])
        self.assertEqual(self.sm.hints("r1", "a"), ["boom"])


class DagTests(Base):
    def test_branching_runs_in_dependency_order(self):
        self.sm.create_run(dag()); self.assertEqual(self.sm.ready_steps("r1"), ["a"])
        order = []
        async def h(env): order.append(env.step_id); return StepResult(ok=True)
        st = asyncio.run(self.sm.run("r1", {"task": h}))
        self.assertTrue(all(v is StepState.SUCCEEDED for v in st.values()))
        self.assertEqual(order[0], "a"); self.assertEqual(order[-1], "d"); self.assertEqual(set(order[1:3]), {"b", "c"})

    def test_failure_blocks_dependents_and_retries_bounded(self):
        self.sm.create_run(dag(steps=[StepSpec(id="a", max_attempts=2), StepSpec(id="b", deps=["a"])]))
        calls = []
        async def bad(env): calls.append(env.attempt); return StepResult(ok=False, error="nope")
        st = asyncio.run(self.sm.run("r1", {"task": bad}))
        self.assertEqual(calls, [1, 2]); self.assertIs(st["a"], StepState.FAILED); self.assertIs(st["b"], StepState.PENDING)
        self.assertEqual(self.sm.hints("r1", "a"), ["nope", "nope"])

    def test_handler_exception_becomes_failure_and_hints_propagate(self):
        self.sm.create_run(dag(steps=[StepSpec(id="a", max_attempts=2)]))
        seen = []
        async def h(env):
            seen.append(list(env.hints))
            if env.attempt == 1: raise RuntimeError("kaput")
            return StepResult(ok=True)
        st = asyncio.run(self.sm.run("r1", {"task": h}))
        self.assertIs(st["a"], StepState.SUCCEEDED); self.assertEqual(seen[1], ["RuntimeError: kaput"])

    def test_no_retry_mode(self):
        self.sm.create_run(dag(steps=[StepSpec(id="a")]))
        async def bad(env): return StepResult(ok=False, error="x")
        st = asyncio.run(self.sm.run("r1", {"task": bad}, retry_failed=False))
        self.assertIs(st["a"], StepState.FAILED); self.assertEqual(self.sm.attempts("r1", "a"), 1)

    def test_duplicate_run_rejected_atomically(self):
        self.sm.create_run(dag())
        import sqlite3
        with self.assertRaises(sqlite3.IntegrityError): self.sm.create_run(dag())
        self.assertEqual(len(self.sm.states("r1")), 4)


class PersistenceTests(Base):
    def test_state_survives_restart_and_recovers_running(self):
        self.sm.create_run(dag()); self.sm.transition("r1", "a", StepState.RUNNING)
        self.sm.close(); self.sm = StateMachine(self.db)
        self.assertIs(self.sm.state("r1", "a"), StepState.RUNNING)
        self.assertEqual(self.sm.recover_interrupted("r1"), ["a"]); self.assertIs(self.sm.state("r1", "a"), StepState.FAILED)
        st = asyncio.run(self.sm.run("r1", {"task": ok})); self.assertIs(st["d"], StepState.SUCCEEDED)

    def test_hard_kill_midrun_is_atomic(self):
        code = ("import sys,os,asyncio;sys.path.insert(0,%r)\n"
                "from harness.orchestrator.state_machine import *;from harness.orchestrator.models import *\n"
                "sm=StateMachine(%r);sm.create_run(DagSpec(run_id='k',steps=[StepSpec(id='a'),StepSpec(id='b',deps=['a'])]))\n"
                "async def h(e):\n  os._exit(9) if e.step_id=='b' else None\n  return StepResult(ok=True)\n"
                "asyncio.run(sm.run('k',{'task':h}))\n") % (str(Path(__file__).resolve().parent.parent), self.db)
        self.assertEqual(subprocess.run([sys.executable, "-c", code]).returncode, 9)
        sm2 = StateMachine(self.db)
        self.assertIs(sm2.state("k", "a"), StepState.SUCCEEDED); self.assertIs(sm2.state("k", "b"), StepState.RUNNING)
        sm2.recover_interrupted("k"); self.assertIs(sm2.state("k", "b"), StepState.FAILED); sm2.close()


class LatencyTests(Base):
    def test_transition_under_1ms(self):
        n = 500
        self.sm.create_run(dag(steps=[StepSpec(id=f"s{i}", max_attempts=1) for i in range(n)]))
        t = time.perf_counter()
        for i in range(n): self.sm.transition("r1", f"s{i}", StepState.RUNNING)
        per = (time.perf_counter() - t) / n * 1000
        print(f"\n  avg transition latency: {per:.3f} ms")
        self.assertLess(per, 1.0)


if __name__ == "__main__":
    unittest.main()
