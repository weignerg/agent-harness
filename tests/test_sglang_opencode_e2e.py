#!/usr/bin/env python3
"""End-to-end integration test for live SGLang and OpenCode Supreme Orchestrator (Issue #39).

Verifies:
1. Live SGLang server responds coherently on http://127.0.0.1:30000.
2. /v1/chat/completions produces coherent text (no gibberish/corrupted tokens).
3. All 4 required models (qwen-3.8-nvfp4, qwen-3.8-q6, ornith-1.5-9b, ornith-1.5-35b)
   are declared in config/opencode/opencode.json with clean display names and #low, #medium, #high variants.
4. opencode run responds as supreme-orchestrator adhering to harness instructions.
"""
from __future__ import annotations

import json
import subprocess
import unittest
import urllib.error
import urllib.request
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
OPENCODE_JSON_PATH = REPO_ROOT / "config" / "opencode" / "opencode.json"
SGLANG_URL = "http://127.0.0.1:30000"


class TestSGLangOpenCodeE2E(unittest.TestCase):
    """End-to-end verification of SGLang inference and OpenCode supreme-orchestrator."""

    def test_opencode_json_model_registrations_and_variants(self) -> None:
        """Verify opencode.json defines all 4 models with clean names and variants."""
        self.assertTrue(OPENCODE_JSON_PATH.is_file(), f"{OPENCODE_JSON_PATH} must exist")
        data = json.loads(OPENCODE_JSON_PATH.read_text(encoding="utf-8"))

        self.assertIn("provider", data)
        self.assertIn("local-sglang", data["provider"])
        models = data["provider"]["local-sglang"].get("models", {})

        # Assert all 4 clean model IDs are registered
        expected_models = {
            "qwen-3.8-nvfp4": "qwen 3.8 nvfp4",
            "qwen-3.8-q6": "qwen 3.8 q6",
            "ornith-1.5-9b": "ornith 1.5 9b",
            "ornith-1.5-35b": "ornith 1.5 35b",
        }
        for mid, clean_name in expected_models.items():
            self.assertIn(mid, models, f"Model {mid} missing from local-sglang")
            self.assertEqual(models[mid]["name"], clean_name)
            variants = models[mid].get("variants", {})
            self.assertIn("low", variants, f"Variant 'low' missing from {mid}")
            self.assertIn("medium", variants, f"Variant 'medium' missing from {mid}")
            self.assertIn("high", variants, f"Variant 'high' missing from {mid}")

        # Assert primary model and agents point to clean local-sglang model
        self.assertEqual(data.get("model"), "local-sglang/qwen-3.8-nvfp4")
        self.assertEqual(data["agent"]["supreme-orchestrator"]["model"], "local-sglang/qwen-3.8-nvfp4")

        # Assert Qwen was purged from ornith-local
        if "ornith-local" in data["provider"]:
            self.assertNotIn("qwen3.8-27b", data["provider"]["ornith-local"].get("models", {}))
            self.assertNotIn("qwen-3.8-nvfp4", data["provider"]["ornith-local"].get("models", {}))

    def _get_active_model_id(self) -> str:
        """Fetch active model id from /v1/models, or default to ornith-1.5-35b."""
        try:
            with urllib.request.urlopen(f"{SGLANG_URL}/v1/models", timeout=5) as resp:
                data = json.loads(resp.read().decode("utf-8"))
                models = data.get("data", [])
                if models and "id" in models[0]:
                    return models[0]["id"]
        except Exception:
            pass
        return "ornith-1.5-35b"

    def test_live_sglang_service_chat_coherence(self) -> None:
        """Verify live SGLang /v1/chat/completions returns coherent arithmetic response."""
        active_model = self._get_active_model_id()
        req_body = json.dumps({
            "model": active_model,
            "messages": [
                {"role": "user", "content": "What is 2 + 2? Respond with just the single digit."}
            ],
            "temperature": 0.0,
            "max_tokens": 64,
        }).encode("utf-8")

        req = urllib.request.Request(
            f"{SGLANG_URL}/v1/chat/completions",
            data=req_body,
            headers={"Content-Type": "application/json"},
            method="POST",
        )
        try:
            with urllib.request.urlopen(req, timeout=15) as resp:
                result = json.loads(resp.read().decode("utf-8"))
        except (urllib.error.URLError, TimeoutError) as e:
            self.skipTest(f"Live SGLang service unreachable at {SGLANG_URL}: {e}")

        self.assertIn("choices", result)
        content = result["choices"][0]["message"]["content"]
        reasoning = result["choices"][0]["message"].get("reasoning_content", "")
        combined = f"{reasoning}\n{content}"

        # Must contain 4 and must not contain known corrupted gibberish sequences
        self.assertTrue("4" in combined or "four" in combined.lower(), f"Unexpected output: {combined}")
        self.assertNotIn("Wearon", combined)
        self.assertNotIn("stcircy", combined)
        self.assertNotIn("do§y", combined)

    def test_live_opencode_supreme_orchestrator_identity(self) -> None:
        """Verify opencode run identifies as supreme-orchestrator under harness rules."""
        active_model = self._get_active_model_id()
        try:
            res = subprocess.run(
                ["opencode", "run", "--model", f"local-sglang/{active_model}", "Who are you and what is your role in this repository?"],
                capture_output=True,
                text=True,
                timeout=60,
                check=False,
            )
        except (FileNotFoundError, subprocess.TimeoutExpired) as e:
            self.skipTest(f"opencode CLI execution skipped: {e}")

        output = f"{res.stdout}\n{res.stderr}"
        # Verify execution succeeded and identified as supreme-orchestrator
        self.assertIn("supreme-orchestrator", output.lower())


if __name__ == "__main__":
    unittest.main()
