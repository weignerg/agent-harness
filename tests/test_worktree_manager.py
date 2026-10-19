import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))

from scripts.worktree_manager import WorktreeManager

class TestWorktreeManager(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.mgr = WorktreeManager(repo_dir=ROOT)
        self.target = Path(self.tmp.name) / "ephemeral_wt"
        import uuid
        self.branch = f"test-ephemeral-wt-{uuid.uuid4().hex[:8]}"

    def tearDown(self):
        self.mgr.prune_worktree(self.target)
        import subprocess
        subprocess.run(["git", "branch", "-D", self.branch], cwd=ROOT, check=False, capture_output=True)
        self.tmp.cleanup()

    def test_provision_and_prune(self):
        self.mgr.provision_worktree(self.branch, self.target)
        self.assertTrue(self.target.exists())
        self.assertTrue((self.target / ".git").exists())
        self.mgr.prune_worktree(self.target)
        self.assertFalse(self.target.exists())

    def test_provision_with_custom_base(self):
        nested_branch = f"{self.branch}-nested"
        nested_target = Path(self.tmp.name) / "nested_wt"
        try:
            self.mgr.provision_worktree(self.branch, self.target, base="HEAD")
            self.mgr.provision_worktree(nested_branch, nested_target, base=self.branch)
            self.assertTrue(nested_target.exists())
            self.assertTrue((nested_target / ".git").exists())
        finally:
            self.mgr.prune_worktree(nested_target)
            self.mgr.prune_worktree(self.target)
            import subprocess
            subprocess.run(["git", "branch", "-D", nested_branch], cwd=ROOT, check=False, capture_output=True)

    def test_provision_existing_branch(self):
        # First provision creates branch
        self.mgr.provision_worktree(self.branch, self.target)
        self.mgr.prune_worktree(self.target)
        # Second provision re-attaches existing branch without error
        re_target = Path(self.tmp.name) / "re_wt"
        try:
            self.mgr.provision_worktree(self.branch, re_target)
            self.assertTrue(re_target.exists())
        finally:
            self.mgr.prune_worktree(re_target)

if __name__ == "__main__":
    unittest.main()
