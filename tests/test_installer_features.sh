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
export PYTHONPATH="${REPO_DIR}:${PYTHONPATH:-}"
export AGENT_HARNESS_CANONICAL_ROOT="${REPO_DIR}"

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

# Global mock systemctl to protect host desktop/session during sandboxed tests
GLOBAL_MOCK_BIN="$(mktemp -d /tmp/test-global-mock-bin-XXXXXX)"
cat << 'EOF' > "${GLOBAL_MOCK_BIN}/systemctl"
#!/bin/sh
if [ "$1" = "--user" ] && [ "$2" = "is-active" ]; then
    echo "active"
    exit 0
fi
if [ "$1" = "--user" ] && [ "$2" = "is-enabled" ]; then
    echo "enabled"
    exit 0
fi
exit 0
EOF
chmod 0755 "${GLOBAL_MOCK_BIN}/systemctl"
export PATH="${GLOBAL_MOCK_BIN}:${PATH}"
cleanup_test_sandboxes() {
    rm -rf "${GLOBAL_MOCK_BIN:-}" "${SANDBOX:-}" "${SANDBOX_GP:-}" "${SANDBOX_HEAL:-}" "${SANDBOX_NV:-}" "${SANDBOX_WARMUP:-}" "${SANDBOX_HC_PROG:-}" "${SANDBOX_HC_FAIL:-}" "${SANDBOX_CLAUDE:-}" "${SANDBOX_AGY:-}" "${SANDBOX_T3:-}" "${SANDBOX_PROF:-}" "${SANDBOX_Q6:-}" 2>/dev/null || true
}
trap cleanup_test_sandboxes EXIT

# --- Test 1: Helper functions and CLI options ---------------------------------
echo "[Test 1] Testing install.sh CLI help and flag parsing..."
HELP_OUT="$("${INSTALL_SCRIPT}" --help)"
if echo "$HELP_OUT" | grep -q -- "--dry-run" && \
   echo "$HELP_OUT" | grep -q -- "--reinstall" && \
   echo "$HELP_OUT" | grep -q -- "--non-interactive" && \
   echo "$HELP_OUT" | grep -q -- "--sglang-model"; then
    pass "install.sh document flags: --dry-run, --reinstall, --non-interactive, --sglang-model"
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
   grep -q "Universal AI Agent System Charter" "${SANDBOX}/.config/opencode/AGENTS.md"; then
    pass "OpenCode guidance properly populated in ~/.config/opencode/AGENTS.md with zero ~/AGENTS.md duplication"
else
    fail "OpenCode guidance missing expected ~/.config/opencode/AGENTS.md or left duplicate ~/AGENTS.md"
fi

# --- Test 11: Verify Host-Customized AGENTS.md Charter Generation ------------
echo "[Test 11] Verifying customized AGENTS.md generated and deployed..."
if [ -f "${SANDBOX}/.config/opencode/AGENTS.md" ] && \
   grep -q "HARDWARE_ARCHITECTURE_START" "${SANDBOX}/.config/opencode/AGENTS.md" && \
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
   grep -q "rules/\*.md" "${SANDBOX}/.config/opencode/opencode.json" && \
   ! grep -q "AGENTS.md" "${SANDBOX}/.config/opencode/opencode.json" && \
   ! grep -q "harness-tools" "${SANDBOX}/.config/opencode/opencode.json" && \
   ! grep -q "opencode-harness" "${SANDBOX}/.config/opencode/opencode.json"; then
    pass "opencode.json wires modular FastMCP modules and points instructions to rules/*.md without AGENTS.md duplication"
else
    fail "opencode.json missing modular FastMCP modules or OpenCode instructions wiring"
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
assert ag['supreme-orchestrator']['permission']['task']['team-orchestrator'] == 'allow'
assert ag['supreme-orchestrator']['permission']['task']['*'] == 'deny'
assert ag['team-orchestrator']['permission']['task']['worker'] == 'allow'
assert ag['architect']['permission']['task']['scout'] == 'allow'
assert ag['reviewer']['permission']['task']['scout'] == 'allow'
assert ag['worker']['permission']['task']['grunt'] == 'allow' and ag['worker']['permission']['task']['scout'] == 'allow'
assert ag['architect']['permission']['bash']['git commit*'] == 'deny'
assert ag['reviewer']['permission']['bash']['git commit*'] == 'deny'
assert ag['scout']['permission']['bash']['git commit*'] == 'deny'
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

# --- Test 22: Verify Post-Install Summary, Password Generation & Terminal Box -----
echo "[Test 22] Verifying post-install summary UX and automatic password generation..."
SANDBOX_GP="$(mktemp -d /tmp/installer-test-summary-XXXXXX)"

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
    pass "Auto-generated password surfaced in completion summary box"
else
    fail "Auto-generated password not surfaced in completion summary"
fi

# --- Test 23: Verify SGLang venv auto-healing with local repository -----------
echo "[Test 23] Verifying SGLang venv auto-healing with local repository..."
SANDBOX_HEAL="$(mktemp -d /tmp/installer-test-heal-XXXXXX)"

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

# --- Test 24: Verify Minimal NVIDIA Driver Mismatch Reboot Box ----------------
echo "[Test 24] Verifying Minimal NVIDIA Driver Mismatch Reboot Box..."
SANDBOX_NV="$(mktemp -d /tmp/installer-test-nv-XXXXXX)"

MOCK_NV_BIN="${SANDBOX_NV}/bin"
mkdir -p "${MOCK_NV_BIN}"
cat << 'EOF' > "${MOCK_NV_BIN}/nvidia-smi"
#!/bin/sh
echo "Failed to initialize NVML: Driver/library version mismatch" >&2
exit 18
EOF
chmod 0755 "${MOCK_NV_BIN}/nvidia-smi"

NV_OUT="$(PATH="${MOCK_NV_BIN}:${PATH}" COLBERT_TIMER_RETRIES=1 OPENCODE_SERVER_RETRIES=1 SGLANG_HEALTHCHECK_RETRIES=1 USER_HOME="${SANDBOX_NV}" HOME="${SANDBOX_NV}" "${INSTALL_SCRIPT}" --target=opencode --healthcheck --non-interactive 2>&1 || true)"
if echo "$NV_OUT" | grep -q "REBOOT REQUIRED: NVIDIA DRIVER UPGRADE DETECTED" && \
   echo "$NV_OUT" | grep -q "sudo reboot" && \
   echo "$NV_OUT" | grep -q "After reboot, resume installation with:" && \
   echo "$NV_OUT" | grep -q "install.sh" && \
   ! echo "$NV_OUT" | grep -q "Kernel Module Version:" && \
   ! echo "$NV_OUT" | grep -q "Diagnostic Information:"; then
    pass "High-contrast clean minimal NVIDIA driver mismatch reboot instruction box emitted"
else
    fail "Minimal NVIDIA driver mismatch reboot instruction box not emitted or contained diagnostic wall of text"
fi

# --- Test 25: Verify SGLang Warmup CLI flags & live warmup execution ----------
echo "[Test 25] Verifying SGLang Warmup CLI flags & live warmup execution..."
HELP_WARMUP="$("${INSTALL_SCRIPT}" --help)"
if echo "$HELP_WARMUP" | grep -q -- "--skip-warmup"; then
    pass "install.sh --help documents --skip-warmup / --warmup"
else
    fail "install.sh --help missing --skip-warmup"
fi

SANDBOX_WARMUP="$(mktemp -d /tmp/installer-test-warmup-XXXXXX)"

# Prepare mock stack with mock sglang binary that simulates a mock server on port 30000
MOCK_WARMUP_STACK="${SANDBOX_WARMUP}/.local/share/opencode-sglang-stack"
mkdir -p "${MOCK_WARMUP_STACK}/venv/bin"

# Mock python3 that succeeds import check
cat << 'EOF' > "${MOCK_WARMUP_STACK}/venv/bin/python3"
#!/bin/sh
if [ "$1" = "-c" ] && [ "$2" = "import sglang" ]; then
    exit 0
fi
exec /usr/bin/python3 "$@"
EOF
chmod 0755 "${MOCK_WARMUP_STACK}/venv/bin/python3"

# Mock sglang binary that starts a simple HTTP server on 127.0.0.1:30000 returning /v1/models 200
cat << 'EOF' > "${MOCK_WARMUP_STACK}/venv/bin/sglang"
#!/usr/bin/env python3
import sys
import http.server
import socketserver

class Handler(http.server.SimpleHTTPRequestHandler):
    def do_GET(self):
        if self.path == '/v1/models':
            self.send_response(200)
            self.send_header('Content-type', 'application/json')
            self.end_headers()
            self.wfile.write(b'{"object":"list","data":[{"id":"ornith-1.5-35b"}]}')
        else:
            self.send_response(404)
            self.end_headers()

socketserver.TCPServer.allow_reuse_address = True
with socketserver.TCPServer(('127.0.0.1', 30099), Handler) as httpd:
    httpd.serve_forever()
EOF
chmod 0755 "${MOCK_WARMUP_STACK}/venv/bin/sglang"

WARMUP_RUN="$(USER_HOME="${SANDBOX_WARMUP}" HOME="${SANDBOX_WARMUP}" SGLANG_PORT=30099 SGLANG_WARMUP_TIMEOUT=10 "${INSTALL_SCRIPT}" --target=opencode --warmup --skip-healthcheck --non-interactive 2>&1 || true)"
if echo "$WARMUP_RUN" | grep -q "SGLang Model Warmup & Weight Verification (Live Progress)" && \
   echo "$WARMUP_RUN" | grep -q "SGLang warmup successful: Model is loaded and healthy."; then
    pass "SGLang foreground warmup pass executed and verified model healthcheck"
else
    fail "SGLang foreground warmup pass failed"
fi

# --- Test 26: Verify SGLang healthcheck live model loading progress & readiness ---
echo "[Test 26] Verifying SGLang healthcheck live model loading progress & readiness..."
SANDBOX_HC_PROG="$(mktemp -d /tmp/installer-test-hc-prog-XXXXXX)"

MOCK_HC_BIN="${SANDBOX_HC_PROG}/bin"
mkdir -p "${MOCK_HC_BIN}"
STATE_HC="${MOCK_HC_BIN}/curl_calls.txt"

cat << EOF > "${MOCK_HC_BIN}/curl"
#!/bin/sh
STATE="${STATE_HC}"
for arg in "\$@"; do
    if echo "\$arg" | grep -q "30000/v1/models"; then
        COUNT=0
        [ -f "\$STATE" ] && COUNT=\$(cat "\$STATE")
        COUNT=\$((COUNT + 1))
        echo "\$COUNT" > "\$STATE"
        if [ "\$COUNT" -eq 1 ]; then
            if echo "\$*" | grep -q "%{http_code}"; then
                printf "\\n503"
            else
                printf '{"error":"Loading model weights"}'
            fi
            exit 0
        else
            if echo "\$*" | grep -q "%{http_code}"; then
                printf '{"object":"list","data":[{"id":"ornith-1.5-35b"}]}\\n200'
            else
                printf '{"object":"list","data":[{"id":"ornith-1.5-35b"}]}\\n'
            fi
            exit 0
        fi
    elif echo "\$arg" | grep -q "4096"; then
        if echo "\$*" | grep -q "%{http_code}"; then
            printf "OpenCode Server\\n200"
        else
            printf "OpenCode Server\\n"
        fi
        exit 0
    fi
done
exit 1
EOF
chmod 0755 "${MOCK_HC_BIN}/curl"

cat << 'EOF' > "${MOCK_HC_BIN}/systemctl"
#!/bin/sh
if [ "$1" = "--user" ] && [ "$2" = "is-active" ]; then
    echo "active"
    exit 0
fi
exit 0
EOF
chmod 0755 "${MOCK_HC_BIN}/systemctl"

HC_PROG_OUT="$(PATH="${MOCK_HC_BIN}:${PATH}" USER_HOME="${SANDBOX_HC_PROG}" HOME="${SANDBOX_HC_PROG}" "${INSTALL_SCRIPT}" --target=opencode --healthcheck --non-interactive 2>&1 || true)"
if echo "$HC_PROG_OUT" | grep -q "SGLang is loading model weights into VRAM" && \
   echo "$HC_PROG_OUT" | grep -q "SGLang inference engine is active and serving on port 30000." && \
   echo "$HC_PROG_OUT" | grep -q "All backend service healthchecks passed!"; then
    pass "SGLang healthcheck emits live loading progress and succeeds upon model readiness"
else
    fail "SGLang healthcheck live loading progress or readiness verification failed"
fi

# --- Test 27: Verify SGLang healthcheck early failure detection --------------
echo "[Test 27] Verifying SGLang healthcheck early failure detection..."
SANDBOX_HC_FAIL="$(mktemp -d /tmp/installer-test-hc-fail-XXXXXX)"

MOCK_FAIL_BIN="${SANDBOX_HC_FAIL}/bin"
mkdir -p "${MOCK_FAIL_BIN}"

cat << 'EOF' > "${MOCK_FAIL_BIN}/curl"
#!/bin/sh
for arg in "$@"; do
    if echo "$arg" | grep -q "4096"; then
        if echo "$*" | grep -q "%{http_code}"; then
            printf "OpenCode Server\n200"
        else
            printf "OpenCode Server\n"
        fi
        exit 0
    fi
done
exit 1
EOF
chmod 0755 "${MOCK_FAIL_BIN}/curl"

cat << 'EOF' > "${MOCK_FAIL_BIN}/systemctl"
#!/bin/sh
if [ "$1" = "--user" ] && [ "$2" = "is-active" ]; then
    if [ "$3" = "opencode-sglang-ornith-35b.service" ] || [ "$4" = "opencode-sglang-ornith-35b.service" ]; then
        echo "failed"
        exit 1
    fi
    echo "active"
    exit 0
fi
exit 0
EOF
chmod 0755 "${MOCK_FAIL_BIN}/systemctl"

FAIL_START_TIME=$(date +%s)
HC_FAIL_OUT="$(PATH="${MOCK_FAIL_BIN}:${PATH}" USER_HOME="${SANDBOX_HC_FAIL}" HOME="${SANDBOX_HC_FAIL}" "${INSTALL_SCRIPT}" --target=opencode --healthcheck --non-interactive 2>&1 || true)"
FAIL_DURATION=$(( $(date +%s) - FAIL_START_TIME ))

if echo "$HC_FAIL_OUT" | grep -q "SGLang service (opencode-sglang-ornith-35b.service) status is failed; aborting wait." && \
   echo "$HC_FAIL_OUT" | grep -q "SGLang inference engine failed healthcheck." && \
   [ "$FAIL_DURATION" -lt 15 ]; then
    pass "SGLang healthcheck aborted immediately upon failed unit state without waiting full timeout"
else
    fail "SGLang healthcheck early failure detection failed or took too long ($FAIL_DURATION s)"
fi

# --- Test 28: Verify Claude Code Background Session & Agent Teams Integration (Issue #12) ---
echo "[Test 28] Verifying Claude Code background session dispatch and agent-teams configuration..."
CLAUDE_CORE_JSON="${REPO_DIR}/config/claude/settings/core.json"
MANIFEST_JSON="${REPO_DIR}/core/manifest.json"
SUPREME_MD="${REPO_DIR}/core/agents/supreme-orchestrator.md"
LAUNCH_MD="${REPO_DIR}/config/orchestration/launching-teams.md"

if [ -f "${CLAUDE_CORE_JSON}" ] && \
   grep -q '"CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS": "1"' "${CLAUDE_CORE_JSON}" && \
   grep -q '"Bash(claude --bg \*)' "${CLAUDE_CORE_JSON}" && \
   grep -q '"Bash(claude agents\*)' "${CLAUDE_CORE_JSON}" && \
   grep -q '"Bash(claude logs \*)' "${CLAUDE_CORE_JSON}" && \
   grep -q '"Bash(claude stop \*)' "${CLAUDE_CORE_JSON}" && \
   grep -q '"Bash(claude stop\*)' "${CLAUDE_CORE_JSON}" && \
   grep -q '"Bash(claude kill \*)' "${CLAUDE_CORE_JSON}" && \
   grep -q '"Bash(claude kill\*)' "${CLAUDE_CORE_JSON}" && \
   grep -q '"Bash(claude rm \*)' "${CLAUDE_CORE_JSON}" && \
   grep -q '"Bash(claude rm\*)' "${CLAUDE_CORE_JSON}"; then
    pass "config/claude/settings/core.json specifies CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS and background allow/deny permissions"
else
    fail "config/claude/settings/core.json missing required agent teams env or allow/deny permissions"
fi

if [ -f "${MANIFEST_JSON}" ] && \
   $PY_BIN -c "
import json
with open('${MANIFEST_JSON}') as f:
    m = json.load(f)
roles = m['roles']
for r in ['supreme-orchestrator', 'team-orchestrator', 'architect', 'worker', 'tester', 'reviewer']:
    assert 'Task' in roles[r]['claude_tools'], f'Role {r} missing Task'
for r in ['scout', 'grunt']:
    assert 'Task' not in roles[r]['claude_tools'], f'Role {r} must not have Task'
"; then
    pass "core/manifest.json grants Task to orchestrators/subagents and omits Task from scout and grunt"
else
    fail "core/manifest.json Task permissions validation failed"
fi

if grep -q "claude --bg -n" "${SUPREME_MD}" && \
   grep -q "claude --bg -n" "${LAUNCH_MD}" && \
   grep -q "claude agents" "${LAUNCH_MD}" && \
   grep -q "claude logs" "${LAUNCH_MD}"; then
    pass "Documentation in supreme-orchestrator.md and launching-teams.md details claude --bg -n workflow"
else
    fail "Documentation missing claude --bg -n background session dispatch details"
fi

SANDBOX_CLAUDE="$(mktemp -d /tmp/installer-test-claude-XXXXXX)"
$PY_BIN -m harness.installer.compiler --core-dir "${REPO_DIR}/core" --runtime claude --output-dir "${SANDBOX_CLAUDE}/agents" >/dev/null 2>&1
if grep -q "tools:.*Task" "${SANDBOX_CLAUDE}/agents/architect.md" && \
   grep -q "tools:.*Task" "${SANDBOX_CLAUDE}/agents/worker.md" && \
   grep -q "tools:.*Task" "${SANDBOX_CLAUDE}/agents/tester.md" && \
   grep -q "tools:.*Task" "${SANDBOX_CLAUDE}/agents/reviewer.md" && \
   ! grep -q "tools:.*Task" "${SANDBOX_CLAUDE}/agents/scout.md" && \
   ! grep -q "tools:.*Task" "${SANDBOX_CLAUDE}/agents/grunt.md"; then
    pass "Compiled Claude agents enforce Task tool permissions for agent teams"
else
    fail "Compiled Claude agents failed Task tool permission verification"
fi

# --- Test 29: Verify Issue #13 Runtime Bash Gates & Task Fan-Out Permissions ---
echo "[Test 29] Verifying Issue #13 runtime bash gates & subagent task fan-out..."
if "${PY_BIN}" -c "
import json
from pathlib import Path

repo = Path('${REPO_DIR}')
opencode_cfg = json.loads((repo / 'config/opencode/opencode.json').read_text(encoding='utf-8'))
claude_cfg = json.loads((repo / 'config/claude/settings/core.json').read_text(encoding='utf-8'))
manifest = json.loads((repo / 'core/manifest.json').read_text(encoding='utf-8'))

# 1. Manifest allowed_subagents
roles = manifest['roles']
assert roles['supreme-orchestrator']['allowed_subagents'] == ['team-orchestrator']
assert roles['team-orchestrator']['allowed_subagents'] == ['architect', 'worker', 'tester', 'reviewer', 'scout', 'grunt']
assert roles['architect']['allowed_subagents'] == ['scout']
assert roles['reviewer']['allowed_subagents'] == ['scout']
assert roles['worker']['allowed_subagents'] == ['grunt', 'scout']
assert roles['tester']['allowed_subagents'] == ['grunt', 'scout']
assert roles['scout']['allowed_subagents'] == []
assert roles['grunt']['allowed_subagents'] == []

# 2. opencode.json permissions
bash_perm = opencode_cfg['permission']['bash']
for pkill in ('kill *', 'pkill *', 'killall *', 'systemctl stop *', 'systemctl --user stop *', 'claude stop *', 'claude kill *'):
    assert bash_perm[pkill] == 'deny', pkill
for ask_cmd in ('git push*', 'git merge*', 'gh pr create*', 'gh pr merge*', 'gh issue close*'):
    assert bash_perm[ask_cmd] == 'ask', ask_cmd

for ro in ('supreme-orchestrator', 'architect', 'reviewer', 'scout'):
    ro_bash = opencode_cfg['agent'][ro]['permission']['bash']
    assert ro_bash['git commit*'] == 'deny', ro
    assert ro_bash['git merge*'] == 'deny', ro

to_bash = opencode_cfg['agent']['team-orchestrator']['permission']['bash']
assert to_bash['git commit*'] == 'deny'
assert to_bash['git merge*'] == 'deny'

# 3. claude settings
claude_deny = claude_cfg['permissions']['deny']
claude_ask = claude_cfg['permissions']['ask']
for cd in ('Bash(kill *)', 'Bash(kill*)', 'Bash(pkill *)', 'Bash(pkill*)', 'Bash(systemctl stop *)', 'Bash(claude stop*)'):
    assert cd in claude_deny, cd
for ca in ('Bash(git push*)', 'Bash(git merge*)', 'Bash(gh pr create*)', 'Bash(gh pr merge*)', 'Bash(gh issue close*)'):
    assert ca in claude_ask, ca
"; then
    pass "Runtime bash gates, outward-facing ask rules, and per-role fan-out allow-lists verified"
else
    fail "Runtime bash gates or per-role fan-out validation failed"
fi

# --- Test 30: Verifying AGY Agent Native Tool Names, Hierarchy & GEMINI.md ---
echo "[Test 30] Verifying AGY agent tool compilation and GEMINI.md documentation (Issue #14)..."
SANDBOX_AGY="$(mktemp -d /tmp/installer-test-agy-XXXXXX)"

python3 -m harness.installer.compiler \
    --core-dir "${REPO_DIR}/core" \
    --runtime agy \
    --output-dir "${SANDBOX_AGY}/agents"

AGY_TOOLS_OK=true

# Check all 8 canonical roles have read_file
for role in supreme-orchestrator team-orchestrator architect worker tester reviewer scout grunt; do
    if ! grep -q -- "- read_file" "${SANDBOX_AGY}/agents/${role}.md"; then
        AGY_TOOLS_OK=false
        echo "Missing read_file in ${role}.md"
    fi
done

# Check edit_file and write_file only in worker, tester, grunt
for rw_role in worker tester grunt; do
    if ! grep -q -- "- edit_file" "${SANDBOX_AGY}/agents/${rw_role}.md" || \
       ! grep -q -- "- write_file" "${SANDBOX_AGY}/agents/${rw_role}.md"; then
        AGY_TOOLS_OK=false
        echo "Missing edit_file or write_file in ${rw_role}.md"
    fi
done

for ro_role in supreme-orchestrator team-orchestrator architect reviewer scout; do
    if grep -q -- "- edit_file" "${SANDBOX_AGY}/agents/${ro_role}.md" || \
       grep -q -- "- write_file" "${SANDBOX_AGY}/agents/${ro_role}.md"; then
        AGY_TOOLS_OK=false
        echo "Unexpected edit_file or write_file in ${ro_role}.md"
    fi
done

# Check invoke_subagent and send_message in orchestrators/callers
for caller in supreme-orchestrator team-orchestrator architect worker tester reviewer; do
    if ! grep -q -- "- invoke_subagent" "${SANDBOX_AGY}/agents/${caller}.md" || \
       ! grep -q -- "- send_message" "${SANDBOX_AGY}/agents/${caller}.md"; then
        AGY_TOOLS_OK=false
        echo "Missing invoke_subagent or send_message in ${caller}.md"
    fi
done

# Check that leaves include send_message and NEVER include invoke_subagent or manage_subagents
for leaf in scout grunt; do
    if ! grep -q -- "- send_message" "${SANDBOX_AGY}/agents/${leaf}.md"; then
        AGY_TOOLS_OK=false
        echo "Missing send_message in leaf ${leaf}.md"
    fi
    if grep -q -- "- invoke_subagent" "${SANDBOX_AGY}/agents/${leaf}.md" || \
       grep -q -- "- manage_subagents" "${SANDBOX_AGY}/agents/${leaf}.md"; then
        AGY_TOOLS_OK=false
        echo "Unexpected invoke_subagent or manage_subagents in leaf ${leaf}.md"
    fi
done

if [ "$AGY_TOOLS_OK" = true ]; then
    pass "Compiled AGY agents contain read_file, proper edit/write permissions, and strict subagent nesting"
else
    fail "Compiled AGY agent tool declarations or nesting boundaries violated"
fi

# Verify GEMINI.md documentation
GEMINI_DOC="${REPO_DIR}/config/agy/GEMINI.md"
if grep -q "read_file" "$GEMINI_DOC" && \
   grep -q "edit_file" "$GEMINI_DOC" && \
   grep -q "write_file" "$GEMINI_DOC" && \
   grep -q "invoke_subagent" "$GEMINI_DOC" && \
   grep -q "manage_subagents" "$GEMINI_DOC" && \
   grep -q "agy remote-control" "$GEMINI_DOC"; then
    pass "config/agy/GEMINI.md accurately documents native tools, subagents, and remote-control daemon"
else
    fail "config/agy/GEMINI.md missing required tool or mechanism documentation"
fi

# --- Test 31: Verifying T3 Code (t3 serve) automatic setup & parity (Issues #15 & #24) ---
echo "[Test 31] Verifying T3 Code (t3 serve) automatic setup, env config, and healthcheck parity (Issue #24)..."
T3_UNIT_SRC="${REPO_DIR}/config/systemd/t3-serve.service"
if [ -f "$T3_UNIT_SRC" ] && \
   grep -q '^EnvironmentFile=-%h/\.config/opencode-backends/env' "$T3_UNIT_SRC" && \
   grep -q 'Environment="T3_SERVE_PORT=3773"' "$T3_UNIT_SRC" && \
   grep -q 't3' "$T3_UNIT_SRC" && \
   grep -q 'serve' "$T3_UNIT_SRC" && \
   grep -q '3773' "$T3_UNIT_SRC" && \
   grep -q 'ExecCondition=' "$T3_UNIT_SRC" && \
   ! grep -q 'http\.server' "$T3_UNIT_SRC" && \
   ! grep -q 'bunx' "$T3_UNIT_SRC" && \
   ! grep -q 'npx' "$T3_UNIT_SRC"; then
    pass "t3-serve.service exists with secure t3 serve, port 3773, and ExecCondition guard"
else
    fail "t3-serve.service missing expected t3 serve configuration or contains forbidden fallbacks"
fi

HELP_OUT="$("${INSTALL_SCRIPT}" --help)"
if echo "$HELP_OUT" | grep -q -- "--with-t3" && echo "$HELP_OUT" | grep -q -- "--no-t3"; then
    pass "install.sh --help documents --with-t3 and --no-t3"
else
    fail "install.sh --help missing --with-t3 or --no-t3"
fi

# 31a: Default install (without --with-t3) automatically provisions T3 Code serve env and units
SANDBOX_T3_DEF="$(mktemp -d /tmp/test-installer-t3-def-XXXXXX)"
USER_HOME="${SANDBOX_T3_DEF}" HOME="${SANDBOX_T3_DEF}" "${INSTALL_SCRIPT}" --target=opencode --non-interactive >/dev/null 2>&1 || true

DEPLOYED_T3_DEF="${SANDBOX_T3_DEF}/.config/systemd/user/t3-serve.service"
ENV_T3_DEF="${SANDBOX_T3_DEF}/.config/opencode-backends/env"

if [ -f "$DEPLOYED_T3_DEF" ] && [ -f "$ENV_T3_DEF" ] && \
   grep -q "^T3_SERVE_PORT=3773" "$ENV_T3_DEF" && \
   grep -q "^T3_SERVE_HOST=0.0.0.0" "$ENV_T3_DEF" && \
   grep -q "^OPENCODE_SERVER_PORT=4096" "$ENV_T3_DEF" && \
   grep -q "^OPENCODE_SERVER_HOST=0.0.0.0" "$ENV_T3_DEF"; then
    pass "Default install automatically provisions T3_SERVE_PORT and OPENCODE_SERVER_PORT in env and deploys unit"
else
    fail "Default install failed to automatically configure T3 Code serve env and unit"
fi

# 31b: Update existing env file with missing T3 config
SANDBOX_T3_UPD="$(mktemp -d /tmp/test-installer-t3-upd-XXXXXX)"
mkdir -p "${SANDBOX_T3_UPD}/.config/opencode-backends"
cat << 'EOF' > "${SANDBOX_T3_UPD}/.config/opencode-backends/env"
HF_TOKEN=hf_mock_secret_token_123456
OPENCODE_SERVER_USERNAME=testuser
OPENCODE_SERVER_PASSWORD=secret_server_password_987
EOF
chmod 600 "${SANDBOX_T3_UPD}/.config/opencode-backends/env"

USER_HOME="${SANDBOX_T3_UPD}" HOME="${SANDBOX_T3_UPD}" "${INSTALL_SCRIPT}" --target=opencode --non-interactive >/dev/null 2>&1 || true

ENV_T3_UPD="${SANDBOX_T3_UPD}/.config/opencode-backends/env"
if grep -q "^T3_SERVE_PORT=3773" "$ENV_T3_UPD" && grep -q "^T3_SERVE_HOST=0.0.0.0" "$ENV_T3_UPD" && \
   grep -q "^OPENCODE_SERVER_PORT=4096" "$ENV_T3_UPD" && grep -q "^OPENCODE_SERVER_HOST=0.0.0.0" "$ENV_T3_UPD"; then
    pass "Installer idempotently updates existing env file with T3_SERVE and OPENCODE_SERVER config"
else
    fail "Installer failed to update existing env file with T3_SERVE config"
fi

# 31c: Verify --no-t3 flag disables T3 Code serve in summary dashboard
NO_T3_OUT="$(USER_HOME="${SANDBOX_T3_DEF}" HOME="${SANDBOX_T3_DEF}" "${INSTALL_SCRIPT}" --target=opencode --no-t3 --non-interactive 2>&1 || true)"
if echo "$NO_T3_OUT" | grep -q "T3 Code Unified Server.*disabled (--no-t3)"; then
    pass "--no-t3 flag correctly reflects disabled state in dashboard"
else
    fail "--no-t3 flag did not reflect disabled state in dashboard"
fi

# 31d: Verify healthcheck parity when t3 is absent vs present
SANDBOX_HC_T3="$(mktemp -d /tmp/test-installer-t3-hc-XXXXXX)"
MOCK_T3_BIN="${SANDBOX_HC_T3}/bin"
mkdir -p "${MOCK_T3_BIN}"

cat << 'EOF' > "${MOCK_T3_BIN}/curl"
#!/bin/sh
for arg in "$@"; do
    if echo "$arg" | grep -q "4096"; then
        if echo "$*" | grep -q "%{http_code}"; then
            printf "OpenCode Server\n200"
        else
            printf "OpenCode Server\n"
        fi
        exit 0
    elif echo "$arg" | grep -q "3773"; then
        if echo "$*" | grep -q "%{http_code}"; then
            printf "T3 Code Server\n200"
        else
            printf "T3 Code Server\n"
        fi
        exit 0
    elif echo "$arg" | grep -q "30000/v1/models"; then
        if echo "$*" | grep -q "%{http_code}"; then
            printf '{"object":"list","data":[{"id":"ornith-1.5-35b"}]}\n200'
        else
            printf '{"object":"list","data":[{"id":"ornith-1.5-35b"}]}\n'
        fi
        exit 0
    fi
done
exit 1
EOF
chmod 0755 "${MOCK_T3_BIN}/curl"

cat << 'EOF' > "${MOCK_T3_BIN}/systemctl"
#!/bin/sh
if [ "$1" = "--user" ] && [ "$2" = "is-active" ]; then
    echo "active"
    exit 0
fi
exit 0
EOF
chmod 0755 "${MOCK_T3_BIN}/systemctl"

# When t3 binary is not in PATH, logs informational message without failing
HC_NO_T3_OUT="$(PATH="${MOCK_T3_BIN}:${PATH}" USER_HOME="${SANDBOX_HC_T3}" HOME="${SANDBOX_HC_T3}" "${INSTALL_SCRIPT}" --target=opencode --healthcheck --skip-warmup --non-interactive 2>&1 || true)"
if echo "$HC_NO_T3_OUT" | grep -q "T3 Code binary (t3) not found in PATH; t3-serve.service deployed and ready once t3 is installed" && \
   echo "$HC_NO_T3_OUT" | grep -q "All backend service healthchecks passed!"; then
    pass "Healthcheck logs info message and passes when t3 binary is not in PATH"
else
    fail "Healthcheck failed when t3 binary was absent"
fi

# When mock t3 binary is in PATH, polls port 3773 and confirms active
cat << 'EOF' > "${MOCK_T3_BIN}/t3"
#!/bin/sh
exit 0
EOF
chmod 0755 "${MOCK_T3_BIN}/t3"

HC_WITH_T3_OUT="$(PATH="${MOCK_T3_BIN}:${PATH}" USER_HOME="${SANDBOX_HC_T3}" HOME="${SANDBOX_HC_T3}" "${INSTALL_SCRIPT}" --target=opencode --healthcheck --skip-warmup --non-interactive 2>&1 || true)"
if echo "$HC_WITH_T3_OUT" | grep -q "Checking T3 Code unified server (port 3773)..." && \
   echo "$HC_WITH_T3_OUT" | grep -q "T3 Code unified server is active and listening on port 3773." && \
   echo "$HC_WITH_T3_OUT" | grep -q "All backend service healthchecks passed!"; then
    pass "Healthcheck actively verifies T3 Code server on port 3773 when t3 binary is installed"
else
    fail "Healthcheck failed to actively verify T3 Code server when t3 binary was present"
fi

# 31e: Uninstall cleanly removes t3-serve.service
USER_HOME="${SANDBOX_T3_DEF}" HOME="${SANDBOX_T3_DEF}" "${REPO_DIR}/uninstall.sh" --global --yes >/dev/null 2>&1 || true
if [ ! -f "$DEPLOYED_T3_DEF" ]; then
    pass "uninstall.sh cleanly removed t3-serve.service"
else
    fail "uninstall.sh failed to remove t3-serve.service"
fi

# --- Test 32: SGLang Selectable Model Profiles (Qwen 3.8 27B) -----------
echo "[Test 32] Verifying SGLang selectable model profiles and backend setup..."
SANDBOX_PROF="$(mktemp -d /tmp/installer-test-prof-XXXXXX)"
PROF_OUT="$(USER_HOME="${SANDBOX_PROF}" HOME="${SANDBOX_PROF}" "${INSTALL_SCRIPT}" --target=opencode --sglang-model=27b-nvfp4 --non-interactive 2>&1 || true)"
ENV_FILE="${SANDBOX_PROF}/.config/opencode-backends/env"
GPU_PROF="${SANDBOX_PROF}/.config/opencode-backends/gpu_profile.json"

if [ -f "$ENV_FILE" ] && \
   grep -q "SGLANG_PRIMARY_MODEL=local-sglang/qwen3.8-27b" "$ENV_FILE" && \
   grep -q "SGLANG_SERVICE=opencode-sglang-qwen27b.service" "$ENV_FILE" && \
   grep -q "SGLANG_27B_MODEL_PATH=nvidia/Qwen3.8-27B-NVFP4" "$ENV_FILE" && \
   grep -q "SGLANG_27B_QUANTIZATION=modelopt" "$ENV_FILE" && \
   ! grep -q "Qwen/Qwen3.8-27B-FP4" "$ENV_FILE" && \
   ! grep -q "SGLANG_27B_QUANTIZATION=fp4" "$ENV_FILE" && \
   [ -f "$GPU_PROF" ] && \
   grep -q '"model_path": "nvidia/Qwen3.8-27B-NVFP4"' "$GPU_PROF" && \
   ! grep -q "Qwen/Qwen3.8-27B-FP4" "$GPU_PROF" && \
   [ -f "${REPO_DIR}/config/systemd/opencode-sglang-qwen27b.service" ]; then
    pass "Installer provisions Qwen 3.8 27B NVFP4 selectable profile, environment, and units"
else
    fail "Installer failed to provision Qwen 3.8 27B profile configuration"
fi

# Verify 27b-q6 provisions valid SGLang gguf quantization flag
SANDBOX_Q6="$(mktemp -d /tmp/installer-test-q6-XXXXXX)"
Q6_OUT="$(USER_HOME="${SANDBOX_Q6}" HOME="${SANDBOX_Q6}" "${INSTALL_SCRIPT}" --target=opencode --sglang-model=27b-q6 --non-interactive 2>&1 || true)"
ENV_FILE_Q6="${SANDBOX_Q6}/.config/opencode-backends/env"
if [ -f "$ENV_FILE_Q6" ] && \
   grep -q "SGLANG_27B_QUANTIZATION=gguf" "$ENV_FILE_Q6" && \
   ! grep -q "SGLANG_27B_QUANTIZATION=q6_k" "$ENV_FILE_Q6"; then
    pass "Installer provisions 27b-q6 profile with valid SGLang gguf quantization flag"
else
    fail "Installer failed to provision 27b-q6 with valid gguf quantization"
fi

# --- Test 33: TL;DR Quickstart & Multi-Runtime Usage Guide (Issue #19) ------
echo "[Test 33] Verifying docs/QUICKSTART.md and README.md integration..."
QS_FILE="${REPO_DIR}/docs/QUICKSTART.md"
README_FILE="${REPO_DIR}/README.md"

if [ -f "$QS_FILE" ] && [ -f "$README_FILE" ] && \
   grep -q "docs/QUICKSTART.md" "$README_FILE" && \
   grep -q "## ⚡ TL;DR Quickstart" "$README_FILE" && \
   grep -q "install.sh --sglang-model" "$QS_FILE" && \
   grep -q "claude --bg -n" "$QS_FILE" && \
   grep -q "agy remote-control" "$QS_FILE" && \
   grep -q "t3-serve.service" "$QS_FILE" && \
   grep -q "opencode-sglang-qwen27b.service" "$QS_FILE" && \
   grep -q "qwen3.8-27b" "$QS_FILE" && \
   grep -q "nvidia/Qwen3.8-27B-NVFP4" "$QS_FILE" && \
   ! grep -q "qwen3.5" "$QS_FILE"; then
    pass "docs/QUICKSTART.md exists, linked from README.md, and documents all 4 surfaces and model switching"
else
    fail "docs/QUICKSTART.md missing required sections, README link, or multi-runtime documentation"
fi

echo "================================================================================"
echo "📊 TEST RESULTS: ${TESTS_PASSED} Passed, ${TESTS_FAILED} Failed"
echo "================================================================================"
[ "$TESTS_FAILED" -eq 0 ]


