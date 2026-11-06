import unittest
from pathlib import Path
from harness.orchestrator.model_proxy import ModelRouter

class TestModelRouter(unittest.TestCase):
    def setUp(self):
        self.router = ModelRouter()
        self.router.load_catalog()

    def test_catalog_loaded(self):
        self.assertGreater(len(self.router.catalog), 0)

    def test_resolve_ornith_35b(self):
        res = self.router.resolve_model_service("ornith-1.5-35b")
        self.assertIsNotNone(res)
        self.assertEqual(res[0], "opencode-sglang-ornith-35b")
        self.assertEqual(res[1], "opencode-sglang-ornith-35b.service")

    def test_resolve_ornith_9b(self):
        res = self.router.resolve_model_service("ornith-1.5-9b")
        self.assertIsNotNone(res)
        self.assertEqual(res[0], "ornith-1.5-9b-nvfp4-low-ctx")
        self.assertEqual(res[1], "ornith-1.5-9b-nvfp4-low-ctx.service")

    def test_resolve_qwen_27b(self):
        res = self.router.resolve_model_service("qwen-3.8-27b")
        self.assertIsNotNone(res)
        self.assertEqual(res[0], "qwen-3.8-27b-nvfp4-med-ctx")
        self.assertEqual(res[1], "qwen-3.8-27b-nvfp4-med-ctx.service")

    def test_resolve_with_provider_prefix(self):
        res = self.router.resolve_model_service("local-sglang/ornith-1.5-35b")
        self.assertIsNotNone(res)
        self.assertEqual(res[0], "opencode-sglang-ornith-35b")

if __name__ == "__main__":
    unittest.main()
