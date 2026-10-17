import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))

from harness.security.red_team import scan_for_vulnerabilities

class TestRedTeam(unittest.TestCase):
    def test_repo_scan_clean(self):
        clean, findings = scan_for_vulnerabilities(ROOT)
        self.assertTrue(clean, f"Repository security scan flagged issues: {findings}")

if __name__ == "__main__":
    unittest.main()
