"""Comprehensive unit tests for runtime engine adapters and dynamic detection."""
from __future__ import annotations

import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))

from harness.runtime import (
    AgyRuntimeAdapter,
    BaseRuntimeAdapter,
    ClaudeRuntimeAdapter,
    OpenCodeRuntimeAdapter,
    detect_runtime_adapter,
    get_runtime_adapter,
)


class TestRuntimeAdapters(unittest.TestCase):
    def test_get_runtime_adapter_aliases(self):
        self.assertIsInstance(get_runtime_adapter("agy"), AgyRuntimeAdapter)
        self.assertIsInstance(get_runtime_adapter("antigravity"), AgyRuntimeAdapter)
        self.assertIsInstance(get_runtime_adapter("gemini"), AgyRuntimeAdapter)
        self.assertIsInstance(get_runtime_adapter("AGY"), AgyRuntimeAdapter)

        self.assertIsInstance(get_runtime_adapter("claude"), ClaudeRuntimeAdapter)
        self.assertIsInstance(get_runtime_adapter("anthropic"), ClaudeRuntimeAdapter)

        self.assertIsInstance(get_runtime_adapter("opencode"), OpenCodeRuntimeAdapter)
        self.assertIsInstance(get_runtime_adapter("sglang"), OpenCodeRuntimeAdapter)

    def test_get_runtime_adapter_invalid(self):
        with self.assertRaises(ValueError) as ctx:
            get_runtime_adapter("unknown-engine")
        self.assertIn("Supported targets", str(ctx.exception))

    def test_adapter_properties_and_methods(self):
        for target in ("agy", "claude", "opencode"):
            adapter = get_runtime_adapter(target)
            self.assertTrue(len(adapter.target_name) > 0)
            self.assertTrue(len(adapter.display_name) > 0)
            self.assertTrue(len(adapter.charter_filename) > 0)
            self.assertTrue(len(adapter.config_dir_name) > 0)
            self.assertIsInstance(adapter.global_config_dir, Path)

            tools = adapter.get_tool_definitions()
            self.assertIn("worktree_manager.py", tools)
            self.assertIn("tdd_pipeline.py", tools)

            charter_path = adapter.get_charter_path("/tmp/test_repo")
            self.assertEqual(charter_path.name, adapter.charter_filename)

            handoff_path = adapter.get_handoff_path("/tmp/test_repo")
            self.assertEqual(handoff_path.name, "handoffs")

            worktree_path = adapter.get_worktree_path("/tmp/test_repo", "feat/my-branch")
            self.assertTrue(str(worktree_path).endswith("feat/my-branch"))

    def test_agy_model_tiers_gemini38(self):
        adapter = AgyRuntimeAdapter()
        tiers = adapter.model_tiers
        self.assertEqual(tiers["architect"]["model"], "gemini-3.8-flash-high")
        self.assertEqual(tiers["worker"]["model"], "gemini-3.8-flash-medium")
        self.assertEqual(tiers["reviewer"]["model"], "gemini-3.8-flash-medium")
        self.assertEqual(tiers["scout"]["model"], "gemini-3.8-flash-low")
        self.assertEqual(tiers["grunt"]["model"], "gemini-3.8-flash-low")

    def test_claude_settings_merge(self):
        adapter = ClaudeRuntimeAdapter()
        base = {
            "permissions": {
                "deny": ["git push*"],
            },
            "theme": "dark",
        }
        override1 = {
            "permissions": {
                "deny": ["gh pr merge*"],
                "allow": ["read_file"],
            },
        }
        override2 = {
            "theme": "light",
            "auto_updater": False,
        }
        merged = adapter.merge_json_settings(base, override1, override2)
        self.assertEqual(merged["theme"], "light")
        self.assertEqual(merged["auto_updater"], False)
        self.assertEqual(merged["permissions"]["allow"], ["read_file"])
        self.assertIn("git push*", merged["permissions"]["deny"])
        self.assertIn("gh pr merge*", merged["permissions"]["deny"])

    def test_opencode_model_tiers(self):
        adapter = OpenCodeRuntimeAdapter()
        tiers = adapter.model_tiers
        self.assertIn("supreme-orchestrator", tiers)
        self.assertIn("worker", tiers)
        self.assertEqual(tiers["supreme-orchestrator"]["sglang_port"], 30000)


class TestDynamicRuntimeDetection(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.mock_root = Path(self.tmp.name)

    def tearDown(self):
        self.tmp.cleanup()

    def test_detect_claude(self):
        (self.mock_root / "CLAUDE.md").write_text("# Claude Charter\n", encoding="utf-8")
        adapter = detect_runtime_adapter(self.mock_root)
        self.assertIsInstance(adapter, ClaudeRuntimeAdapter)

    def test_detect_opencode_from_json(self):
        (self.mock_root / "opencode.json").write_text("{}", encoding="utf-8")
        adapter = detect_runtime_adapter(self.mock_root)
        self.assertIsInstance(adapter, OpenCodeRuntimeAdapter)

    def test_detect_opencode_from_agents_md(self):
        (self.mock_root / "AGENTS.md").write_text("# OpenCode Charter\n", encoding="utf-8")
        adapter = detect_runtime_adapter(self.mock_root)
        self.assertIsInstance(adapter, OpenCodeRuntimeAdapter)

    def test_detect_agy_from_gemini_md(self):
        (self.mock_root / "GEMINI.md").write_text("# Antigravity Charter\n", encoding="utf-8")
        adapter = detect_runtime_adapter(self.mock_root)
        self.assertIsInstance(adapter, AgyRuntimeAdapter)

    def test_detect_default_empty_repo(self):
        adapter = detect_runtime_adapter(self.mock_root)
        self.assertIsInstance(adapter, AgyRuntimeAdapter)


if __name__ == "__main__":
    unittest.main()
