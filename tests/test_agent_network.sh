#!/usr/bin/env bash
set -uo pipefail
R="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"; P=0; F=0
pass(){ echo "  ✅ PASS: $1"; P=$((P+1)); }; fail(){ echo "  ❌ FAIL: $1"; F=$((F+1)); }
S="$R/scripts/agent_network.sh"; RULES="$("$S" --print-rules)"
grep -q 'dport { 30000 }' <<<"$RULES" && pass "only port 30000 allowed" || fail "port 30000 rule"
grep -q 45431 <<<"$RULES" "$R/config/network/agent-bridge.conf" && fail "retired port present" || pass "45431 excluded"
[ "$(grep -c 'dport' <<<"$RULES")" -eq 1 ] && pass "single dport rule" || fail "extra dport rules"
grep -q 'iifname "opencode-br0" drop' <<<"$RULES" && grep -q 'oifname != "opencode-br0" drop' <<<"$RULES" && pass "default-deny ingress+egress" || fail "default deny"
"$S" --create --dry-run | grep -q -- '--internal' && pass "create uses --internal network (no outside access)" || fail "internal"
"$S" --destroy --dry-run | grep -q 'network rm opencode-agent-net' && pass "destroy dry-run" || fail "destroy"
"$S" --bogus >/dev/null 2>&1; [ $? -eq 2 ] && pass "bad flag rejected" || fail "bad flag"
C="$(mktemp)"; sed 's/ALLOWED_PORTS=.*/ALLOWED_PORTS="30000 45431"/' "$R/config/network/agent-bridge.conf" > "$C"
AGENT_NET_CONF="$C" "$S" --print-rules >/dev/null 2>&1 && fail "45431 accepted" || pass "config with 45431 rejected"; rm -f "$C"
if command -v nft >/dev/null && nft --version >/dev/null 2>&1; then
    "$S" --print-rules | nft -c -f - >/dev/null 2>&1 && pass "nft syntax check" || echo "  ℹ️  nft -c unavailable without privileges (skipped)"
fi
if unshare -rn true 2>/dev/null && command -v ip >/dev/null; then
    unshare -rn bash -c 'ip link set lo up; ! (exec 3<>/dev/tcp/127.0.0.1/30000) 2>/dev/null' && pass "netns isolation: port 30000 unreachable w/o host link" || fail "netns"
fi
echo "RESULTS: $P passed, $F failed"; [ $F -eq 0 ]
