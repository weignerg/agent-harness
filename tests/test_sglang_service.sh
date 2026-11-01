#!/usr/bin/env bash
# Locks the production SGLang unit to the verified flags (Task 3.1 / 3.2).
set -uo pipefail
R="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"; P=0; F=0
pass(){ echo "  ✅ PASS: $1"; P=$((P+1)); }; fail(){ echo "  ❌ FAIL: $1"; F=$((F+1)); }
U="$R/config/systemd/opencode-sglang-ornith-35b.service"
need(){ grep -qE -- "$1" "$U" && pass "$2" || fail "$2"; }
need '--model-path ornith-ai/Ornith-1.5-35B-A3B-NVFP4' "NVFP4 model path"
need '--served-model-name ornith-1.5-35b' "served model name"
need '--mem-fraction-static 0.88' "mem fraction 0.88"
need '--chunked-prefill-size 2048' "chunked prefill 2048"
need '--max-running-requests 1' "max running requests 1"
need '--tool-call-parser qwen3_coder' "tool-call parser"
need '--reasoning-parser qwen3' "reasoning parser"
need '--port 30000' "port 30000"
need '--host 127.0.0.1' "loopback only"
need '--context-length (262144|\$\{?SGLANG_CONTEXT_LENGTH)' "256k context (default 262144)"
need 'Environment="SGLANG_CONTEXT_LENGTH=262144"' "explicit SGLANG_CONTEXT_LENGTH default"
need 'PYTORCH_CUDA_ALLOC_CONF=expandable_segments:True' "expandable_segments allocator"
need 'CUDA_HOME=/opt/cuda' "CUDA_HOME"
if grep -qE -- '--context-length [0-9]+\$' "$U"; then fail "corrupted context-length string in template"; else pass "unbroken context-length parameter"; fi
DEPLOYED="$HOME/.config/systemd/user/opencode-sglang-ornith-35b.service"
if [ -f "$DEPLOYED" ]; then
    if grep -qE -- '--context-length [0-9]+\$' "$DEPLOYED"; then fail "corrupted context-length string in deployed unit"; else pass "deployed unit context-length valid"; fi
fi
if grep -qiE 'speculative|eagle|dflash|d-flash|draft|cpu-offload' "$U"; then fail "no speculative/offload flags"; else pass "no speculative/offload flags"; fi
grep -q 'ornith-local' "$R/config/opencode/opencode.json" && grep -q '"baseURL": "http://127.0.0.1:30000/v1"' "$R/config/opencode/opencode.json" && grep -q '"apiKey": "EMPTY"' "$R/config/opencode/opencode.json" && pass "opencode.json provider direct to :30000" || fail "opencode provider"
[ -s "$R/docs/inference_architecture.md" ] && grep -q 'eagle-3' "$R/docs/inference_architecture.md" && grep -q 'continuous batching' "$R/docs/inference_architecture.md" && pass "docs/inference_architecture.md present" || fail "architecture doc"
if curl -sf --max-time 2 http://127.0.0.1:30000/v1/models -o /tmp/_models.json 2>/dev/null; then
    grep -q '"max_model_len": *262144\|262144' /tmp/_models.json && pass "live /v1/models reports 262144" || fail "live max_model_len"
else echo "  ℹ️  SGLang not running; live /v1/models check skipped"; fi
echo "RESULTS: $P passed, $F failed"; [ $F -eq 0 ]
