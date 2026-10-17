"""Comprehensive unit tests for polymorphic memory: context anchoring and task handoffs."""
from __future__ import annotations

import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))

from harness.memory.context_anchor import ContextAnchorInjector
from harness.memory.handoff import TaskHandoff


class TestPolymorphicContextAnchor(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.mock_root = Path(self.tmp.name)

    def tearDown(self):
        self.tmp.cleanup()

    def test_priority1_orchestration_rule_detection(self):
        orch_rule = self.mock_root / ".orchestration" / "rules" / "agent-teams.md"
        orch_rule.parent.mkdir(parents=True, exist_ok=True)
        orch_rule.write_text("Canonical Orchestration Ground Truth", encoding="utf-8")

        # Also create a lower priority file to ensure priority 1 wins
        gemini_file = self.mock_root / "GEMINI.md"
        gemini_file.write_text("Gemini Ground Truth", encoding="utf-8")

        injector = ContextAnchorInjector(base_dir=self.mock_root)
        rules = injector.get_ground_truth_rules()
        self.assertEqual(rules, "Canonical Orchestration Ground Truth")
        self.assertEqual(injector.rules_path, orch_rule)

    def test_priority2_root_charter_detection(self):
        claude_file = self.mock_root / "CLAUDE.md"
        claude_file.write_text("Claude Ground Truth", encoding="utf-8")

        injector = ContextAnchorInjector(base_dir=self.mock_root)
        rules = injector.get_ground_truth_rules()
        self.assertEqual(rules, "Claude Ground Truth")
        self.assertEqual(injector.rules_path, claude_file)

    def test_priority3_engine_rules_fallback(self):
        opencode_rule = self.mock_root / ".opencode" / "rules" / "agent-teams.md"
        opencode_rule.parent.mkdir(parents=True, exist_ok=True)
        opencode_rule.write_text("OpenCode Rules Ground Truth", encoding="utf-8")

        injector = ContextAnchorInjector(base_dir=self.mock_root)
        rules = injector.get_ground_truth_rules()
        self.assertEqual(rules, "OpenCode Rules Ground Truth")
        self.assertEqual(injector.rules_path, opencode_rule)

    def test_explicit_rules_path_override(self):
        custom_file = self.mock_root / "custom_rules.md"
        custom_file.write_text("Custom Rules Content", encoding="utf-8")

        injector = ContextAnchorInjector(rules_path=custom_file)
        self.assertEqual(injector.get_ground_truth_rules(), "Custom Rules Content")

    def test_default_fallback_when_empty(self):
        injector = ContextAnchorInjector(base_dir=self.mock_root)
        self.assertEqual(injector.get_ground_truth_rules(), "Standard Agent Harness Rules")

    def test_byte_stable_prefix_and_reset(self):
        charter = self.mock_root / "GEMINI.md"
        charter.write_text("Ground Truth Content", encoding="utf-8")
        injector = ContextAnchorInjector(rules_path=charter)

        p1 = injector.format_prefix("Milestone 1", "Task 1.1")
        p2 = injector.format_prefix("Milestone 1", "Task 1.1")
        self.assertEqual(p1, p2)
        self.assertIn("=== ANCHOR_START ===", p1)
        self.assertIn("Milestone: Milestone 1", p1)
        self.assertIn("Task: Task 1.1", p1)

        reset = injector.reset_context_for_milestone("Milestone 2")
        self.assertIn("Milestone: Milestone 2", reset)
        self.assertIn("Task: INIT", reset)


class TestPolymorphicTaskHandoff(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.mock_root = Path(self.tmp.name)

    def tearDown(self):
        self.tmp.cleanup()

    def test_priority1_orchestration_handoffs_detection(self):
        orch_handoffs = self.mock_root / ".orchestration" / "handoffs"
        orch_handoffs.mkdir(parents=True, exist_ok=True)

        # Also create lower priority directory
        claude_handoffs = self.mock_root / ".claude" / "handoffs"
        claude_handoffs.mkdir(parents=True, exist_ok=True)

        th = TaskHandoff(base_dir=self.mock_root)
        self.assertEqual(th.handoff_dir.resolve(), orch_handoffs.resolve())

    def test_fallback_engine_handoffs_detection(self):
        claude_handoffs = self.mock_root / ".claude" / "handoffs"
        claude_handoffs.mkdir(parents=True, exist_ok=True)

        th = TaskHandoff(base_dir=self.mock_root)
        self.assertEqual(th.handoff_dir.resolve(), claude_handoffs.resolve())

    def test_default_clean_directory_when_starting_fresh(self):
        th = TaskHandoff(base_dir=self.mock_root)
        expected = self.mock_root / ".orchestration" / "handoffs"
        self.assertEqual(th.handoff_dir.resolve(), expected.resolve())
        self.assertTrue(expected.is_dir())

    def test_discrete_per_task_lifecycle(self):
        th = TaskHandoff(base_dir=self.mock_root)
        file_path = th.write_handoff(
            task_id="issue-1-core",
            task_title="Canonical Core Base",
            status="Complete",
            affected_files=["harness/runtime/base.py"],
            summary="Implemented polymorphic memory and runtime engine adapters.",
            remaining_todos=["Execute integration tests"],
        )
        p = Path(file_path)
        self.assertTrue(p.is_file())
        self.assertEqual(p.name, "TASK_HANDOFF_issue-1-core.md")

        content = th.get_handoff("issue-1-core")
        self.assertIsNotNone(content)
        self.assertIn("Canonical Core Base", content)
        self.assertIn("harness/runtime/base.py", content)

        handoffs = th.list_handoffs()
        self.assertEqual(len(handoffs), 1)

        self.assertTrue(th.clean_handoff("issue-1-core"))
        self.assertEqual(len(th.list_handoffs()), 0)


if __name__ == "__main__":
    unittest.main()
