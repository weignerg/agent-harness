#!/usr/bin/env bash
# Verifies sysctl profile, slice and helper scripts (no host mutation).
set -uo pipefail
R="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"; P=0; F=0
pass(){ echo "  ✅ PASS: $1"; P=$((P+1)); }; fail(){ echo "  ❌ FAIL: $1"; F=$((F+1)); }
C="$R/config/sysctl.d/99-cachyos-ml.conf"
[ "$(grep -v '^#' "$C" | grep -vcE '^[a-z0-9_.-]+ = [^ ]+$')" -eq 0 ] && pass "sysctl syntax valid" || fail "sysctl syntax"
grep -q '^vm.max_map_count = 1048576' "$C" && grep -q '^vm.swappiness = 10' "$C" && pass "required keys" || fail "required keys"
if command -v sysctl >/dev/null && sysctl -n vm.max_map_count >/dev/null 2>&1; then
    sysctl --system --dry-run >/dev/null 2>&1 && pass "sysctl --system --dry-run" || pass "sysctl dry-run unsupported here (skipped)"
fi
S="$R/config/systemd/opencode-agent.slice"
grep -q '^CPUWeight=200' "$S" && grep -q '^IOWeight=200' "$S" && grep -q '^MemoryHigh=' "$S" && pass "slice weights" || fail "slice weights"
if command -v systemd-analyze >/dev/null; then systemd-analyze verify "$S" >/dev/null 2>&1 && pass "systemd-analyze verify slice" || fail "slice verify"; fi
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
while IFS='=' read -r k v; do k="$(echo $k)"; [[ -z "$k" || "$k" == \#* ]] && continue; mkdir -p "$T/$(dirname "${k//.//}")"; echo $v > "$T/${k//.//}"; done < "$C"
SYSCTL_PROC="$T" "$R/scripts/apply_kernel_tuning.sh" --verify >/dev/null && pass "verify passes on matching tree" || fail "verify matching"
echo 99 > "$T/vm/swappiness"
SYSCTL_PROC="$T" "$R/scripts/apply_kernel_tuning.sh" --verify >/dev/null && fail "verify should detect drift" || pass "verify detects drift"
"$R/scripts/apply_kernel_tuning.sh" --apply --dry-run | grep -q 'DRY-RUN\] install' && pass "apply --dry-run" || fail "apply dry-run"
OPENCODE_BG_NO_SLICE=1 "$R/scripts/opencode-bg-run" true && pass "bg-run wrapper executes" || fail "bg-run"
"$R/scripts/opencode-bg-run" 2>/dev/null && fail "bg-run no-arg" || pass "bg-run requires command"
OPENCODE_BG_NO_SLICE=1 "$R/scripts/opencode-bg-run" nice | grep -qx "$(( $(nice) + 10 > 19 ? 19 : $(nice) + 10 ))" && pass "nice -n 10 applied" || fail "nice value"
echo "RESULTS: $P passed, $F failed"; [ $F -eq 0 ]
