import os, stat, sys, tempfile, time, unittest
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
from harness.security import secret_broker as sb


def fake_bin(d, name, body):
    p = Path(d) / name
    p.write_text("#!/usr/bin/env bash\n" + body)
    p.chmod(p.stat().st_mode | stat.S_IEXEC)


class BrokerTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.old = os.environ["PATH"]
        os.environ["PATH"] = self.tmp.name + os.pathsep + self.old

    def tearDown(self):
        os.environ["PATH"] = self.old
        self.tmp.cleanup()

    def test_op_fetch_and_child_env_and_redaction(self):
        fake_bin(self.tmp.name, "op", 'printf "%s" "hf_ABCDEFGHIJKLMNOPQRSTUVWX"')
        b = sb.SecretBroker()
        rc, out, err = b.run_child(["bash", "-c", 'echo "tok=$HF_TOKEN"; echo "$HF_TOKEN" >&2'],
                                   {"HF_TOKEN": "op://Dev/hf/token"})
        self.assertEqual(rc, 0)
        self.assertNotIn("ABCDEFGH", out + err)
        self.assertIn(sb.MASK, out)
        self.assertNotIn("HF_TOKEN", os.environ)

    def test_kwallet_timeout_is_2s_clean_error(self):
        fake_bin(self.tmp.name, "kwalletcli", "sleep 30")
        t = time.time()
        with self.assertRaises(sb.SecretBrokerError) as cm:
            sb.fetch_kwallet("f", "e")
        self.assertLess(time.time() - t, 4)
        self.assertIn("timed out after 2s", str(cm.exception))

    def test_kwallet_ref_and_missing_backend(self):
        fake_bin(self.tmp.name, "kwalletcli", 'echo "pw-$2-$4"')
        self.assertEqual(sb.SecretBroker().resolve({"X": "kwallet://fold/ent"})["X"], "pw-fold-ent")
        os.environ["PATH"] = self.tmp.name  # no `op`
        with self.assertRaises(sb.SecretBrokerError):
            sb.fetch_op("op://a/b/c")

    def test_bad_refs(self):
        for ref in ("plain", "kwallet://onlyfolder", "http://x"):
            with self.assertRaises(sb.SecretBrokerError):
                sb.SecretBroker().resolve({"X": ref})

    def test_pattern_redaction_and_logs(self):
        r = sb.Redactor()
        text = "ghp_" + "a" * 30 + " Bearer abcdefghijklmnopqrstuv password=hunter22 sk-" + "b" * 24
        out = r.redact(text)
        for leak in ("ghp_a", "abcdefghijklmnop", "hunter22", "sk-bbbb"):
            self.assertNotIn(leak, out)
        r.register("custom-secret-value")
        self.assertEqual(r.redact("x custom-secret-value y"), f"x {sb.MASK} y")

    def test_no_disk_persistence(self):
        fake_bin(self.tmp.name, "op", 'printf "%s" "zzSECRETzz"')
        before = set(Path(self.tmp.name).iterdir())
        sb.SecretBroker().resolve({"K": "op://v/i/f"})
        self.assertEqual(before, set(Path(self.tmp.name).iterdir()))


if __name__ == "__main__":
    unittest.main()
