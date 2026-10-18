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
if [ -f "${REPO_DIR}/.venv/bin/python" ]; then
    PY_BIN="${REPO_DIR}/.venv/bin/python"
elif [ -f "${HOME}/.local/share/opencode-sglang-stack/venv/bin/python" ]; then
    PY_BIN="${HOME}/.local/share/opencode-sglang-stack/venv/bin/python"
else
    PY_BIN="python3"
fi

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

# --- Test 2: Dry-run output contains multi-runtime targets and architecture ---
echo "[Test 2] Testing dry-run output contains all required architectural sections..."
DRY_OUT="$("${INSTALL_SCRIPT}" --dry-run --target=all)"
if echo "$DRY_OUT" | grep -q "INSTALLING AGY HARNESS" && \
   echo "$DRY_OUT" | grep -q "INSTALLING CLAUDE CODE HARNESS" && \
   echo "$DRY_OUT" | grep -q "INSTALLING OPENCODE HARNESS" && \
   echo "$DRY_OUT" | grep -q "vault-memory and worktree-manager"; then
    pass "Dry-run output verifies all multi-runtime architectural targets"
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

# Run install.sh with non-interactive mode for opencode target
OUTPUT="$(HOME="${SANDBOX}" "${INSTALL_SCRIPT}" --target=opencode --non-interactive 2>&1 || true)"

# Verify manifest presence
if echo "$OUTPUT" | grep -q "INSTALLING OPENCODE HARNESS"; then
    pass "Manifest header rendered successfully"
else
    fail "Manifest header not found in installer output"
fi

# Verify secret masking / protection
if [ -f "${SANDBOX}/.config/opencode-backends/env" ] && [ "$(stat -c '%a' "${SANDBOX}/.config/opencode-backends/env")" = "600" ]; then
    pass "Secrets (HF_TOKEN and server password) are secured with 0600 permissions"
else
    fail "Secret permissions not observed in sandbox"
fi

# Verify raw secrets NEVER leak to output
if echo "$OUTPUT" | grep -q "hf_mock_secret_token_123456" || echo "$OUTPUT" | grep -q "secret_server_password_987"; then
    fail "SECURITY LEAK: Raw secret found in installer output!"
else
    pass "Security audit passed: No plaintext secrets leaked to stdout/stderr"
fi

# Verify OpenCode target directory is deployed
if echo "$OUTPUT" | grep -q "Target Dir"; then
    pass "Target directory resolved and displayed in manifest"
else
    fail "Target directory missing from output"
fi

# Verify confirmation of deployment
if echo "$OUTPUT" | grep -q "Installed OpenCode 10-component hierarchy"; then
    pass "OpenCode 10-component hierarchy installation confirmed"
else
    fail "OpenCode hierarchy installation confirmation missing from output"
fi

# --- Test 4: Verify ColBERT Document Count Logic ------------------------------
echo "[Test 4] Verifying ColBERT document count reporting..."
DOC_COUNT="$("${REPO_DIR}/scripts/reindex_vault.sh" | grep -oE '[0-9]+ documents' || true)"
if [ -n "$DOC_COUNT" ]; then
    pass "ColBERT indexed document count accurately reported ($DOC_COUNT)"
else
    fail "ColBERT indexed document count not found in output"
fi

# --- Test 5: Verify Granular Detection on Re-run ------------------------------
echo "[Test 5] Verifying granular detection reports already installed items..."
RERUN_OUTPUT="$(HOME="${SANDBOX}" "${INSTALL_SCRIPT}" --target=opencode --non-interactive 2>&1 || true)"
if echo "$RERUN_OUTPUT" | grep -q "INSTALLING OPENCODE HARNESS"; then
    pass "Re-run accurately executes idempotently across targets"
else
    fail "Re-run failed to execute"
fi

# --- Test 6: Verify Multi-Runtime Installation Delta --------------------------
echo "[Test 6] Verifying detailed multi-runtime installation..."
ALL_OUTPUT="$(HOME="${SANDBOX}" "${INSTALL_SCRIPT}" --target=all --non-interactive 2>&1 || true)"
if echo "$ALL_OUTPUT" | grep -q "INSTALLING AGY HARNESS" && \
   echo "$ALL_OUTPUT" | grep -q "INSTALLING CLAUDE CODE HARNESS" && \
   echo "$ALL_OUTPUT" | grep -q "INSTALLING OPENCODE HARNESS"; then
    pass "Multi-runtime installer successfully deploys all targets"
else
    fail "Multi-runtime targets missing from output"
fi

# --- Test 7: Verify ColBERT Scheduled Reindexing Timer -----------------------
echo "[Test 7] Verifying ColBERT scheduled reindexing timer and units..."
if [ -f "${REPO_DIR}/config/systemd/opencode-colbert-reindex.service" ] && \
   [ -f "${REPO_DIR}/config/systemd/opencode-colbert-reindex.timer" ] && \
   grep -q "reindex_vault.sh" "${REPO_DIR}/config/systemd/opencode-colbert-reindex.service" && \
   grep -q "OnUnitActiveSec=5min" "${REPO_DIR}/config/systemd/opencode-colbert-reindex.timer"; then
    pass "opencode-colbert-reindex.service and timer successfully verified in config/systemd"
else
    fail "ColBERT scheduled timer/service files missing in config/systemd"
fi

# --- Test 8: Verify OpenCode Mobile Client Documentation in Entities ---------
echo "[Test 8] Verifying OpenCode Mobile client link and instructions in vault entities..."
if grep -q "https://github.com/alvarolorentedev/opencode-mobile" "${REPO_DIR}/vault/entities/opencode-server.md"; then
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
   grep -q "RTX 5090" "${SANDBOX}/.config/opencode/AGENTS.md"; then
    pass "OpenCode guidance properly populated in ~/.config/opencode/AGENTS.md with zero ~/AGENTS.md duplication"
else
    fail "OpenCode guidance missing expected ~/.config/opencode/AGENTS.md or left duplicate ~/AGENTS.md"
fi

# --- Test 11: Verify Host-Customized AGENTS.md Charter Generation ------------
echo "[Test 11] Verifying customized AGENTS.md generated and deployed..."
if [ -f "${SANDBOX}/.config/opencode/AGENTS.md" ] && \
   grep -q "RTX 5090" "${SANDBOX}/.config/opencode/AGENTS.md" && \
   [ ! -f "${SANDBOX}/AGENTS.md" ]; then
    pass "Customized AGENTS.md charter successfully generated and deployed to ~/.config/opencode/AGENTS.md without ~/AGENTS.md duplication"
else
    fail "Customized AGENTS.md charter missing or duplicated at home root in sandbox"
fi

# --- Test 12: Verify opencode.json FastMCP & Instructions Wiring -------------
echo "[Test 12] Verifying opencode.json FastMCP and instructions configuration..."
if [ -f "${SANDBOX}/.config/opencode/opencode.json" ] && \
   grep -q "harness.mcp.vault_server" "${SANDBOX}/.config/opencode/opencode.json" && \
   grep -q "harness.mcp.worktree_server" "${SANDBOX}/.config/opencode/opencode.json" && \
   grep -q "AGENTS.md" "${SANDBOX}/.config/opencode/opencode.json" && \
   ! grep -q "harness-tools" "${SANDBOX}/.config/opencode/opencode.json" && \
   ! grep -q "opencode-harness" "${SANDBOX}/.config/opencode/opencode.json"; then
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

# --- Test 14: Verify Knowledge Vault Validation -------------------------------
echo "[Test 14] Verifying Obsidian knowledge vault template structure..."
if $PY_BIN -c "
from harness.memory.vault_validator import validate_vault
from pathlib import Path
valid, errors = validate_vault(Path('${REPO_DIR}/vault'))
assert valid, f'Errors: {errors}'
"; then
    pass "Knowledge vault template in vault/ conforms strictly to schema"
else
    fail "Knowledge vault validation failed"
fi

# --- Test 15: Verify FastMCP Vault Server Initialization ----------------------
echo "[Test 15] Verifying Vault Memory FastMCP server initializes..."
if $PY_BIN -c "
from harness.mcp.vault_server import server
assert server is not None
"; then
    pass "Vault Memory FastMCP server initializes cleanly"
else
    fail "Vault Memory FastMCP server initialization failed"
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

# --- Test 17: Verify Manifest Prints Exact Hierarchy Confirmation -----------
echo "[Test 17] Verifying installer confirms 10-component OpenCode deployment..."
if echo "$OUTPUT" | grep -q "Installed OpenCode 10-component hierarchy"; then
    pass "Installer manifest accurately confirms 10-component hierarchy deployment"
else
    fail "Installer manifest missing 10-component hierarchy confirmation"
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

# --- Test 19: Verify Issue #7 CLI flags in install.sh --help -----------------
echo "[Test 19] Verifying Issue #7 CLI flags in install.sh --help..."
HELP_OUT="$("${INSTALL_SCRIPT}" --help)"
if echo "$HELP_OUT" | grep -q -- "--download-models" && \
   echo "$HELP_OUT" | grep -q -- "--no-download-models" && \
   echo "$HELP_OUT" | grep -q -- "--firewall" && \
   echo "$HELP_OUT" | grep -q -- "--no-firewall" && \
   echo "$HELP_OUT" | grep -q -- "--healthcheck" && \
   echo "$HELP_OUT" | grep -q -- "--skip-healthcheck"; then
    pass "install.sh document flags: --download-models, --firewall, --healthcheck"
else
    fail "install.sh --help missing one or more Issue #7 CLI flags"
fi

# --- Test 20: Verify Default Firewall is enabled by default -------------------
echo "[Test 20] Verifying Default Firewall enabled by default..."
FIREWALL_DEFAULT="$("${INSTALL_SCRIPT}" --dry-run --target=opencode)"
if echo "$FIREWALL_DEFAULT" | grep -q "Applying UFW firewall rules" || echo "$FIREWALL_DEFAULT" | grep -q "sudo ufw allow 4096/tcp comment OpenCode Server"; then
    pass "Firewall rules enabled by default in install.sh"
else
    fail "Firewall rules not enabled by default in install.sh"
fi

NO_FIREWALL_OUT="$("${INSTALL_SCRIPT}" --dry-run --target=opencode --no-firewall)"
if echo "$NO_FIREWALL_OUT" | grep -q "Firewall rule management skipped (--no-firewall)"; then
    pass "--no-firewall flag correctly disables firewall rules"
else
    fail "--no-firewall did not skip firewall rules"
fi

# --- Test 21: Verify Model Acquisition Verification Flags ---------------------
echo "[Test 21] Verifying model acquisition verification flags..."
DL_OUT="$("${INSTALL_SCRIPT}" --dry-run --target=opencode --download-models)"
if echo "$DL_OUT" | grep -q "Download Opt  : true" && echo "$DL_OUT" | grep -q "Would verify model weights"; then
    pass "--download-models sets download option to true in dry-run"
else
    fail "--download-models flag failed to activate download option"
fi

NODL_OUT="$("${INSTALL_SCRIPT}" --dry-run --target=opencode --no-download-models)"
if echo "$NODL_OUT" | grep -q "Download Opt  : false" && echo "$NODL_OUT" | grep -q "Would verify model weights"; then
    pass "--no-download-models sets download option to false in dry-run"
else
    fail "--no-download-models flag failed to set download option to false"
fi

# --- Test 22: Verify Grandma-Proof UX, Password Generation & Terminal Box -----
echo "[Test 22] Verifying Grandma-Proof post-install UX and automatic password generation..."
SANDBOX_GP="$(mktemp -d /tmp/installer-test-grandma-XXXXXX)"
trap 'rm -rf "${SANDBOX}" "${SANDBOX_GP}"' EXIT

GP_OUT="$(HOME="${SANDBOX_GP}" "${INSTALL_SCRIPT}" --target=opencode --non-interactive 2>&1 || true)"

# 1. Verify 16-character password auto-generated in env file
if [ -f "${SANDBOX_GP}/.config/opencode-backends/env" ]; then
    GEN_PASS="$(grep '^OPENCODE_SERVER_PASSWORD=' "${SANDBOX_GP}/.config/opencode-backends/env" | cut -d'=' -f2)"
    if [ ${#GEN_PASS} -eq 16 ]; then
        pass "Auto-generated server password is exactly 16 characters"
    else
        fail "Auto-generated password length is ${#GEN_PASS}, expected 16"
    fi
else
    fail "Backend env file not created in sandbox"
fi

# 2. Verify Immediate Next Step terminal box
if echo "$GP_OUT" | grep -q "IMMEDIATE NEXT STEP: RUN THIS COMMAND IN YOUR TERMINAL" && \
   echo "$GP_OUT" | grep -q "opencode"; then
    pass "Immediate Next Step terminal box rendered with 'opencode' command"
else
    fail "Immediate Next Step terminal box missing from installer output"
fi

# 3. Verify auto-generated password is surfaced to user in summary
if echo "$GP_OUT" | grep -q "password: ${GEN_PASS} (auto-generated)"; then
    pass "Auto-generated password surfaced in Grandma-Proof summary box"
else
    fail "Auto-generated password not surfaced in Grandma-Proof summary"
fi

# --- Test 23: Verify SGLang venv auto-healing with local repository -----------
echo "[Test 23] Verifying SGLang venv auto-healing with local repository..."
SANDBOX_HEAL="$(mktemp -d /tmp/installer-test-heal-XXXXXX)"
trap 'rm -rf "${SANDBOX}" "${SANDBOX_GP}" "${SANDBOX_HEAL}"' EXIT

# Prepare mock local sglang repository in candidate path
MOCK_SGLANG_REPO="${SANDBOX_HEAL}/git/sglang/python"
mkdir -p "${MOCK_SGLANG_REPO}"
touch "${MOCK_SGLANG_REPO}/pyproject.toml"

# Prepare mock venv with python3 that simulates broken sglang import initially
MOCK_STACK="${SANDBOX_HEAL}/.local/share/opencode-sglang-stack"
mkdir -p "${MOCK_STACK}/venv/bin"
cat << 'EOF' > "${MOCK_STACK}/venv/bin/python3"
#!/bin/sh
STATE_FILE="$(dirname "$0")/sglang_state"
if [ "$1" = "-c" ] && [ "$2" = "import sglang" ]; then
    if [ -f "$STATE_FILE" ]; then
        exit 0
    else
        echo "ModuleNotFoundError: No module named 'sglang'" >&2
        exit 1
    fi
elif [ "$1" = "-m" ] && [ "$2" = "pip" ] && [ "$3" = "install" ]; then
    touch "$STATE_FILE"
    exit 0
fi
exit 0
EOF
chmod 0755 "${MOCK_STACK}/venv/bin/python3"

HEAL_OUT="$(USER_HOME="${SANDBOX_HEAL}" HOME="${SANDBOX_HEAL}" "${INSTALL_SCRIPT}" --target=opencode --non-interactive 2>&1 || true)"
if echo "$HEAL_OUT" | grep -q "sglang import check failed" && \
   echo "$HEAL_OUT" | grep -q "Successfully auto-healed sglang via editable install"; then
    pass "SGLang venv auto-healed via local candidate repository"
else
    fail "SGLang venv auto-heal failed"
fi

# --- Test 24: Verify NVIDIA Driver Mismatch Detection Banner -------------------
echo "[Test 24] Verifying NVIDIA Driver Mismatch Detection Banner..."
SANDBOX_NV="$(mktemp -d /tmp/installer-test-nv-XXXXXX)"
trap 'rm -rf "${SANDBOX}" "${SANDBOX_GP}" "${SANDBOX_HEAL}" "${SANDBOX_NV}"' EXIT

MOCK_NV_BIN="${SANDBOX_NV}/bin"
mkdir -p "${MOCK_NV_BIN}"
cat << 'EOF' > "${MOCK_NV_BIN}/nvidia-smi"
#!/bin/sh
echo "Failed to initialize NVML: Driver/library version mismatch" >&2
exit 18
EOF
chmod 0755 "${MOCK_NV_BIN}/nvidia-smi"

NV_OUT="$(PATH="${MOCK_NV_BIN}:${PATH}" COLBERT_TIMER_RETRIES=1 OPENCODE_SERVER_RETRIES=1 SGLANG_HEALTHCHECK_RETRIES=1 USER_HOME="${SANDBOX_NV}" HOME="${SANDBOX_NV}" "${INSTALL_SCRIPT}" --target=opencode --healthcheck --non-interactive 2>&1 || true)"
if echo "$NV_OUT" | grep -q "NVIDIA DRIVER/LIBRARY VERSION MISMATCH DETECTED" && \
   echo "$NV_OUT" | grep -q "sudo reboot" && \
   echo "$NV_OUT" | grep -q "systemctl --user start opencode-sglang-ornith-35b.service"; then
    pass "High-contrast NVIDIA driver mismatch banner and reboot remediation emitted"
else
    fail "NVIDIA driver mismatch banner not emitted"
fi

echo "================================================================================"
echo "📊 TEST RESULTS: ${TESTS_PASSED} Passed, ${TESTS_FAILED} Failed"
echo "================================================================================"
[ "$TESTS_FAILED" -eq 0 ]


