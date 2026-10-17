import json
import os
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))

try:
    import jsonschema
except ImportError:
    jsonschema = None

try:
    from harness.mcp.server import (
        server,
        view_file,
        replace_file_content,
        write_to_file,
        bash,
        colbert_retrieve,
        check_command_safety,
        get_strict_schemas,
    )
    from harness.mcp.vault_server import colbert_retrieve as vault_colbert_retrieve
    from harness.mcp.worktree_server import worktree_list as mcp_worktree_list
    HAS_FASTMCP = True
except ImportError:
    HAS_FASTMCP = False

class TestFastMCPServer(unittest.TestCase):
    def setUp(self):
        if not HAS_FASTMCP:
            self.skipTest("fastmcp dependencies not available in current python environment")
        self.tmp_dir = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp_dir.name)

    def tearDown(self):
        if hasattr(self, "tmp_dir"):
            self.tmp_dir.cleanup()

    def test_schemas_strict_draft202012(self):
        if jsonschema is None:
            self.skipTest("jsonschema not installed in current python environment")
        schemas = get_strict_schemas()
        self.assertIn("view_file", schemas)
        self.assertIn("replace_file_content", schemas)
        self.assertIn("write_to_file", schemas)
        self.assertIn("bash", schemas)
        for name, schema in schemas.items():
            self.assertEqual(schema.get("additionalProperties"), False, f"{name} missing additionalProperties: False")
            self.assertEqual(schema.get("strict"), True, f"{name} missing strict: True")
            jsonschema.Draft202012Validator.check_schema(schema)

    def test_view_file_slicing(self):
        f = self.root / "test.txt"
        f.write_text("line1\nline2\nline3\nline4\nline5\n")
        res = view_file(str(f), start_line=2, end_line=4)
        lines = res.splitlines()
        self.assertEqual(len(lines), 3)
        self.assertIn("line2", lines[0])
        self.assertIn("line4", lines[2])

    def test_replace_file_content_unique(self):
        f = self.root / "test.txt"
        f.write_text("foo bar baz foo")
        # Non-unique replace raises ValueError
        with self.assertRaises(ValueError):
            replace_file_content(str(f), target="foo", replacement="qux")
        # Unique replace succeeds
        replace_file_content(str(f), target="bar", replacement="qux")
        self.assertEqual(f.read_text(), "foo qux baz foo")

    def test_write_to_file_guards(self):
        f = self.root / "out.txt"
        write_to_file(str(f), "initial")
        self.assertEqual(f.read_text(), "initial")
        # Overwrite denied without flag
        with self.assertRaises(FileExistsError):
            write_to_file(str(f), "new")
        # Overwrite succeeds
        write_to_file(str(f), "overwritten", overwrite=True)
        self.assertEqual(f.read_text(), "overwritten")
        # Append succeeds
        write_to_file(str(f), "_appended", append=True)
        self.assertEqual(f.read_text(), "overwritten_appended")

    def test_bash_dangerous_guardrails(self):
        self.assertIsNotNone(check_command_safety("rm -rf /some/dir"))
        self.assertIsNotNone(check_command_safety("git reset --hard HEAD~1"))
        self.assertIsNotNone(check_command_safety("chmod 777 script.sh"))
        self.assertIsNone(check_command_safety("ls -la"))

        # Dangerous command blocked without approval
        res = bash("rm -rf /fake/path")
        self.assertEqual(res["status"], "blocked")
        self.assertEqual(res["returncode"], 126)

        # Dangerous command executed with approval
        res = bash("echo 'safe override'", allow_dangerous=True)
        self.assertEqual(res["status"], "executed")
        self.assertIn("safe override", res["stdout"])

    def test_colbert_retrieve_tool(self):
        vault_mock = self.root / "vault"
        vault_mock.mkdir()
        doc = vault_mock / "note.md"
        doc.write_text("SGLang inference engine with 256k context on modern GPU hardware.")

        res = colbert_retrieve(query="SGLang inference", top_k=2, index_dir=str(vault_mock))
        self.assertGreater(len(res), 0)
        self.assertEqual(res[0]["doc_id"], "note.md")
        self.assertIn("GPU hardware", res[0]["text"])

    def test_vault_server_colbert(self):
        vault_mock = self.root / "vault_server_dir"
        vault_mock.mkdir()
        doc = vault_mock / "arch.md"
        doc.write_text("ColBERT late-interaction CPU retrieval with MaxSim.")

        res = vault_colbert_retrieve(query="MaxSim CPU", top_k=2, index_dir=str(vault_mock))
        self.assertGreater(len(res), 0)
        self.assertEqual(res[0]["doc_id"], "arch.md")
        self.assertIn("MaxSim", res[0]["text"])

    def test_worktree_server_list(self):
        trees = mcp_worktree_list()
        self.assertIsInstance(trees, list)
        self.assertGreater(len(trees), 0)
        self.assertTrue(any("path" in t for t in trees))

if __name__ == "__main__":
    unittest.main()
