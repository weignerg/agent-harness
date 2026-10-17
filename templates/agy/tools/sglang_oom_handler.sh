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
SERVICE="opencode-sglang-ornith-35b.service"
STATE_DIR="${HOME}/.config/opencode-backends"
STATE="${STATE_DIR}/context_length.state"
LADDER=(262144 131072 65536 32768)

current() {
    local v=""
    [ -r "$STATE" ] && v="$(sed -n 's/^SGLANG_CONTEXT_LENGTH=\([0-9]\+\)$/\1/p' "$STATE" | tail -1)"
    echo "${v:-${LADDER[0]}}"
}
write_state() {
    mkdir -p "$STATE_DIR"
    local t; t="$(mktemp "${STATE}.XXXXXX")"
    echo "SGLANG_CONTEXT_LENGTH=$1" > "$t" && mv "$t" "$STATE"
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
        tail -n 200 "$OPENCODE_OOM_LOG" | grep -qiE 'CUDA out of memory|torch\.OutOfMemoryError|out of memory' && return 0
        return 1
    fi
    if [ "${SERVICE_RESULT:-}" != "success" ] && command -v journalctl >/dev/null 2>&1; then
        journalctl --user -u "$SERVICE" -n 200 --no-pager 2>/dev/null \
            | grep -qiE 'CUDA out of memory|torch\.OutOfMemoryError' && return 0
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
