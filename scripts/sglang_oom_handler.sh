#!/usr/bin/env bash
# ==============================================================================
# scripts/sglang_oom_handler.sh - OOM context-degradation watchdog.
# Run via systemd ExecStopPost=. On a CUDA/cgroup OOM it steps the context
# window down 262144 -> 131072 -> 65536 -> 32768, persists it in
# ~/.config/opencode-backends/context_length.state (as SGLANG_CONTEXT_LENGTH=N,
# read by the unit's EnvironmentFile) and restarts the service.
#   --reset   restore the 256k baseline      --status  print the active value
# Env: SERVICE_RESULT / EXIT_STATUS (set by systemd), OOM_FORCE=1 (simulate),
#      OPENCODE_OOM_LOG (file to scan for "out of memory", optional).
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

state_key() {
    if [[ "$SERVICE" == *"27b"* || "$SERVICE" == *"qwen"* ]]; then
        echo "SGLANG_27B_CONTEXT_LENGTH"
    elif [[ "$SERVICE" == *"9b"* ]]; then
        echo "SGLANG_9B_CONTEXT_LENGTH"
    else
        echo "SGLANG_CONTEXT_LENGTH"
    fi
}

current() {
    local v=""
    local key
    key="$(state_key)"
    if [ -r "$STATE" ]; then
        v="$(sed -n "s/^${key}=\\([0-9]\\+\\)$/\\1/p" "$STATE" | tail -1)"
    fi
    echo "${v:-${LADDER[0]}}"
}

write_state() {
    mkdir -p "$STATE_DIR"
    local key t
    key="$(state_key)"
    t="$(mktemp "${STATE}.XXXXXX")"
    if [ -r "$STATE" ]; then
        grep -v "^${key}=" "$STATE" > "$t" || true
    fi
    echo "${key}=$1" >> "$t"
    mv "$t" "$STATE"
}
case "${1:-}" in
    --status) current; exit 0 ;;
    --reset) write_state "${LADDER[0]}"; echo "Context reset to ${LADDER[0]}"; exit 0 ;;
    "") ;;
    *) echo "Usage: $0 [--status|--reset]" >&2; exit 2 ;;
esac

is_oom() {
    [ "${OOM_FORCE:-0}" = 1 ] && return 0
    [ "${SERVICE_RESULT:-}" = "oom-kill" ] && return 0
    if [ -n "${OPENCODE_OOM_LOG:-}" ] && [ -r "${OPENCODE_OOM_LOG}" ]; then
        local log_tail
        log_tail="$(tail -n 200 "$OPENCODE_OOM_LOG")"
        if printf '%s\n' "$log_tail" | grep -qiE 'SIGTERM received|Draining requests and shutting down'; then
            return 1
        fi
        printf '%s\n' "$log_tail" | grep -qiE 'CUDA out of memory|torch\.OutOfMemoryError|out of memory' && return 0
        return 1
    fi
    if [ "${SERVICE_RESULT:-}" != "success" ] && command -v journalctl >/dev/null 2>&1; then
        local jlog=""
        if [ -n "${INVOCATION_ID:-}" ]; then
            jlog="$(journalctl --user _SYSTEMD_INVOCATION_ID="$INVOCATION_ID" -n 200 --no-pager 2>/dev/null || true)"
        else
            jlog="$(journalctl --user -u "$SERVICE" -n 200 --no-pager 2>/dev/null || true)"
        fi
        if printf '%s\n' "$jlog" | grep -qiE 'SIGTERM received|Draining requests and shutting down'; then
            return 1
        fi
        printf '%s\n' "$jlog" | grep -qiE 'CUDA out of memory|torch\.OutOfMemoryError' && return 0
    fi
    return 1
}

if ! is_oom; then
    echo "sglang_oom_handler: no OOM detected (result=${SERVICE_RESULT:-n/a}); context unchanged at $(current)"
    exit 0
fi
cur="$(current)"; next="$cur"
for i in "${!LADDER[@]}"; do
    if [ "${LADDER[$i]}" -lt "$cur" ]; then next="${LADDER[$i]}"; break; fi
done
if [ "$next" -eq "$cur" ]; then
    echo "sglang_oom_handler: already at minimum context ${cur}; not restarting (manual intervention needed)" >&2
    exit 1
fi
write_state "$next"
echo "sglang_oom_handler: OOM detected, context ${cur} -> ${next}; restarting ${SERVICE}"
systemctl --user --no-block restart "$SERVICE"
