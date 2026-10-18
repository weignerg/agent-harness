"""Integration and unit tests for Master Universal Installer and Atomic Manifest Engine (Issue #2)."""
from __future__ import annotations

import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path

from harness.installer.manifest import (
    InstallManifest,
    ManifestEngine,
    ManifestEntry,
    compute_sha256,
)
from harness.installer.settings import (
    merge_claude_settings_file,
    merge_json_settings,
)

REPO_ROOT = Path(__file__).resolve().parent.parent
INSTALL_SCRIPT = REPO_ROOT / "install.sh"
UNINSTALL_SCRIPT = REPO_ROOT / "uninstall.sh"


class TestUniversalInstaller(unittest.TestCase):
    """Integration test suite for universal install.sh and manifest rollback engine."""

    def run_installer(self, *args: str, env: dict | None = None) -> subprocess.CompletedProcess[str]:
        cmd_env = os.environ.copy()
        if env:
            cmd_env.update(env)
        cmd_env["PYTHONPATH"] = f"{REPO_ROOT}:{cmd_env.get('PYTHONPATH', '')}"
        return subprocess.run(
            [str(INSTALL_SCRIPT), *args],
            cwd=REPO_ROOT,
            capture_output=True,
            text=True,
            env=cmd_env,
            check=False,
        )

    def run_uninstaller(self, *args: str, env: dict | None = None) -> subprocess.CompletedProcess[str]:
        cmd_env = os.environ.copy()
        if env:
            cmd_env.update(env)
        cmd_env["PYTHONPATH"] = f"{REPO_ROOT}:{cmd_env.get('PYTHONPATH', '')}"
        return subprocess.run(
            [str(UNINSTALL_SCRIPT), *args],
            cwd=REPO_ROOT,
            capture_output=True,
            text=True,
            env=cmd_env,
            check=False,
        )

    def test_target_agy_local_sandbox(self):
        """Test --target agy provisions .orchestration/ and .agents/ symlink with manifest."""
        with tempfile.TemporaryDirectory() as tmp_dir:
            sandbox = Path(tmp_dir) / "test_repo"
            sandbox.mkdir()

            proc = self.run_installer("--target", "agy", "--mode", "local", str(sandbox), "--non-interactive")
            self.assertEqual(proc.returncode, 0, f"Installer failed: {proc.stderr}\n{proc.stdout}")

            orch_dir = sandbox / ".orchestration"
            self.assertTrue(orch_dir.is_dir(), ".orchestration directory was not created")
            self.assertTrue((orch_dir / "rules" / "agent-teams.md").is_file())
            self.assertTrue((orch_dir / "GEMINI.md").is_file())
            self.assertTrue((orch_dir / "AGENTS.md").is_file())
            self.assertTrue((orch_dir / "tools" / "worktree_manager.py").is_file())

            agents_link = sandbox / ".agents"
            self.assertTrue(agents_link.is_symlink(), ".agents must be a symlink")
            self.assertTrue((agents_link / "rules" / "agent-teams.md").is_file())

            # Manifest verification
            manifest_path = orch_dir / "install_manifest.json"
            self.assertTrue(manifest_path.is_file(), "install_manifest.json was not created")
            manifest_data = json.loads(manifest_path.read_text(encoding="utf-8"))
            self.assertEqual(manifest_data["target"], "agy")
            self.assertEqual(manifest_data["mode"], "local")
            self.assertGreater(len(manifest_data["files"]), 0)

            # Check SHA256 integrity of recorded files
            for entry in manifest_data["files"]:
                p = Path(entry["path"])
                self.assertTrue(p.is_file(), f"Recorded file does not exist: {p}")
                self.assertEqual(compute_sha256(p), entry["sha256"])

            # Check .gitignore
            gitignore = sandbox / ".gitignore"
            self.assertTrue(gitignore.is_file())
            git_content = gitignore.read_text(encoding="utf-8")
            self.assertIn(".agents/", git_content)
            self.assertIn(".orchestration/worktrees/", git_content)

    def test_target_claude_local_sandbox_with_json_merge(self):
        """Test --target claude provisions .claude/ with JSON settings merge preserving user config."""
        with tempfile.TemporaryDirectory() as tmp_dir:
            sandbox = Path(tmp_dir) / "test_repo"
            claude_dir = sandbox / ".claude"
            claude_dir.mkdir(parents=True)

            # Pre-populate existing user settings
            user_settings = {
                "theme": "nord",
                "custom_developer_key": "special_val_999",
                "teammateMode": "manual",
                "permissions": {
                    "allow": ["read_file"],
                },
            }
            settings_path = claude_dir / "settings.json"
            settings_path.write_text(json.dumps(user_settings, indent=2), encoding="utf-8")

            proc = self.run_installer("--target", "claude", "--mode", "local", str(sandbox), "--non-interactive")
            self.assertEqual(proc.returncode, 0, f"Installer failed: {proc.stderr}\n{proc.stdout}")

            self.assertTrue((claude_dir / "agents" / "architect.md").is_file())
            self.assertTrue((claude_dir / "CLAUDE.md").is_file())
            self.assertTrue((claude_dir / "skills" / "vault-retrieval" / "SKILL.md").is_file())
            self.assertTrue((claude_dir / "tools" / "tdd_pipeline.py").is_file())

            # Verify settings merge preserved user configuration
            merged_data = json.loads(settings_path.read_text(encoding="utf-8"))
            self.assertEqual(merged_data["theme"], "nord")
            self.assertEqual(merged_data["custom_developer_key"], "special_val_999")
            self.assertEqual(merged_data["teammateMode"], "manual")
            self.assertIn("env", merged_data)
            self.assertEqual(merged_data["env"]["CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS"], "1")
            self.assertEqual(merged_data["permissions"]["allow"], ["read_file"])

            # Manifest recorded
            manifest_path = sandbox / ".orchestration" / "install_manifest.json"
            self.assertTrue(manifest_path.is_file())

    def test_target_opencode_local_sandbox(self):
        """Test --target opencode provisions full 10-component hierarchy and slash commands."""
        with tempfile.TemporaryDirectory() as tmp_dir:
            sandbox = Path(tmp_dir) / "test_repo"
            sandbox.mkdir()

            proc = self.run_installer("--target", "opencode", "--mode", "local", str(sandbox), "--non-interactive")
            self.assertEqual(proc.returncode, 0, f"Installer failed: {proc.stderr}\n{proc.stdout}")

            opencode_dir = sandbox / ".opencode"
            self.assertTrue(opencode_dir.is_dir())
            self.assertTrue((opencode_dir / "opencode.json").is_file())
            self.assertTrue((opencode_dir / "tui.json").is_file())
            self.assertTrue((opencode_dir / "AGENTS.md").is_file())
            self.assertTrue((opencode_dir / "agents" / "supreme-orchestrator.md").is_file())
            self.assertTrue((opencode_dir / "commands" / "worktree.md").is_file())
            self.assertTrue((opencode_dir / "commands" / "review.md").is_file())
            self.assertTrue((opencode_dir / "skills" / "vault-retrieval" / "SKILL.md").is_file())
            self.assertTrue((opencode_dir / "tools" / "worktree_manager.py").is_file())
            self.assertTrue((opencode_dir / "rules" / "agent-teams.md").is_file())
            self.assertTrue((opencode_dir / "plugins" / "README.md").is_file())
            self.assertTrue((opencode_dir / "themes" / "blackwell.json").is_file())

            # Manifest recorded
            manifest_path = sandbox / ".orchestration" / "install_manifest.json"
            self.assertTrue(manifest_path.is_file())

    def test_target_all_local_sandbox(self):
        """Test --target all provisions agy, claude, and opencode unified under .orchestration/."""
        with tempfile.TemporaryDirectory() as tmp_dir:
            sandbox = Path(tmp_dir) / "test_repo"
            sandbox.mkdir()

            proc = self.run_installer("--target", "all", "--mode", "local", str(sandbox), "--non-interactive")
            self.assertEqual(proc.returncode, 0, f"Installer failed: {proc.stderr}\n{proc.stdout}")

            # Check Antigravity / Shared persistence
            self.assertTrue((sandbox / ".orchestration" / "rules" / "agent-teams.md").is_file())
            self.assertTrue((sandbox / ".agents").is_symlink())

            # Check Claude
            self.assertTrue((sandbox / ".claude" / "agents" / "worker.md").is_file())
            self.assertTrue((sandbox / ".claude" / "settings.json").is_file())

            # Check OpenCode
            self.assertTrue((sandbox / ".opencode" / "opencode.json").is_file())
            self.assertTrue((sandbox / ".opencode" / "commands" / "worktree.md").is_file())

            # Check .gitignore covers all
            git_content = (sandbox / ".gitignore").read_text(encoding="utf-8")
            self.assertIn(".agents/", git_content)
            self.assertIn(".claude/", git_content)
            self.assertIn(".opencode/", git_content)
            self.assertIn(".orchestration/worktrees/", git_content)

            # Check unified manifest contains records for all targets
            manifest_path = sandbox / ".orchestration" / "install_manifest.json"
            self.assertTrue(manifest_path.is_file())
            manifest_data = json.loads(manifest_path.read_text(encoding="utf-8"))
            recorded_paths = [f["path"] for f in manifest_data["files"]]
            self.assertTrue(any(".orchestration" in p for p in recorded_paths))
            self.assertTrue(any(".claude" in p for p in recorded_paths))
            self.assertTrue(any(".opencode" in p for p in recorded_paths))

    def test_verify_detecting_intact_and_tampered_files(self):
        """Test --verify reports success on clean state and failure on tampered or missing files."""
        with tempfile.TemporaryDirectory() as tmp_dir:
            sandbox = Path(tmp_dir) / "test_repo"
            sandbox.mkdir()

            # Install
            proc = self.run_installer("--target", "all", "--mode", "local", str(sandbox), "--non-interactive")
            self.assertEqual(proc.returncode, 0)

            # 1. Verify intact
            proc_verify = self.run_installer("--action", "verify", "--mode", "local", str(sandbox))
            self.assertEqual(proc_verify.returncode, 0, f"Verify failed unexpectedly: {proc_verify.stdout}")
            self.assertIn("Verification SUCCESS", proc_verify.stdout)

            # 2. Tamper with a file
            target_file = sandbox / ".orchestration" / "rules" / "code-quality.md"
            with open(target_file, "a", encoding="utf-8") as f:
                f.write("\n# TAMPERED LINE INJECTION\n")

            proc_tampered = self.run_installer("--verify", "--mode", "local", str(sandbox))
            self.assertNotEqual(proc_tampered.returncode, 0, "Verify should fail on tampered file")
            self.assertIn("Tampered Files Detected", proc_tampered.stdout)
            self.assertIn("code-quality.md", proc_tampered.stdout)

            # 3. Missing file detection
            missing_file = sandbox / ".claude" / "CLAUDE.md"
            missing_file.unlink()

            proc_missing = self.run_installer("--verify", "--mode", "local", str(sandbox))
            self.assertNotEqual(proc_missing.returncode, 0, "Verify should fail on missing file")
            self.assertIn("Missing Files Detected", proc_missing.stdout)
            self.assertIn("CLAUDE.md", proc_missing.stdout)

    def test_uninstall_cleanly_rolling_back_without_leaving_stray_files(self):
        """Test --uninstall cleanly rolls back installed files and preserves user-modified files."""
        # Case A: Clean uninstall removes everything without leaving stray files
        with tempfile.TemporaryDirectory() as tmp_dir:
            sandbox = Path(tmp_dir) / "test_repo"
            sandbox.mkdir()

            self.run_installer("--target", "all", "--mode", "local", str(sandbox), "--non-interactive")
            self.assertTrue((sandbox / ".orchestration").is_dir())
            self.assertTrue((sandbox / ".agents").is_symlink())
            self.assertTrue((sandbox / ".claude").is_dir())
            self.assertTrue((sandbox / ".opencode").is_dir())

            proc_uninst = self.run_installer("--uninstall", "--mode", "local", str(sandbox), "--non-interactive")
            self.assertEqual(proc_uninst.returncode, 0)

            self.assertFalse((sandbox / ".agents").exists(), ".agents symlink should be removed")
            self.assertFalse((sandbox / ".claude").exists(), ".claude dir should be removed")
            self.assertFalse((sandbox / ".opencode").exists(), ".opencode dir should be removed")
            self.assertFalse((sandbox / ".orchestration").exists(), ".orchestration dir should be removed")

        # Case B: Rollback preserves user-modified files
        with tempfile.TemporaryDirectory() as tmp_dir:
            sandbox = Path(tmp_dir) / "test_repo"
            sandbox.mkdir()

            self.run_installer("--target", "all", "--mode", "local", str(sandbox), "--non-interactive")

            # User edits opencode.json
            custom_file = sandbox / ".opencode" / "opencode.json"
            with open(custom_file, "a", encoding="utf-8") as f:
                f.write("\n// User custom comment\n")

            proc_uninst = self.run_installer("--action", "uninstall", "--mode", "local", str(sandbox), "--non-interactive")
            self.assertEqual(proc_uninst.returncode, 0)

            # Modified file should be preserved!
            self.assertTrue(custom_file.is_file(), "User-modified file must be preserved by uninstall")
            self.assertIn("Preserved user-modified files", proc_uninst.stdout)

            # Unmodified files should still be removed
            self.assertFalse((sandbox / ".claude").exists())
            self.assertFalse((sandbox / ".agents").exists())

    def test_dry_run_performing_no_disk_modifications(self):
        """Test --dry-run performs zero filesystem modifications."""
        with tempfile.TemporaryDirectory() as tmp_dir:
            sandbox = Path(tmp_dir) / "test_repo"

            # Dry-run on non-existent repo should not create anything
            proc = self.run_installer("--target", "all", "--mode", "local", str(sandbox), "--dry-run")
            self.assertEqual(proc.returncode, 0)
            self.assertFalse(sandbox.exists(), "Dry run must not create sandbox directory")

            # Dry-run on existing empty repo should leave it empty
            sandbox.mkdir()
            proc = self.run_installer("--target", "all", "--mode", "local", str(sandbox), "--dry-run")
            self.assertEqual(proc.returncode, 0)
            self.assertEqual(len(os.listdir(sandbox)), 0, "Dry run must not create any files or dirs")

            # Install real files, then test dry-run uninstall
            self.run_installer("--target", "all", "--mode", "local", str(sandbox), "--non-interactive")
            self.assertTrue((sandbox / ".orchestration").is_dir())

            proc_uninst = self.run_installer("--uninstall", "--mode", "local", str(sandbox), "--dry-run")
            self.assertEqual(proc_uninst.returncode, 0)
            self.assertTrue((sandbox / ".orchestration").is_dir(), "Dry-run uninstall must not remove files")
            self.assertTrue((sandbox / ".claude").is_dir())
            self.assertTrue((sandbox / ".opencode").is_dir())

    def test_python_manifest_engine_direct_api(self):
        """Direct unit testing of ManifestEngine Python API."""
        with tempfile.TemporaryDirectory() as tmp_dir:
            m_path = Path(tmp_dir) / ".orchestration" / "install_manifest.json"
            engine = ManifestEngine(m_path)

            # Record files
            f1 = Path(tmp_dir) / "test1.txt"
            f1.write_text("hello world", encoding="utf-8")
            engine.record_file(f1)

            d1 = Path(tmp_dir) / "subdir"
            d1.mkdir()
            engine.record_directory(d1)

            saved_path = engine.save(target="test", mode="local")
            self.assertEqual(saved_path, m_path)
            self.assertTrue(m_path.is_file())

            # Verify clean
            res = engine.verify()
            self.assertTrue(res["is_valid"])
            self.assertEqual(len(res["intact"]), 1)

            # Tamper
            f1.write_text("hello tampered", encoding="utf-8")
            res_tampered = engine.verify()
            self.assertFalse(res_tampered["is_valid"])
            self.assertEqual(len(res_tampered["tampered"]), 1)

            # Uninstall with force
            rollback_res = engine.uninstall(dry_run=False, force=True)
            self.assertEqual(len(rollback_res["removed_files"]), 1)
            self.assertFalse(f1.exists())

    def test_uninstaller_script_preserves_user_modified_files(self):
        """Test uninstall.sh preserves user-modified and untracked files while removing harness files."""
        with tempfile.TemporaryDirectory() as tmp_dir:
            sandbox = Path(tmp_dir) / "test_repo"
            sandbox.mkdir()

            proc_inst = self.run_installer("--target", "all", "--mode", "local", str(sandbox), "--non-interactive")
            self.assertEqual(proc_inst.returncode, 0)
            self.assertTrue((sandbox / ".orchestration").is_dir())
            self.assertTrue((sandbox / ".agents").is_symlink())
            self.assertTrue((sandbox / ".opencode" / "opencode.json").is_file())

            # User modifies opencode.json
            custom_opencode = sandbox / ".opencode" / "opencode.json"
            with open(custom_opencode, "a", encoding="utf-8") as f:
                f.write("\n// User custom comment\n")

            # User creates an untracked custom rule
            custom_rule = sandbox / ".orchestration" / "rules" / "my_custom_user_rule.md"
            custom_rule.write_text("# My Custom User Rule", encoding="utf-8")

            # Execute uninstall.sh directly via run_uninstaller
            proc_uninst = self.run_uninstaller("--local", str(sandbox), "--yes")
            self.assertEqual(proc_uninst.returncode, 0, f"Uninstaller failed: {proc_uninst.stderr}\n{proc_uninst.stdout}")

            # User-modified and untracked files must be preserved!
            self.assertTrue(custom_opencode.is_file(), "User-modified opencode.json must be preserved by uninstall.sh")
            self.assertTrue(custom_rule.is_file(), "Untracked user rule must be preserved by uninstall.sh")
            self.assertIn("Preserved user-modified files", proc_uninst.stdout)

            # Unmodified harness files must be removed
            self.assertFalse((sandbox / ".agents").exists(), ".agents symlink must be removed")
            self.assertFalse((sandbox / ".claude").exists(), ".claude directory without user files must be removed")

    def test_uninstaller_script_restores_pre_existing_settings_json(self):
        """Test uninstall.sh restores pre-existing settings.json with user keys and cleans up backup."""
        with tempfile.TemporaryDirectory() as tmp_dir:
            sandbox = Path(tmp_dir) / "test_repo"
            claude_dir = sandbox / ".claude"
            claude_dir.mkdir(parents=True)

            pre_existing = {
                "theme": "nord",
                "custom_api_endpoint": "https://api.internal.corp/v1",
                "my_special_token_id": "tok_991823",
                "permissions": {"allow": ["custom_cmd"]},
            }
            settings_file = claude_dir / "settings.json"
            settings_file.write_text(json.dumps(pre_existing, indent=2), encoding="utf-8")

            proc_inst = self.run_installer("--target", "claude", "--mode", "local", str(sandbox), "--non-interactive")
            self.assertEqual(proc_inst.returncode, 0)

            bak_file = claude_dir / "settings.json.pre-harness.bak"
            self.assertTrue(bak_file.is_file(), "settings.json.pre-harness.bak must be created on install")

            merged = json.loads(settings_file.read_text(encoding="utf-8"))
            self.assertIn("env", merged, "Merged settings should contain harness defaults")
            self.assertEqual(merged["theme"], "nord")
            self.assertEqual(merged["custom_api_endpoint"], "https://api.internal.corp/v1")

            # Execute uninstall.sh directly via run_uninstaller
            proc_uninst = self.run_uninstaller("--local", str(sandbox), "--yes")
            self.assertEqual(proc_uninst.returncode, 0, f"Uninstaller failed: {proc_uninst.stderr}\n{proc_uninst.stdout}")

            self.assertTrue(settings_file.is_file(), "settings.json must exist after uninstall")
            self.assertFalse(bak_file.exists(), "settings.json.pre-harness.bak must be removed after restore")

            restored = json.loads(settings_file.read_text(encoding="utf-8"))
            self.assertEqual(restored, pre_existing, "settings.json was not restored to its exact pre-harness state")
            self.assertNotIn("env", restored, "Harness defaults must not remain in restored settings.json")

            # Unmodified harness additions inside .claude must be removed
            self.assertFalse((claude_dir / "agents").exists())
            self.assertFalse((claude_dir / "skills").exists())
            self.assertFalse((claude_dir / "tools").exists())

    def test_pre_existing_agents_dir_backed_up_and_restored(self):
        """Test pre-existing .agents directory is backed up on install and restored on uninstall."""
        with tempfile.TemporaryDirectory() as tmp_dir:
            sandbox = Path(tmp_dir) / "test_repo"
            sandbox.mkdir()

            agents_dir = sandbox / ".agents"
            agents_dir.mkdir()
            user_agent_file = agents_dir / "my_custom_agent.md"
            user_agent_file.write_text("# My Custom Agent", encoding="utf-8")

            proc_inst = self.run_installer("--target", "agy", "--mode", "local", str(sandbox), "--non-interactive")
            self.assertEqual(proc_inst.returncode, 0)
            self.assertTrue((sandbox / ".agents").is_symlink(), ".agents should now be a symlink")
            self.assertTrue((sandbox / ".agents.pre-harness.bak").is_dir(), ".agents directory must be backed up")

            proc_uninst = self.run_uninstaller("--local", str(sandbox), "--yes")
            self.assertEqual(proc_uninst.returncode, 0)
            self.assertFalse((sandbox / ".agents").is_symlink(), ".agents must no longer be a symlink")
            self.assertTrue((sandbox / ".agents").is_dir(), ".agents must be restored as a directory")
            self.assertTrue((sandbox / ".agents" / "my_custom_agent.md").is_file(), "User agent file must be intact")
            self.assertFalse((sandbox / ".agents.pre-harness.bak").exists(), "Backup directory must be removed after restore")

    def test_gitignore_trailing_newline_safety(self):
        """Test .gitignore entries are safely appended even if file lacks a trailing newline."""
        with tempfile.TemporaryDirectory() as tmp_dir:
            sandbox = Path(tmp_dir) / "test_repo"
            sandbox.mkdir()

            gitignore = sandbox / ".gitignore"
            # Write without trailing newline
            gitignore.write_text("node_modules", encoding="utf-8")

            proc_inst = self.run_installer("--target", "all", "--mode", "local", str(sandbox), "--non-interactive")
            self.assertEqual(proc_inst.returncode, 0)

            content = gitignore.read_text(encoding="utf-8")
            lines = content.splitlines()
            self.assertIn("node_modules", lines)
            self.assertIn(".agents/", lines)
            self.assertFalse(any("node_modules.agents" in line for line in lines), "Newline was not inserted between entries")

    def test_opencode_backend_systemd_deployment_global_sandbox(self):
        """Test OpenCode backend deployment deploys systemd user units, tracks in manifest, verifies SHA256, and uninstalls cleanly."""
        with tempfile.TemporaryDirectory() as tmp_dir:
            sandbox = Path(tmp_dir) / "user_home"
            sandbox.mkdir()
            systemd_user_dir = sandbox / ".config" / "systemd" / "user"

            env = {
                "USER_HOME": str(sandbox),
                "SYSTEMD_USER_DIR": str(systemd_user_dir),
                "BACKEND_DIR": str(sandbox / ".config" / "opencode-backends"),
                "OPENCODE_HOME_DIR": str(sandbox / ".config" / "opencode"),
                "HF_TOKEN": "test_hf_token_sample",
                "ANTHROPIC_API_KEY": "test_ant_key_sample",
            }

            # 1. Install OpenCode globally in sandbox
            proc_inst = self.run_installer("--target", "opencode", "--mode", "global", "--non-interactive", env=env)
            self.assertEqual(proc_inst.returncode, 0, f"Installer failed: {proc_inst.stderr}\n{proc_inst.stdout}")

            # Verify deployed systemd user units
            expected_units = [
                "opencode-server.service",
                "opencode-agent.slice",
                "opencode-colbert-reindex.service",
                "opencode-colbert-reindex.timer",
                "opencode-sglang-ornith-35b.service",
            ]
            for unit in expected_units:
                unit_path = systemd_user_dir / unit
                self.assertTrue(unit_path.is_file(), f"Missing systemd user unit: {unit_path}")

            # Verify environment configuration and 0600 permissions
            env_file = sandbox / ".config" / "opencode-backends" / "env"
            self.assertTrue(env_file.is_file())
            self.assertEqual(oct(env_file.stat().st_mode & 0o777), "0o600")
            env_content = env_file.read_text(encoding="utf-8")
            self.assertIn("HF_TOKEN=test_hf_token_sample", env_content)
            self.assertIn("ANTHROPIC_API_KEY=test_ant_key_sample", env_content)

            # Verify opencode.json cloud fallback providers
            opencode_cfg = sandbox / ".config" / "opencode" / "opencode.json"
            self.assertTrue(opencode_cfg.is_file())
            cfg_data = json.loads(opencode_cfg.read_text(encoding="utf-8"))
            self.assertIn("anthropic", cfg_data.get("provider", {}))
            self.assertIn("google", cfg_data.get("provider", {}))

            # Verify manifest tracks deployed systemd user units
            manifest_file = sandbox / ".orchestration" / "install_manifest.json"
            self.assertTrue(manifest_file.is_file())
            manifest_data = json.loads(manifest_file.read_text(encoding="utf-8"))
            recorded_file_paths = [f["path"] for f in manifest_data.get("files", [])]
            for unit in expected_units:
                resolved_unit = str((systemd_user_dir / unit).resolve())
                self.assertIn(resolved_unit, recorded_file_paths, f"Unit {unit} was not recorded in manifest")

            # 2. Verify SHA-256 hashes via --verify
            proc_verify = self.run_installer("--verify", "--mode", "global", env=env)
            self.assertEqual(proc_verify.returncode, 0, f"Verify failed: {proc_verify.stdout}")
            self.assertIn("Verification SUCCESS", proc_verify.stdout)

            # 3. Verify tampering detection on a systemd unit
            target_unit = systemd_user_dir / "opencode-server.service"
            orig_content = target_unit.read_text(encoding="utf-8")
            target_unit.write_text(orig_content + "\n# TAMPERED INJECTION\n", encoding="utf-8")

            proc_tamper = self.run_installer("--verify", "--mode", "global", env=env)
            self.assertNotEqual(proc_tamper.returncode, 0, "Verify should fail when unit is tampered")
            self.assertIn("Tampered Files Detected", proc_tamper.stdout)
            self.assertIn("opencode-server.service", proc_tamper.stdout)

            # Restore original content for clean uninstall
            target_unit.write_text(orig_content, encoding="utf-8")

            # 4. Uninstall rolls back systemd user units
            proc_uninst = self.run_installer("--uninstall", "--mode", "global", "--non-interactive", env=env)
            self.assertEqual(proc_uninst.returncode, 0, f"Uninstall failed: {proc_uninst.stderr}\n{proc_uninst.stdout}")

            for unit in expected_units:
                unit_path = systemd_user_dir / unit
                self.assertFalse(unit_path.exists(), f"Unit {unit} was not removed by uninstall")

            # Non-purged env file must remain intact
            self.assertTrue(env_file.is_file(), "env file should be preserved on standard uninstall")

    def test_opencode_backend_systemd_deployment_local_with_systemd_flag(self):
        """Test OpenCode backend deployment in local repository mode with --systemd flag."""
        with tempfile.TemporaryDirectory() as tmp_dir:
            sandbox = Path(tmp_dir) / "workspace"
            sandbox.mkdir()
            repo_dir = sandbox / "target_project"
            repo_dir.mkdir()
            systemd_user_dir = sandbox / ".config" / "systemd" / "user"

            env = {
                "USER_HOME": str(sandbox),
                "SYSTEMD_USER_DIR": str(systemd_user_dir),
                "BACKEND_DIR": str(sandbox / ".config" / "opencode-backends"),
            }

            proc_inst = self.run_installer(
                "--target", "opencode",
                "--mode", "local",
                str(repo_dir),
                "--systemd",
                "--non-interactive",
                env=env,
            )
            self.assertEqual(proc_inst.returncode, 0, f"Installer failed: {proc_inst.stderr}\n{proc_inst.stdout}")

            # Verify systemd units deployed
            self.assertTrue((systemd_user_dir / "opencode-server.service").is_file())
            self.assertTrue((systemd_user_dir / "opencode-agent.slice").is_file())
            self.assertTrue((systemd_user_dir / "opencode-colbert-reindex.service").is_file())
            self.assertTrue((systemd_user_dir / "opencode-colbert-reindex.timer").is_file())
            self.assertTrue((systemd_user_dir / "opencode-sglang-ornith-35b.service").is_file())

            # Manifest in local repo tracks them
            manifest_file = repo_dir / ".orchestration" / "install_manifest.json"
            self.assertTrue(manifest_file.is_file())
            manifest_data = json.loads(manifest_file.read_text(encoding="utf-8"))
            recorded_file_paths = [f["path"] for f in manifest_data.get("files", [])]
            self.assertIn(str((systemd_user_dir / "opencode-server.service").resolve()), recorded_file_paths)

            # Verify integrity
            proc_verify = self.run_installer("--verify", "--mode", "local", str(repo_dir), env=env)
            self.assertEqual(proc_verify.returncode, 0)
            self.assertIn("Verification SUCCESS", proc_verify.stdout)

            # Uninstall
            proc_uninst = self.run_installer("--uninstall", "--mode", "local", str(repo_dir), "--non-interactive", env=env)
            self.assertEqual(proc_uninst.returncode, 0)
            self.assertFalse((systemd_user_dir / "opencode-server.service").exists())
            self.assertFalse((systemd_user_dir / "opencode-agent.slice").exists())

    def test_opencode_gpu_probe_tuning_in_service_unit(self):
        """Test GPU probe detects profile and tunes service unit memory fraction and context length."""
        with tempfile.TemporaryDirectory() as tmp_dir:
            sandbox = Path(tmp_dir) / "user_home"
            sandbox.mkdir()
            systemd_user_dir = sandbox / ".config" / "systemd" / "user"

            env = {
                "USER_HOME": str(sandbox),
                "SYSTEMD_USER_DIR": str(systemd_user_dir),
                "BACKEND_DIR": str(sandbox / ".config" / "opencode-backends"),
                "OPENCODE_HOME_DIR": str(sandbox / ".config" / "opencode"),
            }

            # Force rtx-5090 profile via --override-gpu
            proc_inst = self.run_installer(
                "--target", "opencode",
                "--mode", "global",
                "--override-gpu", "rtx-5090",
                "--non-interactive",
                env=env,
            )
            self.assertEqual(proc_inst.returncode, 0)

            # Check service file tuning
            unit_file = systemd_user_dir / "opencode-sglang-ornith-35b.service"
            self.assertTrue(unit_file.is_file())
            unit_content = unit_file.read_text(encoding="utf-8")
            self.assertIn("--mem-fraction-static 0.88", unit_content)
            self.assertIn('Environment="SGLANG_CONTEXT_LENGTH=262144"', unit_content)

            # Check gpu_profile.json recorded
            gpu_prof_file = sandbox / ".config" / "opencode-backends" / "gpu_profile.json"
            self.assertTrue(gpu_prof_file.is_file())
            prof_data = json.loads(gpu_prof_file.read_text(encoding="utf-8"))
            self.assertEqual(prof_data["profile"], "rtx-5090")

    def test_installer_parity_flags(self):
        """Test installer accepts and respects parity feature toggles."""
        with tempfile.TemporaryDirectory() as tmp_dir:
            sandbox = Path(tmp_dir) / "home"
            sandbox.mkdir()

            env = {
                "USER_HOME": str(sandbox),
                "SYSTEMD_USER_DIR": str(sandbox / ".config" / "systemd" / "user"),
                "BACKEND_DIR": str(sandbox / ".config" / "opencode-backends"),
                "OPENCODE_HOME_DIR": str(sandbox / ".config" / "opencode"),
            }

            proc = self.run_installer(
                "--target", "opencode",
                "--mode", "global",
                "--no-obsidian",
                "--no-vault",
                "--no-firewall",
                "--no-backends",
                "--dry-run",
                env=env,
            )
            self.assertEqual(proc.returncode, 0)
            self.assertIn("Backend SGLang systemd units skipped (--no-backends)", proc.stdout)
            self.assertIn("Obsidian installation skipped (--no-obsidian)", proc.stdout)
            self.assertIn("Vault scaffolding skipped (--no-vault)", proc.stdout)
            self.assertIn("Firewall rule management skipped (--no-firewall", proc.stdout)

    def test_uninstaller_no_backup_and_wipe_backups_flags(self):
        """Test uninstaller --no-backup and --wipe-backups flags."""
        with tempfile.TemporaryDirectory() as tmp_dir:
            sandbox = Path(tmp_dir) / "test_repo"
            sandbox.mkdir()

            # Install
            self.run_installer("--target", "all", "--mode", "local", str(sandbox), "--non-interactive")
            # Dry-run uninstall with --wipe-backups
            proc_uninst = self.run_uninstaller("--local", str(sandbox), "--wipe-backups", "--dry-run", "--yes")
            self.assertEqual(proc_uninst.returncode, 0)

    def test_non_interactive_sudo_fallback(self):
        """Test non-interactive sudo fallback outputs clear warnings to stderr and copy-paste commands."""
        with tempfile.TemporaryDirectory() as tmp_dir:
            fake_bin = Path(tmp_dir) / "bin"
            fake_bin.mkdir()
            fake_sudo = fake_bin / "sudo"
            fake_sudo.write_text("#!/bin/sh\nexit 1\n", encoding="utf-8")
            fake_sudo.chmod(0o755)

            sandbox = Path(tmp_dir) / "home"
            sandbox.mkdir()

            env = {
                "PATH": f"{fake_bin}:{os.environ.get('PATH', '')}",
                "USER_HOME": str(sandbox),
                "SYSTEMD_USER_DIR": str(sandbox / ".config" / "systemd" / "user"),
                "BACKEND_DIR": str(sandbox / ".config" / "opencode-backends"),
                "OPENCODE_HOME_DIR": str(sandbox / ".config" / "opencode"),
            }

            proc = self.run_installer(
                "--target", "opencode",
                "--mode", "global",
                "--with-firewall",
                "--no-backends",
                "--non-interactive",
                env=env,
            )
            # The installer should proceed without fatal exit and emit warnings to stderr
            self.assertIn("SUDO PRIVILEGE REQUIRED - NON-INTERACTIVE / NON-ROOT ENVIRONMENT", proc.stderr)
            self.assertIn("INSTALLATION IS INCOMPLETE WITHOUT MANUAL ROOT INTERVENTION", proc.stderr)
            self.assertIn("ATTENTION: INSTALLATION INCOMPLETE - MANUAL INTERVENTION REQUIRED", proc.stdout)
            self.assertIn("sudo ufw allow 4096/tcp comment OpenCode Server", proc.stdout)


if __name__ == "__main__":
    unittest.main()
