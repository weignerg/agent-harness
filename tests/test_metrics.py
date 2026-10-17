import json, os, subprocess, sys, tempfile, threading, unittest
from pathlib import Path
ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))
from harness.metrics_logger import MetricsLogger
from harness.security.secret_broker import Redactor


class MetricsTests(unittest.TestCase):
    def setUp(self):
        self.d = tempfile.TemporaryDirectory(); self.p = Path(self.d.name) / "m.jsonl"

    def tearDown(self): self.d.cleanup()

    def test_fields_and_tps(self):
        r = MetricsLogger(self.p).log("ornith-1.5-35b", 2.0, 100, 200)
        self.assertEqual(r["tokens_per_s"], 100.0)
        self.assertEqual(json.loads(self.p.read_text())["prompt_tokens"], 100)

    def test_redaction(self):
        MetricsLogger(self.p).log("m", 1, 1, 1, note="token=hf_" + "x" * 30, h="Bearer " + "a" * 30)
        t = self.p.read_text(); self.assertNotIn("xxxxxxxx", t); self.assertNotIn("aaaaaaaa", t)
        self.assertEqual(oct(self.p.stat().st_mode & 0o777), "0o600")

    def test_concurrent_no_loss_no_interleave(self):
        lg = MetricsLogger(self.p, max_bytes=10**9)
        ts = [threading.Thread(target=lambda i=i: [lg.log("m", 1, i, j) for j in range(50)]) for i in range(8)]
        [t.start() for t in ts]; [t.join() for t in ts]
        lines = self.p.read_text().splitlines(); self.assertEqual(len(lines), 400)
        [json.loads(l) for l in lines]

    def test_rotation_keeps_data(self):
        lg = MetricsLogger(self.p, max_bytes=300, backups=2)
        for i in range(30): lg.log("m", 1, i, i)
        files = sorted(self.p.parent.glob("m.jsonl*")); self.assertLessEqual(len(files), 3); self.assertGreater(len(files), 1)

    def test_diagnostics_script_reports(self):
        env = dict(os.environ, SGLANG_PORT="1", SERVICE="nonexistent-unit.service")
        r = subprocess.run([str(ROOT / "scripts/harness_diagnostics.sh")], env=env, capture_output=True, text=True)
        self.assertEqual(r.returncode, 1); self.assertIn("NOT reachable", r.stdout)
        self.assertIn("service", r.stdout); self.assertIn("gpu", r.stdout)

    def test_diagnostics_live_port(self):
        import socket
        s = socket.socket(); s.bind(("127.0.0.1", 0)); s.listen(1); port = s.getsockname()[1]
        env = dict(os.environ, SGLANG_PORT=str(port))
        r = subprocess.run([str(ROOT / "scripts/harness_diagnostics.sh")], env=env, capture_output=True, text=True)
        s.close(); self.assertIn("reachable", r.stdout); self.assertNotIn("NOT reachable", r.stdout)


if __name__ == "__main__":
    unittest.main()
