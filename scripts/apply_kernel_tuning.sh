#!/usr/bin/env bash
# ==============================================================================
# scripts/apply_kernel_tuning.sh
# Install (--apply, needs root) or verify (--verify, default) the ML sysctl
# profile and the opencode-agent.slice user slice.  --dry-run prints actions only.
# Env: SYSCTL_PROC (default /proc/sys) lets tests point at a fake tree.
# ==============================================================================
set -euo pipefail
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONF="${REPO_DIR}/config/sysctl.d/99-cachyos-ml.conf"
SLICE="${REPO_DIR}/config/systemd/opencode-agent.slice"
PROC="${SYSCTL_PROC:-/proc/sys}"
MODE="verify"; DRY=0
for a in "$@"; do case "$a" in
    --apply) MODE=apply ;; --verify) MODE=verify ;; --dry-run) DRY=1 ;;
    -h|--help) echo "Usage: $0 [--verify|--apply] [--dry-run]"; exit 0 ;;
    *) echo "Unknown option: $a" >&2; exit 2 ;; esac; done

verify() {
    local bad=0 key val want cur path
    while IFS='=' read -r key val; do
        key="$(echo "$key" | xargs)"; want="$(echo "${val:-}" | xargs)"
        [[ -z "$key" || "$key" == \#* ]] && continue
        path="${PROC}/${key//.//}"
        if [ ! -r "$path" ]; then echo "  ⚠️  $key: not available"; continue; fi
        cur="$(xargs < "$path")"
        if [ "$cur" == "$want" ]; then echo "  ✅ $key = $cur"; else echo "  ❌ $key = $cur (recommended $want)"; bad=$((bad+1)); fi
    done < "$CONF"
    return $bad
}

if [ "$MODE" = verify ]; then
    echo "Verifying kernel parameters against ${CONF}..."
    verify && echo "All parameters match." || { echo "Some parameters differ."; exit 1; }
    exit 0
fi

run() { if [ "$DRY" = 1 ]; then echo "[DRY-RUN] $*"; else "$@"; fi; }
if [ "$DRY" = 0 ] && [ "$(id -u)" -ne 0 ]; then echo "--apply requires root (use sudo) or --dry-run" >&2; exit 1; fi
run install -D -m 0644 "$CONF" /etc/sysctl.d/99-cachyos-ml.conf
run sysctl --system
run install -D -m 0644 "$SLICE" /etc/systemd/user/opencode-agent.slice
echo "Applied. Re-run with --verify to confirm."
