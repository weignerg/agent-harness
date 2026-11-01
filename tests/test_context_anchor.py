import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))

from harness.memory.context_anchor import ContextAnchorInjector

class TestContextAnchor(unittest.TestCase):
    def setUp(self):
        self.injector = ContextAnchorInjector(rules_path=ROOT / "config/agy/GEMINI.md")

    def test_byte_stable_prefix(self):
        p1 = self.injector.format_prefix("Milestone 6", "Task 6.2")
        p2 = self.injector.format_prefix("Milestone 6", "Task 6.2")
        self.assertEqual(p1, p2)
        self.assertIn("Antigravity", p1)
        self.assertIn("Milestone: Milestone 6", p1)

    def test_milestone_reset(self):
        reset = self.injector.reset_context_for_milestone("Milestone 7")
        self.assertIn("Milestone: Milestone 7", reset)
        self.assertIn("Task: INIT", reset)

if __name__ == "__main__":
    unittest.main()
