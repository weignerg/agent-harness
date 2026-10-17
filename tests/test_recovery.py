import os, sys, tempfile, unittest
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
from harness.orchestrator.models import DagSpec, StepSpec, StepState
from harness.orchestrator.recovery import CheckpointError, CheckpointManager, self_heal
from harness.orchestrator.state_machine import StateMachine


class T(unittest.TestCase):
    def setUp(self):
        self.t = tempfile.TemporaryDirectory(); self.w = Path(self.t.name) / "work"; self.w.mkdir()
        self.sm = StateMachine(os.path.join(self.t.name, "h.db"))
        self.sm.create_run(DagSpec(run_id="r", steps=[StepSpec(id="a"), StepSpec(id="b", deps=["a"])]))
        self.m = CheckpointManager(self.sm, self.w)

    def tearDown(self): self.sm.close(); self.t.cleanup()


class Rollback(T):
    def test_restores_files_and_db_state(self):
        (self.w / "f.txt").write_text("orig"); ck = self.m.create("r", "pre", ["f.txt", "new.txt"]); self.m.mark_valid(ck)
        (self.w / "f.txt").write_text("CORRUPT"); (self.w / "new.txt").write_text("created later")
        self.sm.transition("r", "a", StepState.RUNNING); self.sm.transition("r", "a", StepState.SUCCEEDED)
        self.assertEqual(self.m.rollback("r"), ck)
        self.assertEqual((self.w / "f.txt").read_text(), "orig"); self.assertFalse((self.w / "new.txt").exists())
        self.assertIs(self.sm.state("r", "a"), StepState.PENDING); self.assertEqual(self.sm.attempts("r", "a"), 0)
        self.assertIs(self.sm.events("r")[-1].to_state, StepState.ROLLED_BACK)

    def test_nearest_valid_and_tiers(self):
        (self.w / "f").write_text("1"); c1 = self.m.create("r", "one", ["f"], "run"); self.m.mark_valid(c1)
        (self.w / "f").write_text("2"); c2 = self.m.create("r", "two", ["f"]); self.m.mark_valid(c2)
        (self.w / "f").write_text("3"); self.m.create("r", "invalid", ["f"])  # never validated
        self.assertEqual(self.m.nearest_valid("r"), c2); self.assertEqual(self.m.nearest_valid("r", "run"), c1)
        self.m.rollback("r"); self.assertEqual((self.w / "f").read_text(), "2")
        self.m.rollback("r", c1); self.assertEqual((self.w / "f").read_text(), "1")

    def test_errors(self):
        with self.assertRaises(CheckpointError): self.m.rollback("r")
        with self.assertRaises(CheckpointError): self.m.create("r", "x", ["../escape"])
        with self.assertRaises(CheckpointError): self.m.create("r", "x", ["f"], tier="bogus")
        with self.assertRaises(CheckpointError): self.m.rollback("r", 999)

    def test_checkpoint_persists_across_restart(self):
        (self.w / "f").write_text("keep"); ck = self.m.create("r", "p", ["f"]); self.m.mark_valid(ck)
        self.sm.close(); self.sm = StateMachine(os.path.join(self.t.name, "h.db")); self.m = CheckpointManager(self.sm, self.w)
        (self.w / "f").write_text("bad"); self.m.rollback("r"); self.assertEqual((self.w / "f").read_text(), "keep")


class Heal(T):
    def setUp(self):
        super().setUp(); (self.w / "code.py").write_text("x = 1\n")
        self.validate = lambda: None if "good" in (self.w / "code.py").read_text() else "missing good marker"

    def test_heals_with_hints_passed_forward(self):
        seen = []
        def action(hints):
            seen.append(list(hints)); (self.w / "code.py").write_text("good\n" if len(seen) == 2 else f"try{len(seen)}\n"); return f"sig{len(seen)}"
        (self.w / "code.py").write_text("good\n"); self.validate()  # sanity
        (self.w / "code.py").write_text("bad\n")
        o = self_heal(self.m, "r", ["code.py"], action, self.validate, budget=3)
        self.assertTrue(o.healed); self.assertEqual(o.attempts, 2); self.assertEqual(seen[0], [])
        self.assertIn("Do NOT repeat: sig1", seen[1][0])

    def test_budget_exhaustion_rolls_back_cleanly(self):
        (self.w / "code.py").write_text("good\n"); ck = self.m.create("r", "known-good", ["code.py"]); self.m.mark_valid(ck)
        n = []
        def action(h): n.append(1); (self.w / "code.py").write_text(f"broken{len(n)}\n"); return f"s{len(n)}"
        o = self_heal(self.m, "r", ["code.py"], action, self.validate, budget=3)
        self.assertFalse(o.healed); self.assertTrue(o.rolled_back); self.assertEqual(len(n), 3); self.assertIn("exhausted", o.reason)
        self.assertEqual((self.w / "code.py").read_text(), "good\n")

    def test_identical_failing_approach_stops_early(self):
        def action(h): (self.w / "code.py").write_text("nope\n"); return "same"
        o = self_heal(self.m, "r", ["code.py"], action, self.validate, budget=5)
        self.assertEqual((o.healed, o.attempts), (False, 2)); self.assertIn("identical", o.reason)
        self.assertEqual((self.w / "code.py").read_text(), "x = 1\n")  # restored to pre-mutation file


if __name__ == "__main__":
    unittest.main()
