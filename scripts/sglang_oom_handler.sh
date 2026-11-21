#!/usr/bin/env bash
# ==============================================================================
# scripts/sglang_oom_handler.sh - Progressive SGLang startup & OOM fallback.
#
# Run via systemd ExecStopPost= (and callable from install.sh --fallback-step).
# All 3 SGLang units start with full-performance defaults (prefill CUDA graphs
# enabled, SGLang auto Mamba cache, decode CUDA graph bs=8, probed context).
# Only when a failure/OOM/capture-crash actually occurs does this handler step
# down the affected model in ~/.config/opencode-backends/context_length.state:
#
#   1. Prefill CUDA graph failure (crash/OOM/hang during prefill capture):
#        disable prefill CUDA graph (--disable-prefill-cuda-graph), keeping
#        default Mamba cache & context length intact.
#   2. Memory / Mamba cache pressure (OOM before prefill capture, or after
#      prefill graph is disabled):
#        step Mamba cache auto -> 8 -> 5 -> 3 (and decode CUDA graph bs 8 -> 4
#        at size 3), keeping context length intact.
#   3. Context length ladder (only after prefill graph & Mamba bounds are
#      exhausted):
#        262144 -> 131072 -> 65536 -> 32768.
#
# CLI:
#   --status                        print active context length for SERVICE
#   --status-all                    print all active overrides for SERVICE
#   --reset                         clear all fallback overrides & restore 256k
#   --fallback-step [auto|prefill|mamba|context] [--no-restart]
#                                   apply next fallback step immediately
#
# Env: SERVICE_RESULT / EXIT_STATUS (set by systemd), OOM_FORCE=1,
#      PREFILL_CRASH_FORCE=1, OPENCODE_OOM_LOG (file to scan, optional).
# ==============================================================================
set -uo pipefail

SERVICE="sglang-ornith-1.5-35b.service"

detect_service() {
    if [ -n "${SGLANG_UNIT:-}" ]; then
        echo "$SGLANG_UNIT"
        return
    fi
    if [ -n "${SGLANG_SERVICE:-}" ]; then
        echo "$SGLANG_SERVICE"
        return
    fi
    if [ -f "${HOME}/.config/opencode-backends/env" ]; then
        local env_svc
        env_svc="$(grep -s '^SGLANG_SERVICE=' "${HOME}/.config/opencode-backends/env" | head -n1 | cut -d'=' -f2- | tr -d '"\047')"
        if [ -n "$env_svc" ]; then
            echo "$env_svc"
            return
        fi
        local env_primary
        env_primary="$(grep -s '^SGLANG_PRIMARY_MODEL=' "${HOME}/.config/opencode-backends/env" | head -n1 | cut -d'=' -f2- | tr -d '"\047')"
        if [[ "$env_primary" == *"27b"* || "$env_primary" == *"qwen"* ]]; then
            echo "sglang-qwen3.8-27b.service"
            return
        elif [[ "$env_primary" == *"9b"* ]]; then
            echo "sglang-ornith-1.5-9b.service"
            return
        elif [[ "$env_primary" == *"35b"* ]]; then
            echo "sglang-ornith-1.5-35b.service"
            return
        fi
    fi
    echo "$SERVICE"
}

SERVICE="$(detect_service)"
STATE_DIR="${HOME}/.config/opencode-backends"
STATE="${STATE_DIR}/context_length.state"

LADDER=(262144 131072 65536 32768)
MAMBA_LADDER=(8 5 3)

service_tag() {
    if [[ "$SERVICE" == *"27b"* || "$SERVICE" == *"qwen"* ]]; then
        echo "27B"
    elif [[ "$SERVICE" == *"9b"* ]]; then
        echo "9B"
    else
        echo "35B"
    fi
}

state_key() {
    local tag
    tag="$(service_tag)"
    case "$tag" in
        27B) echo "SGLANG_27B_CONTEXT_LENGTH" ;;
        9B)  echo "SGLANG_9B_CONTEXT_LENGTH" ;;
        *)   echo "SGLANG_CONTEXT_LENGTH" ;;
    esac
}

prefill_key() {
    echo "SGLANG_$(service_tag)_PREFILL_GRAPH_ARGS"
}

mamba_key() {
    echo "SGLANG_$(service_tag)_MAMBA_ARGS"
}

cg_bs_key() {
    echo "SGLANG_$(service_tag)_CUDA_GRAPH_MAX_BS"
}

read_state_val() {
    local key="$1"
    if [ -r "$STATE" ]; then
        local raw
        raw="$(grep -E "^${key}=" "$STATE" 2>/dev/null | tail -1 | cut -d'=' -f2- || true)"
        raw="${raw#\"}"
        raw="${raw%\"}"
        printf '%s' "$raw"
    fi
}

write_state_kv() {
    local key="$1"
    local val="$2"
    mkdir -p "$STATE_DIR"
    local t
    t="$(mktemp "${STATE}.XXXXXX")"
    if [ -r "$STATE" ]; then
        grep -v "^${key}=" "$STATE" > "$t" || true
    fi
    if [ -n "$val" ]; then
        if [[ "$val" =~ [[:space:]] ]]; then
            printf '%s="%s"\n' "$key" "$val" >> "$t"
        else
            printf '%s=%s\n' "$key" "$val" >> "$t"
        fi
    fi
    mv "$t" "$STATE"
}

remove_state_key() {
    local key="$1"
    if [ -r "$STATE" ]; then
        local t
        t="$(mktemp "${STATE}.XXXXXX")"
        grep -v "^${key}=" "$STATE" > "$t" || true
        mv "$t" "$STATE"
    fi
}

current() {
    local v=""
    local key
    key="$(state_key)"
    v="$(read_state_val "$key")"
    if [ -z "$v" ] || ! [[ "$v" =~ ^[0-9]+$ ]]; then
        local env_val="${!key:-}"
        if [[ "$env_val" =~ ^[0-9]+$ ]]; then
            v="$env_val"
        fi
    fi
    echo "${v:-${LADDER[0]}}"
}

current_prefill_graph() {
    local v
    v="$(read_state_val "$(prefill_key)")"
    if [ -n "$v" ]; then
        echo "$v"
    else
        echo "enabled"
    fi
}

current_mamba_size() {
    local v
    v="$(read_state_val "$(mamba_key)")"
    if [[ "$v" =~ --max-mamba-cache-size[[:space:]]+([0-9]+) ]]; then
        echo "${BASH_REMATCH[1]}"
    else
        echo "auto"
    fi
}

current_cg_bs() {
    local v
    v="$(read_state_val "$(cg_bs_key)")"
    echo "${v:-8}"
}

write_state() {
    write_state_kv "$(state_key)" "$1"
}

reset_service_state() {
    remove_state_key "$(prefill_key)"
    remove_state_key "$(mamba_key)"
    remove_state_key "$(cg_bs_key)"
    write_state "${LADDER[0]}"
}

step_disable_prefill() {
    local pkey cur_p
    pkey="$(prefill_key)"
    cur_p="$(read_state_val "$pkey")"
    if [[ "$cur_p" == *"--disable-prefill-cuda-graph"* ]]; then
        return 1
    fi
    write_state_kv "$pkey" "--disable-prefill-cuda-graph"
    STEP_DESC="disabled prefill CUDA graph (${pkey}=--disable-prefill-cuda-graph; Mamba cache=$(current_mamba_size), context=$(current))"
    return 0
}

step_mamba_cache() {
    local cur_m next_m=""
    cur_m="$(current_mamba_size)"
    if [ "$cur_m" = "auto" ]; then
        next_m="${MAMBA_LADDER[0]}"
    else
        for sz in "${MAMBA_LADDER[@]}"; do
            if [ "$sz" -lt "$cur_m" ]; then
                next_m="$sz"
                break
            fi
        done
    fi
    if [ -z "$next_m" ]; then
        return 1
    fi
    local mval="--max-mamba-cache-size ${next_m} --mamba-radix-cache-strategy extra_buffer --mamba-ssm-dtype float32"
    write_state_kv "$(mamba_key)" "$mval"
    local extra=""
    if [ "$next_m" -le 3 ]; then
        write_state_kv "$(cg_bs_key)" "4"
        extra=", decode_cg_bs=4"
    fi
    STEP_DESC="stepped Mamba cache ${cur_m} -> ${next_m}${extra} (context=$(current))"
    return 0
}

step_context_length() {
    local cur next
    cur="$(current)"
    next="$cur"
    for i in "${!LADDER[@]}"; do
        if [ "${LADDER[$i]}" -lt "$cur" ]; then
            next="${LADDER[$i]}"
            break
        fi
    done
    if [ "$next" -eq "$cur" ]; then
        return 1
    fi
    write_state "$next"
    STEP_DESC="stepped context ${cur} -> ${next}"
    return 0
}

apply_progressive_fallback() {
    local mode="$1"
    STEP_DESC=""
    case "$mode" in
        prefill)
            step_disable_prefill && return 0
            step_mamba_cache && return 0
            step_context_length && return 0
            return 1
            ;;
        mamba)
            step_mamba_cache && return 0
            step_disable_prefill && return 0
            step_context_length && return 0
            return 1
            ;;
        context)
            step_context_length && return 0
            return 1
            ;;
        auto|oom)
            step_disable_prefill && return 0
            step_mamba_cache && return 0
            step_context_length && return 0
            return 1
            ;;
        *)
            echo "sglang_oom_handler: unknown fallback mode: $mode" >&2
            return 2
            ;;
    esac
}

FALLBACK_MODE=""
NO_RESTART=false

while [ $# -gt 0 ]; do
    case "$1" in
        --status)
            current
            exit 0
            ;;
        --status-all)
            echo "service=${SERVICE} context=$(current) prefill_graph=$(current_prefill_graph) mamba_cache=$(current_mamba_size) decode_cg_bs=$(current_cg_bs)"
            exit 0
            ;;
        --reset)
            reset_service_state
            echo "Reset ${SERVICE}: context=${LADDER[0]}, prefill_graph=enabled, mamba_cache=auto, decode_cg_bs=8"
            exit 0
            ;;
        --fallback-step)
            FALLBACK_MODE="${2:-auto}"
            shift
            ;;
        --no-restart)
            NO_RESTART=true
            ;;
        *)
            echo "Usage: $0 [--status|--status-all|--reset|--fallback-step auto|prefill|mamba|context [--no-restart]]" >&2
            exit 2
            ;;
    esac
    shift
done

read_failure_log() {
    if [ -n "${OPENCODE_OOM_LOG:-}" ] && [ -r "${OPENCODE_OOM_LOG}" ]; then
        tail -n 250 "$OPENCODE_OOM_LOG" 2>/dev/null || true
        return 0
    fi
    if [ "${SERVICE_RESULT:-}" != "success" ] && command -v journalctl >/dev/null 2>&1; then
        if [ -n "${INVOCATION_ID:-}" ]; then
            journalctl --user _SYSTEMD_INVOCATION_ID="$INVOCATION_ID" -n 250 --no-pager 2>/dev/null || true
        else
            journalctl --user -u "$SERVICE" -n 250 --no-pager 2>/dev/null || true
        fi
    fi
}

detect_failure_kind() {
    if [ "${PREFILL_CRASH_FORCE:-0}" = "1" ]; then
        echo "prefill"
        return 0
    fi
    if [ "${OOM_FORCE:-0}" = "1" ]; then
        echo "oom"
        return 0
    fi
    if [ "${SERVICE_RESULT:-}" = "success" ]; then
        echo "none"
        return 1
    fi
    if [ "${SERVICE_RESULT:-}" = "oom-kill" ]; then
        echo "oom"
        return 0
    fi

    local log_tail
    log_tail="$(read_failure_log)"
    if [ -z "$log_tail" ]; then
        echo "none"
        return 1
    fi

    # Ignore intentional graceful shutdowns
    if printf '%s\n' "$log_tail" | grep -qiE 'SIGTERM received|Draining requests and shutting down'; then
        echo "none"
        return 1
    fi

    # Never misclassify auth, CLI, or missing-package errors as memory/graph failures
    if printf '%s\n' "$log_tail" | grep -qiE 'unrecognized arguments|401 Client Error|GatedRepoError|ModuleNotFoundError|No module named'; then
        echo "none"
        return 1
    fi

    local saw_prefill_begin=false
    local saw_prefill_end=false
    if printf '%s\n' "$log_tail" | grep -q 'Capture target prefill CUDA graph begin'; then
        saw_prefill_begin=true
    fi
    if printf '%s\n' "$log_tail" | grep -q 'Capture target prefill CUDA graph end'; then
        saw_prefill_end=true
    fi

    # Case 1: Died or crashed during prefill CUDA graph capture
    if [ "$saw_prefill_begin" = true ] && [ "$saw_prefill_end" = false ]; then
        echo "prefill"
        return 0
    fi

    # Case 2: OOM or CUDA/allocator memory failure
    if printf '%s\n' "$log_tail" | grep -qiE 'CUDA out of memory|torch\.OutOfMemoryError|out of memory|Not enough memory|double free or corruption|free\(\): invalid|malloc\(\):|CUDA error|cudaError'; then
        # If OOM happened BEFORE prefill graph capture even began (e.g. during
        # Mamba/KV cache allocation), try stepping down Mamba cache first so
        # prefill CUDA graphs can remain enabled if they fit.
        if [ "$saw_prefill_begin" = false ] && printf '%s\n' "$log_tail" | grep -qiE 'Mamba Cache|KV cache|available_gpu_mem|mem_fraction|allocate'; then
            echo "mamba"
        else
            echo "oom"
        fi
        return 0
    fi

    echo "none"
    return 1
}

if [ -n "$FALLBACK_MODE" ]; then
    effective_mode="$FALLBACK_MODE"
    if [ "$effective_mode" = "auto" ]; then
        detected="$(detect_failure_kind || true)"
        if [ -n "$detected" ] && [ "$detected" != "none" ]; then
            effective_mode="$detected"
        fi
    fi
    if ! apply_progressive_fallback "$effective_mode"; then
        echo "sglang_oom_handler: fallback floor reached for ${SERVICE} (prefill=$(current_prefill_graph), mamba=$(current_mamba_size), context=$(current)); manual intervention needed" >&2
        exit 1
    fi
    echo "sglang_oom_handler: ${STEP_DESC} for ${SERVICE}"
    if [ "$NO_RESTART" != true ]; then
        systemctl --user --no-block restart "$SERVICE"
    fi
    exit 0
fi

failure_kind="$(detect_failure_kind || true)"
if [ -z "$failure_kind" ] || [ "$failure_kind" = "none" ]; then
    echo "sglang_oom_handler: no recoverable OOM/CUDA-graph failure detected (result=${SERVICE_RESULT:-n/a}); state unchanged (prefill=$(current_prefill_graph), mamba=$(current_mamba_size), context=$(current))"
    exit 0
fi

if ! apply_progressive_fallback "$failure_kind"; then
    echo "sglang_oom_handler: already at minimum fallback floor for ${SERVICE} (prefill=$(current_prefill_graph), mamba=$(current_mamba_size), context=$(current)); not restarting (manual intervention needed)" >&2
    exit 1
fi

echo "sglang_oom_handler: ${failure_kind} failure detected, ${STEP_DESC}; restarting ${SERVICE}"
if [ "$NO_RESTART" != true ]; then
    systemctl --user --no-block restart "$SERVICE"
fi
