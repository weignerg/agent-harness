import asyncio, os, sys, tempfile, unittest
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
from harness.orchestrator import reviewer as R
from harness.orchestrator.models import StepResult, StepSpec, StepState
from harness.orchestrator.state_machine import StateMachine


class Repo(unittest.TestCase):
    def setUp(self):
        self.t = tempfile.TemporaryDirectory(); self.p = Path(self.t.name)

    def tearDown(self): self.t.cleanup()

    def w(self, name, text): (self.p / name).write_text(text)

    REQ = [R.Requirement("R1", "must expose add()", "calc.py", r"def add\(", forbidden=r"def subtract\(")]


class Pillars(Repo):
    def good(self):
        self.w("calc.py", "def add(a, b):\n    return a + b\n"); self.w("test_ok.sh", "#!/bin/sh\nexit 0\n")

    def test_clean_change_passes(self):
        self.good(); rep = R.review(self.p, test_cmd=["sh", "test_ok.sh"], files=["calc.py"], requirements=self.REQ)
        self.assertTrue(rep.passed, rep.summary())

    def test_catches_intentional_bug_via_failing_tests(self):
        self.w("calc.py", "def add(a, b):\n    return a - b\n"); self.w("t.sh", "#!/bin/sh\necho 'assert 3 == -1' >&2\nexit 1\n")
        rep = R.review(self.p, test_cmd=["sh", "t.sh"], files=["calc.py"], requirements=self.REQ)
        self.assertFalse(rep.passed); self.assertIn("tests failed (exit 1)", rep.summary())

    def test_catches_security_regressions(self):
        self.w("calc.py", "import os, subprocess\ndef add(a,b):\n    eval('1')\n    subprocess.run('x', shell=True)\n"
                          "    api_key = 'abcd1234efgh5678'\n    return a+b\n")
        self.w("t.sh", "exit 0\n"); rep = R.review(self.p, test_cmd=["sh", "t.sh"], files=["calc.py"], requirements=self.REQ)
        s = rep.summary(); self.assertIn("eval() call", s); self.assertIn("shell=True", s); self.assertIn("hard-coded credential", s)

    def test_catches_syntax_error(self):
        self.w("calc.py", "def add(a, b)\n    return a\n"); self.w("t.sh", "exit 0\n")
        self.assertIn("syntax error", R.review(self.p, test_cmd=["sh", "t.sh"], files=["calc.py"], requirements=[]).summary())

    def test_catches_prompt_deviation(self):
        self.w("calc.py", "def multiply(a,b):\n    return a*b\ndef subtract(a,b):\n    return a-b\n"); self.w("t.sh", "exit 0\n")
        s = R.review(self.p, test_cmd=["sh", "t.sh"], files=["calc.py"], requirements=self.REQ).summary()
        self.assertIn("R1: not satisfied", s); self.assertIn("forbidden deviation", s)

    def test_missing_file_and_missing_test_cmd_and_timeout(self):
        self.assertIn("missing", R.check_alignment(self.p, self.REQ)[0].message)
        self.assertFalse(R.review(self.p, test_cmd=None, files=[], requirements=[]).passed)
        self.w("slow.sh", "sleep 5\n"); self.assertIn("timed out", R.check_execution(self.p, ["sh", "slow.sh"], timeout=0.3)[0].message)
        self.assertIn("not found", R.check_execution(self.p, ["definitely-not-a-cmd"])[0].message)

    def test_comment_mentions_do_not_trigger(self):
        self.w("c.py", "# never use eval( here\nx = 1\n"); self.assertEqual(R.check_security(self.p, ["c.py"]), [])


class Consensus(Repo):
    def rep(self, ok, pillar="alignment"):
        return R.Report("r", [] if ok else [R.Finding(pillar, "x")])

    def test_rules(self):
        D = R.Decision
        self.assertEqual(R.consensus([self.rep(True), self.rep(True)]), D.APPROVED)
        self.assertEqual(R.consensus([self.rep(False), self.rep(False)]), D.REJECTED)
        self.assertEqual(R.consensus([self.rep(True), self.rep(False)]), D.HUMAN_GATE)
        self.assertEqual(R.consensus([self.rep(True), self.rep(False)], human=lambda r: True), D.APPROVED)
        self.assertEqual(R.consensus([self.rep(True), self.rep(False)], human=lambda r: False), D.REJECTED)
        self.assertEqual(R.consensus([self.rep(True), self.rep(False, "execution")], human=lambda r: True), D.REJECTED)  # evidence wins
        self.assertEqual(R.consensus([]), D.REJECTED)


class DagGate(Repo):
    def run_dag(self, ok_code):
        self.w("calc.py", "def add(a,b):\n    return a+b\n"); self.w("t.sh", f"exit {ok_code}\n")
        db = StateMachine(os.path.join(self.t.name, "h.db"))
        dag = R.with_review_gate("g", [StepSpec(id="work")])
        db.create_run(dag)
        async def work(env): return StepResult(ok=True)
        async def done(env): return StepResult(ok=True)
        st = asyncio.run(db.run("g", {"task": work, "complete": done, "review": R.reviewer_handler(self.p, ["sh", "t.sh"], ["calc.py"], self.REQ)}))
        db.close(); return st

    def test_completion_requires_reviewer_pass(self):
        st = self.run_dag(0); self.assertIs(st["complete"], StepState.SUCCEEDED)

    def test_failed_review_blocks_completion(self):
        st = self.run_dag(1); self.assertIs(st["review"], StepState.FAILED); self.assertIs(st["complete"], StepState.PENDING)


if __name__ == "__main__":
    unittest.main()
