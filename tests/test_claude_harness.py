"""Unit and integration tests for Claude Code integration in unified agent-harness."""
from __future__ import annotations

import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path

from harness.memory.context_anchor import ContextAnchorInjector
from harness.memory.handoff import TaskHandoff
from scripts.worktree_manager import WorktreeManager

REPO_ROOT = Path(__file__).resolve().parent.parent
TEMPLATE_DIR = REPO_ROOT / "templates" / "claude"
AGENTS_DIR = TEMPLATE_DIR / "agents"

EXPECTED_AGENTS = {
    "architect.md": ("opus", "architect"),
    "worker.md": ("sonnet", "worker"),
    "reviewer.md": ("sonnet", "reviewer"),
    "tester.md": ("sonnet", "tester"),
    "scout.md": ("haiku", "scout"),
    "grunt.md": ("haiku", "grunt"),
}

EXPECTED_SKILLS = {
    "adversarial-review",
    "context-anchoring",
    "sglang-management",
    "tdd-pipeline",
    "vault-retrieval",
    "worktree-lifecycle",
    "read-only-block",
}


class TestClaudeHarnessStructure(unittest.TestCase):
    def test_repo_root_has_no_tracked_active_harness_dirs_or_charters(self):
        for forbidden in (".opencode", "AGENTS.md", "GEMINI.md", "CLAUDE.md", "opencode.json"):
            self.assertFalse(
                (REPO_ROOT / forbidden).exists(),
                f"Forbidden root path present in agent-harness: {forbidden}",
            )
        proc = subprocess.run(
            ["git", "ls-files", ".claude", ".opencode", ".agents", "AGENTS.md", "GEMINI.md", "CLAUDE.md", "opencode.json"],
            cwd=REPO_ROOT,
            capture_output=True,
            text=True,
            check=False,
        )
        self.assertEqual(proc.stdout.strip(), "")

    def test_gitignore_blocks_active_harness_paths(self):
        gitignore_text = (REPO_ROOT / ".gitignore").read_text(encoding="utf-8")
        for required_entry in (".claude/", ".opencode/", ".agents/", "CLAUDE.md", "AGENTS.md", "GEMINI.md"):
            self.assertIn(required_entry, gitignore_text)

    def test_all_canonical_agents_defined_with_proper_models(self):
        for filename, (expected_model, expected_name) in EXPECTED_AGENTS.items():
            agent_file = AGENTS_DIR / filename
            self.assertTrue(agent_file.is_file(), f"Missing canonical agent: {filename}")
            content = agent_file.read_text(encoding="utf-8")
            self.assertIn(f"name: {expected_name}", content)
            self.assertIn(f"model: {expected_model}", content)

    def test_skills_catalog_complete(self):
        skills_dir = TEMPLATE_DIR / "skills"
        self.assertTrue(skills_dir.is_dir(), "skills directory missing in templates/claude")
        present_skills = {p.name for p in skills_dir.iterdir() if p.is_dir()}
        for expected in EXPECTED_SKILLS:
            self.assertIn(expected, present_skills)
            skill_md = skills_dir / expected / "SKILL.md"
            self.assertTrue(skill_md.is_file(), f"Missing SKILL.md in {expected}")

    def test_read_only_block_files(self):
        ro_dir = TEMPLATE_DIR / "orchestration" / "read-only-block"
        self.assertTrue(ro_dir.is_dir())
        self.assertTrue((ro_dir / "block-external-writes.py").is_file())
        self.assertTrue((ro_dir / "settings.json").is_file())
        settings_data = json.loads((ro_dir / "settings.json").read_text(encoding="utf-8"))
        denied = settings_data.get("permissions", {}).get("deny", [])
        self.assertIn("mcp__github__create_issue", denied)
        self.assertIn("mcp__github__create_pull_request", denied)
        self.assertIn("mcp__github__merge_pull_request", denied)
        self.assertIn("mcp__github__create_or_update_file_contents", denied)
        self.assertIn("Bash(gh pr merge*)", denied)
        self.assertIn("Bash(git push*)", denied)

    def test_worktree_manager_claude_default_path(self):
        mgr = WorktreeManager(repo_dir=REPO_ROOT, runtime="claude")
        default_path = mgr.default_worktree_path("feat/test-branch")
        self.assertIn(".claude", str(default_path))
        self.assertTrue(str(default_path).endswith("feat/test-branch"))


if __name__ == "__main__":
    unittest.main()
