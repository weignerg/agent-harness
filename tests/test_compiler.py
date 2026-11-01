"""Unit and integration tests for Model Compiler and SGLang Selectable Profiles (Issue #16)."""
from __future__ import annotations

import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path

from harness.installer.compiler import (
    compile_agents,
    compile_opencode_frontmatter,
)

REPO_ROOT = Path(__file__).resolve().parent.parent


class TestModelCompilerAndProfiles(unittest.TestCase):
    """Test suite for SGLang Qwen 3.5 27B / 35B selectable profiles, compiler, and configurations."""

    def setUp(self) -> None:
        self.core_dir = REPO_ROOT / "core"
        self.opencode_json_path = REPO_ROOT / "config" / "opencode" / "opencode.json"
        self.manifest_path = self.core_dir / "manifest.json"
        self.qwen27b_service_path = REPO_ROOT / "config" / "systemd" / "opencode-sglang-qwen27b.service"
        self.qwen35b_service_path = REPO_ROOT / "config" / "systemd" / "opencode-sglang-qwen35b.service"
        self.install_sh_path = REPO_ROOT / "install.sh"

        with open(self.manifest_path, "r", encoding="utf-8") as f:
            self.manifest = json.load(f)

    def test_opencode_json_defines_selectable_sglang_models(self) -> None:
        """Verify config/opencode/opencode.json registers local-sglang provider and qwen models."""
        self.assertTrue(self.opencode_json_path.exists(), "opencode.json must exist")
        with open(self.opencode_json_path, "r", encoding="utf-8") as f:
            cfg = json.load(f)

        providers = cfg.get("provider", {})
        self.assertIn("local-sglang", providers, "provider local-sglang must be registered")

        sglang_provider = providers["local-sglang"]
        self.assertEqual(sglang_provider.get("npm"), "@ai-sdk/openai-compatible")
        options = sglang_provider.get("options", {})
        self.assertEqual(options.get("baseURL"), "http://127.0.0.1:30000/v1")
        self.assertEqual(options.get("apiKey"), "EMPTY")

        models = sglang_provider.get("models", {})
        self.assertIn("qwen3.5-27b", models, "qwen3.5-27b model must be registered")
        self.assertIn("qwen3.5-35b-a3b", models, "qwen3.5-35b-a3b model must be registered")
        self.assertIn("qwen3.5-9b", models, "qwen3.5-9b model must be registered")

        qwen27b = models["qwen3.5-27b"]
        self.assertIn("Qwen 3.5 27B", qwen27b.get("name", ""))
        self.assertGreaterEqual(qwen27b.get("context", 0), 131072, "qwen3.5-27b context must be at least 131072")
        self.assertGreaterEqual(qwen27b.get("output", 0), 32768, "qwen3.5-27b output must be at least 32768")
        self.assertEqual(qwen27b.get("modalities"), ["text", "image"])

        variants = qwen27b.get("variants", {})
        self.assertIn("high", variants)
        self.assertIn("medium", variants)
        self.assertIn("low", variants)
        self.assertEqual(variants["high"].get("reasoningEffort"), "high")

    def test_core_manifest_profiles(self) -> None:
        """Verify core/manifest.json declares model_profiles and default_model_profile."""
        self.assertIn("model_profiles", self.manifest)
        profiles = self.manifest["model_profiles"]
        self.assertIn("qwen3.5-35b-a3b", profiles)
        self.assertIn("qwen3.5-27b", profiles)

        prof27 = profiles["qwen3.5-27b"]
        self.assertEqual(prof27.get("heavy"), "local-sglang/qwen3.5-27b")
        self.assertEqual(prof27.get("workhorse"), "local-sglang/qwen3.5-27b")
        self.assertEqual(prof27.get("fast"), "local-sglang/qwen3.5-9b")

        prof35 = profiles["qwen3.5-35b-a3b"]
        self.assertEqual(prof35.get("heavy"), "local-sglang/qwen3.5-35b-a3b")
        self.assertEqual(prof35.get("workhorse"), "local-sglang/qwen3.5-35b-a3b")
        self.assertEqual(prof35.get("fast"), "local-sglang/qwen3.5-9b")

        self.assertEqual(self.manifest.get("default_model_profile"), "qwen3.5-35b-a3b")

    def test_qwen27b_service_unit_configuration(self) -> None:
        """Verify opencode-sglang-qwen27b.service parameters meet Issue #16 criteria."""
        self.assertTrue(self.qwen27b_service_path.exists(), "opencode-sglang-qwen27b.service must exist")
        content = self.qwen27b_service_path.read_text(encoding="utf-8")

        # 100% VRAM residency / quantization flags
        self.assertIn("fp8_e4m3", content, "KV-cache dtype must be fp8_e4m3")
        self.assertIn("--kv-cache-dtype", content, "Service must specify --kv-cache-dtype")
        self.assertIn("flashinfer", content, "Attention backend must be flashinfer")
        self.assertIn("--tool-call-parser qwen3_coder", content, "Tool-call parser must be qwen3_coder")
        self.assertIn("--reasoning-parser qwen3", content, "Reasoning parser must be qwen3")
        self.assertIn("--port 30000", content, "Port must be 30000")
        self.assertIn("--host 127.0.0.1", content, "Host must be 127.0.0.1")
        self.assertIn("SGLANG_SERVICE=opencode-sglang-qwen27b.service", content)
        self.assertTrue(
            "--speculative-algorithm" in content or "SGLANG_27B_SPECULATIVE" in content,
            "Service unit must configure speculative decoding",
        )

    def test_qwen35b_service_symlink_or_unit_exists(self) -> None:
        """Verify opencode-sglang-qwen35b.service exists."""
        self.assertTrue(self.qwen35b_service_path.exists(), "opencode-sglang-qwen35b.service must exist")

    def test_compiler_frontmatter_model_profile_resolution(self) -> None:
        """Verify compile_opencode_frontmatter selects appropriate model based on overrides."""
        tier_models = self.manifest["model_tiers"]
        roles = self.manifest["roles"]

        # Default behavior: 35B model
        fm_worker_default = compile_opencode_frontmatter("worker", roles["worker"], tier_models)
        self.assertIn("local-sglang/qwen3.5-35b-a3b", fm_worker_default)

        # Explicit primary_model override (e.g. 27B)
        fm_worker_override = compile_opencode_frontmatter(
            "worker",
            roles["worker"],
            tier_models,
            primary_model="local-sglang/qwen3.5-27b",
        )
        self.assertIn("local-sglang/qwen3.5-27b", fm_worker_override)

        # Leaf roles remain 9b regardless of primary model override
        fm_grunt = compile_opencode_frontmatter(
            "grunt",
            roles["grunt"],
            tier_models,
            primary_model="local-sglang/qwen3.5-27b",
        )
        self.assertIn("local-sglang/qwen3.5-9b", fm_grunt)

    def test_compile_agents_writes_custom_profile(self) -> None:
        """Verify compile_agents emits agent markdown with specified model profile."""
        with tempfile.TemporaryDirectory() as tmp_dir:
            out_dir = Path(tmp_dir) / "opencode" / "agents"
            compile_agents(
                core_dir=self.core_dir,
                target_runtime="opencode",
                output_dir=out_dir,
                model_profile="qwen3.5-27b",
            )
            worker_file = out_dir / "worker.md"
            self.assertTrue(worker_file.exists())
            worker_content = worker_file.read_text(encoding="utf-8")
            self.assertIn("model: local-sglang/qwen3.5-27b", worker_content)

            scout_file = out_dir / "scout.md"
            self.assertTrue(scout_file.exists())
            scout_content = scout_file.read_text(encoding="utf-8")
            self.assertIn("model: local-sglang/qwen3.5-9b", scout_content)

    def test_install_sh_help_documents_sglang_model_flag(self) -> None:
        """Verify install.sh --help exposes --sglang-model flag."""
        res = subprocess.run(
            [str(self.install_sh_path), "--help"],
            capture_output=True,
            text=True,
            check=False,
        )
        self.assertEqual(res.returncode, 0)
        self.assertIn("--sglang-model", res.stdout)
        self.assertIn("27b-nvfp4", res.stdout)
        self.assertIn("35b-a3b", res.stdout)


if __name__ == "__main__":
    unittest.main()
