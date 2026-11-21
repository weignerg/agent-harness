#!/usr/bin/env bash
# Simulated startup-crash & OOM progressive fallback tests for scripts/sglang_oom_handler.sh
# (mock systemctl, sandboxed HOME).
set -uo pipefail
R="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"; P=0; F=0
pass(){ echo "  ✅ PASS: $1"; P=$((P+1)); }; fail(){ echo "  ❌ FAIL: $1"; F=$((F+1)); }
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT; mkdir "$T/bin" "$T/home"
printf '#!/usr/bin/env bash\necho "$@" >> "%s/calls"\n' "$T" > "$T/bin/systemctl"; chmod +x "$T/bin/systemctl"
unset SGLANG_SERVICE SGLANG_PRIMARY_MODEL SGLANG_UNIT SGLANG_CONTEXT_LENGTH SGLANG_27B_CONTEXT_LENGTH SGLANG_9B_CONTEXT_LENGTH
export PATH="$T/bin:$PATH" HOME="$T/home"; H="$R/scripts/sglang_oom_handler.sh"; S="$HOME/.config/opencode-backends/context_length.state"

# 1. Baseline defaults: prefill graph enabled, Mamba auto, decode bs 8, context 262144
[ "$("$H" --status)" = 262144 ] && pass "baseline context 262144" || fail "baseline context"
"$H" --status-all | grep -q 'prefill_graph=enabled mamba_cache=auto decode_cg_bs=8' \
    && pass "baseline defaults: prefill=enabled, mamba=auto, decode_cg_bs=8" \
    || fail "baseline defaults"

# 2. Clean stop leaves state untouched
SERVICE_RESULT=success "$H" >/dev/null
[ ! -e "$S" ] && [ ! -e "$T/calls" ] && pass "non-OOM leaves state alone" || fail "false positive"

# 3. Prefill CUDA graph capture crash (double free) -> Stage 1 disables ONLY prefill CUDA graph
cat << 'EOF' > "$T/log"
[2026-11-20 22:00:00] Capture target prefill CUDA graph begin. backend=breakable, avail mem=0.85 GB
double free or corruption (!prev)
EOF
OPENCODE_OOM_LOG="$T/log" SERVICE_RESULT=exit-code "$H" >/dev/null
if grep -qx 'SGLANG_35B_PREFILL_GRAPH_ARGS=--disable-prefill-cuda-graph' "$S" && \
   "$H" --status-all | grep -q 'context=262144 prefill_graph=--disable-prefill-cuda-graph mamba_cache=auto decode_cg_bs=8' && \
   grep -q -- '--user --no-block restart sglang-ornith-1.5-35b.service' "$T/calls"; then
    pass "prefill graph double-free -> Stage 1 disables prefill graph only (keeps Mamba=auto & 256k)"
else
    fail "Stage 1 prefill fallback"
fi

# 4. Subsequent OOMs -> Stage 2 steps Mamba cache auto -> 8 -> 5 -> 3 (with decode bs 4) before touching context
OOM_FORCE=1 "$H" >/dev/null
"$H" --status-all | grep -q 'context=262144 .*mamba_cache=8 decode_cg_bs=8' \
    && pass "Stage 2a OOM -> Mamba cache auto -> 8 (context stays 262144)" \
    || fail "Stage 2a Mamba 8"

OOM_FORCE=1 "$H" >/dev/null
"$H" --status-all | grep -q 'context=262144 .*mamba_cache=5 decode_cg_bs=8' \
    && pass "Stage 2b OOM -> Mamba cache 8 -> 5 (context stays 262144)" \
    || fail "Stage 2b Mamba 5"

OOM_FORCE=1 "$H" >/dev/null
"$H" --status-all | grep -q 'context=262144 .*mamba_cache=3 decode_cg_bs=4' \
    && pass "Stage 2c OOM -> Mamba cache 5 -> 3 + decode_cg_bs=4 (context stays 262144)" \
    || fail "Stage 2c Mamba 3"

# State file must remain cleanly bash-sourceable with quoted MAMBA_ARGS
if bash -n "$S" && bash -c "source '$S'" 2>/dev/null; then
    pass "context_length.state with quoted MAMBA_ARGS sources cleanly in bash"
else
    fail "context_length.state bash syntax"
fi

# 5. Once prefill & Mamba bounds are exhausted -> Stage 3 steps context 262144 -> 131072 -> 65536 -> 32768
OOM_FORCE=1 "$H" >/dev/null
grep -qx 'SGLANG_CONTEXT_LENGTH=131072' "$S" && pass "Stage 3a OOM -> context 262144 -> 131072" || fail "Stage 3a 131072"

SERVICE_RESULT=oom-kill "$H" >/dev/null
[ "$("$H" --status)" = 65536 ] && pass "Stage 3b cgroup oom-kill -> 65536" || fail "Stage 3b 65536"

echo "CUDA out of memory. Tried to allocate" > "$T/log"
OPENCODE_OOM_LOG="$T/log" SERVICE_RESULT=exit-code "$H" >/dev/null
[ "$("$H" --status)" = 32768 ] && pass "Stage 3c log scan -> 32768" || fail "Stage 3c 32768"

# 6. Floor at 32k stops restart loop
rm -f "$T/calls"
OOM_FORCE=1 "$H" >/dev/null 2>&1; rc=$?
[ $rc -eq 1 ] && [ "$("$H" --status)" = 32768 ] && [ ! -e "$T/calls" ] \
    && pass "floor at 32k, no restart loop" \
    || fail "floor at 32k"

# 7. Non-OOM / auth / CLI failures ignored
echo "unrelated traceback" > "$T/log"
OPENCODE_OOM_LOG="$T/log" SERVICE_RESULT=exit-code "$H" >/dev/null
[ "$("$H" --status)" = 32768 ] && [ ! -e "$T/calls" ] && pass "unrelated failure ignored" || fail "unrelated log"

echo "401 Client Error: Unauthorized for url (GatedRepoError)" > "$T/log"
OPENCODE_OOM_LOG="$T/log" SERVICE_RESULT=exit-code "$H" >/dev/null
[ ! -e "$T/calls" ] && pass "401/GatedRepoError auth failure ignored" || fail "auth error ignored"

# 8. --reset clears prefill/mamba/decode_bs overrides and restores 256k
"$H" --reset >/dev/null
"$H" --status-all | grep -q 'context=262144 prefill_graph=enabled mamba_cache=auto decode_cg_bs=8' \
    && pass "--reset restores full defaults (256k, prefill=enabled, mamba=auto, bs=8)" \
    || fail "reset defaults"

# 9. OOM BEFORE prefill capture (during Mamba/KV allocation) steps Mamba first, keeping prefill graph ON
cat << 'EOF' > "$T/log"
[2026-11-20 22:01:00] Mamba Cache is allocated. max_mamba_cache_size: 45
torch.OutOfMemoryError: CUDA out of memory while allocating KV cache
EOF
OPENCODE_OOM_LOG="$T/log" SERVICE_RESULT=exit-code SGLANG_SERVICE=sglang-ornith-1.5-9b.service "$H" >/dev/null
if SGLANG_SERVICE=sglang-ornith-1.5-9b.service "$H" --status-all | grep -q 'context=262144 prefill_graph=enabled mamba_cache=8 decode_cg_bs=8'; then
    pass "pre-capture Mamba/KV OOM steps Mamba cache first while keeping prefill CUDA graph enabled"
else
    fail "pre-capture Mamba OOM priority"
fi

# 10. SIGTERM intentional shutdown ignored
rm -f "$T/calls"
printf 'CUDA out of memory\nSIGTERM received. Draining requests and shutting down...\n' > "$T/log"
OPENCODE_OOM_LOG="$T/log" SERVICE_RESULT=exit-code "$H" >/dev/null
[ "$("$H" --status)" = 262144 ] && [ ! -e "$T/calls" ] \
    && pass "SIGTERM intentional stop ignored (no restart, state unchanged)" \
    || fail "SIGTERM intentional stop"

# 11. Per-model state isolation (27B vs 35B vs 9B)
rm -f "$S" "$T/calls"
"$H" --reset >/dev/null
PREFILL_CRASH_FORCE=1 SGLANG_SERVICE=sglang-qwen3.8-27b.service "$H" >/dev/null
OOM_FORCE=1 SGLANG_SERVICE=sglang-qwen3.8-27b.service "$H" >/dev/null
if "$H" --status-all | grep -q 'context=262144 prefill_graph=enabled mamba_cache=auto' && \
   SGLANG_SERVICE=sglang-qwen3.8-27b.service "$H" --status-all | grep -q 'prefill_graph=--disable-prefill-cuda-graph mamba_cache=8'; then
    pass "27B fallback state is isolated from 35B state"
else
    fail "per-model state isolation"
fi

# 12. --fallback-step --no-restart mode (used by install.sh)
rm -f "$T/calls"
SGLANG_SERVICE=sglang-ornith-1.5-9b.service "$H" --fallback-step prefill --no-restart >/dev/null
if SGLANG_SERVICE=sglang-ornith-1.5-9b.service "$H" --status-all | grep -q 'prefill_graph=--disable-prefill-cuda-graph' && \
   [ ! -e "$T/calls" ]; then
    pass "--fallback-step prefill --no-restart persists state without calling systemctl"
else
    fail "--fallback-step --no-restart"
fi

# 13. All 3 systemd units wired to context_length.state, handler, and unbraced fallback vars
for U in \
    "$R/config/systemd/sglang-ornith-1.5-35b.service" \
    "$R/config/systemd/sglang-ornith-1.5-9b.service" \
    "$R/config/systemd/sglang-qwen3.8-27b.service"; do
    b="$(basename "$U")"
    if grep -q 'ExecStopPost=.*sglang_oom_handler.sh' "$U" && \
       grep -q 'context_length.state' "$U" && \
       grep -qE '\$SGLANG_(35B|27B|9B)_PREFILL_GRAPH_ARGS' "$U" && \
       grep -qE '\$SGLANG_(35B|27B|9B)_MAMBA_ARGS' "$U"; then
        pass "${b} wired to handler, state file, and unbraced fallback vars"
    else
        fail "${b} wiring"
    fi
done

echo "RESULTS: $P passed, $F failed"; [ $F -eq 0 ]
