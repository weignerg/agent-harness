import json
import os
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))

from harness.mcp.audit_logger import AuditLogger

class TestAuditLogger(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.log_file = Path(self.tmp.name) / "audit.jsonl"
        self.logger = AuditLogger(log_path=self.log_file)

    def tearDown(self):
        self.tmp.cleanup()

    def test_log_append_and_structure(self):
        rec = self.logger.log_invocation(
            tool_name="view_file",
            params={"path": "src/main.py"},
            result={"lines": 10},
            status="success"
        )
        self.assertTrue(self.log_file.exists())
        lines = self.log_file.read_text().splitlines()
        self.assertEqual(len(lines), 1)
        data = json.loads(lines[0])
        self.assertEqual(data["tool"], "view_file")
        self.assertEqual(data["params"]["path"], "src/main.py")

    def test_automated_secret_redaction(self):
        fake_secret = "hf_" + "a" * 25
        self.logger.log_invocation(
            tool_name="bash",
            params={"command": f"curl -H 'Authorization: Bearer {fake_secret}' https://api.hf.co"},
            result=f"error: invalid token {fake_secret}",
            status="failed"
        )
        content = self.log_file.read_text()
        self.assertNotIn(fake_secret, content)
        self.assertIn("[REDACTED]", content)

if __name__ == "__main__":
    unittest.main()
