"""Unit tests for the Deterministic Subagent Frontmatter Compiler (Issue #14)."""
from __future__ import annotations

import tempfile
import unittest
from pathlib import Path

from harness.installer.compiler import compile_agents, compile_agy_frontmatter

REPO_ROOT = Path(__file__).resolve().parent.parent
CORE_DIR = REPO_ROOT / "core"
CONFIG_DIR = REPO_ROOT / "config"


class TestCompilerFrontmatter(unittest.TestCase):
    def setUp(self):
        self.temp_dir = tempfile.TemporaryDirectory()
        self.output_dir = Path(self.temp_dir.name)

    def tearDown(self):
        self.temp_dir.cleanup()

    def test_compile_agy_native_tools_and_permissions(self):
        """Verify AGY agent frontmatter matches canonical v1.4.12+ tools and hierarchy."""
        compiled = compile_agents(
            core_dir=CORE_DIR,
            target_runtime="agy",
            output_dir=self.output_dir,
        )
        self.assertGreaterEqual(len(compiled), 8)

        # Map role -> compiled text
        role_texts = {}
        for p in compiled:
            role_texts[p.stem] = p.read_text(encoding="utf-8")

        all_roles = [
            "supreme-orchestrator",
            "team-orchestrator",
            "architect",
            "worker",
            "tester",
            "reviewer",
            "scout",
            "grunt",
        ]
        read_write_roles = ["worker", "tester", "grunt"]
        read_only_roles = [r for r in all_roles if r not in read_write_roles]

        subagent_callers = [
            "supreme-orchestrator",
            "team-orchestrator",
            "architect",
            "worker",
            "tester",
            "reviewer",
        ]
        silent_leaves = ["scout", "grunt"]

        for role in all_roles:
            self.assertIn(role, role_texts, f"Role {role} missing from compiled output")
            text = role_texts[role]

            # 1. read_file and send_message must be present in ALL roles
            self.assertIn("- read_file", text, f"Role {role} must have read_file")
            self.assertIn("- send_message", text, f"Role {role} must have send_message")

            # 2. edit_file and write_file only in read-write roles
            if role in read_write_roles:
                self.assertIn("- edit_file", text, f"Role {role} must have edit_file")
                self.assertIn("- write_file", text, f"Role {role} must have write_file")
            else:
                self.assertNotIn("- edit_file", text, f"Role {role} must NOT have edit_file")
                self.assertNotIn("- write_file", text, f"Role {role} must NOT have write_file")

            # 3. invoke_subagent only in caller roles, NEVER in silent leaves
            if role in subagent_callers:
                self.assertIn("- invoke_subagent", text, f"Role {role} must have invoke_subagent")
            if role in silent_leaves:
                self.assertNotIn("- invoke_subagent", text, f"Leaf role {role} must NEVER have invoke_subagent")
                self.assertNotIn("- manage_subagents", text, f"Leaf role {role} must NEVER have manage_subagents")

        # Architectural search web permission
        self.assertIn("- search_web", role_texts["architect"])
        self.assertIn("- search_web", role_texts["reviewer"])

    def test_compile_agy_frontmatter_invariant_filtering(self):
        """Verify compile_agy_frontmatter enforces readonly stripping and leaf tool restrictions."""
        tier_models = {
            "workhorse": {"agy": "flash", "agy_model_id": "gemini-3.8-flash-medium"},
            "fast": {"agy": "flash_lite", "agy_model_id": "gemini-3.8-flash-low"},
        }

        # 1. Read-only role with illegal mutating tools injected in agy_tools
        ro_meta = {
            "tier": "workhorse",
            "readonly": True,
            "agy_tools": ["read_file", "edit_file", "write_file", "replace_file_content", "write_to_file", "send_message"],
        }
        ro_fm = compile_agy_frontmatter("reviewer", ro_meta, tier_models)
        self.assertIn("- read_file", ro_fm)
        self.assertIn("- send_message", ro_fm)
        self.assertNotIn("- edit_file", ro_fm)
        self.assertNotIn("- write_file", ro_fm)
        self.assertNotIn("- replace_file_content", ro_fm)
        self.assertNotIn("- write_to_file", ro_fm)

        # 2. Leaf role with illegal spawning tools injected in agy_tools and missing send_message
        leaf_meta = {
            "tier": "fast",
            "readonly": True,
            "agy_tools": ["read_file", "invoke_subagent", "manage_subagents"],
        }
        leaf_fm = compile_agy_frontmatter("scout", leaf_meta, tier_models)
        self.assertIn("- read_file", leaf_fm)
        self.assertIn("- send_message", leaf_fm)
        self.assertNotIn("- invoke_subagent", leaf_fm)
        self.assertNotIn("- manage_subagents", leaf_fm)

    def test_gemini_md_documents_tools_and_mechanisms(self):
        """Verify config/agy/GEMINI.md documents canonical tools and background mechanisms."""
        gemini_md = CONFIG_DIR / "agy" / "GEMINI.md"
        self.assertTrue(gemini_md.is_file())
        text = gemini_md.read_text(encoding="utf-8")

        required_symbols = [
            "read_file",
            "edit_file",
            "write_file",
            "invoke_subagent",
            "manage_subagents",
            "agy remote-control",
        ]
        for sym in required_symbols:
            self.assertIn(sym, text, f"config/agy/GEMINI.md must document {sym}")

    def test_compile_opencode_and_claude(self):
        """Verify OpenCode and Claude Code frontmatter compilation integrity."""
        # OpenCode
        opencode_dir = self.output_dir / "opencode"
        compile_agents(core_dir=CORE_DIR, target_runtime="opencode", output_dir=opencode_dir)
        scout_opencode = (opencode_dir / "scout.md").read_text(encoding="utf-8")
        self.assertIn("task: deny", scout_opencode)
        team_opencode = (opencode_dir / "team-orchestrator.md").read_text(encoding="utf-8")
        self.assertIn("task: allow", team_opencode)

        # Claude
        claude_dir = self.output_dir / "claude"
        compile_agents(core_dir=CORE_DIR, target_runtime="claude", output_dir=claude_dir)
        worker_claude = (claude_dir / "worker.md").read_text(encoding="utf-8")
        self.assertIn("tools: Read, Edit, Write, Grep, Glob, Bash", worker_claude)
        self.assertIn("model: sonnet", worker_claude)


if __name__ == "__main__":
    unittest.main()
