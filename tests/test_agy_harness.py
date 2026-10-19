"""Unit and integration tests for the standalone Antigravity (agy-harness) repository."""
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
CORE_DIR = REPO_ROOT / "core"
CONFIG_DIR = REPO_ROOT / "config"
PLUGIN_DIR = CONFIG_DIR / "agy" / "plugins" / "agent-harness"
AGENTS_DIR = CORE_DIR / "agents"

EXPECTED_AGENTS = {
    "supreme-orchestrator.md": ("pro", "gemini-3.8-flash-high", "Gemini 3.8 High"),
    "team-orchestrator.md": ("pro", "gemini-3.8-flash-high", "Gemini 3.8 High"),
    "architect.md": ("pro", "gemini-3.8-flash-high", "Gemini 3.8 High"),
    "worker.md": ("flash", "gemini-3.8-flash-medium", "Gemini 3.8 Medium"),
    "tester.md": ("flash", "gemini-3.8-flash-medium", "Gemini 3.8 Medium"),
    "reviewer.md": ("flash", "gemini-3.8-flash-medium", "Gemini 3.8 Medium"),
    "scout.md": ("flash_lite", "gemini-3.8-flash-low", "Gemini 3.8 Low"),
    "grunt.md": ("flash_lite", "gemini-3.8-flash-low", "Gemini 3.8 Low"),
    "compaction.md": ("flash_lite", "gemini-3.8-flash-low", "Gemini 3.8 Low"),
    "summary.md": ("flash_lite", "gemini-3.8-flash-low", "Gemini 3.8 Low"),
}

EXPECTED_SKILLS = {
    "adversarial-review",
    "context-anchoring",
    "read-only-block",
    "sglang-management",
    "tdd-pipeline",
    "vault-retrieval",
    "worktree-lifecycle",
}


class TestAgyHarnessStructure(unittest.TestCase):
    def test_repo_root_has_no_tracked_active_harness_dirs_or_charters(self):
        for forbidden in (".opencode", "AGENTS.md", "GEMINI.md", "opencode.json"):
            self.assertFalse(
                (REPO_ROOT / forbidden).exists(),
                f"Forbidden root path present in agy-harness: {forbidden}",
            )
        proc = subprocess.run(
            ["git", "ls-files", ".agents", ".opencode", "AGENTS.md", "GEMINI.md", "opencode.json"],
            cwd=REPO_ROOT,
            capture_output=True,
            text=True,
            check=False,
        )
        self.assertEqual(proc.stdout.strip(), "")

    def test_gitignore_blocks_active_harness_paths(self):
        gitignore_text = (REPO_ROOT / ".gitignore").read_text(encoding="utf-8")
        for required_entry in (".opencode/", ".agents/", "opencode.json", "AGENTS.md", "GEMINI.md"):
            self.assertIn(required_entry, gitignore_text)

    def test_canonical_plugin_and_no_local_suffix_references(self):
        self.assertTrue(PLUGIN_DIR.is_dir())
        plugin_meta = json.loads((PLUGIN_DIR / "plugin.json").read_text(encoding="utf-8"))
        self.assertEqual(plugin_meta["name"], "agy-harness")
        self.assertIn("Gemini 3.8", plugin_meta["displayName"])

        # Verify no *-local or local-blackwell references remain in core, config, README, or CONTRIBUTING
        checked_files = [
            REPO_ROOT / "README.md",
            REPO_ROOT / "CONTRIBUTING.md",
            CONFIG_DIR / "agy" / "GEMINI.md",
            CORE_DIR / "CHARTER.md",
            *list((CORE_DIR / "rules").glob("*.md")),
            *list((CORE_DIR / "skills").glob("*/SKILL.md")),
            *list(AGENTS_DIR.glob("*.md")),
        ]
        forbidden_tokens = (
            "local-blackwell",
            "supreme-orchestrator-local",
            "team-orchestrator-local",
            "architect-local",
            "worker-local",
            "tester-local",
            "reviewer-local",
            "scout-local",
            "grunt-local",
        )
        for fpath in checked_files:
            text = fpath.read_text(encoding="utf-8")
            for tok in forbidden_tokens:
                self.assertNotIn(tok, text, f"Stale token '{tok}' found in {fpath}")

    def test_eight_canonical_agent_profiles_gemini38_tiers_and_safety(self):
        self.assertTrue(AGENTS_DIR.is_dir())
        actual_files = {p.name for p in AGENTS_DIR.glob("*.md")}
        for exp in EXPECTED_AGENTS:
            self.assertIn(exp, actual_files)

        manifest = json.loads((CORE_DIR / "manifest.json").read_text(encoding="utf-8"))
        roles = manifest.get("roles", {})
        for filename, (expected_model_alias, expected_gemini_id, expected_tier_label) in EXPECTED_AGENTS.items():
            content = (AGENTS_DIR / filename).read_text(encoding="utf-8")
            expected_name = filename[:-3]
            self.assertIn(expected_name, roles)
            role_meta = roles[expected_name]
            tier_info = manifest["model_tiers"][role_meta["tier"]]
            self.assertEqual(tier_info["agy"], expected_model_alias)
            self.assertEqual(tier_info["agy_model_id"], expected_gemini_id)

            # Orchestrator Non-Termination Invariant in every agent profile
            self.assertIn("Orchestrator Non-Termination Invariant", content)
            self.assertIn("supreme-orchestrator", content)
            self.assertIn("team-orchestrator", content)
            self.assertIn("manage_subagents", content)
            self.assertIn("manage_task", content)

        team_body = (AGENTS_DIR / "team-orchestrator.md").read_text(encoding="utf-8")
        self.assertIn("Architect-First", team_body)
        self.assertIn(".orchestration/worktrees/<branch>", team_body)
        self.assertIn("Automatic Adversarial Review Loop", team_body)

        reviewer_body = (AGENTS_DIR / "reviewer.md").read_text(encoding="utf-8")
        self.assertIn("Second-Pass Review Scope Gate", reviewer_body)

    def test_branch_governance_and_orchestrator_safety_rules(self):
        git_wf = (CORE_DIR / "rules" / "git-workflow.md").read_text(encoding="utf-8")
        self.assertIn("Branch Governance (`release` vs `develop`)", git_wf)
        self.assertIn("`release` is the GitHub default branch reserved for stable releases", git_wf)
        self.assertIn("must always remain checked out in the local repository root", git_wf)

        proc_safety = (CORE_DIR / "rules" / "process-safety.md").read_text(encoding="utf-8")
        self.assertIn("Orchestrator Non-Termination Invariant", proc_safety)
        self.assertIn('Action: "kill"', proc_safety)

        agent_teams = (CORE_DIR / "rules" / "agent-teams.md").read_text(encoding="utf-8")
        self.assertIn("Orchestrator Non-Termination Invariant", agent_teams)
        self.assertIn("Branch Governance (`release` vs `develop`)", agent_teams)

    def test_skills_and_oom_watchdog_use_agy_paths(self):
        skills_dir = CORE_DIR / "skills"
        actual_skills = {p.name for p in skills_dir.iterdir() if p.is_dir()}
        self.assertEqual(actual_skills, EXPECTED_SKILLS)

        for skill_name in EXPECTED_SKILLS:
            skill_md = (skills_dir / skill_name / "SKILL.md").read_text(encoding="utf-8")
            self.assertNotIn("~/.config/opencode/", skill_md, f"Stale opencode path in {skill_name}")
            self.assertNotIn(".agents/rules.md", skill_md, f"Stale .agents/rules.md in {skill_name}")
            self.assertNotIn("~/agy/worktrees", skill_md, f"Stale ~/agy/worktrees in {skill_name}")

        wt_skill = (skills_dir / "worktree-lifecycle" / "SKILL.md").read_text(encoding="utf-8")
        self.assertIn(".orchestration/worktrees/", wt_skill)
        sglang_skill = (skills_dir / "sglang-management" / "SKILL.md").read_text(encoding="utf-8")
        self.assertIn("sglang_oom_handler.sh", sglang_skill)
        anchor_skill = (skills_dir / "context-anchoring" / "SKILL.md").read_text(encoding="utf-8")
        self.assertIn("GEMINI.md", anchor_skill)

        oom_script = REPO_ROOT / "scripts" / "sglang_oom_handler.sh"
        self.assertIn(
            'SERVICE="opencode-sglang-ornith-35b.service"',
            oom_script.read_text(encoding="utf-8"),
        )

    def test_runtime_defaults_for_worktree_anchor_and_handoff(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            (tmp_path / ".orchestration_root").write_text("mode=local\n", encoding="utf-8")
            mgr = WorktreeManager(repo_dir=tmp_path, runtime="agy")
            self.assertEqual(
                mgr.default_worktree_path("feat/issue-147"),
                (tmp_path / ".orchestration" / "worktrees" / "feat/issue-147").resolve(),
            )

            orch_mgr = WorktreeManager(repo_dir=tmp_path)
            self.assertEqual(
                orch_mgr.default_worktree_path("feat/issue-147"),
                (tmp_path / ".orchestration" / "worktrees" / "feat/issue-147").resolve(),
            )

            anchor = ContextAnchorInjector()
            self.assertIn(anchor.rules_path.name, ("GEMINI.md", "agent-teams.md"))

            orig_cwd = Path.cwd()
            try:
                os.chdir(tmp_path)
                handoff = TaskHandoff()
                self.assertEqual(handoff.handoff_dir, Path(".orchestration/handoffs"))
            finally:
                os.chdir(orig_cwd)

    def test_installer_dry_run_and_sandboxed_global_and_local_modes(self):
        install_sh = REPO_ROOT / "install.sh"
        uninstall_sh = REPO_ROOT / "uninstall.sh"

        # 1. Dry-run
        dry_proc = subprocess.run(
            [str(install_sh), "--dry-run"],
            cwd=REPO_ROOT,
            capture_output=True,
            text=True,
            check=True,
        )
        self.assertIn("[DRY-RUN]", dry_proc.stdout)

        with tempfile.TemporaryDirectory() as tmp:
            sandbox_home = Path(tmp) / "home"
            gemini_cfg = sandbox_home / ".gemini" / "config"
            agents_home = sandbox_home / ".agents"
            legacy_plugin = gemini_cfg / "plugins" / "local-blackwell" / "agents"
            legacy_plugin.mkdir(parents=True, exist_ok=True)
            (legacy_plugin / "orchestrator-local.md").write_text("stale", encoding="utf-8")

            new_plugin_agents = gemini_cfg / "plugins" / "agy-harness" / "agents"
            new_plugin_agents.mkdir(parents=True, exist_ok=True)
            (new_plugin_agents / "stale-agent.md").write_text("stale", encoding="utf-8")

            # Seed stale ~/AGENTS.md, existing MCP server ('rea'), and existing 3rd-party skill
            (sandbox_home / "AGENTS.md").write_text("stale home charter", encoding="utf-8")
            (gemini_cfg / "mcp_config.json").write_text(
                json.dumps({"mcpServers": {"rea": {"command": "rea", "args": ["mcp"]}}}),
                encoding="utf-8",
            )
            third_party_skill = agents_home / "skills" / "reverse-engineer-anything"
            third_party_skill.mkdir(parents=True, exist_ok=True)
            (third_party_skill / "SKILL.md").write_text("# REA", encoding="utf-8")

            env = os.environ.copy()
            env["USER_HOME"] = str(sandbox_home)
            env["GEMINI_CONFIG_DIR"] = str(gemini_cfg)
            env["AGENTS_HOME_DIR"] = str(agents_home)

            # 2. Global install in sandbox
            subprocess.run(
                [str(install_sh), "--global", "--non-interactive"],
                cwd=REPO_ROOT,
                env=env,
                capture_output=True,
                text=True,
                check=True,
            )

            self.assertFalse((gemini_cfg / "plugins" / "local-blackwell").exists())
            self.assertFalse((sandbox_home / "AGENTS.md").exists())
            self.assertFalse((new_plugin_agents / "stale-agent.md").exists())
            self.assertEqual({p.name for p in new_plugin_agents.glob("*.md")}, set(EXPECTED_AGENTS.keys()))
            self.assertTrue((agents_home / "AGENTS.md").is_file())
            self.assertTrue((agents_home / "GEMINI.md").is_file())
            self.assertTrue((third_party_skill / "SKILL.md").is_file())

            # Global verification for AGY (~/.gemini/): documented locations only, nothing duplicated
            gemini_home = sandbox_home / ".gemini"
            self.assertTrue((gemini_home / "AGENTS.md").is_file())
            self.assertTrue((gemini_home / "GEMINI.md").is_file())
            gemini_md_text = (gemini_home / "GEMINI.md").read_text(encoding="utf-8")
            self.assertLess(len(gemini_md_text.encode("utf-8")), 24000, "GEMINI.md must be strictly < 24KB")
            # AGY loads ~/.gemini/AGENTS.md natively: GEMINI.md must neither include nor inline the charter.
            self.assertNotIn("@[", gemini_md_text)
            self.assertNotIn("Universal AI Agent System Charter", gemini_md_text)
            self.assertIn("Antigravity", gemini_md_text)
            self.assertTrue((gemini_cfg / "rules" / "agent-teams.md").is_file())
            self.assertTrue((gemini_cfg / "plugins" / "agent-harness" / "skills" / "adversarial-review" / "SKILL.md").is_file())
            # Skills are exposed once (via the plugin); undocumented duplicate locations must not exist.
            self.assertFalse((gemini_cfg / "skills" / "adversarial-review").exists())
            self.assertFalse((gemini_home / "antigravity" / "skills").exists())
            self.assertFalse((gemini_home / "antigravity" / "mcp_config.json").exists())
            self.assertFalse((gemini_home / "antigravity-cli" / "rules").exists())
            self.assertFalse((gemini_home / "settings.json").exists())

            mcp_data = json.loads((gemini_cfg / "mcp_config.json").read_text(encoding="utf-8"))
            self.assertIn("rea", mcp_data["mcpServers"])
            self.assertIn("vault-memory", mcp_data["mcpServers"])
            self.assertIn("worktree-manager", mcp_data["mcpServers"])

            # 3. Local install in sandbox target repo with legacy .agent migration check
            target_repo = Path(tmp) / "sample-repo"
            target_repo.mkdir(parents=True, exist_ok=True)
            (target_repo / ".agent").mkdir(parents=True, exist_ok=True)
            (target_repo / ".agent" / "legacy.txt").write_text("legacy agent data", encoding="utf-8")

            subprocess.run(
                [str(install_sh), "--local", str(target_repo), "--non-interactive"],
                cwd=REPO_ROOT,
                env=env,
                capture_output=True,
                text=True,
                check=True,
            )

            self.assertFalse((target_repo / ".agent").exists())
            self.assertTrue((target_repo / ".agent.pre-harness.bak").is_dir())
            self.assertTrue((target_repo / "AGENTS.md").is_file())
            self.assertTrue((target_repo / "GEMINI.md").is_file())
            self.assertTrue((target_repo / "CLAUDE.md").is_file())
            self.assertTrue((target_repo / ".agents" / "AGENTS.md").is_file())
            self.assertTrue((target_repo / ".agents" / "GEMINI.md").is_file())
            # Undocumented workspace MCP/settings files must not be generated (they would not resolve the harness).
            self.assertFalse((target_repo / ".agents" / "mcp.json").exists())
            self.assertFalse((target_repo / ".agents" / "settings.json").exists())
            self.assertTrue((target_repo / ".agents" / "rules" / "agent-teams.md").is_file())
            self.assertTrue((target_repo / ".agents" / "tools" / "worktree_manager.py").is_file())
            repo_gitignore = (target_repo / ".gitignore").read_text(encoding="utf-8")
            self.assertIn(".agents/", repo_gitignore)
            self.assertIn(".opencode/", repo_gitignore)

            # 4. Uninstall dry-run
            un_proc = subprocess.run(
                [str(uninstall_sh), "--dry-run"],
                cwd=REPO_ROOT,
                env=env,
                capture_output=True,
                text=True,
                check=True,
            )
            self.assertIn("[DRY-RUN]", un_proc.stdout)


if __name__ == "__main__":
    unittest.main()
