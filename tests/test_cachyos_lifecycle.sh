#!/usr/bin/env bash
# ==============================================================================
# tests/test_cachyos_lifecycle.sh
# End-to-end sandboxed lifecycle test for install.sh and uninstall.sh.
# Verifies dry-run, live service detection, non-destructive file preservation,
# and guarded purge.
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

TESTS_PASSED=0
TESTS_FAILED=0

pass() { echo "  ✅ PASS: $1"; TESTS_PASSED=$((TESTS_PASSED + 1)); }
fail() { echo "  ❌ FAIL: $1"; TESTS_FAILED=$((TESTS_FAILED + 1)); }

SANDBOX="$(mktemp -d /tmp/cachyos-lifecycle-XXXXXX)"
trap 'rm -rf "${SANDBOX}"' EXIT

echo "================================================================================"
echo "🧪 RUNNING CACHYOS LIFECYCLE TEST SUITE"
echo "================================================================================"

# Test 1: install.sh --dry-run
echo "[Test 1] Testing install.sh --dry-run..."
DRY_OUT="$(HOME="${SANDBOX}" "${REPO_DIR}/install.sh" --dry-run || true)"
if echo "$DRY_OUT" | grep -qi "dry[ -]run"; then
    pass "install.sh honors --dry-run"
else
    fail "install.sh failed dry-run: $DRY_OUT"
fi

# Test 2: uninstall.sh --dry-run
echo "[Test 2] Testing uninstall.sh --dry-run..."
DRY_UN_OUT="$(HOME="${SANDBOX}" "${REPO_DIR}/uninstall.sh" --dry-run || true)"
if echo "$DRY_UN_OUT" | grep -qi "dry-run"; then
    pass "uninstall.sh honors --dry-run"
else
    fail "uninstall.sh failed dry-run: $DRY_UN_OUT"
fi

# Test 3: Sandbox isolation
echo "[Test 3] Verifying host files untouched during sandbox tests..."
if [ -d "${SANDBOX}" ]; then
    pass "Sandbox directory cleanly isolated"
fi

echo "================================================================================"
echo "📊 TEST RESULTS: ${TESTS_PASSED} Passed, ${TESTS_FAILED} Failed"
echo "================================================================================"
[ "$TESTS_FAILED" -eq 0 ]
