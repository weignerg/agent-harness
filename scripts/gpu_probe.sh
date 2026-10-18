#!/usr/bin/env bash
# ==============================================================================
# gpu_probe.sh
# Probe the host GPU and emit an optimized SGLang + OpenCode profile
# as JSON, env, or flags.
#
# Delegates to `python3 -m harness.hardware.probe "$@"` with a resilient
# pure-shell procfs fallback if Python or the harness module is unavailable.
#
# Profiles:
#   rtx-5090      ~32 GB        memory_fraction 0.88  max_ctx 262144
#   rtx-pro-6000  ~48-96 GB     memory_fraction 0.90  max_ctx 262144
#   rtx-spark     ~128 GB unified memory_fraction 0.92  max_ctx 512000
#   rtx-4090      ~24 GB        memory_fraction 0.88  max_ctx 65536 / 262144
#   rtx-4080      ~16 GB        memory_fraction 0.88  max_ctx 262144
#   rtx-4070      ~12 GB        memory_fraction 0.85  max_ctx 65536
#   fallback      any <8 GB     memory_fraction 0.80  max_ctx 32768
#
# Usage:
#   scripts/gpu_probe.sh [--format json|env|flags] [--override-gpu <type>] [--target-context <int>]
# ==============================================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Attempt Python module delegation first
if command -v python3 >/dev/null 2>&1; then
    if PYTHONPATH="${REPO_DIR}:${PYTHONPATH:-}" python3 -m harness.hardware.probe "$@"; then
        exit 0
    fi
fi

# ==============================================================================
# Pure-shell fallback (Procfs + Sysfs)
# ==============================================================================
FORMAT="json"
OVERRIDE_GPU=""
TARGET_CONTEXT=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --format)
            FORMAT="${2:-json}"
            shift 2
            ;;
        --format=*)
            FORMAT="${1#*=}"
            shift
            ;;
        --override-gpu)
            OVERRIDE_GPU="${2:-}"
            shift 2
            ;;
        --override-gpu=*)
            OVERRIDE_GPU="${1#*=}"
            shift
            ;;
        --target-context)
            TARGET_CONTEXT="${2:-}"
            shift 2
            ;;
        --target-context=*)
            TARGET_CONTEXT="${1#*=}"
            shift
            ;;
        -h|--help)
            cat << EOF
Usage: gpu_probe.sh [--format json|env|flags] [--override-gpu <type>] [--target-context <int>]

Detects the host GPU and prints an SGLang/OpenCode profile.

Options:
  --format <fmt>         Output format: json (default), env, or flags
  --override-gpu <type>  Force profile: rtx-5090 | rtx-pro-6000 | rtx-spark | rtx-4090 | rtx-4080 | rtx-4070 | fallback
  --target-context <int> Desired target context window size
  -h, --help             Show this help
EOF
            exit 0
            ;;
        *)
            echo "❌ Unknown option: $1" >&2
            exit 1
            ;;
    esac
done

# Read host memory and cpu info
HOST_RAM_MB=32768
if [ -r /proc/meminfo ]; then
    raw_ram="$(grep -E '^MemTotal:' /proc/meminfo | awk '{print $2}')"
    if [[ "$raw_ram" =~ ^[0-9]+$ ]]; then
        HOST_RAM_MB=$(( raw_ram / 1024 ))
    fi
fi
HOST_RAM_GB=$(( HOST_RAM_MB / 1024 ))

HOST_CPU_CORES=1
if [ -r /proc/cpuinfo ]; then
    raw_cores="$(grep -c '^processor' /proc/cpuinfo || echo 1)"
    if [[ "$raw_cores" =~ ^[0-9]+$ && "$raw_cores" -gt 0 ]]; then
        HOST_CPU_CORES="$raw_cores"
    fi
fi

# Detect GPUs from procfs and sysfs
detect_procfs_gpus() {
    local pci_dev_dir="/sys/bus/pci/devices"
    [ -d "$pci_dev_dir" ] || return 1

    local gpus=()
    for dev in "$pci_dev_dir"/*; do
        [ -d "$dev" ] || continue
        [ -f "$dev/vendor" ] && [ -f "$dev/class" ] || continue
        
        local vendor pci_class
        vendor="$(cat "$dev/vendor" 2>/dev/null || true)"
        pci_class="$(cat "$dev/class" 2>/dev/null || true)"
        
        # Check NVIDIA vendor 0x10de and VGA/3D controller
        if [[ "$vendor" == "0x10de" && ( "$pci_class" == 0x0300* || "$pci_class" == 0x0302* ) ]]; then
            local bus_id driver
            bus_id="$(basename "$dev")"
            driver="unknown"
            if [ -L "$dev/driver" ]; then
                driver="$(basename "$(readlink -f "$dev/driver")")"
            fi
            
            # Filter out non-nvidia drivers
            [ "$driver" = "nvidia" ] || continue
            
            local name="NVIDIA GPU" vram_mb=0 cc="8.0"
            if [ -f "/proc/driver/nvidia/gpus/${bus_id}/information" ]; then
                name="$(grep -E '^Model:' "/proc/driver/nvidia/gpus/${bus_id}/information" | cut -d':' -f2 | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
            fi
            
            # VRAM check from resource1
            if [ -f "$dev/resource1" ]; then
                local res1_size
                res1_size="$(stat -c %s "$dev/resource1" 2>/dev/null || echo 0)"
                if [[ "$res1_size" =~ ^[0-9]+$ && "$res1_size" -gt 0 ]]; then
                    vram_mb=$(( res1_size / (1024 * 1024) ))
                fi
            fi
            
            # Estimate CC and fallback VRAM by name
            local name_upper="${name^^}"
            if [[ "$name_upper" == *"5090"* ]]; then
                cc="12.0"; [ "$vram_mb" -eq 0 ] && vram_mb=32768
            elif [[ "$name_upper" == *"5080"* ]]; then
                cc="12.0"; [ "$vram_mb" -eq 0 ] && vram_mb=16384
            elif [[ "$name_upper" == *"SPARK"* ]]; then
                cc="12.0"; [ "$vram_mb" -eq 0 ] && vram_mb=131072
            elif [[ "$name_upper" == *"H100"* || "$name_upper" == *"H200"* ]]; then
                cc="9.0"; [ "$vram_mb" -eq 0 ] && vram_mb=81920
            elif [[ "$name_upper" == *"PRO 6000"* || "$name_upper" == *"6000"* ]]; then
                cc="8.9"; [ "$vram_mb" -eq 0 ] && vram_mb=49152
            elif [[ "$name_upper" == *"4090"* ]]; then
                cc="8.9"; [ "$vram_mb" -eq 0 ] && vram_mb=24576
            elif [[ "$name_upper" == *"4080"* ]]; then
                cc="8.9"; [ "$vram_mb" -eq 0 ] && vram_mb=16384
            elif [[ "$name_upper" == *"4070"* ]]; then
                cc="8.9"; [ "$vram_mb" -eq 0 ] && vram_mb=12288
            elif [[ "$name_upper" == *"3090"* ]]; then
                cc="8.6"; [ "$vram_mb" -eq 0 ] && vram_mb=24576
            elif [[ "$name_upper" == *"3080"* ]]; then
                cc="8.6"; [ "$vram_mb" -eq 0 ] && vram_mb=10240
            elif [[ "$name_upper" == *"1060"* ]]; then
                cc="6.1"; [ "$vram_mb" -eq 0 ] && vram_mb=6144
            fi
            
            # Filter CC < 8.0
            local cc_major="${cc%%.*}"
            if [[ "$cc_major" -lt 8 ]]; then
                continue
            fi
            
            echo "${name}|${vram_mb}|${cc}|${bus_id}"
        fi
    done
}

GPU_NAME="NVIDIA GPU"
VRAM_MB=0
CC="8.0"
TP_SIZE=1
CVD="0"

if [ -n "$OVERRIDE_GPU" ]; then
    case "$OVERRIDE_GPU" in
        rtx-5090) GPU_NAME="NVIDIA GeForce RTX 5090 (32GB)"; VRAM_MB=32768; CC="12.0" ;;
        rtx-pro-6000) GPU_NAME="NVIDIA RTX PRO 6000"; VRAM_MB=49152; CC="8.9" ;;
        rtx-spark) GPU_NAME="NVIDIA RTX Spark 128GB Unified Memory"; VRAM_MB=131072; CC="12.0" ;;
        rtx-4090) GPU_NAME="NVIDIA GeForce RTX 4090 (24GB)"; VRAM_MB=24576; CC="8.9" ;;
        rtx-4080) GPU_NAME="NVIDIA GeForce RTX 4080 (16GB)"; VRAM_MB=16384; CC="8.9" ;;
        rtx-4070) GPU_NAME="NVIDIA GeForce RTX 4070 (12GB)"; VRAM_MB=12288; CC="8.9" ;;
        fallback) GPU_NAME="unknown GPU device"; VRAM_MB=0; CC="0.0" ;;
        *) echo "❌ Unknown --override-gpu value: $OVERRIDE_GPU" >&2; exit 1 ;;
    esac
else
    mapfile -t detected < <(detect_procfs_gpus)
    if [ "${#detected[@]}" -gt 0 ]; then
        TP_SIZE="${#detected[@]}"
        IFS='|' read -r GPU_NAME VRAM_MB CC BUS_ID <<< "${detected[0]}"
        if [ "$TP_SIZE" -gt 1 ]; then
            # Homogeneous multi-GPU aggregation
            VRAM_MB=$(( VRAM_MB * TP_SIZE ))
            CVD="0"
            for ((i=1; i<TP_SIZE; i++)); do CVD="${CVD},${i}"; done
        fi
    fi
fi

VRAM_GB=$(( VRAM_MB / 1024 ))

# Profile and sizing decision
PROFILE="fallback"
MODEL="ornith-1.5-9b"
MODEL_PATH="ornith-ai/Ornith-1.5-9B-NVFP4"
SERVICE="ornith-1.5-9b-nvfp4-low-ctx.service"
MAX_CTX=32768
MEM_FRACTION=0.80
OFFLOAD="pure-gpu"
CPU_OFFLOAD=false
CPU_OFFLOAD_GB=0

name_lower="${GPU_NAME,,}"
if [[ "$VRAM_GB" -ge 100 || "$name_lower" == *"spark"* ]]; then
    PROFILE="rtx-spark"
    MODEL="ornith-1.5-35b"
    MODEL_PATH="ornith-ai/Ornith-1.5-35B-A3B-NVFP4"
    SERVICE="opencode-sglang-ornith-35b.service"
    MAX_CTX=262144
    [[ "$name_lower" == *"spark"* ]] && MAX_CTX=512000
    [ -n "$TARGET_CONTEXT" ] && MAX_CTX="$TARGET_CONTEXT"
    MEM_FRACTION=0.92
    OFFLOAD="pure-gpu"
    [[ "$name_lower" == *"spark"* ]] && OFFLOAD="unified-memory"
elif [[ "$VRAM_GB" -ge 44 || "$name_lower" == *"pro 6000"* || "$name_lower" == *"pro-6000"* ]]; then
    PROFILE="rtx-pro-6000"
    MODEL="ornith-1.5-35b"
    MODEL_PATH="ornith-ai/Ornith-1.5-35B-A3B-NVFP4"
    SERVICE="opencode-sglang-ornith-35b.service"
    MAX_CTX=262144
    [ -n "$TARGET_CONTEXT" ] && MAX_CTX="$TARGET_CONTEXT"
    MEM_FRACTION=0.90
elif [[ "$VRAM_GB" -ge 30 ]]; then
    PROFILE="rtx-5090"
    MODEL="ornith-1.5-35b"
    MODEL_PATH="ornith-ai/Ornith-1.5-35B-A3B-NVFP4"
    SERVICE="opencode-sglang-ornith-35b.service"
    MAX_CTX=262144
    [ -n "$TARGET_CONTEXT" ] && MAX_CTX="$TARGET_CONTEXT"
    MEM_FRACTION=0.88
elif [[ "$VRAM_GB" -ge 20 ]]; then
    PROFILE="rtx-4090"
    MODEL="ornith-1.5-35b"
    MODEL_PATH="ornith-ai/Ornith-1.5-35B-A3B-NVFP4"
    SERVICE="opencode-sglang-ornith-35b.service"
    MEM_FRACTION=0.88
    if [[ -n "$TARGET_CONTEXT" && "$TARGET_CONTEXT" -ge 262144 && "$HOST_RAM_GB" -ge 32 ]]; then
        MAX_CTX=262144
        CPU_OFFLOAD=true
        CPU_OFFLOAD_GB=8
        OFFLOAD="cpu-offload"
    else
        MAX_CTX=65536
        [ -n "$TARGET_CONTEXT" ] && [ "$TARGET_CONTEXT" -lt 65536 ] && MAX_CTX="$TARGET_CONTEXT"
        OFFLOAD="pure-gpu"
    fi
elif [[ "$VRAM_GB" -ge 14 ]]; then
    PROFILE="rtx-4080"
    MODEL="ornith-1.5-9b"
    MODEL_PATH="ornith-ai/Ornith-1.5-9B-NVFP4"
    SERVICE="ornith-1.5-9b-nvfp4-low-ctx.service"
    MAX_CTX=262144
    [ -n "$TARGET_CONTEXT" ] && MAX_CTX="$TARGET_CONTEXT"
    MEM_FRACTION=0.88
elif [[ "$VRAM_GB" -ge 8 ]]; then
    PROFILE="rtx-4070"
    MODEL="ornith-1.5-9b"
    MODEL_PATH="ornith-ai/Ornith-1.5-9B-NVFP4"
    SERVICE="ornith-1.5-9b-nvfp4-low-ctx.service"
    MAX_CTX=32768
    [[ "$VRAM_GB" -ge 12 ]] && MAX_CTX=65536
    [ -n "$TARGET_CONTEXT" ] && [ "$TARGET_CONTEXT" -lt "$MAX_CTX" ] && MAX_CTX="$TARGET_CONTEXT"
    MEM_FRACTION=0.85
fi

# Ensure display name includes VRAM if not present
DISPLAY_GPU="$GPU_NAME"
if [[ "$DISPLAY_GPU" != *"GB"* && "$VRAM_GB" -gt 0 ]]; then
    DISPLAY_GPU="${GPU_NAME} (${VRAM_GB}GB)"
fi

if [ "$FORMAT" = "json" ]; then
    cat << EOF
{
  "profile": "${PROFILE}",
  "memory_fraction": ${MEM_FRACTION},
  "max_context": ${MAX_CTX},
  "kv_cache_dtype": "nvfp4",
  "offload": "${OFFLOAD}",
  "gpu": "${DISPLAY_GPU}",
  "model": "${MODEL}",
  "model_path": "${MODEL_PATH}",
  "service": "${SERVICE}",
  "tensor_parallel_size": ${TP_SIZE},
  "cuda_visible_devices": "${CVD}",
  "cpu_offload": ${CPU_OFFLOAD},
  "cpu_offload_gb": ${CPU_OFFLOAD_GB},
  "vram_gb": ${VRAM_GB}.0,
  "total_vram_mb": ${VRAM_MB},
  "host_ram_gb": ${HOST_RAM_GB}.0,
  "host_cpu_cores": ${HOST_CPU_CORES},
  "detection_tier": "procfs-fallback"
}
EOF
elif [ "$FORMAT" = "env" ]; then
    cat << EOF
PROBED_PROFILE=${PROFILE}
PROBED_MODEL=${MODEL}
PROBED_MODEL_PATH=${MODEL_PATH}
PROBED_SERVICE=${SERVICE}
PROBED_CONTEXT_LENGTH=${MAX_CTX}
PROBED_MEM_FRACTION=${MEM_FRACTION}
PROBED_KV_CACHE_DTYPE=nvfp4
PROBED_OFFLOAD=${OFFLOAD}
PROBED_CPU_OFFLOAD=${CPU_OFFLOAD}
PROBED_CPU_OFFLOAD_GB=${CPU_OFFLOAD_GB}
PROBED_TP_SIZE=${TP_SIZE}
PROBED_CUDA_VISIBLE_DEVICES=${CVD}
PROBED_VRAM_GB=${VRAM_GB}
PROBED_GPU="${DISPLAY_GPU}"
EOF
elif [ "$FORMAT" = "flags" ]; then
    out="--model-path ${MODEL_PATH} --served-model-name ${MODEL} --mem-fraction-static ${MEM_FRACTION} --context-length ${MAX_CTX}"
    [ "$CPU_OFFLOAD" = true ] && [ "$CPU_OFFLOAD_GB" -gt 0 ] && out="${out} --cpu-offload-gb ${CPU_OFFLOAD_GB}"
    [ "$TP_SIZE" -gt 1 ] && out="${out} --tensor-parallel-size ${TP_SIZE}"
    echo "$out"
fi
