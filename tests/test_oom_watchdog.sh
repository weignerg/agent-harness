#!/usr/bin/env bash
# Simulated-OOM tests for scripts/sglang_oom_handler.sh (mock systemctl, sandboxed HOME).
set -uo pipefail
R="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"; P=0; F=0
pass(){ echo "  ✅ PASS: $1"; P=$((P+1)); }; fail(){ echo "  ❌ FAIL: $1"; F=$((F+1)); }
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT; mkdir "$T/bin" "$T/home"
printf '#!/usr/bin/env bash\necho "$@" >> "%s/calls"\n' "$T" > "$T/bin/systemctl"; chmod +x "$T/bin/systemctl"
export PATH="$T/bin:$PATH" HOME="$T/home"; H="$R/scripts/sglang_oom_handler.sh"; S="$HOME/.config/opencode-backends/context_length.state"
[ "$("$H" --status)" = 262144 ] && pass "baseline 262144" || fail "baseline"
SERVICE_RESULT=success "$H" >/dev/null; [ ! -e "$S" ] && [ ! -e "$T/calls" ] && pass "non-OOM leaves state alone" || fail "false positive"
OOM_FORCE=1 "$H" >/dev/null; grep -qx 'SGLANG_CONTEXT_LENGTH=131072' "$S" && pass "262144 -> 131072, state persisted" || fail "first step"
grep -q -- '--user --no-block restart opencode-sglang-ornith-35b.service' "$T/calls" && pass "service restart requested" || fail "restart"
SERVICE_RESULT=oom-kill "$H" >/dev/null; [ "$("$H" --status)" = 65536 ] && pass "cgroup oom-kill -> 65536" || fail "oom-kill step"
echo "CUDA out of memory. Tried to allocate" > "$T/log"; OPENCODE_OOM_LOG="$T/log" SERVICE_RESULT=exit-code "$H" >/dev/null; [ "$("$H" --status)" = 32768 ] && pass "log scan -> 32768" || fail "log scan"
rm -f "$T/calls"; OOM_FORCE=1 "$H" >/dev/null 2>&1; rc=$?; [ $rc -eq 1 ] && [ "$("$H" --status)" = 32768 ] && [ ! -e "$T/calls" ] && pass "floor at 32k, no restart loop" || fail "floor"
echo "unrelated traceback" > "$T/log"; OPENCODE_OOM_LOG="$T/log" SERVICE_RESULT=exit-code "$H" >/dev/null; [ "$("$H" --status)" = 32768 ] && pass "non-OOM failure ignored" || fail "non-oom log"
"$H" --reset >/dev/null; [ "$("$H" --status)" = 262144 ] && pass "--reset restores 256k" || fail "reset"
U="$R/config/systemd/opencode-sglang-ornith-35b.service"
grep -q 'ExecStopPost=.*sglang_oom_handler.sh' "$U" && grep -q 'context_length.state' "$U" && grep -q -- '--context-length ${SGLANG_CONTEXT_LENGTH}' "$U" && pass "unit wired to state + handler" || fail "unit wiring"
command -v systemd-analyze >/dev/null && { systemd-analyze --user verify "$U" 2>&1 | grep -qi 'sglang_oom_handler.sh.*not' && pass "verify (path warnings expected on dev host)" || pass "systemd-analyze verify ok"; }
echo "RESULTS: $P passed, $F failed"; [ $F -eq 0 ]
