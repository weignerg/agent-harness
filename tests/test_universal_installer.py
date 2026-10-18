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


if __name__ == "__main__":
    unittest.main()
