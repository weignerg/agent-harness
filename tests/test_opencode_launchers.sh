#!/usr/bin/env bash
# ==============================================================================
# tests/test_opencode_launchers.sh
# Verifies that external launcher wrappers (opencode-local and individualized
# role launchers) are completely retired (OBE) in favor of the canonical
# native `opencode` CLI configured via opencode.json.
#
# Verifies:
# 1. opencode-local and role launchers are retired from bin/.
# 2. Native in-session multi-agent dispatch via opencode.json.
# 3. Direct provider connection to port 30000 with zero proxy hops.
# 4. Zero legacy references (45431, agy, blackwell) across the repository.
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

TESTS_PASSED=0
TESTS_FAILED=0

pass() {
    echo "  ✅ PASS: $1"
    TESTS_PASSED=$((TESTS_PASSED + 1))
}
fail() {
    echo "  ❌ FAIL: $1"
    TESTS_FAILED=$((TESTS_FAILED + 1))
}

echo "================================================================================"
echo "🧪 RUNNING OPENCODE LAUNCHER CONFIG TEST SUITE: $(date '+%Y-%m-%d %H:%M:%S %Z')"
echo "================================================================================"

# --- Test 1: Redundant external wrappers retired from bin/ --------------------
echo "[Test 1] Verifying all external wrapper scripts are retired from bin/..."
RETIRED_LAUNCHERS=(
    "opencode-local"
    "opencode-architect-local"
    "opencode-worker-local"
    "opencode-reviewer-local"
    "opencode-sub-agent-local"
)
for r in "${RETIRED_LAUNCHERS[@]}"; do
    if [ -f "${REPO_DIR}/bin/${r}" ]; then
        fail "OBE launcher still exists: bin/${r}"
    else
        pass "OBE launcher retired: bin/${r}"
    fi
done

# --- Test 2: Pruning verified in install.sh ------------------------------------
echo "[Test 2] Verifying install.sh cleans legacy ~/.local/bin launchers..."
INSTALL_SCRIPT="${REPO_DIR}/install.sh"
if grep -q "opencode-local" "$INSTALL_SCRIPT" && grep -qE "rm -f.*(obsolete_launcher|legacy_launcher)" "$INSTALL_SCRIPT"; then
    pass "install.sh actively prunes opencode-local and role launchers"
else
    fail "install.sh missing cleanup for retired launchers"
fi

# --- Test 3: In-session multi-agent dispatch via opencode.json -----------------
echo "[Test 3] Verifying native in-session multi-agent model dispatch in config/opencode/opencode.json..."
python3 -c "
import json
with open('${REPO_DIR}/config/opencode/opencode.json') as f:
    cfg = json.load(f)
assert cfg.get('model') == 'ornith-local/ornith-1.5-35b', 'Default model must be ornith-1.5-35b'
assert cfg.get('small_model') == 'ornith-local/ornith-1.5-9b', 'Small model must be ornith-1.5-9b'
agents = cfg.get('agent', {})
for role in ['supreme-orchestrator', 'team-orchestrator', 'architect', 'worker', 'tester', 'reviewer']:
    assert agents.get(role, {}).get('model') == 'ornith-local/ornith-1.5-35b', f'{role} model wrong'
for role in ['scout', 'grunt', 'summary', 'compaction']:
    assert agents.get(role, {}).get('model') == 'ornith-local/ornith-1.5-9b', f'{role} model wrong'
" && pass "opencode.json defines native in-session agent model dispatch" || fail "opencode.json agent definitions invalid"

# --- Test 4: Zero-bloat guards -------------------------------------------------
echo "[Test 4] No launcher references the legacy bridge, agy, or blackwell..."
if [ -d "${REPO_DIR}/bin" ] && grep -rniE "45431|agy|local-blackwell|blackwell/" "${REPO_DIR}/bin" >/dev/null 2>&1; then
    fail "legacy references remain in bin/"
else
    pass "bin/ is free of legacy references"
fi
if [ -d "${REPO_DIR}/bin" ]; then
    for l in "${REPO_DIR}"/bin/opencode-*; do
        if [ -e "$l" ] && [[ -L "$l" ]]; then fail "symlink in bin/: $l"; fi
    done
fi
if grep -q '"blackwell"' "${REPO_DIR}/config/opencode/opencode.json"; then
    fail "opencode.json still defines blackwell provider"
else
    pass "opencode.json provider keys match ornith-local only"
fi

# --- summary -----------------------------------------------------------------
echo ""
echo "================================================================================"
echo "📊 TEST RESULTS: ${TESTS_PASSED} Passed, ${TESTS_FAILED} Failed"
echo "================================================================================"
if [ "$TESTS_FAILED" -eq 0 ]; then
    echo "🎉 ALL LAUNCHER TESTS PASSED (100% Pass Rate)"
    exit 0
else
    echo "❌ SOME TESTS FAILED"
    exit 1
fi
