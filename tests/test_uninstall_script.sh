#!/usr/bin/env bash
# ==============================================================================
# tests/test_uninstall_script.sh
# Test suite for the OpenCode Agent Harness uninstallation script (uninstall.sh).
#
# Verifies:
# 1. Flag parsing (--help, --dry-run, --purge, invalid flags).
# 2. --dry-run prints planned actions without mutating state.
# 3. Standard uninstall removes launchers, unit files, opencode.json, GPU profile,
#    and model catalog; preserves the backend venv, HF token env, and CONFIG_DIR.
# 4. --purge removes backend virtual environments and configuration directory.
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
UNINSTALL_SCRIPT="${REPO_DIR}/uninstall.sh"

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
echo "🧪 RUNNING UNINSTALL SCRIPT TEST SUITE: $(date '+%Y-%m-%d %H:%M:%S %Z')"
echo "================================================================================"

# ------------------------------------------------------------------------------
# TEST 1: Flag parsing & help output
# ------------------------------------------------------------------------------
echo "[Test 1] Testing --help and invalid option handling..."
HELP_OUTPUT="$("$UNINSTALL_SCRIPT" --help)"
if [[ "$HELP_OUTPUT" == *"--dry-run"* ]] && [[ "$HELP_OUTPUT" == *"--purge"* ]]; then
    pass "--help prints available options and usage"
else
    fail "--help output missing expected options"
fi

set +e
INVALID_OUTPUT="$("$UNINSTALL_SCRIPT" --invalid-flag 2>&1)"
INVALID_RC=$?
set -e
if [ "$INVALID_RC" -ne 0 ] && [[ "$INVALID_OUTPUT" == *"Unknown option"* ]]; then
    pass "Invalid flag exits non-zero and emits error message"
else
    fail "Invalid flag did not fail properly (code: ${INVALID_RC})"
fi

# ------------------------------------------------------------------------------
# TEST 2: Dry-run simulation markers
# ------------------------------------------------------------------------------
echo "[Test 2] Testing --dry-run output without mutating state..."
DRY_OUTPUT="$("$UNINSTALL_SCRIPT" --dry-run)"
if [[ "$DRY_OUTPUT" == *"[DRY-RUN"* ]] && [[ "$DRY_OUTPUT" == *"SIMULATING"* ]]; then
    pass "--dry-run emits simulated dry-run markers"
else
    fail "--dry-run missing simulation indicators"
fi

DRY_HOME="$(mktemp -d)"
mkdir -p "${DRY_HOME}/.local/share/opencode-sglang-stack" "${DRY_HOME}/.config/opencode-backends"
DRY_PURGE_OUTPUT="$(HOME="${DRY_HOME}" "$UNINSTALL_SCRIPT" --dry-run --purge)"
rm -rf "${DRY_HOME}"
if [[ "$DRY_PURGE_OUTPUT" == *"Purging backend stacks"* ]] && [[ "$DRY_PURGE_OUTPUT" == *"[DRY-RUN] Would remove directory"* ]]; then
    pass "--dry-run --purge simulates purging directories"
else
    fail "--dry-run --purge missing purge indicators"
fi

# ------------------------------------------------------------------------------
# TEST 3: Sandbox Verification: --dry-run preserves all files
# ------------------------------------------------------------------------------
echo "[Test 3] Testing sandbox --dry-run file preservation..."
SANDBOX="$(mktemp -d /tmp/opencode-uninstall-test-XXXXXX)"
trap 'rm -rf "${SANDBOX}"' EXIT

setup_sandbox() {
    local root="$1"
    mkdir -p "${root}/.local/share/opencode-sglang-stack/venv"
    mkdir -p "${root}/.config/opencode-backends"
    mkdir -p "${root}/.config/systemd/user"
    mkdir -p "${root}/.config/opencode"
    mkdir -p "${root}/.local/bin"

    touch "${root}/.config/systemd/user/opencode-sglang-backend.service"
    touch "${root}/.config/systemd/user/opencode-sglang-port-30000.service"
    touch "${root}/.local/bin/opencode"
    touch "${root}/.local/bin/opencode-local"
    touch "${root}/.config/opencode/opencode.json"
    touch "${root}/.config/opencode/AGENTS.md"
    touch "${root}/AGENTS.md"
    touch "${root}/.config/opencode-backends/gpu_profile.json"
    touch "${root}/.config/opencode-backends/models_catalog.json"
    echo 'HF_TOKEN=dummy' > "${root}/.config/opencode-backends/env"
    touch "${root}/.local/share/opencode-sglang-stack/venv/bin-python"
}

setup_sandbox "$SANDBOX"

MOCK_BIN="${SANDBOX}/mock-bin"
mkdir -p "$MOCK_BIN"
cat << 'EOF' > "${MOCK_BIN}/systemctl"
#!/usr/bin/env bash
exit 0
EOF
chmod +x "${MOCK_BIN}/systemctl"

HOME="$SANDBOX" PATH="${MOCK_BIN}:${PATH}" "$UNINSTALL_SCRIPT" --dry-run >/dev/null

if [ -f "${SANDBOX}/.local/bin/opencode-local" ] && \
   [ -f "${SANDBOX}/.config/opencode/opencode.json" ] && \
   [ -f "${SANDBOX}/.config/opencode/AGENTS.md" ] && \
   [ -f "${SANDBOX}/AGENTS.md" ] && \
   [ -f "${SANDBOX}/.config/opencode-backends/gpu_profile.json" ] && \
   [ -f "${SANDBOX}/.config/systemd/user/opencode-sglang-backend.service" ]; then
    pass "Dry-run left all sandbox files untouched"
else
    fail "Dry-run deleted files in sandbox!"
fi

# ------------------------------------------------------------------------------
# TEST 4: Sandbox Standard Uninstall (no --purge)
# ------------------------------------------------------------------------------
echo "[Test 4] Testing standard uninstallation (retaining venv & HF token)..."
HOME="$SANDBOX" PATH="${MOCK_BIN}:${PATH}" "$UNINSTALL_SCRIPT" >/dev/null

if [ ! -f "${SANDBOX}/.local/bin/opencode-local" ] && \
   [ -f "${SANDBOX}/.local/bin/opencode" ] && \
   [ ! -f "${SANDBOX}/.config/opencode/opencode.json" ] && \
   [ ! -f "${SANDBOX}/.config/opencode/AGENTS.md" ] && \
   [ ! -f "${SANDBOX}/AGENTS.md" ] && \
   [ ! -f "${SANDBOX}/.config/opencode-backends/gpu_profile.json" ] && \
   [ ! -f "${SANDBOX}/.config/opencode-backends/models_catalog.json" ] && \
   [ ! -f "${SANDBOX}/.config/systemd/user/opencode-sglang-backend.service" ] && \
   [ ! -f "${SANDBOX}/.config/systemd/user/opencode-sglang-port-30000.service" ]; then
    pass "Standard uninstall removed harness launchers/units/records/charters but preserved the user's own opencode CLI"
else
    fail "Standard uninstall failed to clean harness artifacts (or wrongly removed user CLI)"
fi

# HF token env preserved, CONFIG_DIR retained.
if [ -f "${SANDBOX}/.config/opencode-backends/env" ] && \
   [ "$(cat "${SANDBOX}/.config/opencode-backends/env")" == "HF_TOKEN=dummy" ] && \
   [ -d "${SANDBOX}/.config/opencode-backends" ] && \
   [ -d "${SANDBOX}/.local/share/opencode-sglang-stack" ]; then
    pass "HF token env, CONFIG_DIR, and backend venv preserved without --purge"
else
    fail "HF token / backend stack was unexpectedly removed without --purge"
fi

# ------------------------------------------------------------------------------
# TEST 5: Sandbox Uninstallation with --purge
# ------------------------------------------------------------------------------
echo "[Test 5] Testing uninstallation with --purge..."
HOME="$SANDBOX" PATH="${MOCK_BIN}:${PATH}" "$UNINSTALL_SCRIPT" --purge -y >/dev/null

if [ ! -d "${SANDBOX}/.local/share/opencode-sglang-stack" ] && \
   [ ! -d "${SANDBOX}/.config/opencode-backends" ]; then
    pass "--purge successfully removed backend venv and configuration directory"
else
    fail "--purge failed to remove backend directories"
fi

# ------------------------------------------------------------------------------
# TEST 6: Scoping — uninstall must NOT remove unrelated user service units
# ------------------------------------------------------------------------------
echo "[Test 6] Verifying uninstall stays scoped to harness-managed service units..."
SB6="$(mktemp -d /tmp/opencode-uninstall-scope-XXXXXX)"
mkdir -p "${SB6}/.config/systemd/user" "${SB6}/.config/opencode-backends" "${SB6}/.local/bin" "${SB6}/.config/opencode"
touch "${SB6}/.config/systemd/user/opencode-sglang-bridge.service"
touch "${SB6}/.config/systemd/user/opencode-sglang-port-30000.service"
touch "${SB6}/.config/systemd/user/orphan-user.service"
touch "${SB6}/.config/opencode-backends/gpu_profile.json"
HOME="$SB6" PATH="${MOCK_BIN}:${PATH}" "$UNINSTALL_SCRIPT" >/dev/null 2>&1
if [ ! -f "${SB6}/.config/systemd/user/opencode-sglang-bridge.service" ] && \
   [ ! -f "${SB6}/.config/systemd/user/opencode-sglang-port-30000.service" ] && \
   [ -f "${SB6}/.config/systemd/user/orphan-user.service" ]; then
    pass "uninstall removed harness units only; unrelated .service preserved"
else
    fail "uninstall scoping wrong: unrelated .service removed or harness unit kept"
fi
rm -rf "$SB6"

# ------------------------------------------------------------------------------
# TEST 7: Empty systemd/user dir (no .service units) must not crash uninstall
# ------------------------------------------------------------------------------
echo "[Test 7] Verifying uninstall exits cleanly with zero harness service units..."
SB7="$(mktemp -d /tmp/opencode-uninstall-empty-XXXXXX)"
mkdir -p "${SB7}/.config/systemd/user" "${SB7}/.config/opencode-backends"
echo "HOME=${SB7}" > "${SB7}/.config/opencode-backends/env"
set +e
HOME="$SB7" PATH="${MOCK_BIN}:${PATH}" "$UNINSTALL_SCRIPT" >/dev/null 2>&1
RC7=$?
set -e
if [ "$RC7" -eq 0 ]; then
    pass "uninstall exits cleanly when no harness .service units exist"
else
    fail "uninstall crashed (rc=${RC7}) when no .service units exist"
fi
rm -rf "$SB7"

echo ""
echo "================================================================================"
echo "📊 TEST RESULTS: ${TESTS_PASSED} Passed, ${TESTS_FAILED} Failed"
echo "================================================================================"
if [ "$TESTS_FAILED" -eq 0 ]; then
    echo "🎉 ALL UNINSTALL TESTS PASSED (100% Pass Rate)"
    exit 0
else
    echo "❌ SOME UNINSTALL TESTS FAILED"
    exit 1
fi
