import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))

from scripts.gh_pr_automation import GitHubPRAutomation

class TestGitHubPRAutomation(unittest.TestCase):
    def setUp(self):
        self.auto = GitHubPRAutomation()

    def test_parse_ci_log_failures(self):
        sample_log = """
test_one (tests.test_a.TestA) ... ok
FAIL: test_two (tests.test_b.TestB)
Traceback (most recent call last):
  AssertionError: expected True but got False
ERROR: test_three (tests.test_c.TestC)
RuntimeError: timeout
"""
        failures = self.auto.parse_ci_log_failures(sample_log)
        self.assertEqual(len(failures), 2)
        self.assertEqual(failures[0]["test"], "test_two")
        self.assertEqual(failures[0]["type"], "FAIL")
        self.assertEqual(failures[1]["test"], "test_three")
        self.assertEqual(failures[1]["type"], "ERROR")

if __name__ == "__main__":
    unittest.main()
