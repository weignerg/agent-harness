"""
tests/test_gpu_probe.py: Comprehensive test suite for harness.hardware.probe (Issue #4).

Covers:
  - Mock profiles: RTX 5090, H100, RTX Spark (>=100GB), RTX 4090 (24GB), 16GB, 12GB, 8GB, fallback
  - VFIO passthrough & non-nvidia driver filtering
  - Compute capability < 8.0 filtering
  - Multi-GPU logic: homogeneous aggregation vs heterogeneous primary selection
  - Guarded CPU offload rules (strict: never offload when VRAM holds context)
  - NVML mismatch recovery via Tier 3 procfs/sysfs
  - Serialization: JSON, env, flags formats
  - CLI overrides: --override-gpu and --target-context
  - Live host sanity check (RTX 5090 Threadripper classification)
"""

import json
import os
import shutil
import tempfile
import unittest
from unittest.mock import MagicMock, patch

from harness.hardware.probe import (
    GPUInfo,
    HardwareProbe,
    SystemResources,
    classify_model_sizing,
    classify_profile,
    compute_dynamic_vram_spillover,
    evaluate_multi_gpu,
    filter_compute_gpus,
    probe_hardware,
    probe_tier1_torch,
    probe_tier2_nvidia_smi,
    probe_tier3_procfs_sysfs,
)


class TestGPUProfileClassification(unittest.TestCase):
    """Test model sizing, memory fraction, context window, and guarded offload matrix."""

    def test_rtx_5090_classification(self):
        gpu = GPUInfo(
            index=0,
            name="NVIDIA GeForce RTX 5090",
            memory_total_mb=32768,
            compute_cap=12.0,
            driver="nvidia",
        )
        p = classify_profile(
            effective_vram_gb=32.0,
            primary_gpu=gpu,
            host_ram_gb=128.0,
            host_cpu_cores=24,
            tier="mock",
        )
        self.assertEqual(p.profile, "rtx-5090")
        self.assertEqual(p.model, "ornith-1.5-35b")
        self.assertEqual(p.model_path, "ornith-ai/Ornith-1.5-35B-A3B-NVFP4")
        self.assertEqual(p.service, "sglang-ornith-1.5-35b.service")
        self.assertEqual(p.max_context, 262144)
        self.assertEqual(p.memory_fraction, 0.88)
        self.assertFalse(p.cpu_offload)
        self.assertEqual(p.cpu_offload_gb, 0)
        self.assertEqual(p.offload, "pure-gpu")

    def test_h100_classification(self):
        gpu = GPUInfo(
            index=0,
            name="NVIDIA H100 80GB HBM3",
            memory_total_mb=81920,
            compute_cap=9.0,
            driver="nvidia",
        )
        p = classify_profile(
            effective_vram_gb=80.0,
            primary_gpu=gpu,
            host_ram_gb=256.0,
            host_cpu_cores=64,
            tier="mock",
        )
        self.assertEqual(p.model, "ornith-1.5-35b")
        self.assertEqual(p.max_context, 262144)
        self.assertIn(p.memory_fraction, (0.88, 0.90))
        self.assertFalse(p.cpu_offload)
        self.assertEqual(p.cpu_offload_gb, 0)

    def test_rtx_spark_classification(self):
        gpu = GPUInfo(
            index=0,
            name="NVIDIA RTX Spark 128GB Unified Memory",
            memory_total_mb=131072,
            compute_cap=12.0,
            driver="nvidia",
        )
        p = classify_profile(
            effective_vram_gb=128.0,
            primary_gpu=gpu,
            host_ram_gb=128.0,
            host_cpu_cores=32,
            tier="mock",
        )
        self.assertEqual(p.profile, "rtx-spark")
        self.assertEqual(p.model, "ornith-1.5-35b")
        self.assertEqual(p.memory_fraction, 0.92)
        self.assertGreaterEqual(p.max_context, 262144)
        self.assertEqual(p.offload, "unified-memory")
        self.assertFalse(p.cpu_offload)

    def test_rtx_4090_pure_gpu_default(self):
        gpu = GPUInfo(
            index=0,
            name="NVIDIA GeForce RTX 4090",
            memory_total_mb=24576,
            compute_cap=8.9,
            driver="nvidia",
        )
        p = classify_profile(
            effective_vram_gb=24.0,
            primary_gpu=gpu,
            host_ram_gb=64.0,
            host_cpu_cores=16,
            tier="mock",
        )
        self.assertEqual(p.profile, "rtx-4090")
        self.assertEqual(p.model, "ornith-1.5-35b")
        self.assertEqual(p.max_context, 65536)
        self.assertEqual(p.memory_fraction, 0.88)
        self.assertFalse(p.cpu_offload)
        self.assertEqual(p.cpu_offload_gb, 0)
        self.assertEqual(p.offload, "pure-gpu")

    def test_rtx_4090_forced_256k_ram_ge_32gb(self):
        gpu = GPUInfo(
            index=0,
            name="NVIDIA GeForce RTX 4090",
            memory_total_mb=24576,
            compute_cap=8.9,
            driver="nvidia",
        )
        p = classify_profile(
            effective_vram_gb=24.0,
            primary_gpu=gpu,
            host_ram_gb=64.0,
            host_cpu_cores=16,
            target_context=262144,
            tier="mock",
        )
        self.assertEqual(p.model, "ornith-1.5-35b")
        self.assertEqual(p.max_context, 262144)
        self.assertTrue(p.cpu_offload)
        self.assertEqual(p.cpu_offload_gb, 8)
        self.assertEqual(p.offload, "cpu-offload")

    def test_rtx_4090_forced_256k_ram_lt_32gb_guarded(self):
        gpu = GPUInfo(
            index=0,
            name="NVIDIA GeForce RTX 4090",
            memory_total_mb=24576,
            compute_cap=8.9,
            driver="nvidia",
        )
        p = classify_profile(
            effective_vram_gb=24.0,
            primary_gpu=gpu,
            host_ram_gb=16.0,  # Insufficient host RAM for 8GB offload
            host_cpu_cores=16,
            target_context=262144,
            tier="mock",
        )
        self.assertEqual(p.model, "ornith-1.5-35b")
        self.assertEqual(p.max_context, 65536)
        self.assertFalse(p.cpu_offload)
        self.assertEqual(p.cpu_offload_gb, 0)
        self.assertEqual(p.offload, "pure-gpu")

    def test_guarded_cpu_offload_5090_strict_rule(self):
        # Strict rule: Ensure CPU offload is NEVER enabled when GPU VRAM can hold context
        gpu = GPUInfo(
            index=0,
            name="NVIDIA GeForce RTX 5090",
            memory_total_mb=32768,
            compute_cap=12.0,
            driver="nvidia",
        )
        p = classify_profile(
            effective_vram_gb=32.0,
            primary_gpu=gpu,
            host_ram_gb=128.0,
            host_cpu_cores=24,
            target_context=262144,
            tier="mock",
        )
        self.assertFalse(p.cpu_offload)
        self.assertEqual(p.cpu_offload_gb, 0)
        self.assertNotIn("--cpu-offload", p.to_flags())

    def test_16gb_gpu_classification(self):
        gpu = GPUInfo(
            index=0,
            name="NVIDIA GeForce RTX 4080",
            memory_total_mb=16384,
            compute_cap=8.9,
            driver="nvidia",
        )
        p = classify_profile(
            effective_vram_gb=16.0,
            primary_gpu=gpu,
            host_ram_gb=32.0,
            host_cpu_cores=8,
            tier="mock",
        )
        self.assertEqual(p.profile, "rtx-4080")
        self.assertEqual(p.model, "ornith-1.5-9b")
        self.assertEqual(p.model_path, "ornith-ai/Ornith-1.5-9B-NVFP4")
        self.assertEqual(p.service, "sglang-ornith-1.5-9b.service")
        self.assertEqual(p.max_context, 262144)
        self.assertEqual(p.memory_fraction, 0.88)
        self.assertFalse(p.cpu_offload)

    def test_12gb_gpu_classification(self):
        gpu = GPUInfo(
            index=0,
            name="NVIDIA GeForce RTX 4070",
            memory_total_mb=12288,
            compute_cap=8.9,
            driver="nvidia",
        )
        p = classify_profile(
            effective_vram_gb=12.0,
            primary_gpu=gpu,
            host_ram_gb=32.0,
            host_cpu_cores=8,
            tier="mock",
        )
        self.assertEqual(p.model, "ornith-1.5-9b")
        self.assertEqual(p.max_context, 65536)
        self.assertEqual(p.memory_fraction, 0.85)
        self.assertFalse(p.cpu_offload)

    def test_8gb_gpu_classification(self):
        gpu = GPUInfo(
            index=0,
            name="NVIDIA GeForce RTX 3070",
            memory_total_mb=8192,
            compute_cap=8.6,
            driver="nvidia",
        )
        p = classify_profile(
            effective_vram_gb=8.0,
            primary_gpu=gpu,
            host_ram_gb=32.0,
            host_cpu_cores=8,
            tier="mock",
        )
        self.assertEqual(p.model, "ornith-1.5-9b")
        self.assertEqual(p.max_context, 32768)
        self.assertEqual(p.memory_fraction, 0.85)

    def test_fallback_profile_lt_8gb(self):
        p = classify_profile(
            effective_vram_gb=6.0,
            primary_gpu=None,
            host_ram_gb=16.0,
            host_cpu_cores=4,
            tier="mock",
        )
        self.assertEqual(p.profile, "fallback")
        self.assertEqual(p.model, "ornith-1.5-9b")
        self.assertEqual(p.max_context, 32768)
        self.assertEqual(p.memory_fraction, 0.80)


class TestDeviceFilteringAndMultiGPU(unittest.TestCase):
    """Test passthrough isolation, CC thresholds, and multi-GPU evaluation."""

    def test_vfio_passthrough_filtering(self):
        g0 = GPUInfo(
            index=0,
            name="NVIDIA GeForce RTX 5090",
            memory_total_mb=32768,
            compute_cap=12.0,
            driver="nvidia",
        )
        g1 = GPUInfo(
            index=1,
            name="NVIDIA GeForce GTX 1060 6GB",
            memory_total_mb=6144,
            compute_cap=6.1,
            driver="vfio-pci",
        )
        valid, excluded = filter_compute_gpus([g0, g1])
        self.assertEqual(len(valid), 1)
        self.assertEqual(valid[0].name, "NVIDIA GeForce RTX 5090")
        self.assertEqual(len(excluded), 1)
        self.assertEqual(excluded[0].name, "NVIDIA GeForce GTX 1060 6GB")

    def test_compute_capability_lt_8_filtering(self):
        g0 = GPUInfo(
            index=0,
            name="NVIDIA GeForce RTX 5090",
            memory_total_mb=32768,
            compute_cap=12.0,
            driver="nvidia",
        )
        g1 = GPUInfo(
            index=1,
            name="NVIDIA GeForce GTX 1060 6GB",
            memory_total_mb=6144,
            compute_cap=6.1,
            driver="nvidia",  # Driver is nvidia, but CC < 8.0
        )
        valid, excluded = filter_compute_gpus([g0, g1])
        self.assertEqual(len(valid), 1)
        self.assertEqual(valid[0].index, 0)
        self.assertEqual(len(excluded), 1)
        self.assertEqual(excluded[0].index, 1)

    def test_homogeneous_multi_gpu(self):
        g0 = GPUInfo(
            index=0,
            name="NVIDIA GeForce RTX 3090",
            memory_total_mb=24576,
            compute_cap=8.6,
            driver="nvidia",
        )
        g1 = GPUInfo(
            index=1,
            name="NVIDIA GeForce RTX 3090",
            memory_total_mb=24576,
            compute_cap=8.6,
            driver="nvidia",
        )
        tp_size, eff_vram_gb, cvd, is_homo, primary = evaluate_multi_gpu([g0, g1])
        self.assertTrue(is_homo)
        self.assertEqual(tp_size, 2)
        self.assertEqual(eff_vram_gb, 48.0)
        self.assertEqual(cvd, "0,1")

        p = classify_profile(
            effective_vram_gb=eff_vram_gb,
            primary_gpu=primary,
            tp_size=tp_size,
            cuda_visible_devices=cvd,
            tier="mock",
        )
        self.assertEqual(p.model, "ornith-1.5-35b")
        self.assertEqual(p.max_context, 262144)
        self.assertEqual(p.tensor_parallel_size, 2)
        self.assertEqual(p.cuda_visible_devices, "0,1")
        self.assertIn("--tensor-parallel-size 2", p.to_flags())

    def test_heterogeneous_multi_gpu(self):
        g0 = GPUInfo(
            index=0,
            name="NVIDIA GeForce RTX 5090",
            memory_total_mb=32768,
            compute_cap=12.0,
            driver="nvidia",
        )
        g1 = GPUInfo(
            index=1,
            name="NVIDIA GeForce RTX 4090",
            memory_total_mb=24576,
            compute_cap=8.9,
            driver="nvidia",
        )
        tp_size, eff_vram_gb, cvd, is_homo, primary = evaluate_multi_gpu([g0, g1])
        self.assertFalse(is_homo)
        self.assertEqual(tp_size, 1)
        self.assertEqual(eff_vram_gb, 32.0)
        self.assertEqual(primary.name, "NVIDIA GeForce RTX 5090")
        self.assertEqual(cvd, "0")


class TestDetectionCascadeAndMockProcfs(unittest.TestCase):
    """Test multi-tier detection cascade and mock sysfs/procfs parsing."""

    def test_tier2_nvidia_smi_parsing(self):
        mock_output = (
            "0, NVIDIA GeForce RTX 5090, 32768, 31000, 0000:81:00.0, 12.0, 615.78\n"
        )
        gpus = probe_tier2_nvidia_smi(runner=lambda cmd: mock_output)
        self.assertIsNotNone(gpus)
        self.assertEqual(len(gpus), 1)
        g = gpus[0]
        self.assertEqual(g.name, "NVIDIA GeForce RTX 5090")
        self.assertEqual(g.memory_total_mb, 32768)
        self.assertEqual(g.compute_cap, 12.0)
        self.assertEqual(g.pci_bus_id, "0000:81:00.0")

    def test_nvml_mismatch_recovery_tier3(self):
        """Simulate nvidia-smi throwing exit code 18 (NVML mismatch) and recover via Tier 3."""
        tmp = tempfile.mkdtemp()
        try:
            proc_root = os.path.join(tmp, "proc")
            sys_root = os.path.join(tmp, "sys")
            pci_dir = os.path.join(sys_root, "bus/pci/devices/0000:81:00.0")
            drivers_dir = os.path.join(sys_root, "bus/pci/drivers/nvidia")
            os.makedirs(pci_dir, exist_ok=True)
            os.makedirs(drivers_dir, exist_ok=True)

            with open(os.path.join(pci_dir, "vendor"), "w") as f:
                f.write("0x10de\n")
            with open(os.path.join(pci_dir, "class"), "w") as f:
                f.write("0x030000\n")
            with open(os.path.join(pci_dir, "device"), "w") as f:
                f.write("0x2b85\n")
            with open(os.path.join(pci_dir, "resource1"), "w") as f:
                # 32 GB dummy sparse file
                f.seek(34359738368 - 1)
                f.write("\0")

            # Link driver -> nvidia
            os.symlink(drivers_dir, os.path.join(pci_dir, "driver"))

            # Create /proc/driver/nvidia/gpus/0000:81:00.0/information
            proc_gpu = os.path.join(proc_root, "driver/nvidia/gpus/0000:81:00.0")
            os.makedirs(proc_gpu, exist_ok=True)
            with open(os.path.join(proc_gpu, "information"), "w") as f:
                f.write(
                    "Model: \t\t NVIDIA GeForce RTX 5090\n"
                    "Bus Location: \t 0000:81:00.0\n"
                    "GPU Firmware: \t 615.71.09\n"
                )

            # Create /proc/meminfo and /proc/cpuinfo
            with open(os.path.join(proc_root, "meminfo"), "w") as f:
                f.write("MemTotal:       131345376 kB\nMemAvailable:   103931128 kB\n")
            with open(os.path.join(proc_root, "cpuinfo"), "w") as f:
                f.write("model name\t: AMD Ryzen Threadripper 7960X 24-Cores\nprocessor\t: 0\n")

            # Runner that fails with exit code 18
            def failing_runner(cmd):
                raise RuntimeError("Driver/library version mismatch: 615.78 vs kernel module 615.71.09")

            prober = HardwareProbe(
                procfs_root=proc_root,
                sysfs_root=sys_root,
                smi_runner=failing_runner,
            )
            profile = prober.probe()
            self.assertEqual(profile.profile, "rtx-5090")
            self.assertEqual(profile.model, "ornith-1.5-35b")
            self.assertEqual(profile.max_context, 262144)
            self.assertEqual(profile.vram_gb, 32.0)
            self.assertEqual(profile.detection_tier, "procfs-sysfs")
        finally:
            shutil.rmtree(tmp)


class TestSerializationAndCLI(unittest.TestCase):
    """Test JSON, env, flags output formats, and CLI override options."""

    def test_json_and_env_and_flags_output(self):
        gpu = GPUInfo(
            index=0,
            name="NVIDIA GeForce RTX 5090",
            memory_total_mb=32768,
            compute_cap=12.0,
            driver="nvidia",
        )
        p = classify_profile(
            effective_vram_gb=32.0,
            primary_gpu=gpu,
            host_ram_gb=128.0,
            host_cpu_cores=24,
            tier="mock",
        )

        # JSON dictionary
        d = p.to_dict()
        self.assertEqual(d["profile"], "rtx-5090")
        self.assertEqual(d["max_context"], 262144)
        self.assertEqual(d["memory_fraction"], 0.88)
        self.assertEqual(d["model"], "ornith-1.5-35b")
        self.assertEqual(d["cpu_offload"], False)
        self.assertEqual(d["cpu_offload_gb"], 0)

        # Environment format
        env = p.to_env()
        self.assertIn("PROBED_PROFILE=rtx-5090", env)
        self.assertIn("PROBED_MODEL=ornith-1.5-35b", env)
        self.assertIn("PROBED_CONTEXT_LENGTH=262144", env)
        self.assertIn("PROBED_MEM_FRACTION=0.88", env)
        self.assertIn("PROBED_CPU_OFFLOAD=false", env)
        self.assertIn("PROBED_CPU_OFFLOAD_GB=0", env)

        # Flags format
        flags = p.to_flags()
        self.assertIn("--model-path ornith-ai/Ornith-1.5-35B-A3B-NVFP4", flags)
        self.assertIn("--served-model-name ornith-1.5-35b", flags)
        self.assertIn("--mem-fraction-static 0.88", flags)
        self.assertIn("--context-length 262144", flags)
        self.assertNotIn("--cpu-offload-gb", flags)

    def test_override_gpu_options(self):
        prober = HardwareProbe()
        for ov, expected_model, expected_ctx in [
            ("rtx-5090", "ornith-1.5-35b", 262144),
            ("rtx-pro-6000", "ornith-1.5-35b", 262144),
            ("rtx-spark", "ornith-1.5-35b", 512000),
            ("rtx-4090", "ornith-1.5-35b", 65536),
            ("rtx-4080", "ornith-1.5-9b", 262144),
            ("rtx-4070", "ornith-1.5-9b", 65536),
            ("fallback", "ornith-1.5-9b", 32768),
        ]:
            prof = prober.probe(override_gpu=ov)
            self.assertEqual(prof.model, expected_model, f"Failed for {ov}")
            self.assertEqual(prof.max_context, expected_ctx, f"Failed for {ov}")

        with self.assertRaises(ValueError):
            prober.probe(override_gpu="invalid-card-name")


class TestLiveHostProbe(unittest.TestCase):
    """Sanity test executing real probe on the physical host."""

    def test_live_host_matches_architect_spec(self):
        profile = probe_hardware()
        # Physical host has RTX 5090 32GB (GPU 0) and GTX 1060 (GPU 1, vfio-pci)
        self.assertEqual(profile.profile, "rtx-5090")
        self.assertEqual(profile.model, "ornith-1.5-35b")
        self.assertEqual(profile.max_context, 262144)
        self.assertEqual(profile.memory_fraction, 0.88)
        self.assertFalse(profile.cpu_offload)
        self.assertEqual(profile.cpu_offload_gb, 0)
        self.assertEqual(profile.tensor_parallel_size, 1)
        self.assertEqual(profile.cuda_visible_devices, "0")
        self.assertGreaterEqual(profile.vram_gb, 30.0)


class TestPerModelHardwareSizingIssue49(unittest.TestCase):
    """Test Issue #49 adaptive per-model hardware sizing, context scaling, and CPU offload."""

    def test_rtx_5090_32gb_vram_125gb_ram_pure_gpu_sizing(self):
        """RTX 5090 (32 GB VRAM, 125 GB RAM): 100% in VRAM, Ornith 35B, Qwen 3.8 27B, and Ornith 9B at 262144."""
        gpu = GPUInfo(
            index=0,
            name="NVIDIA GeForce RTX 5090",
            memory_total_mb=32768,
            compute_cap=12.0,
            driver="nvidia",
        )
        p = classify_profile(
            effective_vram_gb=32.0,
            primary_gpu=gpu,
            host_ram_gb=125.0,
            host_cpu_cores=24,
            tier="mock",
        )
        d = p.to_dict()
        self.assertIn("model_sizing", d)
        self.assertIn("models", d)
        sizing = d["model_sizing"]

        # Ornith 1.5 35B: 100% VRAM, 256k context
        ornith = sizing["ornith-1.5-35b"]
        self.assertEqual(ornith["max_context"], 262144)
        self.assertEqual(ornith["memory_fraction"], 0.88)
        self.assertFalse(ornith["cpu_offload"])
        self.assertEqual(ornith["cpu_offload_gb"], 0)
        self.assertEqual(ornith["offload"], "pure-gpu")

        # Qwen 3.8 27B: 100% VRAM, 256k context
        qwen = sizing["qwen3.8-27b"]
        self.assertEqual(qwen["max_context"], 262144)
        self.assertEqual(qwen["memory_fraction"], 0.88)
        self.assertFalse(qwen["cpu_offload"])
        self.assertEqual(qwen["cpu_offload_gb"], 0)
        self.assertEqual(qwen["offload"], "pure-gpu")

        # Ornith 1.5 9B: 100% VRAM, 256k context
        ornith9b = sizing["ornith-1.5-9b"]
        self.assertEqual(ornith9b["max_context"], 262144)
        self.assertEqual(ornith9b["memory_fraction"], 0.88)
        self.assertFalse(ornith9b["cpu_offload"])
        self.assertEqual(ornith9b["cpu_offload_gb"], 0)
        self.assertEqual(ornith9b["offload"], "pure-gpu")

    def test_continuous_dynamic_vram_spillover_across_arbitrary_gpus(self):
        """Test compute_dynamic_vram_spillover attempts 100% GPU first and spills deficit to CPU RAM only when needed."""
        # 1. 32 GB GPU (RTX 5090): 100% pure GPU at 262144 context for both 35B MoE and 27B Dense
        res_32 = compute_dynamic_vram_spillover(
            effective_vram_gb=32.0,
            host_ram_gb=125.0,
            model_weights_gb=19.0,
            min_kv_gb=2.0,
            full_ctx_kv_gb=9.0,
            memory_fraction=0.88,
        )
        self.assertEqual(res_32["max_context"], 262144)
        self.assertFalse(res_32["cpu_offload"])
        self.assertEqual(res_32["cpu_offload_gb"], 0)
        self.assertEqual(res_32["offload"], "pure-gpu")

        # 2. 24 GB GPU (RTX 4090): 100% pure GPU at 65536 context when 256k not forced (usable 21.12 >= 19.0 + 2.0)
        res_24_pure = compute_dynamic_vram_spillover(
            effective_vram_gb=24.0,
            host_ram_gb=64.0,
            model_weights_gb=19.0,
            min_kv_gb=2.0,
            full_ctx_kv_gb=9.5,
            memory_fraction=0.88,
        )
        self.assertEqual(res_24_pure["max_context"], 65536)
        self.assertFalse(res_24_pure["cpu_offload"])
        self.assertEqual(res_24_pure["cpu_offload_gb"], 0)
        self.assertEqual(res_24_pure["recommended_cpu_offload_gb"], 8)
        self.assertEqual(res_24_pure["offload"], "pure-gpu")

        # 3. 20 GB intermediate GPU: usable 17.6 GB < 21.0 GB -> spills 4 GB to CPU RAM
        res_20_spill = compute_dynamic_vram_spillover(
            effective_vram_gb=20.0,
            host_ram_gb=64.0,
            model_weights_gb=19.0,
            min_kv_gb=2.0,
            full_ctx_kv_gb=9.5,
            memory_fraction=0.88,
        )
        self.assertTrue(res_20_spill["cpu_offload"])
        self.assertEqual(res_20_spill["cpu_offload_gb"], 4)
        self.assertEqual(res_20_spill["offload"], "cpu-offload")
        self.assertEqual(res_20_spill["max_context"], 65536)

        # 4. 16 GB GPU (RTX 4080) and 12 GB GPU (RTX 4070): proportional spillover
        res_16 = compute_dynamic_vram_spillover(
            effective_vram_gb=16.0,
            host_ram_gb=64.0,
            model_weights_gb=19.0,
            min_kv_gb=8.5,
            full_ctx_kv_gb=9.5,
            memory_fraction=0.88,
        )
        self.assertTrue(res_16["cpu_offload"])
        self.assertEqual(res_16["cpu_offload_gb"], 14)

        res_12 = compute_dynamic_vram_spillover(
            effective_vram_gb=12.0,
            host_ram_gb=64.0,
            model_weights_gb=19.0,
            min_kv_gb=6.5,
            full_ctx_kv_gb=9.5,
            memory_fraction=0.85,
        )
        self.assertTrue(res_12["cpu_offload"])
        self.assertEqual(res_12["cpu_offload_gb"], 16)

    def test_rtx_4090_24gb_vram_64gb_ram_and_16gb_ram(self):
        """RTX 4090 (24 GB VRAM, 64 GB RAM & 16 GB RAM): context scaling and automatic CPU RAM offload."""
        gpu = GPUInfo(
            index=0,
            name="NVIDIA GeForce RTX 4090",
            memory_total_mb=24576,
            compute_cap=8.9,
            driver="nvidia",
        )

        # Case 1: 24 GB VRAM + 64 GB Host RAM (default target_context)
        p_64 = classify_profile(
            effective_vram_gb=24.0,
            primary_gpu=gpu,
            host_ram_gb=64.0,
            host_cpu_cores=16,
            tier="mock",
        )
        s_64 = p_64.to_dict()["model_sizing"]
        self.assertEqual(s_64["ornith-1.5-35b"]["max_context"], 65536)
        self.assertFalse(s_64["ornith-1.5-35b"]["cpu_offload"])
        self.assertEqual(s_64["ornith-1.5-35b"]["cpu_offload_gb"], 0)
        self.assertEqual(s_64["ornith-1.5-35b"]["recommended_cpu_offload_gb"], 8)

        # Qwen 27B Dense enables 6 GB CPU offload on 24 GB VRAM + 64 GB RAM so 64k context fits without OOM
        self.assertEqual(s_64["qwen3.8-27b"]["max_context"], 65536)
        self.assertTrue(s_64["qwen3.8-27b"]["cpu_offload"])
        self.assertEqual(s_64["qwen3.8-27b"]["cpu_offload_gb"], 6)
        self.assertEqual(s_64["qwen3.8-27b"]["offload"], "cpu-offload")

        # Case 2: 24 GB VRAM + 64 GB Host RAM with target_context=262144
        p_256k = classify_profile(
            effective_vram_gb=24.0,
            primary_gpu=gpu,
            host_ram_gb=64.0,
            host_cpu_cores=16,
            target_context=262144,
            tier="mock",
        )
        s_256k = p_256k.to_dict()["model_sizing"]
        self.assertEqual(s_256k["ornith-1.5-35b"]["max_context"], 262144)
        self.assertTrue(s_256k["ornith-1.5-35b"]["cpu_offload"])
        self.assertEqual(s_256k["ornith-1.5-35b"]["cpu_offload_gb"], 8)
        self.assertEqual(s_256k["ornith-1.5-35b"]["offload"], "cpu-offload")

        # Case 3: 24 GB VRAM + 16 GB Host RAM (insufficient RAM for CPU offload -> pure GPU with scaled context)
        p_16 = classify_profile(
            effective_vram_gb=24.0,
            primary_gpu=gpu,
            host_ram_gb=16.0,
            host_cpu_cores=8,
            tier="mock",
        )
        s_16 = p_16.to_dict()["model_sizing"]
        self.assertEqual(s_16["ornith-1.5-35b"]["max_context"], 65536)
        self.assertFalse(s_16["ornith-1.5-35b"]["cpu_offload"])
        self.assertEqual(s_16["ornith-1.5-35b"]["cpu_offload_gb"], 0)

        self.assertEqual(s_16["qwen3.8-27b"]["max_context"], 32768)
        self.assertFalse(s_16["qwen3.8-27b"]["cpu_offload"])
        self.assertEqual(s_16["qwen3.8-27b"]["cpu_offload_gb"], 0)
        self.assertEqual(s_16["qwen3.8-27b"]["offload"], "pure-gpu")

    def test_rtx_4080_16gb_and_rtx_4070_12gb_profiles(self):
        """RTX 4080 (16 GB VRAM) and RTX 4070 (12 GB VRAM) per-model sizing and offload."""
        gpu_4080 = GPUInfo(
            index=0,
            name="NVIDIA GeForce RTX 4080",
            memory_total_mb=16384,
            compute_cap=8.9,
            driver="nvidia",
        )
        # RTX 4080 with 64 GB RAM (>= 48 GB)
        p_4080_high_ram = classify_profile(
            effective_vram_gb=16.0,
            primary_gpu=gpu_4080,
            host_ram_gb=64.0,
            host_cpu_cores=16,
            tier="mock",
        )
        self.assertEqual(p_4080_high_ram.model, "ornith-1.5-9b")
        self.assertEqual(p_4080_high_ram.max_context, 262144)
        self.assertFalse(p_4080_high_ram.cpu_offload)
        s_4080_high = p_4080_high_ram.to_dict()["model_sizing"]
        for m in ("ornith-1.5-35b", "qwen3.8-27b"):
            self.assertEqual(s_4080_high[m]["max_context"], 32768)
            self.assertTrue(s_4080_high[m]["cpu_offload"])
            self.assertEqual(s_4080_high[m]["cpu_offload_gb"], 14)
            self.assertEqual(s_4080_high[m]["offload"], "cpu-offload")

        # RTX 4080 with 32 GB RAM (< 48 GB)
        p_4080_low_ram = classify_profile(
            effective_vram_gb=16.0,
            primary_gpu=gpu_4080,
            host_ram_gb=32.0,
            host_cpu_cores=8,
            tier="mock",
        )
        s_4080_low = p_4080_low_ram.to_dict()["model_sizing"]
        for m in ("ornith-1.5-35b", "qwen3.8-27b"):
            self.assertEqual(s_4080_low[m]["max_context"], 16384)
            self.assertTrue(s_4080_low[m]["cpu_offload"])
            self.assertEqual(s_4080_low[m]["cpu_offload_gb"], 12)
            self.assertEqual(s_4080_low[m]["offload"], "cpu-offload")

        # RTX 4070 (12 GB VRAM) with 64 GB RAM
        gpu_4070 = GPUInfo(
            index=0,
            name="NVIDIA GeForce RTX 4070",
            memory_total_mb=12288,
            compute_cap=8.9,
            driver="nvidia",
        )
        p_4070 = classify_profile(
            effective_vram_gb=12.0,
            primary_gpu=gpu_4070,
            host_ram_gb=64.0,
            host_cpu_cores=16,
            tier="mock",
        )
        self.assertEqual(p_4070.model, "ornith-1.5-9b")
        self.assertEqual(p_4070.max_context, 65536)
        self.assertFalse(p_4070.cpu_offload)
        s_4070 = p_4070.to_dict()["model_sizing"]
        for m in ("ornith-1.5-35b", "qwen3.8-27b"):
            self.assertEqual(s_4070[m]["max_context"], 16384)
            self.assertTrue(s_4070[m]["cpu_offload"])
            self.assertEqual(s_4070[m]["cpu_offload_gb"], 16)
            self.assertEqual(s_4070[m]["offload"], "cpu-offload")

    def test_model_cli_flag_and_probe_hardware_model_override(self):
        """Test --model flag in probe.py and scripts/gpu_probe.sh."""
        import subprocess
        from pathlib import Path

        repo_root = Path(__file__).resolve().parent.parent
        gpu_probe_sh = repo_root / "scripts" / "gpu_probe.sh"

        # 1. Python API with model="qwen3.8-27b" on rtx-4090
        p = probe_hardware(override_gpu="rtx-4090", model="qwen3.8-27b")
        self.assertEqual(p.model, "qwen3.8-27b")
        self.assertEqual(p.service, "sglang-qwen3.8-27b.service")
        self.assertEqual(p.max_context, 65536)
        self.assertTrue(p.cpu_offload)
        self.assertEqual(p.cpu_offload_gb, 6)
        self.assertIn("--cpu-offload-gb 6", p.to_flags())

        # 2. Shell CLI wrapper with --model qwen3.8-27b on rtx-4090
        proc = subprocess.run(
            [str(gpu_probe_sh), "--override-gpu", "rtx-4090", "--model", "qwen3.8-27b"],
            cwd=repo_root,
            capture_output=True,
            text=True,
            check=True,
        )
        data = json.loads(proc.stdout)
        self.assertEqual(data["model"], "qwen3.8-27b")
        self.assertEqual(data["service"], "sglang-qwen3.8-27b.service")
        self.assertEqual(data["max_context"], 65536)
        self.assertTrue(data["cpu_offload"])
        self.assertEqual(data["cpu_offload_gb"], 6)
        self.assertIn("model_sizing", data)

        # 3. Shell CLI wrapper supports raw CSV --override-gpu strings
        proc_csv = subprocess.run(
            [str(gpu_probe_sh), "--override-gpu", "NVIDIA GeForce RTX 5090, 32768, 12.0"],
            cwd=repo_root,
            capture_output=True,
            text=True,
            check=True,
        )
        data_csv = json.loads(proc_csv.stdout)
        self.assertEqual(data_csv["profile"], "rtx-5090")
        self.assertEqual(data_csv["service"], "sglang-ornith-1.5-35b.service")
        self.assertEqual(data_csv["max_context"], 262144)

    def test_model_runtime_limits_across_vram_tiers(self):
        # 12 GB GPU -> tight limits (mamba=3, decode_bs=4) for all models
        sizing_12 = classify_model_sizing(effective_vram_gb=12.0, host_ram_gb=32.0)
        for model_key in ("ornith-1.5-35b", "qwen3.8-27b", "ornith-1.5-9b"):
            entry = sizing_12[model_key]
            self.assertTrue(entry["disable_prefill_cuda_graph"])
            self.assertEqual(entry["max_mamba_cache_size"], 3)
            self.assertEqual(entry["cuda_graph_max_bs_decode"], 4)

        # 16 GB GPU -> pure-GPU 9B gets (5, 8); CPU-offloaded 35B/27B get tight (3, 4)
        sizing_16 = classify_model_sizing(effective_vram_gb=16.0, host_ram_gb=32.0)
        self.assertEqual(sizing_16["ornith-1.5-9b"]["max_mamba_cache_size"], 5)
        self.assertEqual(sizing_16["ornith-1.5-9b"]["cuda_graph_max_bs_decode"], 8)
        self.assertEqual(sizing_16["ornith-1.5-35b"]["max_mamba_cache_size"], 3)
        self.assertEqual(sizing_16["qwen3.8-27b"]["max_mamba_cache_size"], 3)

        # 32 GB GPU -> pure-GPU (5, 8) for all models
        sizing_32 = classify_model_sizing(effective_vram_gb=32.0, host_ram_gb=64.0)
        for model_key in ("ornith-1.5-35b", "qwen3.8-27b", "ornith-1.5-9b"):
            entry = sizing_32[model_key]
            self.assertTrue(entry["disable_prefill_cuda_graph"])
            self.assertEqual(entry["max_mamba_cache_size"], 5)
            self.assertEqual(entry["cuda_graph_max_bs_decode"], 8)


if __name__ == "__main__":
    unittest.main()
