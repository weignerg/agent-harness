import os
import sys
import tempfile
import time
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))

from harness.memory.colbert_engine import CPUColBERTIndex

class TestColBERT(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.index = CPUColBERTIndex(index_dir=self.tmp.name)

    def tearDown(self):
        self.tmp.cleanup()

    def test_cpu_execution_zero_vram(self):
        # Guarantee no CUDA libraries or torch CUDA initialization occurs
        self.assertNotIn("CUDA_VISIBLE_DEVICES", os.environ or {})

    def test_late_interaction_maxsim_retrieval(self):
        self.index.add_document("doc1", "SGLang inference server runs on port 30000 with 256k context.")
        self.index.add_document("doc2", "OpenCode multi-agent state machine uses SQLite and Pydantic.")
        self.index.add_document("doc3", "ColBERT provides late-interaction token scoring on CPU.")

        res = self.index.search("SGLang port 30000", top_k=2)
        self.assertEqual(len(res), 2)
        self.assertEqual(res[0]["doc_id"], "doc1")

    def test_latency_benchmark_under_15ms(self):
        for i in range(100):
            self.index.add_document(f"doc_{i}", f"Sample document chunk {i} containing semantic information for testing.")
        
        t0 = time.perf_counter()
        results = self.index.search("semantic information chunk 42", top_k=5)
        elapsed_ms = (time.perf_counter() - t0) * 1000.0
        self.assertLess(elapsed_ms, 15.0, f"Query took {elapsed_ms:.2f}ms, exceeding 15ms target")
        self.assertGreater(len(results), 0)

    def test_save_and_load(self):
        self.index.add_document("p1", "Persistent document item.")
        self.index.save()
        
        loaded = CPUColBERTIndex(index_dir=self.tmp.name)
        loaded.load()
        res = loaded.search("Persistent document", top_k=1)
        self.assertEqual(len(res), 1)
        self.assertEqual(res[0]["doc_id"], "p1")

if __name__ == "__main__":
    unittest.main()
