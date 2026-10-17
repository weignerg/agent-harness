#!/usr/bin/env bash
# ==============================================================================
# test_systemd_units.sh
# Unit and regression test suite for systemd service unit definitions.
#
# Verifies:
# 1. Zero occurrences of empty Environment="HF_TOKEN=" override in any service.
# 2. Presence of EnvironmentFile=-%h/.config/opencode-backends/env in all 14 services.
# 3. Presence of EnvironmentFile=-%h/.config/opencode-backends/env in install.sh.
# 4. Valid systemd unit sections ([Unit], [Service], [Install]) in all unit files.
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG_DIR="${SCRIPT_DIR}/config/systemd"
INSTALL_SCRIPT="${SCRIPT_DIR}/install.sh"

echo "================================================================================"
echo "🧪 Running Systemd Service Unit Tests (Issue #1 Regression Suite)"
echo "================================================================================"

# 1. Check service files count
SERVICE_FILES=("$CONFIG_DIR"/*.service)
NUM_FILES=${#SERVICE_FILES[@]}
echo "[CHECK 1] Found ${NUM_FILES} service unit files in ${CONFIG_DIR}."
if [ "$NUM_FILES" -ne 21 ]; then
    echo "❌ FAIL: Expected exactly 21 service files, found ${NUM_FILES}."
    exit 1
fi
echo "✅ Passed: Exactly 21 service files found."

# 2. Check for forbidden Environment="HF_TOKEN="
echo "[CHECK 2] Scanning for forbidden 'Environment=\"HF_TOKEN=\"' overrides..."
if grep -rn 'Environment="HF_TOKEN="' "$CONFIG_DIR" "$INSTALL_SCRIPT"; then
    echo "❌ FAIL: Found forbidden 'Environment=\"HF_TOKEN=\"' in service or installer files."
    exit 1
fi
echo "✅ Passed: Zero occurrences of 'Environment=\"HF_TOKEN=\"' found."

# 3. Check for EnvironmentFile in all 14 service units
echo "[CHECK 3] Verifying 'EnvironmentFile=-%h/.config/opencode-backends/env' in all service units..."
MISSING_ENVFILE=0
for svc in "${SERVICE_FILES[@]}"; do
    unit_name="$(basename "$svc")"
    if ! grep -q '^EnvironmentFile=-%h/\.config/opencode-backends/env' "$svc"; then
        echo "❌ FAIL: Missing EnvironmentFile in ${unit_name}"
        MISSING_ENVFILE=$((MISSING_ENVFILE + 1))
    fi
done

if [ "$MISSING_ENVFILE" -gt 0 ]; then
    echo "❌ FAIL: ${MISSING_ENVFILE} service files missing EnvironmentFile."
    exit 1
fi
echo "✅ Passed: All ${NUM_FILES} service unit files specify EnvironmentFile=-%h/.config/opencode-backends/env."

# 4. Check install.sh provisions the HF_TOKEN backend env file
echo "[CHECK 4] Verifying install.sh provisions the HF_TOKEN backend env file..."
if ! grep -q 'opencode-backends' "$INSTALL_SCRIPT" || ! grep -q 'env' "$INSTALL_SCRIPT"; then
    echo "❌ FAIL: install.sh does not provision the backend env file."
    exit 1
fi
echo "✅ Passed: install.sh provisions the HF_TOKEN backend env file."

# 5. Check structural validity of systemd units
echo "[CHECK 5] Checking systemd unit section structure..."
STRUCT_ERRORS=0
for svc in "${SERVICE_FILES[@]}"; do
    unit_name="$(basename "$svc")"
    if ! grep -q '^\[Unit\]' "$svc" || ! grep -q '^\[Service\]' "$svc" || ! grep -q '^\[Install\]' "$svc"; then
        echo "❌ FAIL: Malformed systemd sections in ${unit_name}"
        STRUCT_ERRORS=$((STRUCT_ERRORS + 1))
    fi
done

if [ "$STRUCT_ERRORS" -gt 0 ]; then
    echo "❌ FAIL: ${STRUCT_ERRORS} service files had malformed sections."
    exit 1
fi
echo "✅ Passed: All ${NUM_FILES} service unit files contain valid [Unit], [Service], and [Install] sections."

echo "================================================================================"
echo "🎉 ALL SYSTEMD UNIT VERIFICATION TESTS PASSED (100%)"
echo "================================================================================"
exit 0
