#!/usr/bin/env bash
# ==============================================================================
# scripts/harness_diagnostics.sh - service health, free VRAM, port, active requests.
# Exit 0 = healthy (service active and port reachable), 1 otherwise.
# Env: SGLANG_HOST (127.0.0.1), SGLANG_PORT (30000), SERVICE name override.
# ==============================================================================
set -uo pipefail
HOST="${SGLANG_HOST:-127.0.0.1}"; PORT="${SGLANG_PORT:-30000}"
SERVICE="${SERVICE:-opencode-sglang-ornith-35b.service}"; BAD=0
echo "== OpenCode harness diagnostics ($(date '+%F %T')) =="
if command -v systemctl >/dev/null 2>&1; then
    st="$(systemctl --user is-active "$SERVICE" 2>/dev/null || true)"; st="${st:-unknown}"
    echo "service  $SERVICE: $st"; [ "$st" = active ] || BAD=1
else echo "service  systemctl unavailable"; BAD=1; fi
if command -v nvidia-smi >/dev/null 2>&1 && out="$(nvidia-smi --query-gpu=name,memory.used,memory.total --format=csv,noheader,nounits 2>/dev/null)"; then
    while IFS=, read -r n u t; do
        u="$(echo "$u" | xargs)"; t="$(echo "$t" | xargs)"
        echo "gpu      $(echo "$n" | xargs): ${u} MiB used / ${t} MiB total, $((t - u)) MiB free"
    done <<<"$out"
else echo "gpu      nvidia-smi unavailable"; fi
if (exec 3<>"/dev/tcp/${HOST}/${PORT}") 2>/dev/null; then
    echo "port     ${HOST}:${PORT} reachable"
    if m="$(curl -sf --max-time 3 "http://${HOST}:${PORT}/metrics" 2>/dev/null)"; then
        run="$(grep -E '^sglang:num_running_reqs' <<<"$m" | awk '{print $NF}' | head -1)"
        que="$(grep -E '^sglang:num_queue_reqs' <<<"$m" | awk '{print $NF}' | head -1)"
        echo "requests running=${run:-n/a} queued=${que:-n/a}"
    else echo "requests metrics endpoint unavailable"; fi
else echo "port     ${HOST}:${PORT} NOT reachable"; BAD=1; fi
ctx="${HOME}/.config/opencode-backends/context_length.state"
[ -r "$ctx" ] && echo "context  $(cat "$ctx")" || echo "context  baseline (262144)"
exit $BAD
