#!/usr/bin/env python3
"""
harness.hardware.probe: Multi-tier GPU/CPU probing, device filtering, and model sizing.

Detection Cascade:
  Tier 1: PyTorch / CUDA runtime (torch.cuda)
  Tier 2: nvidia-smi CLI query
  Tier 3: /proc/driver/nvidia/gpus/*/information and /sys/bus/pci/devices/* sysfs

Rules:
  - Exclude non-nvidia drivers (e.g. vfio-pci VM passthrough)
  - Exclude compute capability < 8.0 (e.g. Pascal CC 6.1)
  - Homogeneous multi-GPU: tensor_parallel_size = count, effective VRAM = count * VRAM
  - Heterogeneous multi-GPU: select primary with largest VRAM and highest CC; set CUDA_VISIBLE_DEVICES
  - Total VRAM >= 30GB: Model ornith-1.5-35b, ctx 262144, static mem 0.88 (or 0.92 for >=100GB), cpu_offload: false
  - 20-30GB VRAM:
      Pure GPU: ctx 65536, cpu_offload: false
      Target ctx >= 256k AND RAM >= 32GB: ctx 262144, cpu_offload: true, cpu_offload_gb: 8
  - 14-20GB VRAM: Model ornith-1.5-9b, ctx 262144, static mem 0.88, cpu_offload: false
  - 8-14GB VRAM: Model ornith-1.5-9b, ctx 32768-65536, static mem 0.85, cpu_offload: false
  - Guarded CPU offload: NEVER enabled if GPU VRAM can hold target context.
"""

from __future__ import annotations

import argparse
from dataclasses import dataclass, asdict
import json
import os
import re
import subprocess
import sys
from typing import Callable, Dict, List, Optional, Tuple


@dataclass
class GPUInfo:
    index: int
    name: str
    memory_total_mb: int
    memory_free_mb: Optional[int] = None
    compute_cap: float = 0.0
    driver: str = "nvidia"
    driver_version: str = "unknown"
    pci_bus_id: str = "unknown"


@dataclass
class SystemResources:
    cpu_model: str = "unknown"
    cpu_cores: int = 1
    ram_total_mb: int = 0
    ram_available_mb: int = 0


@dataclass
class ProbedProfile:
    profile: str
    memory_fraction: float
    max_context: int
    kv_cache_dtype: str
    offload: str
    gpu: str
    model: str
    model_path: str
    service: str
    tensor_parallel_size: int = 1
    cuda_visible_devices: str = "0"
    cpu_offload: bool = False
    cpu_offload_gb: int = 0
    vram_gb: float = 0.0
    total_vram_mb: int = 0
    host_ram_gb: float = 0.0
    host_cpu_cores: int = 0
    detection_tier: str = "unknown"

    def to_dict(self) -> Dict[str, Any]:
        return {
            "profile": self.profile,
            "memory_fraction": self.memory_fraction,
            "max_context": self.max_context,
            "kv_cache_dtype": self.kv_cache_dtype,
            "offload": self.offload,
            "gpu": self.gpu,
            "model": self.model,
            "model_path": self.model_path,
            "service": self.service,
            "tensor_parallel_size": self.tensor_parallel_size,
            "cuda_visible_devices": self.cuda_visible_devices,
            "cpu_offload": self.cpu_offload,
            "cpu_offload_gb": self.cpu_offload_gb,
            "vram_gb": round(self.vram_gb, 2),
            "total_vram_mb": self.total_vram_mb,
            "host_ram_gb": round(self.host_ram_gb, 2),
            "host_cpu_cores": self.host_cpu_cores,
            "detection_tier": self.detection_tier,
        }

    def to_env(self) -> str:
        lines = [
            f"PROBED_PROFILE={self.profile}",
            f"PROBED_MODEL={self.model}",
            f"PROBED_MODEL_PATH={self.model_path}",
            f"PROBED_SERVICE={self.service}",
            f"PROBED_CONTEXT_LENGTH={self.max_context}",
            f"PROBED_MEM_FRACTION={self.memory_fraction}",
            f"PROBED_KV_CACHE_DTYPE={self.kv_cache_dtype}",
            f"PROBED_OFFLOAD={self.offload}",
            f"PROBED_CPU_OFFLOAD={'true' if self.cpu_offload else 'false'}",
            f"PROBED_CPU_OFFLOAD_GB={self.cpu_offload_gb}",
            f"PROBED_TP_SIZE={self.tensor_parallel_size}",
            f"PROBED_CUDA_VISIBLE_DEVICES={self.cuda_visible_devices}",
            f"PROBED_VRAM_GB={int(round(self.vram_gb))}",
            f'PROBED_GPU="{self.gpu}"',
        ]
        return "\n".join(lines)

    def to_flags(self) -> str:
        flags = [
            f"--model-path {self.model_path}",
            f"--served-model-name {self.model}",
            f"--mem-fraction-static {self.memory_fraction}",
            f"--context-length {self.max_context}",
        ]
        if self.cpu_offload and self.cpu_offload_gb > 0:
            flags.append(f"--cpu-offload-gb {self.cpu_offload_gb}")
        if self.tensor_parallel_size > 1:
            flags.append(f"--tensor-parallel-size {self.tensor_parallel_size}")
        return " ".join(flags)


# Known PCI device IDs mapping: device_id -> (name, vram_mb, compute_cap)
PCI_DEVICE_MAP: Dict[str, Tuple[str, int, float]] = {
    "0x2b85": ("NVIDIA GeForce RTX 5090", 32768, 12.0),
    "0x2b87": ("NVIDIA GeForce RTX 5080", 16384, 12.0),
    "0x2b89": ("NVIDIA GeForce RTX 5070 Ti", 16384, 12.0),
    "0x2684": ("NVIDIA GeForce RTX 4090", 24576, 8.9),
    "0x2704": ("NVIDIA GeForce RTX 4080", 16384, 8.9),
    "0x2786": ("NVIDIA GeForce RTX 4070", 12288, 8.9),
    "0x27e0": ("NVIDIA GeForce RTX 4070 Ti", 12288, 8.9),
    "0x2204": ("NVIDIA GeForce RTX 3090", 24576, 8.6),
    "0x2206": ("NVIDIA GeForce RTX 3080", 10240, 8.6),
    "0x2208": ("NVIDIA GeForce RTX 3080 Ti", 12288, 8.6),
    "0x2484": ("NVIDIA GeForce RTX 3070", 8192, 8.6),
    "0x2503": ("NVIDIA GeForce RTX 3060", 12288, 8.6),
    "0x2330": ("NVIDIA H100 80GB HBM3", 81920, 9.0),
    "0x2331": ("NVIDIA H100 PCIe", 81920, 9.0),
    "0x20b0": ("NVIDIA A100-SXM4-40GB", 40960, 8.0),
    "0x20b2": ("NVIDIA A100-PCIE-40GB", 40960, 8.0),
    "0x20b5": ("NVIDIA A100-SXM4-80GB", 81920, 8.0),
    "0x2230": ("NVIDIA RTX A6000", 49152, 8.6),
    "0x26b5": ("NVIDIA RTX 6000 Ada Generation", 49152, 8.9),
    "0x1c03": ("NVIDIA GeForce GTX 1060 6GB", 6144, 6.1),
    "0x1b80": ("NVIDIA GeForce GTX 1080", 8192, 6.1),
    "0x1e04": ("NVIDIA GeForce RTX 2080 Ti", 11264, 7.5),
    "0x1e84": ("NVIDIA GeForce RTX 2080", 8192, 7.5),
    "0x1eb8": ("NVIDIA Tesla T4", 16384, 7.5),
}


def estimate_compute_cap_from_name(name: str) -> float:
    n = name.upper()
    if any(k in n for k in ["5090", "5080", "5070", "GB200", "GB202", "BLACKWELL"]):
        return 12.0
    if any(k in n for k in ["SPARK"]):
        return 12.0
    if any(k in n for k in ["H100", "H200", "H800", "HOPPER", "GH200"]):
        return 9.0
    if any(k in n for k in ["4090", "4080", "4070", "4060", "L40", "L4", "6000 ADA"]):
        return 8.9
    if any(k in n for k in ["3090", "3080", "3070", "3060", "A100", "A6000", "A40", "A10", "PRO 6000"]):
        return 8.6
    if any(k in n for k in ["2080", "2070", "2060", "TITAN RTX", "T4", "TURING"]):
        return 7.5
    if any(k in n for k in ["V100", "VOLTA"]):
        return 7.0
    if any(k in n for k in ["1080", "1070", "1060", "P100", "P40", "PASCAL"]):
        return 6.1
    if any(k in n for k in ["980", "970", "MAXWELL"]):
        return 5.2
    return 8.0


def estimate_vram_from_name(name: str) -> int:
    n = name.upper()
    if "SPARK" in n:
        return 131072
    if "H200" in n:
        return 144384
    if "H100" in n or "A100-80" in n or "A100 80" in n:
        return 81920
    if "6000" in n:
        return 49152
    if "A100" in n:
        return 40960
    if "5090" in n:
        return 32768
    if "4090" in n or "3090" in n:
        return 24576
    if "5080" in n or "5070 TI" in n or "4080" in n or "T4" in n:
        return 16384
    if "4070" in n or "3060" in n or "3080 TI" in n:
        return 12288
    if "3080" in n:
        return 10240
    if "3070" in n or "1080" in n or "2080" in n:
        return 8192
    if "1060" in n:
        return 6144
    return 0


def probe_system_resources(procfs_root: str = "/proc") -> SystemResources:
    """Reads /proc/meminfo and /proc/cpuinfo."""
    cpu_model = "unknown"
    cpu_cores = 0
    ram_total_mb = 0
    ram_available_mb = 0

    meminfo_path = os.path.join(procfs_root, "meminfo")
    if os.path.isfile(meminfo_path):
        try:
            with open(meminfo_path, "r", encoding="utf-8", errors="ignore") as f:
                for line in f:
                    if line.startswith("MemTotal:"):
                        parts = line.split()
                        if len(parts) >= 2 and parts[1].isdigit():
                            ram_total_mb = int(parts[1]) // 1024
                    elif line.startswith("MemAvailable:"):
                        parts = line.split()
                        if len(parts) >= 2 and parts[1].isdigit():
                            ram_available_mb = int(parts[1]) // 1024
        except Exception:
            pass

    cpuinfo_path = os.path.join(procfs_root, "cpuinfo")
    if os.path.isfile(cpuinfo_path):
        try:
            with open(cpuinfo_path, "r", encoding="utf-8", errors="ignore") as f:
                for line in f:
                    if "model name" in line and cpu_model == "unknown":
                        cpu_model = line.split(":", 1)[1].strip()
                    elif line.startswith("processor"):
                        cpu_cores += 1
        except Exception:
            pass

    if cpu_cores == 0:
        cpu_cores = os.cpu_count() or 1
    if ram_total_mb == 0:
        # Fallback to sensible default
        ram_total_mb = 32768
        ram_available_mb = 16384

    return SystemResources(
        cpu_model=cpu_model,
        cpu_cores=cpu_cores,
        ram_total_mb=ram_total_mb,
        ram_available_mb=ram_available_mb,
    )


def probe_tier1_torch() -> Optional[List[GPUInfo]]:
    """Tier 1: PyTorch / CUDA runtime."""
    try:
        import torch  # type: ignore
        if not torch.cuda.is_available():
            return None
        count = torch.cuda.device_count()
        if count == 0:
            return None

        gpus: List[GPUInfo] = []
        for i in range(count):
            props = torch.cuda.get_device_properties(i)
            name = props.name
            total_mb = props.total_memory // (1024 * 1024)
            free_mb = None
            try:
                free_b, _ = torch.cuda.mem_get_info(i)
                free_mb = free_b // (1024 * 1024)
            except Exception:
                pass
            cc = float(f"{props.major}.{props.minor}")
            driver_ver = getattr(torch.version, "cuda", "unknown")
            gpus.append(
                GPUInfo(
                    index=i,
                    name=name,
                    memory_total_mb=total_mb,
                    memory_free_mb=free_mb,
                    compute_cap=cc,
                    driver="nvidia",
                    driver_version=str(driver_ver),
                    pci_bus_id=f"cuda:{i}",
                )
            )
        return gpus
    except Exception:
        return None


def probe_tier2_nvidia_smi(runner: Optional[Callable[[List[str]], str]] = None) -> Optional[List[GPUInfo]]:
    """Tier 2: nvidia-smi CLI query."""
    cmd = [
        "nvidia-smi",
        "--query-gpu=index,name,memory.total,memory.free,pci.bus_id,compute_cap,driver_version",
        "--format=csv,noheader,nounits",
    ]
    try:
        if runner is None:
            res = subprocess.run(cmd, capture_output=True, text=True, check=True)
            output = res.stdout
        else:
            output = runner(cmd)

        lines = [line.strip() for line in output.strip().splitlines() if line.strip()]
        if not lines:
            return None

        gpus: List[GPUInfo] = []
        for line in lines:
            parts = [p.strip() for p in line.split(",")]
            if len(parts) < 7:
                continue
            idx = int(parts[0])
            name = parts[1]
            total_mb = int(parts[2])
            free_mb = int(parts[3])
            bus_id = parts[4]
            cc = float(parts[5])
            driver_ver = parts[6]
            gpus.append(
                GPUInfo(
                    index=idx,
                    name=name,
                    memory_total_mb=total_mb,
                    memory_free_mb=free_mb,
                    compute_cap=cc,
                    driver="nvidia",
                    driver_version=driver_ver,
                    pci_bus_id=bus_id,
                )
            )
        return gpus if gpus else None
    except Exception:
        return None


def probe_tier3_procfs_sysfs(
    procfs_root: str = "/proc", sysfs_root: str = "/sys"
) -> Optional[List[GPUInfo]]:
    """Tier 3: /proc/driver/nvidia/gpus/*/information and /sys/bus/pci/devices/* sysfs."""
    pci_dir = os.path.join(sysfs_root, "bus/pci/devices")
    if not os.path.isdir(pci_dir):
        return None

    # Load /proc/driver/nvidia/gpus/*/information map: bus_id -> info dict
    proc_info: Dict[str, Dict[str, str]] = {}
    proc_gpu_dir = os.path.join(procfs_root, "driver/nvidia/gpus")
    if os.path.isdir(proc_gpu_dir):
        try:
            for entry in os.listdir(proc_gpu_dir):
                info_path = os.path.join(proc_gpu_dir, entry, "information")
                if os.path.isfile(info_path):
                    p_data: Dict[str, str] = {}
                    with open(info_path, "r", encoding="utf-8", errors="ignore") as f:
                        for line in f:
                            if ":" in line:
                                k, v = line.split(":", 1)
                                p_data[k.strip()] = v.strip()
                    bus_loc = p_data.get("Bus Location", entry).strip()
                    proc_info[bus_loc] = p_data
                    # Also map standard forms
                    proc_info[entry] = p_data
        except Exception:
            pass

    found_gpus: List[GPUInfo] = []
    index = 0
    for dev_name in sorted(os.listdir(pci_dir)):
        dev_path = os.path.join(pci_dir, dev_name)
        vendor_path = os.path.join(dev_path, "vendor")
        class_path = os.path.join(dev_path, "class")

        if not (os.path.isfile(vendor_path) and os.path.isfile(class_path)):
            continue
        try:
            with open(vendor_path, "r", encoding="utf-8", errors="ignore") as f:
                vendor = f.read().strip().lower()
            with open(class_path, "r", encoding="utf-8", errors="ignore") as f:
                pci_class = f.read().strip().lower()
        except Exception:
            continue

        # Check NVIDIA vendor (0x10de) and display controller class (0x0300 or 0x0302)
        if vendor != "0x10de" or not (
            pci_class.startswith("0x0300") or pci_class.startswith("0x0302")
        ):
            continue

        # Determine driver
        driver = "unknown"
        driver_link = os.path.join(dev_path, "driver")
        if os.path.islink(driver_link) or os.path.exists(driver_link):
            try:
                driver = os.path.basename(os.readlink(driver_link))
            except Exception:
                pass

        # Determine VRAM size
        vram_mb = 0
        # Method A: resource1 file size
        res1_path = os.path.join(dev_path, "resource1")
        if os.path.isfile(res1_path):
            try:
                vram_mb = os.path.getsize(res1_path) // (1024 * 1024)
            except Exception:
                pass

        # Method B: resource file line 2 (BAR1)
        if vram_mb == 0:
            res_path = os.path.join(dev_path, "resource")
            if os.path.isfile(res_path):
                try:
                    with open(res_path, "r", encoding="utf-8", errors="ignore") as f:
                        lines = f.readlines()
                        if len(lines) >= 2:
                            parts = lines[1].strip().split()
                            if len(parts) >= 2:
                                start = int(parts[0], 16)
                                end = int(parts[1], 16)
                                if end > start:
                                    vram_mb = (end - start + 1) // (1024 * 1024)
                except Exception:
                    pass

        # Information from /proc if available
        p_data = proc_info.get(dev_name, {})
        name = p_data.get("Model")
        driver_ver = p_data.get("GPU Firmware", "unknown")

        dev_id = ""
        device_id_path = os.path.join(dev_path, "device")
        if os.path.isfile(device_id_path):
            try:
                with open(device_id_path, "r", encoding="utf-8", errors="ignore") as f:
                    dev_id = f.read().strip().lower()
            except Exception:
                pass

        # Match name and CC
        if not name:
            known_name, known_mb, known_cc = PCI_DEVICE_MAP.get(
                dev_id, (f"NVIDIA Device {dev_id}", 0, 0.0)
            )
            name = known_name
            if vram_mb == 0:
                vram_mb = known_mb
            cc = known_cc
        else:
            cc = estimate_compute_cap_from_name(name)

        if vram_mb == 0 and name:
            vram_mb = estimate_vram_from_name(name)

        found_gpus.append(
            GPUInfo(
                index=index,
                name=name or "NVIDIA GPU",
                memory_total_mb=vram_mb,
                memory_free_mb=None,
                compute_cap=cc,
                driver=driver,
                driver_version=driver_ver,
                pci_bus_id=dev_name,
            )
        )
        index += 1

    return found_gpus if found_gpus else None


def filter_compute_gpus(all_gpus: List[GPUInfo]) -> Tuple[List[GPUInfo], List[GPUInfo]]:
    """
    Filters devices according to requirements:
    - Exclude devices using vfio-pci or non-nvidia drivers
    - Exclude devices with Compute Capability < 8.0 (e.g. Pascal GTX 1060)
    Returns (valid_compute_gpus, excluded_gpus).
    """
    valid: List[GPUInfo] = []
    excluded: List[GPUInfo] = []
    for g in all_gpus:
        if g.driver != "nvidia":
            excluded.append(g)
        elif g.compute_cap < 8.0:
            excluded.append(g)
        else:
            valid.append(g)
    return valid, excluded


def evaluate_multi_gpu(
    valid_gpus: List[GPUInfo],
) -> Tuple[int, float, str, bool, GPUInfo]:
    """
    Multi-GPU evaluation:
    - If homogeneous compute GPUs:
        tensor_parallel_size = count
        effective VRAM = count * VRAM
        cuda_visible_devices = comma-separated indices
    - If heterogeneous:
        select primary compute GPU with largest VRAM and highest compute capability;
        set CUDA_VISIBLE_DEVICES to primary's index
    Returns (tp_size, eff_vram_gb, cuda_visible_devices, is_homogeneous, primary_gpu).
    """
    if not valid_gpus:
        raise ValueError("No valid compute GPUs found")

    if len(valid_gpus) == 1:
        g = valid_gpus[0]
        return 1, g.memory_total_mb / 1024.0, str(g.index), True, g

    ref = valid_gpus[0]
    is_homogeneous = True
    for g in valid_gpus[1:]:
        if g.compute_cap != ref.compute_cap:
            is_homogeneous = False
            break
        # Check VRAM similarity within 5%
        if abs(g.memory_total_mb - ref.memory_total_mb) > (0.05 * ref.memory_total_mb):
            is_homogeneous = False
            break

    if is_homogeneous:
        tp_size = len(valid_gpus)
        eff_vram_gb = sum(g.memory_total_mb for g in valid_gpus) / 1024.0
        cvd = ",".join(str(g.index) for g in valid_gpus)
        primary = valid_gpus[0]
        return tp_size, eff_vram_gb, cvd, True, primary
    else:
        # Heterogeneous: select primary with largest VRAM and highest CC
        primary = max(valid_gpus, key=lambda g: (g.memory_total_mb, g.compute_cap))
        tp_size = 1
        eff_vram_gb = primary.memory_total_mb / 1024.0
        cvd = str(primary.index)
        return tp_size, eff_vram_gb, cvd, False, primary


def classify_profile(
    effective_vram_gb: float,
    primary_gpu: Optional[GPUInfo] = None,
    host_ram_gb: float = 0.0,
    host_cpu_cores: int = 0,
    target_context: Optional[int] = None,
    tp_size: int = 1,
    cuda_visible_devices: str = "0",
    tier: str = "unknown",
) -> ProbedProfile:
    """
    Sizing & Model Selection Matrix:
      - Total VRAM >= 30 GB:
          Model ornith-1.5-35b, ctx 262144, static mem 0.88 (or 0.92 for >=100GB), cpu_offload: false, cpu_offload_gb: 0
      - 20 GB <= VRAM < 30 GB:
          Pure GPU: ctx 65536, cpu_offload: false
          Target ctx forced/requested >= 256k AND host RAM >= 32GB: ctx 262144, cpu_offload: true, cpu_offload_gb: 8
      - 14 GB <= VRAM < 20 GB:
          Model ornith-1.5-9b, ctx 262144, static mem 0.88, cpu_offload: false
      - 8 GB <= VRAM < 14 GB:
          Model ornith-1.5-9b, ctx 32768-65536, static mem 0.85, cpu_offload: false
      - VRAM < 8 GB:
          Fallback profile
      - Guarded CPU Offloading:
          Strict rule: CPU offloading is NEVER enabled when the GPU VRAM can hold the target context.
    """
    vram = effective_vram_gb
    gpu_name = primary_gpu.name if primary_gpu else "NVIDIA GPU"
    total_vram_mb = int(round(vram * 1024))

    if vram >= 100.0 or "spark" in gpu_name.lower():
        profile = "rtx-spark"
        model = "ornith-1.5-35b"
        model_path = "ornith-ai/Ornith-1.5-35B-A3B-NVFP4"
        service = "opencode-sglang-ornith-35b.service"
        max_context = 512000 if ("spark" in gpu_name.lower()) else 262144
        if target_context:
            max_context = target_context
        memory_fraction = 0.92
        offload = "unified-memory" if "spark" in gpu_name.lower() else "pure-gpu"
        cpu_offload = False
        cpu_offload_gb = 0

    elif vram >= 44.0 or "pro 6000" in gpu_name.lower() or "pro-6000" in gpu_name.lower():
        profile = "rtx-pro-6000"
        model = "ornith-1.5-35b"
        model_path = "ornith-ai/Ornith-1.5-35B-A3B-NVFP4"
        service = "opencode-sglang-ornith-35b.service"
        max_context = target_context if target_context else 262144
        memory_fraction = 0.90
        offload = "pure-gpu"
        cpu_offload = False
        cpu_offload_gb = 0

    elif vram >= 30.0:
        # e.g. RTX 5090 (32GB)
        profile = "rtx-5090"
        model = "ornith-1.5-35b"
        model_path = "ornith-ai/Ornith-1.5-35B-A3B-NVFP4"
        service = "opencode-sglang-ornith-35b.service"
        max_context = target_context if target_context else 262144
        memory_fraction = 0.88
        offload = "pure-gpu"
        cpu_offload = False
        cpu_offload_gb = 0

    elif vram >= 20.0:
        # e.g. RTX 4090 / 3090 (24GB)
        profile = "rtx-4090"
        model = "ornith-1.5-35b"
        model_path = "ornith-ai/Ornith-1.5-35B-A3B-NVFP4"
        service = "opencode-sglang-ornith-35b.service"
        memory_fraction = 0.88

        # Guarded CPU offload check:
        # If target context is forced/requested 256k AND host RAM >= 32GB
        if (target_context is not None and target_context >= 262144) and host_ram_gb >= 32.0:
            max_context = 262144
            cpu_offload = True
            cpu_offload_gb = 8
            offload = "cpu-offload"
        else:
            # Pure GPU fits 64k
            max_context = min(target_context, 65536) if target_context else 65536
            cpu_offload = False
            cpu_offload_gb = 0
            offload = "pure-gpu"

    elif vram >= 14.0:
        # e.g. 16GB cards
        profile = "rtx-4080"
        model = "ornith-1.5-9b"
        model_path = "ornith-ai/Ornith-1.5-9B-NVFP4"
        service = "ornith-1.5-9b-nvfp4-low-ctx.service"
        max_context = target_context if target_context else 262144
        memory_fraction = 0.88
        offload = "pure-gpu"
        cpu_offload = False
        cpu_offload_gb = 0

    elif vram >= 8.0:
        # e.g. 12GB or 8GB cards
        profile = "rtx-4070"
        model = "ornith-1.5-9b"
        model_path = "ornith-ai/Ornith-1.5-9B-NVFP4"
        service = "ornith-1.5-9b-nvfp4-low-ctx.service"
        default_ctx = 65536 if vram >= 12.0 else 32768
        max_context = min(target_context, default_ctx) if target_context else default_ctx
        memory_fraction = 0.85
        offload = "pure-gpu"
        cpu_offload = False
        cpu_offload_gb = 0

    else:
        # Fallback profile
        profile = "fallback"
        model = "ornith-1.5-9b"
        model_path = "ornith-ai/Ornith-1.5-9B-NVFP4"
        service = "ornith-1.5-9b-nvfp4-low-ctx.service"
        max_context = target_context if target_context else 32768
        memory_fraction = 0.80
        offload = "pure-gpu"
        cpu_offload = False
        cpu_offload_gb = 0

    # Ensure display name has VRAM if not already
    display_gpu = gpu_name
    if "GB" not in display_gpu and total_vram_mb > 0:
        display_gpu = f"{gpu_name} ({int(round(vram))}GB)"

    return ProbedProfile(
        profile=profile,
        memory_fraction=memory_fraction,
        max_context=max_context,
        kv_cache_dtype="nvfp4",
        offload=offload,
        gpu=display_gpu,
        model=model,
        model_path=model_path,
        service=service,
        tensor_parallel_size=tp_size,
        cuda_visible_devices=cuda_visible_devices,
        cpu_offload=cpu_offload,
        cpu_offload_gb=cpu_offload_gb,
        vram_gb=vram,
        total_vram_mb=total_vram_mb,
        host_ram_gb=host_ram_gb,
        host_cpu_cores=host_cpu_cores,
        detection_tier=tier,
    )


class HardwareProbe:
    """Orchestrates multi-tier GPU and host resource detection."""

    def __init__(
        self,
        procfs_root: str = "/proc",
        sysfs_root: str = "/sys",
        smi_runner: Optional[Callable[[List[str]], str]] = None,
    ):
        self.procfs_root = procfs_root
        self.sysfs_root = sysfs_root
        self.smi_runner = smi_runner

    def probe(
        self,
        override_gpu: Optional[str] = None,
        target_context: Optional[int] = None,
    ) -> ProbedProfile:
        resources = probe_system_resources(self.procfs_root)
        host_ram_gb = resources.ram_total_mb / 1024.0
        host_cpu_cores = resources.cpu_cores

        if override_gpu:
            return self._handle_override(
                override_gpu, target_context, host_ram_gb, host_cpu_cores
            )

        # Tier 1: PyTorch / CUDA
        tier = "torch"
        all_gpus = probe_tier1_torch()

        # Tier 2: nvidia-smi
        if not all_gpus:
            tier = "nvidia-smi"
            all_gpus = probe_tier2_nvidia_smi(self.smi_runner)

        # Tier 3: /proc & /sys sysfs
        if not all_gpus:
            tier = "procfs-sysfs"
            all_gpus = probe_tier3_procfs_sysfs(self.procfs_root, self.sysfs_root)

        if not all_gpus:
            # Complete fallback
            return classify_profile(
                effective_vram_gb=0.0,
                primary_gpu=None,
                host_ram_gb=host_ram_gb,
                host_cpu_cores=host_cpu_cores,
                target_context=target_context,
                tier="fallback",
            )

        # Device Filtering
        valid_gpus, excluded_gpus = filter_compute_gpus(all_gpus)

        if not valid_gpus:
            # All available devices were filtered (e.g. vfio-pci or CC < 8.0)
            return classify_profile(
                effective_vram_gb=0.0,
                primary_gpu=None,
                host_ram_gb=host_ram_gb,
                host_cpu_cores=host_cpu_cores,
                target_context=target_context,
                tier=f"{tier}-filtered",
            )

        # Multi-GPU evaluation
        tp_size, eff_vram_gb, cvd, is_homo, primary = evaluate_multi_gpu(valid_gpus)

        return classify_profile(
            effective_vram_gb=eff_vram_gb,
            primary_gpu=primary,
            host_ram_gb=host_ram_gb,
            host_cpu_cores=host_cpu_cores,
            target_context=target_context,
            tp_size=tp_size,
            cuda_visible_devices=cvd,
            tier=tier,
        )

    def _handle_override(
        self,
        override_gpu: str,
        target_context: Optional[int],
        host_ram_gb: float,
        host_cpu_cores: int,
    ) -> ProbedProfile:
        norm = override_gpu.lower()
        if norm in ("rtx-5090", "5090"):
            primary = GPUInfo(
                index=0,
                name="NVIDIA GeForce RTX 5090 (32GB)",
                memory_total_mb=32768,
                compute_cap=12.0,
            )
            vram = 32.0
        elif norm in ("rtx-pro-6000", "pro-6000", "6000"):
            primary = GPUInfo(
                index=0,
                name="NVIDIA RTX PRO 6000",
                memory_total_mb=49152,
                compute_cap=8.9,
            )
            vram = 48.0
        elif norm in ("rtx-spark", "spark"):
            primary = GPUInfo(
                index=0,
                name="NVIDIA RTX Spark 128GB Unified Memory",
                memory_total_mb=131072,
                compute_cap=12.0,
            )
            vram = 128.0
        elif norm in ("rtx-4090", "4090"):
            primary = GPUInfo(
                index=0,
                name="NVIDIA GeForce RTX 4090 (24GB)",
                memory_total_mb=24576,
                compute_cap=8.9,
            )
            vram = 24.0
        elif norm in ("rtx-4080", "4080"):
            primary = GPUInfo(
                index=0,
                name="NVIDIA GeForce RTX 4080 (16GB)",
                memory_total_mb=16384,
                compute_cap=8.9,
            )
            vram = 16.0
        elif norm in ("rtx-4070", "4070"):
            primary = GPUInfo(
                index=0,
                name="NVIDIA GeForce RTX 4070 (12GB)",
                memory_total_mb=12288,
                compute_cap=8.9,
            )
            vram = 12.0
        elif norm == "fallback":
            primary = GPUInfo(
                index=0,
                name="unknown GPU device",
                memory_total_mb=0,
                compute_cap=0.0,
            )
            vram = 0.0
        else:
            raise ValueError(
                f"Unknown --override-gpu value: {override_gpu} (valid: rtx-5090, rtx-pro-6000, rtx-spark, rtx-4090, rtx-4080, rtx-4070, fallback)"
            )

        return classify_profile(
            effective_vram_gb=vram,
            primary_gpu=primary,
            host_ram_gb=host_ram_gb,
            host_cpu_cores=host_cpu_cores,
            target_context=target_context,
            tp_size=1,
            cuda_visible_devices="0",
            tier="override",
        )


def probe_hardware(
    override_gpu: Optional[str] = None,
    target_context: Optional[int] = None,
    procfs_root: str = "/proc",
    sysfs_root: str = "/sys",
    smi_runner: Optional[Callable[[List[str]], str]] = None,
) -> ProbedProfile:
    prober = HardwareProbe(
        procfs_root=procfs_root,
        sysfs_root=sysfs_root,
        smi_runner=smi_runner,
    )
    return prober.probe(override_gpu=override_gpu, target_context=target_context)


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Probe host GPU and CPU resources for SGLang/OpenCode deployment."
    )
    parser.add_argument(
        "--format",
        choices=["json", "env", "flags"],
        default="json",
        help="Output format: json (default), env, or flags.",
    )
    parser.add_argument(
        "--override-gpu",
        type=str,
        default=None,
        help="Force a specific GPU profile: rtx-5090, rtx-pro-6000, rtx-spark, rtx-4090, rtx-4080, rtx-4070, fallback.",
    )
    parser.add_argument(
        "--target-context",
        type=int,
        default=None,
        help="Requested target context window size (e.g. 262144, 65536).",
    )

    args = parser.parse_args()

    try:
        profile = probe_hardware(
            override_gpu=args.override_gpu,
            target_context=args.target_context,
        )
    except Exception as e:
        sys.stderr.write(f"❌ Error probing hardware: {e}\n")
        sys.exit(1)

    if args.format == "json":
        print(json.dumps(profile.to_dict(), indent=2))
    elif args.format == "env":
        print(profile.to_env())
    elif args.format == "flags":
        print(profile.to_flags())


if __name__ == "__main__":
    main()
