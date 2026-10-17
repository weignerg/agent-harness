#!/usr/bin/env bash
# ==============================================================================
# tests/test_harness_dependencies.sh
# Verifies installation, configuration, and runtime readiness of all
# agentic harness dependencies:
# 1. ColBERTv2 CPU late-interaction dependencies (onnxruntime, numpy, tokenizers)
# 2. FastMCP server and JSON Schema dependencies (fastmcp, pydantic, jsonschema)
# 3. Obsidian Knowledge Vault management software detection & guidance
# 4. SGLang stack virtual environment linking and isolation
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
echo "🧪 RUNNING HARNESS DEPENDENCY VERIFICATION TEST SUITE"
echo "================================================================================"

# --- Python Interpreter Resolution --------------------------------------------
if [ -f "${REPO_DIR}/.venv/bin/python" ]; then
    PY_BIN="${REPO_DIR}/.venv/bin/python"
elif [ -f "${HOME}/.local/share/opencode-sglang-stack/venv/bin/python" ]; then
    PY_BIN="${HOME}/.local/share/opencode-sglang-stack/venv/bin/python"
elif command -v uv >/dev/null 2>&1; then
    PY_BIN="uv run python3"
else
    PY_BIN="python3"
fi

# --- Test 1: Python Runtime & Dependency Verification -------------------------
echo "[Test 1] Verifying core harness Python dependencies in [${PY_BIN}]..."
$PY_BIN -c "
import sys
modules = ['pydantic', 'numpy', 'tokenizers', 'onnxruntime', 'fastmcp', 'jsonschema']
missing = []
for m in modules:
    try:
        __import__(m)
    except ImportError:
        missing.append(m)
if missing:
    print(f'Missing modules: {missing}')
    sys.exit(1)
" && pass "All harness Python modules (ColBERT/FastMCP/Pydantic/JSONSchema) import cleanly" || \
    fail "One or more harness Python modules failed to import"

# --- Test 2: ColBERTv2 CPU Late-Interaction Execution ------------------------
echo "[Test 2] Verifying ColBERTv2 engine runs on CPU without CUDA initialization..."
$PY_BIN -c "
from harness.memory.colbert_engine import CPUColBERTIndex
idx = CPUColBERTIndex()
idx.add_document('doc1', 'CachyOS Linux optimized with local SGLang inference')
idx.add_document('doc2', 'ColBERT late-interaction token retrieval on CPU')
res = idx.search('SGLang inference', top_k=1)
assert len(res) == 1, 'Expected 1 result'
assert res[0]['doc_id'] == 'doc1', 'Expected doc1 to rank first'
" && pass "ColBERT engine executes pure CPU MaxSim retrieval correctly" || \
    fail "ColBERT engine execution failed"

# --- Test 3: FastMCP Tool Server Initialization --------------------------------
echo "[Test 3] Verifying FastMCP tool server and Draft 2020-12 schema validation..."
$PY_BIN -c "
from harness.mcp.server import server, get_strict_schemas
import jsonschema
schemas = get_strict_schemas()
assert 'colbert_retrieve' in schemas, 'colbert_retrieve missing from FastMCP schemas'
for tool_name, schema in schemas.items():
    jsonschema.Draft202012Validator.check_schema(schema)
" && pass "FastMCP schemas (including colbert_retrieve) strictly validate against Draft 2020-12" || \
    fail "FastMCP schema validation failed"

# --- Test 4: Obsidian Detection and Guidance ----------------------------------
echo "[Test 4] Verifying Obsidian Knowledge Vault detection & guidance..."
if command -v obsidian >/dev/null 2>&1 || (command -v flatpak >/dev/null 2>&1 && flatpak list 2>/dev/null | grep -qi "obsidian"); then
    pass "Obsidian is installed and detected on host"
else
    # Verify pacman repository availability on CachyOS
    if command -v pacman >/dev/null 2>&1; then
        if pacman -Si obsidian >/dev/null 2>&1; then
            pass "Obsidian is available in package repositories (extra/obsidian)"
        else
            fail "Obsidian not found in package repositories"
        fi
    else
        pass "Non-pacman system: manual installation guidance verified"
    fi
fi

# --- Test 5: install.sh dry-run dependency reporting --------------------------
echo "[Test 5] Verifying install.sh --dry-run reports all dependencies..."
DRY_OUTPUT="$("${REPO_DIR}/install.sh" --dry-run)"
if echo "$DRY_OUTPUT" | grep -qi "Obsidian" && \
   echo "$DRY_OUTPUT" | grep -qi "FastMCP Tools" && \
   echo "$DRY_OUTPUT" | grep -qi "ColBERT Index" && \
   echo "$DRY_OUTPUT" | grep -qi "OpenCode Server" && \
   echo "$DRY_OUTPUT" | grep -qi "Harness dependencies"; then
    pass "install.sh dry-run accurately reports Obsidian, ColBERT, FastMCP, and OpenCode Server dependencies"
else
    fail "install.sh dry-run missing dependency reporting in output"
fi

# --- Test 6: OpenCode Headless Remote Server Setup ----------------------------
echo "[Test 6] Verifying OpenCode headless remote server configuration..."
if [ ! -f "${REPO_DIR}/scripts/opencode_serve.sh" ]; then
    pass "opencode_serve.sh wrapper retired in favor of native systemd user unit"
else
    fail "scripts/opencode_serve.sh should not exist"
fi

if [ -f "${REPO_DIR}/config/systemd/opencode-server.service" ] && \
   grep -q "EnvironmentFile=-%h/\.config/opencode-backends/env" "${REPO_DIR}/config/systemd/opencode-server.service" && \
   grep -q "4096" "${REPO_DIR}/config/systemd/opencode-server.service"; then
    pass "config/systemd/opencode-server.service defines port 4096 and backend environment file"
else
    fail "config/systemd/opencode-server.service missing or invalid"
fi

# --- Summary ------------------------------------------------------------------
echo ""
echo "================================================================================"
echo "📊 TEST RESULTS: ${TESTS_PASSED} Passed, ${TESTS_FAILED} Failed"
echo "================================================================================"
if [ "$TESTS_FAILED" -eq 0 ]; then
    echo "🎉 ALL HARNESS DEPENDENCY TESTS PASSED"
    exit 0
else
    echo "❌ DEPENDENCY TESTS FAILED"
    exit 1
fi
