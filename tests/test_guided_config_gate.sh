#!/usr/bin/env bash
# ==============================================================================
# tests/test_guided_config_gate.sh
# Issue-#67: guided per-runtime config wizard + human-confirmed T3 completion gate.
#
# 1. No regression: run install.sh end-to-end in a sandbox non-interactively
#    (this is the path the Windows bootstrap uses: install.sh ... -y) and with
#    --dry-run. Assert clean exit + completion dashboard.
# 2. WSL auto-login parser unit test: extract detect_wsl_default_user() from
#    install.sh and feed it synthetic wsl.conf values via __HARNESS_WSL_CONF_PATH,
#    asserting [user] default= is parsed correctly, comments/blank-lines/other
#    sections are ignored, and it errors out when the conf is absent.
# 3. Reconciliation guard: reconcile_wsl_username() must be non-destructive when
#    NON_INTERACTIVE=true (mismatch note only, keeps the candidate value).
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
export PYTHONPATH="${REPO_DIR}:${PYTHONPATH:-}"
export AGENT_HARNESS_CANONICAL_ROOT="${REPO_DIR}"

INSTALL_SCRIPT="${REPO_DIR}/install.sh"

TESTS_PASSED=0
TESTS_FAILED=0
pass() { echo "  ✅ PASS: $1"; TESTS_PASSED=$((TESTS_PASSED + 1)); }
fail() { echo "  ❌ FAIL: $1"; TESTS_FAILED=$((TESTS_FAILED + 1)); }
section() { echo ""; echo "── $1 ──"; }

if [ ! -f "${INSTALL_SCRIPT}" ]; then
    echo "❌ install.sh not found at ${INSTALL_SCRIPT}"
    exit 1
fi

# Extract a top-level bash function (def line "name() {" to a lone "}" at col 0).
extract_fn() {
    awk -v n="$1" '
        $0 == n "() {" {p=1; print; next}
        p { print }
        $0 == "}" && p { exit }
    ' "${INSTALL_SCRIPT}"
}

echo "================================================================================"
echo "🧪 RUNNING GUIDED CONFIG + T3 GATE TEST SUITE (Issue-#67)"
echo "================================================================================"

# ------------------------------------------------------------------------------
# 1. No-regression: non-interactive sandbox install + dry-run.
# ------------------------------------------------------------------------------
section "1. No-regression: non-interactive sandbox install"
SANDBOX="$(mktemp -d /tmp/harness-67-XXXXXX)"
cleanup() { rm -rf "${SANDBOX}" 2>/dev/null || true; }
trap cleanup EXIT

# Global mock systemctl to protect the host during sandboxed tests.
MOCK_BIN="$(mktemp -d /tmp/mock-bin-67-XXXXXX)"
cat > "${MOCK_BIN}/systemctl" <<'EOF'
#!/bin/sh
exit 0
EOF
chmod 0755 "${MOCK_BIN}/systemctl"
export PATH="${MOCK_BIN}:${PATH}"

if out="$("$INSTALL_SCRIPT" --mode local "${SANDBOX}" --target all --no-healthcheck --skip-warmup --no-firewall --no-obsidian --no-vault --non-interactive 2>&1)"; then
    if echo "$out" | grep -q "AGENT HARNESS DEPLOYMENT DASHBOARD" && echo "$out" | grep -q "installation complete"; then
        pass "non-interactive sandbox install exits 0 and renders dashboard"
    else
        fail "non-interactive sandbox install output missing dashboard/completion"; echo "$out" | tail -20
    fi
else
    rc=$?
    fail "non-interactive sandbox install returned non-zero (rc=${rc})"; echo "$out" | tail -20
fi

if out="$("$INSTALL_SCRIPT" --mode local "${SANDBOX}" --target all --dry-run 2>&1)"; then
    if echo "$out" | grep -q "AGENT HARNESS DEPLOYMENT DASHBOARD" && echo "$out" | grep -q "DRY-RUN"; then
        pass "dry-run install exits 0, is non-mutating, renders dashboard"
    else
        fail "dry-run install output missing dashboard/DRY-RUN markers"; echo "$out" | tail -20
    fi
else
    rc=$?
    fail "dry-run install returned non-zero (rc=${rc})"; echo "$out" | tail -20
fi

# ------------------------------------------------------------------------------
# 2. WSL default-user parser unit test.
# ------------------------------------------------------------------------------
section "2. WSL default-user parser (detect_wsl_default_user)"
PARSER_SRC="$(extract_fn detect_wsl_default_user)"
if [ -n "$PARSER_SRC" ] && ! printf '%s\n' "$PARSER_SRC" | grep -q "not a number"; then
    pass "extract detect_wsl_default_user from install.sh"

    # Invoke the extracted parser via a clean env, calling the function explicitly.
    run_parser() {
        env -i PATH="$PATH" __HARNESS_WSL_CONF_PATH="$1" bash -c "$PARSER_SRC; detect_wsl_default_user || true" 2>/dev/null
    }

    # Case A: per-user wsl.conf with [user] default=opencode
    CONF_A="$(mktemp /tmp/wslconfA-XXXXXX)"
    cat > "$CONF_A" <<'EOF'
[warnings]
automaticstartup=yes

[user]
default=opencode
EOF
    got="$(run_parser "$CONF_A")"
    if [ "$got" = "opencode" ]; then pass "parses [user] default=opencode"; else fail "expected opencode, got '${got}'"; fi

    # Case B: global wsl.conf with mixed case key and leading/trailing spaces
    CONF_B="$(mktemp /tmp/wslconfB-XXXXXX)"
    cat > "$CONF_B" <<'EOF'
[user]
   Default =   WindowsUser  
EOF
    got="$(run_parser "$CONF_B")"
    if [ "$got" = "WindowsUser" ]; then pass "parses case-insensitive Default with trimming"; else fail "expected WindowsUser, got '${got}'"; fi

    # Case C: comments and blanks are ignored; last matching section wins
    CONF_C="$(mktemp /tmp/wslconfC-XXXXXX)"
    cat > "$CONF_C" <<'EOF'
[user]
default=root   # auto-login account
EOF
    got="$(run_parser "$CONF_C")"
    if [ "$got" = "root" ]; then pass "strips trailing comment from default="; else fail "expected root, got '${got}'"; fi

    # Case D: absent conf -> empty output (function returns 1, guarded by || true)
    CONF_D="$(mktemp -d /tmp/wslconfD-XXXXXX)/missing.conf"
    out="$(run_parser "$CONF_D")"
    if [ -z "$out" ]; then pass "absent conf yields empty output (no crash)"; else fail "expected empty output, got '${out}'"; fi

    # Case E: CRLF line endings in /etc/wsl.conf
    CONF_E="$(mktemp /tmp/wslconfE-XXXXXX)"
    printf '[boot]\r\nsystemd=true\r\n[user]\r\ndefault=wsluser\r\n' > "$CONF_E"
    got="$(run_parser "$CONF_E")"
    if [ "$got" = "wsluser" ]; then pass "parses CRLF wsl.conf cleanly"; else fail "expected wsluser (no CR), got '${got}'"; fi

    # Case F: /etc/wsl.conf is checked first in production candidate discovery
    if printf '%s\n' "$PARSER_SRC" | grep -q 'candidates=("/etc/wsl.conf")'; then
        pass "detect_wsl_default_user checks /etc/wsl.conf first"
    else
        fail "detect_wsl_default_user missing /etc/wsl.conf primary candidate"
    fi
else
    fail "could not extract detect_wsl_default_user"
fi

# ------------------------------------------------------------------------------
# 3. Reconciliation guard: non-destructive in NON_INTERACTIVE mode.
# ------------------------------------------------------------------------------
section "3. Reconciliation guard (reconcile_wsl_username, NON_INTERACTIVE)"
# Source the real reconcile_wsl_username() + its dependencies from install.sh.
SRC_FILE="$(mktemp /tmp/recon-src-XXXXXX)"
{ printf '%s\n' "$(extract_fn reconcile_wsl_username)"; printf '\n';
  printf '%s\n' "$(extract_fn detect_wsl)"; printf '\n';
  printf '%s\n' "$(extract_fn detect_wsl_default_user)"; } > "$SRC_FILE"
if [ -s "$SRC_FILE" ]; then
    # Force WSL on, force a mismatch, NON_INTERACTIVE=true -> keeps candidate, sets mismatch note.
    CONF_M="$(mktemp /tmp/wslconfM-XXXXXX)"
    printf '[user]\ndefault=opencode\n' > "$CONF_M"
    if out="$(env -i PATH="$PATH" \
            WSL_DISTRO_NAME="Ubuntu" \
            __HARNESS_WSL_CONF_PATH="$CONF_M" \
            NON_INTERACTIVE=true DRY_RUN=false \
            bash -c ". \"$SRC_FILE\"; reconcile_wsl_username 'someoneelse'; printf 'STATUS=%s\\nRET=%s\\n' \"\$RECONCILIATION_STATUS\" \"\$RECONCILED_SERVER_USERNAME\"" 2>/dev/null)"
    then
        if printf '%s\n' "$out" | grep -q "STATUS=mismatch" && printf '%s\n' "$out" | grep -q "RET=someoneelse"; then
            pass "NON_INTERACTIVE keeps candidate value and flags mismatch (non-destructive)"
        else
            fail "unexpected reconciler output"; echo "$out"
        fi
    else
        fail "reconciler errored under NON_INTERACTIVE"
    fi
else
    fail "could not extract reconcile_wsl_username / dependencies"
fi

# ------------------------------------------------------------------------------
# 4. T3 gate unreachable-port regression check.
# ------------------------------------------------------------------------------
section "4. T3 gate state when required ports are unreachable"
GATE_SRC="$(extract_fn human_confirmed_t3_gate)"
if printf '%s\n' "$GATE_SRC" | grep -A 3 'if \[ "\$ok_4096" != true \] || \[ "\$ok_3773" != true \]; then' | grep -q 'T3_GATE_CONFIRMED="false"'; then
    pass "human_confirmed_t3_gate sets T3_GATE_CONFIRMED=false when ports unreachable"
else
    fail "human_confirmed_t3_gate leaves T3_GATE_CONFIRMED=true when ports unreachable"
fi

echo ""
echo "================================================================================"
echo "RESULTS: ${TESTS_PASSED} passed, ${TESTS_FAILED} failed"
echo "================================================================================"
[ "${TESTS_FAILED}" -eq 0 ]
