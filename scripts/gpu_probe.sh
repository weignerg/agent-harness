#!/usr/bin/env bash
# ==============================================================================
# gpu_probe.sh
# Probe the host GPU and emit an optimized SGLang + OpenCode profile
# as JSON. Used by install.sh (Issue #21) to size KV-cache memory fraction,
# context window, and offload policy per detected card.
#
# Profiles:
#   rtx-5090      ~32 GB        memory_fraction 0.88  max_ctx 262144
#   rtx-pro-6000  ~48-96 GB     memory_fraction 0.90  max_ctx 262144
#   rtx-spark     ~128 GB unified memory_fraction 0.92  max_ctx 512000
#   fallback      any >=32 GB   memory_fraction 0.88  max_ctx 262144
#
# Usage:
#   scripts/gpu_probe.sh [--override-gpu <type>]
# ==============================================================================
set -euo pipefail

OVERRIDE_GPU=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --override-gpu)
            OVERRIDE_GPU="${2:-}"
            shift 2
            ;;
        --override-gpu=*)
            OVERRIDE_GPU="${1#*=}"
            shift
            ;;
        -h|--help)
            cat << EOF
Usage: gpu_probe.sh [--override-gpu <type>]

Detects the host GPU and prints an SGLang/OpenCode profile as JSON.

Options:
  --override-gpu <type>  Force a profile: rtx-5090 | rtx-pro-6000 | rtx-spark | fallback
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

detect_nvidia_smi() {
    command -v nvidia-smi >/dev/null 2>&1 || return 1
    nvidia-smi --query-gpu=name,memory.total --format=csv,noheader,nounits 2>/dev/null | head -n1 || return 1
}

choose_profile() {
    local forced="$1"
    local gpu_name="$2"
    local mem_mib="$3"

    if [[ -n "$forced" ]]; then
        case "$forced" in
            rtx-5090|rtx-pro-6000|rtx-spark|fallback) ;;
            *) echo "❌ Unknown --override-gpu value: $forced (valid: rtx-5090, rtx-pro-6000, rtx-spark, fallback)" >&2; exit 1 ;;
        esac
        echo "$forced"
        return
    fi

    local name_lower="${gpu_name,,}"
    if [[ "$name_lower" == *"spark"* ]]; then
        echo "rtx-spark"; return
    fi
    if [[ "$name_lower" == *"pro 6000"* || "$name_lower" == *"pro-6000"* || "$name_lower" == *"6000"* ]]; then
        echo "rtx-pro-6000"; return
    fi
    if [[ "$name_lower" == *"5090"* ]]; then
        echo "rtx-5090"; return
    fi

    # No name match: fall back on usable VRAM threshold.
    local mem_gb=$(( mem_mib / 1024 ))
    if [[ "$mem_gb" -ge 100 ]]; then
        echo "rtx-spark"
    elif [[ "$mem_gb" -ge 44 ]]; then
        echo "rtx-pro-6000"
    else
        echo "fallback"
    fi
}

profile_json() {
    local profile="$1"
    case "$profile" in
        rtx-5090)
            echo '{"profile":"rtx-5090","memory_fraction":0.88,"max_context":262144,"kv_cache_dtype":"nvfp4","offload":"pure-gpu","gpu":"NVIDIA GeForce RTX 5090 (32GB)"}' ;;
        rtx-pro-6000)
            echo '{"profile":"rtx-pro-6000","memory_fraction":0.90,"max_context":262144,"kv_cache_dtype":"nvfp4","offload":"pure-gpu","gpu":"NVIDIA RTX PRO 6000"}' ;;
        rtx-spark)
            echo '{"profile":"rtx-spark","memory_fraction":0.92,"max_context":512000,"kv_cache_dtype":"nvfp4","offload":"unified-memory","gpu":"NVIDIA RTX Spark 128GB Unified Memory"}' ;;
        fallback)
            echo '{"profile":"fallback","memory_fraction":0.88,"max_context":262144,"kv_cache_dtype":"nvfp4","offload":"pure-gpu","gpu":"unknown GPU device"}' ;;
        *)
            echo '{"profile":"fallback","memory_fraction":0.88,"max_context":262144,"kv_cache_dtype":"nvfp4","offload":"pure-gpu","gpu":"unknown device"}' ;;
    esac
}

main() {
    local gpu_name="" mem_mib=0
    local smi_line
    if smi_line="$(detect_nvidia_smi)" && [[ -n "$smi_line" ]]; then
        gpu_name="$(echo "$smi_line" | cut -d',' -f1 | sed 's/[[:space:]]*$//')"
        local mem_raw
        mem_raw="$(echo "$smi_line" | cut -d',' -f2 | tr -d '[:space:]')"
        if [[ "$mem_raw" =~ ^[0-9]+$ ]]; then
            mem_mib="$mem_raw"
        fi
    fi

    local profile
    profile="$(choose_profile "$OVERRIDE_GPU" "$gpu_name" "$mem_mib")"

    local json
    json="$(profile_json "$profile")"

    echo "$json"
}

main
