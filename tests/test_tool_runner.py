import asyncio
import os
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))

from harness.mcp.tool_runner import DynamicToolRegistry, EphemeralToolRunner

class TestToolRunner(unittest.TestCase):
    def setUp(self):
        self.registry = DynamicToolRegistry()
        self.registry.register_core_tool("echo_core", lambda msg: f"core:{msg}")
        self.registry.register_core_tool("upper_core", lambda msg: msg.upper())

    def test_core_tools(self):
        res = asyncio.run(self.registry.call_tool_async("echo_core", {"msg": "hello"}))
        self.assertEqual(res, "core:hello")

    def test_ephemeral_uv_run_execution(self):
        script_body = """
import sys, json

data = json.load(sys.stdin)
num = data.get("num", 0)
print(json.dumps({"squared": num * num}))
"""
        self.registry.register_dynamic_tool("square_tool", script_body)
        res = asyncio.run(self.registry.call_tool_async("square_tool", {"num": 5}))
        self.assertTrue(res["ok"])
        self.assertEqual(res["result"]["squared"], 25)

    def test_parallel_batch_tool_calling(self):
        calls = [
            {"name": "echo_core", "kwargs": {"msg": "one"}},
            {"name": "upper_core", "kwargs": {"msg": "two"}},
            {"name": "echo_core", "kwargs": {"msg": "three"}},
        ]
        results = asyncio.run(self.registry.batch_call_tools(calls))
        self.assertEqual(len(results), 3)
        self.assertEqual(results[0]["result"], "core:one")
        self.assertEqual(results[1]["result"], "TWO")
        self.assertEqual(results[2]["result"], "core:three")

    def test_batch_call_error_handling(self):
        calls = [
            {"name": "echo_core", "kwargs": {"msg": "valid"}},
            {"name": "non_existent_tool", "kwargs": {}},
        ]
        results = asyncio.run(self.registry.batch_call_tools(calls))
        self.assertEqual(len(results), 2)
        self.assertTrue(results[0]["ok"])
        self.assertFalse(results[1]["ok"])
        self.assertIn("Unknown tool", results[1]["error"])

if __name__ == "__main__":
    unittest.main()
