"""Comprehensive tests for authoritative .orchestration binding, git common dir anchoring, and directory discipline (Issue #6)."""
from __future__ import annotations

import os
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from harness.memory.handoff import TaskHandoff
from harness.paths import (
    parse_anchor_file,
    resolve_authoritative_orchestration_root,
    resolve_true_repo_root,
)
from scripts.worktree_manager import WorktreeManager


class TestAuthoritativeRootAndDiscipline(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.tmp_path = Path(self.tmp.name).resolve()
        self.main_repo = self.tmp_path / "main_repo"
        self.main_repo.mkdir()

        # Initialize main git repo
        subprocess.run(["git", "init", "-b", "develop"], cwd=self.main_repo, capture_output=True, check=True)
        subprocess.run(["git", "config", "user.name", "HarnessTest"], cwd=self.main_repo, capture_output=True, check=True)
        subprocess.run(["git", "config", "user.email", "test@example.com"], cwd=self.main_repo, capture_output=True, check=True)

        # Create initial commit so HEAD exists
        (self.main_repo / "README.md").write_text("# Test Repo\n", encoding="utf-8")
        subprocess.run(["git", "add", "README.md"], cwd=self.main_repo, capture_output=True, check=True)
        subprocess.run(["git", "commit", "-m", "Initial commit"], cwd=self.main_repo, capture_output=True, check=True)

        # Create simulated git worktree
        self.worktree_dir = self.main_repo / ".agents" / "worktrees" / "fix" / "issue-6-discipline"
        self.worktree_dir.parent.mkdir(parents=True, exist_ok=True)
        subprocess.run(
            ["git", "worktree", "add", "-b", "fix/issue-6-discipline", str(self.worktree_dir), "develop"],
            cwd=self.main_repo,
            capture_output=True,
            check=True,
        )

    def tearDown(self):
        self.tmp.cleanup()

    def test_resolve_true_repo_root_inside_worktree(self):
        """Test resolve_true_repo_root inside a git worktree resolves to main repo root, NOT worktree root."""
        # 1. Pass worktree path explicitly
        resolved = resolve_true_repo_root(self.worktree_dir)
        self.assertEqual(resolved, self.main_repo.resolve())

        # 2. Pass deep nested path inside worktree
        nested_dir = self.worktree_dir / "subdir" / "deep"
        nested_dir.mkdir(parents=True)
        resolved_nested = resolve_true_repo_root(nested_dir)
        self.assertEqual(resolved_nested, self.main_repo.resolve())

        # 3. Running with cwd inside worktree
        orig_cwd = os.getcwd()
        try:
            os.chdir(self.worktree_dir)
            resolved_cwd = resolve_true_repo_root()
            self.assertEqual(resolved_cwd, self.main_repo.resolve())
        finally:
            os.chdir(orig_cwd)

    def test_resolve_true_repo_root_outside_git(self):
        """Test resolve_true_repo_root outside git returns None or directory with .orchestration."""
        non_git = self.tmp_path / "non_git_dir"
        non_git.mkdir()
        self.assertIsNone(resolve_true_repo_root(non_git))

        # If .orchestration exists in non-git directory
        (non_git / ".orchestration").mkdir()
        self.assertEqual(resolve_true_repo_root(non_git), non_git.resolve())

    def test_priority_1_env_override(self):
        """Test Priority 1: ORCHESTRATION_ROOT environment override takes highest precedence."""
        override_path = self.tmp_path / "custom_orchestration"
        override_path.mkdir()

        with patch.dict(os.environ, {"ORCHESTRATION_ROOT": str(override_path)}):
            # Even when executed from inside a git worktree
            resolved = resolve_authoritative_orchestration_root(self.worktree_dir)
            self.assertEqual(resolved, override_path.resolve())

    def test_priority_2_anchor_file(self):
        """Test Priority 2: .orchestration_root file anchor."""
        custom_orch = self.tmp_path / "custom_anchor_orch"
        custom_orch.mkdir()

        # 1. Anchor in true_repo root
        anchor_file = self.main_repo / ".orchestration_root"
        anchor_file.write_text(f"mode=local\nroot={custom_orch}\n", encoding="utf-8")

        with patch.dict(os.environ, {}, clear=True):
            resolved = resolve_authoritative_orchestration_root(self.worktree_dir)
            self.assertEqual(resolved, custom_orch.resolve())

        # 2. Anchor in true_repo / .orchestration / .orchestration_root
        anchor_file.unlink()
        (self.main_repo / ".orchestration").mkdir(exist_ok=True)
        sub_anchor = self.main_repo / ".orchestration" / ".orchestration_root"
        sub_anchor.write_text(f"mode=local\nroot={custom_orch}\n", encoding="utf-8")

        with patch.dict(os.environ, {}, clear=True):
            resolved = resolve_authoritative_orchestration_root(self.worktree_dir)
            self.assertEqual(resolved, custom_orch.resolve())

        # 3. Relative root in anchor file
        sub_anchor.write_text("root=.orchestration\n", encoding="utf-8")
        with patch.dict(os.environ, {}, clear=True):
            resolved = resolve_authoritative_orchestration_root(self.worktree_dir)
            self.assertEqual(resolved, (self.main_repo / ".orchestration").resolve())

    def test_priority_3_main_repo_orchestration_from_nested_worktree(self):
        """Test Priority 3: <main_repo>/.orchestration from inside a nested worktree cwd."""
        main_orch = self.main_repo / ".orchestration"
        main_orch.mkdir(exist_ok=True)

        with patch.dict(os.environ, {}, clear=True):
            orig_cwd = os.getcwd()
            try:
                os.chdir(self.worktree_dir)
                resolved = resolve_authoritative_orchestration_root()
                self.assertEqual(resolved, main_orch.resolve())

                # CRITICAL: Verify <worktree>/.orchestration was NOT created or returned
                self.assertFalse((self.worktree_dir / ".orchestration").exists())
                self.assertNotEqual(resolved, (self.worktree_dir / ".orchestration").resolve())
            finally:
                os.chdir(orig_cwd)

    def test_priority_3_symlinked_agents_directory(self):
        """Test Priority 3: <main_repo>/.agents symlink targeting .orchestration."""
        main_orch = self.main_repo / ".orchestration"
        main_orch.mkdir(exist_ok=True)
        agents_symlink = self.main_repo / ".agents_link"
        agents_symlink.symlink_to(main_orch, target_is_directory=True)

        # Test resolving target
        with patch.dict(os.environ, {}, clear=True):
            resolved = resolve_authoritative_orchestration_root(self.worktree_dir)
            self.assertEqual(resolved, main_orch.resolve())

    def test_priority_4_global_fallback(self):
        """Test Priority 4: Fallback to global ~/.orchestration when outside git repo."""
        non_git = self.tmp_path / "outside_git"
        non_git.mkdir()
        fake_home = self.tmp_path / "fake_home"
        fake_home.mkdir()

        with patch.dict(os.environ, {}, clear=True), patch.object(Path, "home", return_value=fake_home):
            resolved = resolve_authoritative_orchestration_root(non_git)
            self.assertEqual(resolved, (fake_home / ".orchestration").resolve())

            # Also test global anchor file
            (fake_home / ".orchestration").mkdir()
            global_anchor = fake_home / ".orchestration" / ".orchestration_root"
            custom_global = fake_home / "custom_global_orch"
            global_anchor.write_text(f"mode=global\nroot={custom_global}\n", encoding="utf-8")

            resolved_anchor = resolve_authoritative_orchestration_root(non_git)
            self.assertEqual(resolved_anchor, custom_global.resolve())

    def test_task_handoff_detect_handoff_dir_in_worktree(self):
        """Test TaskHandoff.detect_handoff_dir() called from inside nested worktree."""
        (self.main_repo / ".orchestration" / "handoffs").mkdir(parents=True, exist_ok=True)

        with patch.dict(os.environ, {}, clear=True):
            # Call from inside nested worktree
            detected = TaskHandoff.detect_handoff_dir(base_dir=self.worktree_dir)
            expected = (self.main_repo / ".orchestration" / "handoffs").resolve()
            self.assertEqual(detected, expected)
            self.assertFalse((self.worktree_dir / ".orchestration").exists())

            # Instantiate TaskHandoff without explicit path
            orig_cwd = os.getcwd()
            try:
                os.chdir(self.worktree_dir)
                th = TaskHandoff()
                self.assertEqual(th.handoff_dir, expected)
                self.assertFalse((self.worktree_dir / ".orchestration").exists())
            finally:
                os.chdir(orig_cwd)

    def test_worktree_manager_inside_nested_worktree(self):
        """Test WorktreeManager called from inside nested worktree targets main_repo and avoids nesting."""
        (self.main_repo / ".orchestration").mkdir(exist_ok=True)

        orig_cwd = os.getcwd()
        try:
            os.chdir(self.worktree_dir)
            mgr = WorktreeManager()
            self.assertEqual(mgr.repo_dir, self.main_repo.resolve())

            new_branch = "feat/issue-7-subsystem-audit"
            target_path = mgr.default_worktree_path(new_branch)
            expected_target = (self.main_repo / ".orchestration" / "worktrees" / new_branch).resolve()
            self.assertEqual(target_path, expected_target)

            # Ensure it does NOT nest under current worktree
            self.assertFalse(str(target_path).startswith(str(self.worktree_dir.resolve())))
            self.assertTrue(str(target_path).startswith(str(self.main_repo.resolve())))
        finally:
            os.chdir(orig_cwd)


class TestInstallerAuthoritativeRootAnchoring(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.tmp_path = Path(self.tmp.name).resolve()
        self.repo_root = Path(__file__).resolve().parent.parent
        self.install_sh = self.repo_root / "install.sh"
        self.uninstall_sh = self.repo_root / "uninstall.sh"

    def tearDown(self):
        self.tmp.cleanup()

    def test_installer_local_mode_anchoring_and_gitignore(self):
        """Test install.sh in local mode writes .orchestration_root anchors and updates .gitignore."""
        target_repo = self.tmp_path / "local_repo"
        target_repo.mkdir()
        subprocess.run(["git", "init", "-b", "develop"], cwd=target_repo, capture_output=True, check=True)

        env = os.environ.copy()
        env["PYTHONPATH"] = f"{self.repo_root}:{env.get('PYTHONPATH', '')}"

        # Run local install
        res = subprocess.run(
            [str(self.install_sh), "--mode", "local", str(target_repo), "--target", "agy", "-y"],
            cwd=self.repo_root,
            capture_output=True,
            text=True,
            env=env,
            check=False,
        )
        self.assertEqual(res.returncode, 0, f"install.sh failed: {res.stderr}")

        # Check .orchestration_root at repo root
        anchor_root = target_repo / ".orchestration_root"
        self.assertTrue(anchor_root.is_file(), f"{anchor_root} missing")
        content = anchor_root.read_text(encoding="utf-8")
        self.assertIn("mode=local", content)
        self.assertIn(f"root={(target_repo / '.orchestration').resolve()}", content)

        # Check .orchestration/.orchestration_root
        sub_anchor = target_repo / ".orchestration" / ".orchestration_root"
        self.assertTrue(sub_anchor.is_file(), f"{sub_anchor} missing")
        sub_content = sub_anchor.read_text(encoding="utf-8")
        self.assertIn("mode=local", sub_content)
        self.assertIn(f"root={(target_repo / '.orchestration').resolve()}", sub_content)

        # Check .gitignore
        gitignore = target_repo / ".gitignore"
        self.assertTrue(gitignore.is_file())
        gi_content = gitignore.read_text(encoding="utf-8")
        self.assertIn(".orchestration_root", gi_content)

        # Test uninstall cleanly removes .orchestration_root
        uninst_res = subprocess.run(
            [str(self.uninstall_sh), "--local", str(target_repo), "-y"],
            cwd=self.repo_root,
            capture_output=True,
            text=True,
            env=env,
            check=False,
        )
        self.assertEqual(uninst_res.returncode, 0, f"uninstall.sh failed: {uninst_res.stderr}")
        self.assertFalse(anchor_root.exists(), "uninstall did not clean up .orchestration_root")
        self.assertFalse(sub_anchor.exists(), "uninstall did not clean up .orchestration/.orchestration_root")

    def test_installer_global_mode_anchoring(self):
        """Test install.sh in global mode writes global anchor, backend env, and MCP configs."""
        fake_user_home = self.tmp_path / "global_user"
        fake_user_home.mkdir()

        env = os.environ.copy()
        env["USER_HOME"] = str(fake_user_home)
        env["HOME"] = str(fake_user_home)
        env["PYTHONPATH"] = f"{self.repo_root}:{env.get('PYTHONPATH', '')}"

        # Run global install for opencode
        res = subprocess.run(
            [str(self.install_sh), "--global", "--target", "opencode", "--no-backends", "-y"],
            cwd=self.repo_root,
            capture_output=True,
            text=True,
            env=env,
            check=False,
        )
        self.assertEqual(res.returncode, 0, f"install.sh failed: {res.stderr}")

        # Check global anchor file
        global_anchor = fake_user_home / ".orchestration" / ".orchestration_root"
        self.assertTrue(global_anchor.is_file(), f"{global_anchor} missing")
        anchor_content = global_anchor.read_text(encoding="utf-8")
        self.assertIn("mode=global", anchor_content)
        self.assertIn(f"root={(fake_user_home / '.orchestration').resolve()}", anchor_content)

        # Check backend env
        backend_env = fake_user_home / ".config" / "opencode-backends" / "env"
        self.assertTrue(backend_env.is_file(), f"{backend_env} missing")
        env_content = backend_env.read_text(encoding="utf-8")
        self.assertIn(f"ORCHESTRATION_ROOT={(fake_user_home / '.orchestration').resolve()}", env_content)

        # Check opencode.json MCP environment configs
        import json
        opencode_json = fake_user_home / ".config" / "opencode" / "opencode.json"
        self.assertTrue(opencode_json.is_file(), f"{opencode_json} missing")
        cfg = json.loads(opencode_json.read_text(encoding="utf-8"))
        mcp = cfg.get("mcp", {})
        self.assertIn("vault-memory", mcp)
        self.assertEqual(
            mcp["vault-memory"]["environment"]["ORCHESTRATION_ROOT"],
            str((fake_user_home / ".orchestration").resolve()),
        )
        self.assertIn("worktree-manager", mcp)
        self.assertEqual(
            mcp["worktree-manager"]["environment"]["ORCHESTRATION_ROOT"],
            str((fake_user_home / ".orchestration").resolve()),
        )


class TestDirectoryDisciplineInvariant(unittest.TestCase):
    def test_invariant_present_in_shared_rules(self):
        """Test Directory Discipline Invariant is present in shared and mirrored rules."""
        repo_root = Path(__file__).resolve().parent.parent
        expected = "Directory Discipline Invariant"

        rule_files = [
            repo_root / "templates" / "shared" / "rules" / "process-safety.md",
            repo_root / "templates" / "shared" / "rules" / "agent-teams.md",
            repo_root / "templates" / "agy" / "rules" / "process-safety.md",
            repo_root / "templates" / "agy" / "rules" / "agent-teams.md",
            repo_root / "templates" / "claude" / "rules" / "process-safety.md",
            repo_root / "templates" / "claude" / "rules" / "agent-teams.md",
            repo_root / "templates" / "opencode" / "rules" / "process-safety.md",
            repo_root / "templates" / "opencode" / "rules" / "agent-teams.md",
        ]
        for rf in rule_files:
            self.assertTrue(rf.is_file(), f"Missing rule file: {rf}")
            self.assertIn(expected, rf.read_text(encoding="utf-8"), f"Invariant missing in {rf}")

    def test_invariant_present_in_all_agent_definitions(self):
        """Test Directory Discipline Invariant is present in all runtime agent definitions."""
        repo_root = Path(__file__).resolve().parent.parent
        expected = "Directory Discipline Invariant"

        agent_dirs = [
            repo_root / "templates" / "agy" / "plugins" / "agy-harness" / "agents",
            repo_root / "templates" / "claude" / "agents",
            repo_root / "templates" / "opencode" / "agents",
        ]
        for ad in agent_dirs:
            md_files = list(ad.glob("*.md"))
            self.assertEqual(len(md_files), 10, f"Expected 10 agent files in {ad}, found {len(md_files)}")
            for af in md_files:
                self.assertIn(expected, af.read_text(encoding="utf-8"), f"Invariant missing in {af}")


if __name__ == "__main__":
    unittest.main()

