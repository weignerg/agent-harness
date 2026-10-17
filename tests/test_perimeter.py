import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))

from harness.memory.perimeter import check_note_safety

class TestPerimeter(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.note = Path(self.tmp.name) / "note.md"

    def tearDown(self):
        self.tmp.cleanup()

    def test_safe_note(self):
        self.note.write_text("""# Architectural Note
Refer to `harness/orchestrator/state_machine.py` at line 42 for `run_step`.
```python
def snippet():
    pass
```
""")
        safe, errors = check_note_safety(self.note)
        self.assertTrue(safe, f"Safe note marked unsafe: {errors}")

    def test_reject_oversized_code_block(self):
        code = "\n".join(f"line_{i} = {i}" for i in range(50))
        self.note.write_text(f"""# Code Dump
```python
{code}
```
""")
        safe, errors = check_note_safety(self.note)
        self.assertFalse(safe)
        self.assertIn("exceeds maximum allowed size", errors[0])

    def test_reject_secret_in_note(self):
        secret = "hf_" + "a" * 25
        self.note.write_text(f"# Secrets\nKey is {secret}")
        safe, errors = check_note_safety(self.note)
        self.assertFalse(safe)
        self.assertIn("secret pattern detected", errors[0])

if __name__ == "__main__":
    unittest.main()
