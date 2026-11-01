"""Unit tests for compiler and Claude Code experimental agent-teams integration."""
from __future__ import annotations

import json
import tempfile
import unittest
from pathlib import Path

from harness.installer.compiler import compile_agents, compile_claude_frontmatter

REPO_ROOT = Path(__file__).resolve().parent.parent
CORE_DIR = REPO_ROOT / "core"
CONFIG_DIR = REPO_ROOT / "config"


class TestClaudeSettingsCore(unittest.TestCase):
    def setUp(self):
        self.core_settings_path = CONFIG_DIR / "claude" / "settings" / "core.json"
        self.assertTrue(self.core_settings_path.is_file(), f"Missing {self.core_settings_path}")
        self.settings = json.loads(self.core_settings_path.read_text(encoding="utf-8"))

    def test_experimental_agent_teams_env_flag(self):
        env = self.settings.get("env", {})
        self.assertEqual(env.get("CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS"), "1")

    def test_background_session_allow_permissions(self):
        perms = self.settings.get("permissions", {})
        allowed = perms.get("allow", [])
        expected_allow = [
            "Bash(claude --bg *)",
            "Bash(claude --background *)",
            "Bash(claude agents*)",
            "Bash(claude logs *)",
        ]
        for rule in expected_allow:
            self.assertIn(rule, allowed, f"Missing allow rule in core.json: {rule}")

    def test_orchestrator_non_termination_deny_permissions(self):
        perms = self.settings.get("permissions", {})
        denied = perms.get("deny", [])
        expected_deny = [
            "Bash(claude stop *)",
            "Bash(claude kill *)",
            "Bash(claude rm *)",
        ]
        for rule in expected_deny:
            self.assertIn(rule, denied, f"Missing deny rule in core.json: {rule}")


class TestManifestAndCompiledClaudeAgents(unittest.TestCase):
    def setUp(self):
        self.manifest_path = CORE_DIR / "manifest.json"
        self.assertTrue(self.manifest_path.is_file(), f"Missing {self.manifest_path}")
        self.manifest = json.loads(self.manifest_path.read_text(encoding="utf-8"))
        self.roles = self.manifest.get("roles", {})

    def test_manifest_claude_tools_task_distribution(self):
        task_allowed_roles = [
            "supreme-orchestrator",
            "team-orchestrator",
            "architect",
            "worker",
            "tester",
            "reviewer",
        ]
        task_denied_roles = [
            "scout",
            "grunt",
            "compaction",
            "summary",
        ]

        for role_name in task_allowed_roles:
            self.assertIn(role_name, self.roles, f"Role {role_name} missing from manifest")
            tools_str = self.roles[role_name].get("claude_tools", "")
            tools = [t.strip() for t in tools_str.split(",") if t.strip()]
            self.assertIn("Task", tools, f"Role {role_name} in manifest must include Task in claude_tools")

        for role_name in task_denied_roles:
            self.assertIn(role_name, self.roles, f"Role {role_name} missing from manifest")
            tools_str = self.roles[role_name].get("claude_tools", "")
            tools = [t.strip() for t in tools_str.split(",") if t.strip()]
            self.assertNotIn("Task", tools, f"Leaf role {role_name} in manifest must NOT include Task in claude_tools")

    def test_compile_agents_claude_output(self):
        with tempfile.TemporaryDirectory() as tmp_dir:
            out_dir = Path(tmp_dir)
            compiled = compile_agents(core_dir=CORE_DIR, target_runtime="claude", output_dir=out_dir)
            self.assertTrue(len(compiled) >= 8)

            task_allowed_roles = [
                "supreme-orchestrator",
                "team-orchestrator",
                "architect",
                "worker",
                "tester",
                "reviewer",
            ]
            task_denied_roles = [
                "scout",
                "grunt",
                "compaction",
                "summary",
            ]

            for role_name in task_allowed_roles:
                agent_file = out_dir / f"{role_name}.md"
                self.assertTrue(agent_file.is_file(), f"Missing compiled agent: {agent_file}")
                content = agent_file.read_text(encoding="utf-8")
                # Parse frontmatter
                parts = content.split("---")
                self.assertTrue(len(parts) >= 3, f"Invalid frontmatter in {agent_file}")
                fm = parts[1]
                self.assertIn("tools:", fm)
                tools_line = [l for l in fm.splitlines() if l.strip().startswith("tools:")][0]
                self.assertIn("Task", tools_line, f"Compiled {role_name}.md tools line must contain Task: {tools_line}")

            for role_name in task_denied_roles:
                agent_file = out_dir / f"{role_name}.md"
                self.assertTrue(agent_file.is_file(), f"Missing compiled agent: {agent_file}")
                content = agent_file.read_text(encoding="utf-8")
                parts = content.split("---")
                self.assertTrue(len(parts) >= 3, f"Invalid frontmatter in {agent_file}")
                fm = parts[1]
                self.assertIn("tools:", fm)
                tools_line = [l for l in fm.splitlines() if l.strip().startswith("tools:")][0]
                self.assertNotIn("Task", tools_line, f"Compiled {role_name}.md tools line must NOT contain Task: {tools_line}")


class TestDocumentationClaudeBg(unittest.TestCase):
    def test_supreme_orchestrator_documents_claude_bg_n(self):
        doc = (CORE_DIR / "agents" / "supreme-orchestrator.md").read_text(encoding="utf-8")
        self.assertIn("claude --bg -n", doc)
        self.assertIn("CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1", doc)
        self.assertIn("claude agents", doc)
        self.assertIn("claude logs", doc)

    def test_team_orchestrator_documents_claude_bg_n(self):
        doc = (CORE_DIR / "agents" / "team-orchestrator.md").read_text(encoding="utf-8")
        self.assertIn("claude --bg -n", doc)
        self.assertIn("CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1", doc)
        self.assertIn("claude agents", doc)
        self.assertIn("claude logs", doc)

    def test_launching_teams_documents_claude_bg_n(self):
        doc = (CONFIG_DIR / "orchestration" / "launching-teams.md").read_text(encoding="utf-8")
        self.assertIn("claude --bg -n", doc)
        self.assertIn("CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1", doc)
        self.assertIn("claude agents", doc)
        self.assertIn("claude logs", doc)
        self.assertIn("claude stop", doc)
        self.assertIn("claude kill", doc)
        self.assertIn("claude rm", doc)


if __name__ == "__main__":
    unittest.main()
