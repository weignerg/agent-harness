#!/usr/bin/env bash
# ==============================================================================
# tests/test_installer_features.sh
# Verifies advanced features of install.sh (Issue #120):
# 1. Granular component detection & skip/reinstall prompt logic
# 2. Port forwarding & firewall detection (port 4096)
# 3. Dedicated ColBERT indexing configuration section & doc counting
# 4. Configuration & Service Manifest generation (with secret masking)
# 5. Non-interactive & dry-run state isolation
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

TESTS_PASSED=0
TESTS_FAILED=0

pass() { echo "  ✅ PASS: $1"; TESTS_PASSED=$((TESTS_PASSED + 1)); }
fail() { echo "  ❌ FAIL: $1"; TESTS_FAILED=$((TESTS_FAILED + 1)); }

echo "================================================================================"
echo "🧪 RUNNING INSTALLER MODULAR FEATURES TEST SUITE (Issue #120)"
echo "================================================================================"

INSTALL_SCRIPT="${REPO_DIR}/install.sh"

# --- Test 1: Helper functions and CLI options ---------------------------------
echo "[Test 1] Testing install.sh CLI help and flag parsing..."
HELP_OUT="$("${INSTALL_SCRIPT}" --help)"
if echo "$HELP_OUT" | grep -q -- "--dry-run" && \
   echo "$HELP_OUT" | grep -q -- "--reinstall" && \
   echo "$HELP_OUT" | grep -q -- "--non-interactive"; then
    pass "install.sh document flags: --dry-run, --reinstall, --non-interactive"
else
    fail "install.sh --help missing expected flags"
fi

# --- Test 2: Dry-run output contains port forwarding, ColBERT, and Obsidian ---
echo "[Test 2] Testing dry-run output contains all required architectural sections..."
DRY_OUT="$("${INSTALL_SCRIPT}" --dry-run)"
if echo "$DRY_OUT" | grep -q "Firewall Port 4096:" && \
   echo "$DRY_OUT" | grep -q "Network LAN IP:" && \
   echo "$DRY_OUT" | grep -q "ColBERT Index:" && \
   echo "$DRY_OUT" | grep -q "Obsidian Vault:" && \
   echo "$DRY_OUT" | grep -q "OpenCode Server:"; then
    pass "Dry-run output verifies network, ColBERT, Obsidian, and OpenCode server"
else
    fail "Dry-run output missing one or more required architectural items"
fi

# --- Test 3: Sandbox Non-Interactive Install Manifest Generation --------------
echo "[Test 3] Testing non-interactive install in isolated sandbox generates clean manifest..."
SANDBOX="$(mktemp -d /tmp/installer-test-sandbox-XXXXXX)"
trap 'rm -rf "${SANDBOX}"' EXIT

# Prepare mock environment inside sandbox
mkdir -p "${SANDBOX}/.config/opencode-backends"
cat << 'EOF' > "${SANDBOX}/.config/opencode-backends/env"
HF_TOKEN=hf_mock_secret_token_123456
OPENCODE_SERVER_USERNAME=testuser
OPENCODE_SERVER_PASSWORD=secret_server_password_987
OPENCODE_SERVER_PORT=4096
OPENCODE_SERVER_HOST=0.0.0.0
EOF
chmod 600 "${SANDBOX}/.config/opencode-backends/env"

# Run install.sh with non-interactive mode
OUTPUT="$(HOME="${SANDBOX}" "${INSTALL_SCRIPT}" --override-gpu rtx-5090 --non-interactive 2>&1 || true)"

# Verify manifest presence
if echo "$OUTPUT" | grep -q "OPENCODE HARNESS CONFIGURATION & SERVICE MANIFEST"; then
    pass "Manifest header rendered successfully"
else
    fail "Manifest header not found in installer output"
fi

# Verify secret masking in manifest
if echo "$OUTPUT" | grep -q "\[Configured - Protected\]"; then
    pass "Secrets (HF_TOKEN and server password) are masked in manifest"
else
    fail "Secret masking not observed in manifest"
fi

# Verify raw secrets NEVER leak to output
if echo "$OUTPUT" | grep -q "hf_mock_secret_token_123456" || echo "$OUTPUT" | grep -q "secret_server_password_987"; then
    fail "SECURITY LEAK: Raw secret found in installer output!"
else
    pass "Security audit passed: No plaintext secrets leaked to stdout/stderr"
fi

# Verify ColBERT section is present
if echo "$OUTPUT" | grep -q "\[ColBERT\] Configuring ColBERTv2 Semantic Retrieval Index"; then
    pass "Dedicated ColBERT configuration section executed and displayed"
else
    fail "ColBERT configuration section missing from output"
fi

# Verify Network / Port Forwarding section is present
if echo "$OUTPUT" | grep -q "Network & Port Forwarding Information" && \
   echo "$OUTPUT" | grep -q "Local LAN Address:" && \
   echo "$OUTPUT" | grep -q "WAN / Remote Access:"; then
    pass "Network & port forwarding verification and router guidance rendered"
else
    fail "Network & port forwarding guidance missing from output"
fi

# --- Test 4: Verify ColBERT Document Count Logic ------------------------------
echo "[Test 4] Verifying ColBERT document count reporting..."
if echo "$OUTPUT" | grep -qE "[0-9]+ documents indexed"; then
    pass "ColBERT indexed document count accurately reported in manifest"
else
    fail "ColBERT indexed document count not found in manifest"
fi

# --- Test 5: Verify Granular Detection on Re-run ------------------------------
echo "[Test 5] Verifying granular detection reports already installed items..."
RERUN_OUTPUT="$(HOME="${SANDBOX}" "${INSTALL_SCRIPT}" --override-gpu rtx-5090 --non-interactive 2>&1 || true)"
if echo "$RERUN_OUTPUT" | grep -q "Existing HF_TOKEN found" && \
   echo "$RERUN_OUTPUT" | grep -q "OpenCode headless server credentials already configured" && \
   echo "$RERUN_OUTPUT" | grep -q "ColBERT semantic index is already compiled"; then
    pass "Re-run accurately detects existing components and defaults to skip without reinstallation"
else
    fail "Re-run failed to detect existing components"
fi

# --- Test 6: Verify Detailed Action & Change Audit Table -----------------------
echo "[Test 6] Verifying detailed action & change audit delta table..."
if echo "$OUTPUT" | grep -q "DETAILED ACTION & CHANGE AUDIT (INSTALLATION DELTA)" && \
   echo "$OUTPUT" | grep -q "COMPONENT / TARGET FILE" && \
   echo "$OUTPUT" | grep -q "Harness Engine: FastMCP Servers" && \
   echo "$OUTPUT" | grep -q "ColBERT: Scheduled Timer"; then
    pass "Installation delta change audit table rendered with all components"
else
    fail "Audit delta table missing or incomplete in output"
fi

# --- Test 7: Verify ColBERT Scheduled Reindexing Timer -----------------------
echo "[Test 7] Verifying ColBERT scheduled reindexing timer and units..."
if echo "$OUTPUT" | grep -q "Configuring scheduled background ColBERT vault reindexing" && \
   [ -f "${SANDBOX}/.config/systemd/user/opencode-colbert-reindex.service" ] && \
   [ -f "${SANDBOX}/.config/systemd/user/opencode-colbert-reindex.timer" ]; then
    pass "opencode-colbert-reindex.service and timer successfully deployed"
else
    fail "ColBERT scheduled timer/service files missing in sandbox systemd user dir"
fi

# --- Test 8: Verify OpenCode Mobile Client Documentation in Manifest ---------
echo "[Test 8] Verifying OpenCode Mobile client link and instructions in output..."
if echo "$OUTPUT" | grep -q "MOBILE CLIENT (OpenCode Mobile)" && \
   echo "$OUTPUT" | grep -q "https://github.com/alvarolorentedev/opencode-mobile"; then
    pass "OpenCode Mobile client documentation and repository link rendered"
else
    fail "OpenCode Mobile client documentation missing from output"
fi

# --- Test 9: Verify scripts/reindex_vault.sh executes cleanly ----------------
echo "[Test 9] Verifying standalone execution of scripts/reindex_vault.sh..."
REINDEX_OUT="$("${REPO_DIR}/scripts/reindex_vault.sh")"
if echo "$REINDEX_OUT" | grep -q "Successfully reindexed" && \
   echo "$REINDEX_OUT" | grep -q "documents"; then
    pass "scripts/reindex_vault.sh executes standalone CPU reindexing cleanly"
else
    fail "scripts/reindex_vault.sh failed execution: $REINDEX_OUT"
fi

# --- Test 10: Verify OpenCode Guidance Deployed to ~/.config/opencode/AGENTS.md (No ~/AGENTS.md duplicate) ---
echo "[Test 10] Verifying OpenCode guidance deployed to ~/.config/opencode/AGENTS.md with no duplicate ~/AGENTS.md..."
if [ ! -f "${SANDBOX}/AGENTS.md" ] && \
   [ -f "${SANDBOX}/.config/opencode/AGENTS.md" ] && \
   grep -q "RTX 5090" "${SANDBOX}/.config/opencode/AGENTS.md" && \
   [ ! -d "${SANDBOX}/.agents" ] && \
   [ ! -d "${SANDBOX}/.local/share/opencode-harness" ]; then
    pass "OpenCode guidance properly populated in ~/.config/opencode/AGENTS.md with zero ~/AGENTS.md duplication and zero .agents directory"
else
    fail "OpenCode guidance missing expected ~/.config/opencode/AGENTS.md or left duplicate ~/AGENTS.md"
fi

# --- Test 11: Verify Host-Customized AGENTS.md Charter Generation ------------
echo "[Test 11] Verifying customized AGENTS.md generated and deployed..."
if [ -f "${SANDBOX}/.config/opencode/AGENTS.md" ] && \
   grep -q "RTX 5090" "${SANDBOX}/.config/opencode/AGENTS.md" && \
   [ ! -f "${SANDBOX}/AGENTS.md" ] && \
   [ ! -d "${SANDBOX}/.agents" ]; then
    pass "Customized AGENTS.md charter successfully generated and deployed to ~/.config/opencode/AGENTS.md without ~/AGENTS.md duplication"
else
    fail "Customized AGENTS.md charter missing or duplicated at home root in sandbox"
fi

# --- Test 12: Verify opencode.json FastMCP & Instructions Wiring -------------
echo "[Test 12] Verifying opencode.json FastMCP and instructions configuration..."
if [ -f "${SANDBOX}/.config/opencode/opencode.json" ] && \
   grep -q "harness.mcp.vault_server" "${SANDBOX}/.config/opencode/opencode.json" && \
   grep -q "harness.mcp.worktree_server" "${SANDBOX}/.config/opencode/opencode.json" && \
   grep -q "${SANDBOX}/.config/opencode/AGENTS.md" "${SANDBOX}/.config/opencode/opencode.json" && \
   grep -q "${SANDBOX}/.config/opencode/rules/\*.md" "${SANDBOX}/.config/opencode/opencode.json" && \
   ! grep -q "harness-tools" "${SANDBOX}/.config/opencode/opencode.json" && \
   ! grep -q "opencode-harness" "${SANDBOX}/.config/opencode/opencode.json" && \
   ! grep -q "\.agents" "${SANDBOX}/.config/opencode/opencode.json"; then
    pass "opencode.json wires modular FastMCP modules and points instructions to OpenCode AGENTS.md"
else
    fail "opencode.json missing modular FastMCP modules or OpenCode AGENTS.md wiring"
fi

# --- Test 13: Verify Repository Sanitization (Zero host paths / developer info)
echo "[Test 13] Verifying repository is sanitized of host mount paths and developer usernames..."
BAD_PATH_PATTERN="/WH""NAS"
DEV_HANDLE_PATTERN="wei""gnerg"

WHNAS_MATCHES="$(git -C "${REPO_DIR}" grep -i "$BAD_PATH_PATTERN" || true)"
DEV_MATCHES="$(git -C "${REPO_DIR}" grep -i "$DEV_HANDLE_PATTERN" -- ':(exclude)LICENSE' ':(exclude)pyproject.toml' || true)"

if [ -z "$WHNAS_MATCHES" ] && [ -z "$DEV_MATCHES" ] && \
   ! grep -q "192.168.0.155" "${REPO_DIR}/README.md" && \
   ! grep -q "192.168.0.155" "${REPO_DIR}/vault/entities/opencode-server.md"; then
    pass "Repository is fully sanitized of host paths, developer handle, and host IPs"
else
    fail "Leak detected in repository: WHNAS matches='$WHNAS_MATCHES' DEV matches='$DEV_MATCHES'"
fi

# --- Test 14: Verify Obsidian Vault Registration in Sandbox ------------------
echo "[Test 14] Verifying Obsidian vault registration strictly targets ~/Vaults/home..."
OBS_JSON="${SANDBOX}/.config/obsidian/obsidian.json"
if [ -f "$OBS_JSON" ] && \
   grep -q "${SANDBOX}/Vaults/home" "$OBS_JSON" && \
   ! grep -q "${REPO_DIR}/vault" "$OBS_JSON" && \
   ! grep -q "open-code-harness/vault" "$OBS_JSON"; then
    pass "Obsidian vault registration cleanly registered ~/Vaults/home and excluded repo template vault"
else
    fail "Obsidian vault registration missing ~/Vaults/home or leaked repo template vault into $OBS_JSON"
fi

# --- Test 15: Verify Backend Vault Symlinks Point to Home Vault --------------
echo "[Test 15] Verifying backend vault symlinks point to user's home vault..."
if [ -L "${SANDBOX}/.config/opencode-backends/vault" ] && \
   [ "$(readlink "${SANDBOX}/.config/opencode-backends/vault")" = "${SANDBOX}/Vaults/home" ]; then
    pass "Backend vault symlink points to ~/Vaults/home"
else
    fail "Backend vault symlink does not point to ~/Vaults/home"
fi

# --- Test 16: Verify 10-Component OpenCode Hierarchy Deployed in Sandbox -----
echo "[Test 16] Verifying full 10-component OpenCode hierarchy deployed to ~/.config/opencode/..."
CFG_DIR="${SANDBOX}/.config/opencode"
if [ -f "${CFG_DIR}/opencode.json" ] && \
   [ -f "${CFG_DIR}/AGENTS.md" ] && \
   [ -f "${CFG_DIR}/tui.json" ] && \
   [ -f "${CFG_DIR}/agents/supreme-orchestrator.md" ] && \
   [ -f "${CFG_DIR}/agents/team-orchestrator.md" ] && \
   [ -f "${CFG_DIR}/agents/architect.md" ] && \
   [ -f "${CFG_DIR}/agents/reviewer.md" ] && \
   [ -f "${CFG_DIR}/commands/worktree.md" ] && \
   [ -f "${CFG_DIR}/skills/vault-retrieval/SKILL.md" ] && \
   [ -x "${CFG_DIR}/tools/worktree_manager.py" ] && \
   [ -f "${CFG_DIR}/rules/agent-teams.md" ] && \
   [ -f "${CFG_DIR}/rules/git-workflow.md" ] && \
   [ -f "${CFG_DIR}/rules/code-quality.md" ] && \
   [ -f "${CFG_DIR}/rules/process-safety.md" ] && \
   [ -f "${CFG_DIR}/plugins/README.md" ] && \
   [ -f "${CFG_DIR}/themes/blackwell.json" ]; then
    pass "All 10 OpenCode configuration hierarchy components successfully deployed in sandbox"
else
    fail "10-component OpenCode configuration hierarchy missing required files"
fi

# --- Test 17: Verify Manifest Prints Exact Hierarchy Layout ------------------
echo "[Test 17] Verifying manifest outputs exact 10-component hierarchy..."
if echo "$OUTPUT" | grep -q "OPENCODE CONFIGURATION HIERARCHY (~/.config/opencode/):" && \
   echo "$OUTPUT" | grep -q "├── opencode.json" && \
   echo "$OUTPUT" | grep -q "├── AGENTS.md" && \
   echo "$OUTPUT" | grep -q "├── tui.json" && \
   echo "$OUTPUT" | grep -q "├── agents/" && \
   echo "$OUTPUT" | grep -q "├── commands/" && \
   echo "$OUTPUT" | grep -q "├── skills/" && \
   echo "$OUTPUT" | grep -q "├── tools/" && \
   echo "$OUTPUT" | grep -q "├── rules/" && \
   echo "$OUTPUT" | grep -q "├── plugins/" && \
   echo "$OUTPUT" | grep -q "└── themes/"; then
    pass "Installer manifest accurately outputs exact 10-component layout tree"
else
    fail "Installer manifest missing exact 10-component layout tree"
fi

# --- Test 18: Verify OpenCode resolves agents, prompts, and rules ------------
echo "[Test 18] Verifying opencode resolves agent prompts, permissions, and rule instructions..."
if command -v opencode >/dev/null 2>&1; then
    RESOLVED="$(cd "$REPO_DIR" && HOME="${SANDBOX}" opencode debug config 2>/dev/null || true)"
    if echo "$RESOLVED" | python3 -c "
import sys, json
d = json.load(sys.stdin)
ag = d['agent']
assert ag['reviewer'].get('mode') == 'subagent' and ag['reviewer'].get('prompt')
assert ag['reviewer']['permission']['edit'] == 'deny'
assert ag['supreme-orchestrator'].get('prompt') and ag['supreme-orchestrator'].get('mode') == 'primary'
assert 'task' in ag['supreme-orchestrator']['prompt'] or 'subagent' in ag['supreme-orchestrator']['prompt']
assert 'team' in ag['supreme-orchestrator']['prompt'].lower() and 'delegates' in ag['supreme-orchestrator']['prompt']
assert ag['supreme-orchestrator']['permission']['edit'] == 'deny' and ag['supreme-orchestrator']['permission']['write'] == 'deny'
assert ag['team-orchestrator'].get('prompt') and ag['team-orchestrator'].get('mode') == 'subagent'
assert 'team' in ag['team-orchestrator']['prompt'].lower() and 'reviewer' in ag['team-orchestrator']['prompt']
for n in ('scout', 'grunt'):
    assert ag[n]['permission'].get('task') == 'deny', n
    assert 'Requests for' in ag[n]['prompt'], n
for n in ('supreme-orchestrator', 'team-orchestrator', 'architect', 'worker', 'tester'):
    assert n in ag and ag[n].get('prompt'), n
assert any('rules' in i for i in d['instructions'])
"; then
        pass "opencode resolves agent profiles (.md) with prompts/permissions and loads rules instructions"
    else
        fail "opencode did not resolve agent prompts/permissions or rules instructions"
    fi
else
    echo "  ⏭️  SKIP: opencode binary not installed"
fi

echo "================================================================================"
echo "📊 TEST RESULTS: ${TESTS_PASSED} Passed, ${TESTS_FAILED} Failed"
echo "================================================================================"
[ "$TESTS_FAILED" -eq 0 ]
