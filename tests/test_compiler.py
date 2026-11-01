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
    """Test suite for SGLang Qwen 3.8/3.5 27B and Ornith 35B selectable profiles, compiler, and configurations."""

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
        """Verify config/opencode/opencode.json registers both ornith-local and local-sglang with 27B models."""
        self.assertTrue(self.opencode_json_path.exists(), "opencode.json must exist")
        with open(self.opencode_json_path, "r", encoding="utf-8") as f:
            cfg = json.load(f)

        providers = cfg.get("provider", {})
        self.assertIn("ornith-local", providers, "provider ornith-local must be registered")
        self.assertIn("local-sglang", providers, "provider local-sglang must be registered")

        # Baseline ornith-local provider preserved
        ornith_prov = providers["ornith-local"]
        ornith_models = ornith_prov.get("models", {})
        self.assertIn("ornith-1.5-35b", ornith_models)
        self.assertIn("ornith-1.5-9b", ornith_models)
        self.assertIn("qwen3.8-27b", ornith_models)
        self.assertIn("qwen3.5-27b", ornith_models)

        # local-sglang provider models
        sglang_prov = providers["local-sglang"]
        sglang_models = sglang_prov.get("models", {})
        self.assertIn("qwen3.8-27b", sglang_models)
        self.assertIn("qwen3.5-27b", sglang_models)
        self.assertIn("qwen3.5-35b-a3b", sglang_models)
        self.assertIn("ornith-1.5-35b", sglang_models)

        qwen38_27b = sglang_models["qwen3.8-27b"]
        self.assertIn("Qwen 3.8 27B", qwen38_27b.get("name", ""))
        self.assertGreaterEqual(qwen38_27b.get("context", 0), 131072)
        self.assertGreaterEqual(qwen38_27b.get("output", 0), 32768)
        self.assertEqual(qwen38_27b.get("modalities"), ["text", "image"])
        self.assertIn("high", qwen38_27b.get("variants", {}))

    def test_core_manifest_profiles_and_baseline_default(self) -> None:
        """Verify core/manifest.json preserves ornith baseline as default while declaring selectable profiles."""
        self.assertIn("model_profiles", self.manifest)
        profiles = self.manifest["model_profiles"]
        self.assertIn("ornith-1.5-35b", profiles)
        self.assertIn("qwen3.8-27b", profiles)
        self.assertIn("qwen3.5-27b", profiles)
        self.assertIn("qwen3.5-35b-a3b", profiles)

        # Default profile must remain the baseline ornith-1.5-35b
        self.assertEqual(self.manifest.get("default_model_profile"), "ornith-1.5-35b")

        # Baseline tier defaults
        tiers = self.manifest.get("model_tiers", {})
        self.assertEqual(tiers.get("heavy", {}).get("opencode"), "ornith-local/ornith-1.5-35b")
        self.assertEqual(tiers.get("workhorse", {}).get("opencode"), "ornith-local/ornith-1.5-35b")
        self.assertEqual(tiers.get("fast", {}).get("opencode"), "ornith-local/ornith-1.5-9b")

        # Selectable profiles definition
        self.assertEqual(profiles["qwen3.8-27b"].get("workhorse"), "local-sglang/qwen3.8-27b")
        self.assertEqual(profiles["qwen3.5-27b"].get("workhorse"), "local-sglang/qwen3.5-27b")
        self.assertEqual(profiles["ornith-1.5-35b"].get("workhorse"), "ornith-local/ornith-1.5-35b")

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
        """Verify compile_opencode_frontmatter preserves baseline default and respects overrides."""
        tier_models = self.manifest["model_tiers"]
        roles = self.manifest["roles"]

        # Default behavior: preserves baseline ornith-1.5-35b model
        fm_worker_default = compile_opencode_frontmatter("worker", roles["worker"], tier_models)
        self.assertIn("ornith-local/ornith-1.5-35b", fm_worker_default)

        # Explicit primary_model override (qwen3.8-27b)
        fm_worker_qwen38 = compile_opencode_frontmatter(
            "worker",
            roles["worker"],
            tier_models,
            primary_model="local-sglang/qwen3.8-27b",
        )
        self.assertIn("local-sglang/qwen3.8-27b", fm_worker_qwen38)

        # Explicit primary_model override (qwen3.5-27b)
        fm_worker_qwen35 = compile_opencode_frontmatter(
            "worker",
            roles["worker"],
            tier_models,
            primary_model="local-sglang/qwen3.5-27b",
        )
        self.assertIn("local-sglang/qwen3.5-27b", fm_worker_qwen35)

        # Leaf roles remain fast model (ornith-local/ornith-1.5-9b) regardless of primary override
        fm_grunt = compile_opencode_frontmatter(
            "grunt",
            roles["grunt"],
            tier_models,
            primary_model="local-sglang/qwen3.8-27b",
        )
        self.assertIn("ornith-local/ornith-1.5-9b", fm_grunt)

    def test_compile_agents_writes_custom_profiles_and_baseline_default(self) -> None:
        """Verify compile_agents emits agent markdown with baseline default and selectable profiles."""
        with tempfile.TemporaryDirectory() as tmp_dir:
            base_dir = Path(tmp_dir)

            # 1. Default compile (no profile passed) -> ornith-local/ornith-1.5-35b
            out_default = base_dir / "agents_default"
            compile_agents(core_dir=self.core_dir, target_runtime="opencode", output_dir=out_default)
            worker_def = (out_default / "worker.md").read_text(encoding="utf-8")
            self.assertIn("model: ornith-local/ornith-1.5-35b", worker_def)

            # 2. model_profile="qwen3.8-27b"
            out_qwen38 = base_dir / "agents_qwen38"
            compile_agents(core_dir=self.core_dir, target_runtime="opencode", output_dir=out_qwen38, model_profile="qwen3.8-27b")
            worker_q38 = (out_qwen38 / "worker.md").read_text(encoding="utf-8")
            self.assertIn("model: local-sglang/qwen3.8-27b", worker_q38)

            # 3. model_profile="qwen3.5-27b"
            out_qwen35 = base_dir / "agents_qwen35"
            compile_agents(core_dir=self.core_dir, target_runtime="opencode", output_dir=out_qwen35, model_profile="qwen3.5-27b")
            worker_q35 = (out_qwen35 / "worker.md").read_text(encoding="utf-8")
            self.assertIn("model: local-sglang/qwen3.5-27b", worker_q35)

            # 4. model_profile="27b-nvfp4"
            out_nvfp4 = base_dir / "agents_nvfp4"
            compile_agents(core_dir=self.core_dir, target_runtime="opencode", output_dir=out_nvfp4, model_profile="27b-nvfp4")
            worker_nvfp4 = (out_nvfp4 / "worker.md").read_text(encoding="utf-8")
            self.assertTrue("27b" in worker_nvfp4)

            # 5. model_profile="27b-q6"
            out_q6 = base_dir / "agents_q6"
            compile_agents(core_dir=self.core_dir, target_runtime="opencode", output_dir=out_q6, model_profile="27b-q6")
            worker_q6 = (out_q6 / "worker.md").read_text(encoding="utf-8")
            self.assertTrue("27b" in worker_q6)

    def test_install_sh_help_documents_sglang_model_flag(self) -> None:
        """Verify install.sh --help exposes --sglang-model flag and profile options."""
        res = subprocess.run(
            [str(self.install_sh_path), "--help"],
            capture_output=True,
            text=True,
            check=False,
        )
        self.assertEqual(res.returncode, 0)
        self.assertIn("--sglang-model", res.stdout)
        self.assertIn("ornith-35b", res.stdout)
        self.assertIn("qwen3.8-27b", res.stdout)
        self.assertIn("27b-nvfp4", res.stdout)
        self.assertIn("35b-a3b", res.stdout)


if __name__ == "__main__":
    unittest.main()
