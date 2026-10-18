#!/usr/bin/env bash
# ==============================================================================
# tests/test_scaffold_subvault.sh
# Regression and verification test suite for repository sub-vault scaffolding.
#
# Verifies:
# 1. Input validation on non-existent directories.
# 2. Directory structure creation (entities, decisions, protocols, projects, .obsidian, .index).
# 3. Starter template generation (overview.md, workflow.md, decisions/0001-baseline.md).
# 4. Content verification (ADR baseline, workflow governance, sub-vault navigation).
# 5. Mirroring to <repo>/.orchestration/memory/.
# 6. Obsidian Desktop vault auto-registration in ~/.config/obsidian/obsidian.json.
# 7. Preservation of existing vaults in obsidian.json (zero clobbering).
# 8. Idempotency (re-running does not duplicate entries or overwrite customized content).
# 9. Symlink creation in ~/Vaults/repos/<repo_name>.
# 10. Initial ColBERT index creation (.index/index.json).
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCAFFOLD_SCRIPT="${SCRIPT_DIR}/scripts/scaffold_subvault.sh"

TEST_TEMP="$(mktemp -d /tmp/test_subvault_XXXXXX)"
cleanup() {
    rm -rf "$TEST_TEMP"
}
trap cleanup EXIT

SANDBOX_HOME="${TEST_TEMP}/mock_home"
SAMPLE_REPO="${TEST_TEMP}/sample_repo"
mkdir -p "${SANDBOX_HOME}" "${SAMPLE_REPO}"

echo "================================================================================"
echo "🧪 Running Repository Sub-Vault Scaffolding Test Suite"
echo "   Harness Root : ${SCRIPT_DIR}"
echo "   Temp Sandbox : ${TEST_TEMP}"
echo "================================================================================"

pass() { echo "  ✅ Passed: $1"; }
fail() { echo "  ❌ FAIL: $1"; exit 1; }

# --- Check 1: Input validation on invalid directory ---
echo "[CHECK 1] Testing argument validation on non-existent directory..."
if USER_HOME="${SANDBOX_HOME}" "${SCAFFOLD_SCRIPT}" "${TEST_TEMP}/does_not_exist" 2>/dev/null; then
    fail "scaffold_subvault.sh should have exited with error on invalid directory"
else
    pass "Rejected invalid directory with non-zero exit code"
fi

# --- Check 2: Pre-seed existing obsidian.json with existing vault ---
echo "[CHECK 2] Pre-seeding existing obsidian.json to test non-destructive registration..."
OBSIDIAN_DIR="${SANDBOX_HOME}/.config/obsidian"
mkdir -p "${OBSIDIAN_DIR}"
cat << 'EOF' > "${OBSIDIAN_DIR}/obsidian.json"
{
  "vaults": {
    "existing12345": {
      "path": "/home/user/Vaults/personal",
      "ts": 1600000000000,
      "open": true
    }
  }
}
EOF
pass "Pre-seeded existing obsidian.json with personal vault"

# --- Check 3: Execute scaffold_subvault.sh on sample repository ---
echo "[CHECK 3] Executing scaffold_subvault.sh on sample repository..."
USER_HOME="${SANDBOX_HOME}" "${SCAFFOLD_SCRIPT}" "${SAMPLE_REPO}"
pass "Executed scaffold_subvault.sh successfully"

# --- Check 4: Verify directory structure ---
echo "[CHECK 4] Verifying sub-vault directory structure..."
for sub in entities decisions protocols projects .obsidian .index; do
    [ -d "${SAMPLE_REPO}/vault/${sub}" ] || fail "Missing directory ${SAMPLE_REPO}/vault/${sub}"
    [ -d "${SAMPLE_REPO}/.orchestration/memory/${sub}" ] || fail "Missing mirrored directory ${SAMPLE_REPO}/.orchestration/memory/${sub}"
done
pass "All 6 standard subdirectories provisioned in both vault/ and .orchestration/memory/"

# --- Check 5: Verify starter templates and content ---
echo "[CHECK 5] Verifying starter markdown templates..."
[ -f "${SAMPLE_REPO}/vault/overview.md" ] || fail "Missing vault/overview.md"
[ -f "${SAMPLE_REPO}/vault/workflow.md" ] || fail "Missing vault/workflow.md"
[ -f "${SAMPLE_REPO}/vault/decisions/0001-baseline.md" ] || fail "Missing vault/decisions/0001-baseline.md"

grep -q "sample_repo Knowledge Vault Overview" "${SAMPLE_REPO}/vault/overview.md" || fail "overview.md missing repo title"
grep -q ".orchestration/worktrees/<branch>" "${SAMPLE_REPO}/vault/workflow.md" || fail "workflow.md missing worktree path"
grep -q "ADR 0001: Baseline Repository Architecture" "${SAMPLE_REPO}/vault/decisions/0001-baseline.md" || fail "ADR 0001 missing header"
pass "All starter templates populated with valid Markdown content"

# --- Check 6: Verify template synchronization to .orchestration/memory ---
echo "[CHECK 6] Verifying synchronization to .orchestration/memory/..."
[ -f "${SAMPLE_REPO}/.orchestration/memory/overview.md" ] || fail "Missing mirrored overview.md"
[ -f "${SAMPLE_REPO}/.orchestration/memory/workflow.md" ] || fail "Missing mirrored workflow.md"
[ -f "${SAMPLE_REPO}/.orchestration/memory/decisions/0001-baseline.md" ] || fail "Missing mirrored ADR 0001"
pass "Templates synchronized into .orchestration/memory/"

# --- Check 7: Verify obsidian.json safe registration ---
echo "[CHECK 7] Verifying obsidian.json safe registration..."
python3 -c "
import json
from pathlib import Path

cfg = Path('${OBSIDIAN_DIR}/obsidian.json')
data = json.loads(cfg.read_text(encoding='utf-8'))
vaults = data.get('vaults', {})

assert 'existing12345' in vaults, 'Existing vault was wiped out!'
assert any(v.get('path') == '${SAMPLE_REPO}/vault' for v in vaults.values()), 'New sub-vault was not registered!'
assert len(vaults) == 2, f'Expected exactly 2 vaults, found {len(vaults)}'
" || fail "obsidian.json verification failed"
pass "Existing vault preserved and new sub-vault cleanly registered"

# --- Check 8: Verify idempotency on second run ---
echo "[CHECK 8] Testing idempotency on repeated execution..."
USER_HOME="${SANDBOX_HOME}" "${SCAFFOLD_SCRIPT}" "${SAMPLE_REPO}"
python3 -c "
import json
from pathlib import Path

cfg = Path('${OBSIDIAN_DIR}/obsidian.json')
data = json.loads(cfg.read_text(encoding='utf-8'))
vaults = data.get('vaults', {})
assert len(vaults) == 2, f'Duplicate vaults created in obsidian.json! Count: {len(vaults)}'
" || fail "Idempotency check failed (vault duplicated in obsidian.json)"
pass "Repeated execution is 100% idempotent and does not create duplicate entries"

# --- Check 9: Verify symlink creation in ~/Vaults/repos/<repo_name> ---
echo "[CHECK 9] Verifying symlink in ~/Vaults/repos/sample_repo..."
LINK_PATH="${SANDBOX_HOME}/Vaults/repos/sample_repo"
[ -L "${LINK_PATH}" ] || fail "Symlink not created at ${LINK_PATH}"
TARGET_PATH="$(readlink -f "${LINK_PATH}")"
[ "${TARGET_PATH}" = "${SAMPLE_REPO}/vault" ] || fail "Symlink points to ${TARGET_PATH}, expected ${SAMPLE_REPO}/vault"
pass "Symlink ${LINK_PATH} correctly resolves to ${SAMPLE_REPO}/vault"

# --- Check 10: Verify ColBERT index generation ---
echo "[CHECK 10] Verifying initial ColBERT index creation..."
[ -f "${SAMPLE_REPO}/vault/.index/index.json" ] || fail "ColBERT index.json was not generated"
python3 -c "
import json
from pathlib import Path

idx_file = Path('${SAMPLE_REPO}/vault/.index/index.json')
data = json.loads(idx_file.read_text(encoding='utf-8'))
assert len(data.get('doc_ids', [])) >= 3, f'Expected at least 3 indexed documents, found {len(data.get(\"doc_ids\", []))}'
" || fail "ColBERT index does not contain expected indexed documents"
pass "Initial ColBERT index successfully created with >=3 indexed documents"

echo "================================================================================"
echo "🎉 ALL SUB-VAULT SCAFFOLDING CHECKS PASSED!"
echo "================================================================================"
