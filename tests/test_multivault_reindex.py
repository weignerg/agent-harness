import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
REINDEX_SCRIPT = ROOT / "scripts" / "reindex_vault.sh"


class TestMultiVaultReindex(unittest.TestCase):
    """Multi-vault ColBERT reindexer (Issue #124): home + per-source sub-vaults."""

    def setUp(self):
        self.home = tempfile.TemporaryDirectory()
        self.user_home = self.home.name
        self.hv = Path(self.user_home) / "Vaults" / "home"
        self.repos = Path(self.user_home) / "Vaults" / "repos"
        self.hv.mkdir(parents=True)
        (self.hv / "entities").mkdir()
        (self.repos / "srcA").mkdir(parents=True)
        (self.repos / "srcA" / "projects").mkdir()
        self.env = {**os.environ, "HOME": self.user_home}
        self.env.pop("USER_HOME", None)

    def tearDown(self):
        self.home.cleanup()

    def _write(self, path, text):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)

    def _run(self, *args):
        return subprocess.run(
            [str(REINDEX_SCRIPT), *args],
            env=self.env,
            capture_output=True,
            text=True,
        )

    def test_all_mode_indexes_home_and_source(self):
        self._write(self.hv / "entities" / "model.md",
                    "---\ntitle: A\n---\nSGLang runs on port 30000.\n")
        self._write(self.repos / "srcA" / "projects" / "task.md",
                    "---\ntitle: B\n---\nFrameXML is read-only.\n")

        res = self._run("--all")
        self.assertEqual(res.returncode, 0, res.stderr)
        self.assertIn("Successfully reindexed", res.stdout)

        home_index = self.hv / ".index" / "index.json"
        srcA_index = self.repos / "srcA" / ".index" / "index.json"
        self.assertTrue(home_index.exists(), "home index must exist")
        self.assertTrue(srcA_index.exists(), "source sub-vault index must exist")

        home_docs = json.loads(home_index.read_text()).get("doc_ids", [])
        srcA_docs = json.loads(srcA_index.read_text()).get("doc_ids", [])
        self.assertEqual(len(home_docs), 1, "home index should contain 1 doc")
        self.assertEqual(len(srcA_docs), 1, "source sub-vault should contain 1 doc")

    def test_sources_are_isolated(self):
        self._write(self.hv / "projects" / "note.md",
                    "---\ntitle: A\n---\nSGLang runs on port 30000.\n")
        self._write(self.repos / "srcA" / "projects" / "task.md",
                    "---\ntitle: B\n---\nFrameXML is read-only.\n")

        self._run("--all")

        home_docs = json.loads((self.hv / ".index" / "index.json").read_text()).get("doc_ids", [])
        srcA_docs = json.loads((self.repos / "srcA" / ".index" / "index.json").read_text()).get("doc_ids", [])
        self.assertIn("projects/note.md", home_docs)
        self.assertIn("projects/task.md", srcA_docs)
        self.assertNotIn("projects/note.md", srcA_docs, "home note must not leak into source index")

    def test_index_written_to_index_dir_not_vault_root(self):
        self._write(self.hv / "entities" / "model.md",
                    "---\ntitle: A\n---\nSGLang runs on port 30000.\n")

        self._run("--all")

        self.assertTrue((self.hv / ".index" / "index.json").exists())
        self.assertFalse((self.hv / "index.json").exists(),
                         "index.json must be written to .index/, never the vault root")

    def test_hidden_directories_are_skipped(self):
        self._write(self.hv / "entities" / "model.md",
                    "---\ntitle: A\n---\nSGLang runs on port 30000.\n")
        self._write(self.hv / ".obsidian" / "workspace.json", '{"files": []}')

        self._run("--all")

        docs = json.loads((self.hv / ".index" / "index.json").read_text()).get("doc_ids", [])
        self.assertEqual(len(docs), 1, "notes under .obsidian/ must be skipped")

    def test_single_target_mode(self):
        self._write(self.hv / "entities" / "model.md",
                    "---\ntitle: A\n---\nSGLang runs on port 30000.\n")
        self._write(self.repos / "srcA" / "projects" / "task.md",
                    "---\ntitle: B\n---\nFrameXML is read-only.\n")

        res = self._run(str(self.hv))
        self.assertEqual(res.returncode, 0, res.stderr)

        self.assertTrue((self.hv / ".index" / "index.json").exists())
        self.assertFalse((self.repos / "srcA" / ".index" / "index.json").exists(),
                         "only the requested target should be reindexed")

    def test_falls_back_to_repo_vault_when_no_vaults(self):
        # Use a temp HOME that has no ~/Vaults tree at all.
        with tempfile.TemporaryDirectory() as bare_home:
            env = {**os.environ, "HOME": bare_home}
            env.pop("USER_HOME", None)
            res = subprocess.run(
                [str(REINDEX_SCRIPT), "--all"],
                env=env,
                capture_output=True,
                text=True,
            )
        self.assertEqual(res.returncode, 0, res.stderr)
        # With no ~/Vaults present, the reindexer still indexes the repo vault.
        self.assertIn("Successfully reindexed", res.stdout)
        self.assertTrue((ROOT / "vault" / ".index" / "index.json").exists())


if __name__ == "__main__":
    unittest.main()
