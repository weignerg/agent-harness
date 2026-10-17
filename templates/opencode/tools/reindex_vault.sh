#!/usr/bin/env bash
# ==============================================================================
# scripts/reindex_vault.sh
# Scheduled & on-demand ColBERTv2 semantic memory vault reindexer.
# Runs strictly on host CPU with zero VRAM allocation.
#
# Usage:
#   reindex_vault.sh                 # reindex every location (home + all repos)
#   reindex_vault.sh --all           # same as the default
#   reindex_vault.sh <path> [<path>] # reindex specific vault/location(s)
#
# Each location's index is written to its own <path>/.index/index.json.
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Resolve the repository root by locating the ColBERT engine, with a fallback.
REPO_DIR="${ENGINE_REPO:-}"
if [ -z "$REPO_DIR" ]; then
    dir="$SCRIPT_DIR"
    while [ "$dir" != "/" ] && [ ! -f "${dir}/harness/memory/colbert_engine.py" ]; do
        dir="$(cd "${dir}/.." 2>/dev/null && pwd || echo "${dir}/..")"
    done
    if [ -f "${dir}/harness/memory/colbert_engine.py" ]; then
        REPO_DIR="$dir"
    fi
fi
if [ -z "$REPO_DIR" ]; then
    REPO_DIR="$(cd "${SCRIPT_DIR}/.." 2>/dev/null && pwd || echo "${HOME}/.config/opencode-backends/repo")"
fi

USER_HOME="${USER_HOME:-${HOME}}"
STACK_DIR="${USER_HOME}/.local/share/opencode-sglang-stack"
TARGET_PY="${STACK_DIR}/venv/bin/python"
if [ ! -f "$TARGET_PY" ]; then
    TARGET_PY="python3"
fi

INDEX_HOME="${USER_HOME}/Vaults/home"
INDEX_REPOS="${USER_HOME}/Vaults/repos"

# Repo vault as a fallback so the timer/CLI still index something on hosts
# that have not yet migrated to the multi-vault layout.
REPO_VAULT_DIR="${REPO_DIR}/vault"

# Print a single location's reindex result.
reindex_location() {
    local loc="${1%/}"
    if [ ! -d "$loc" ]; then
        echo "  - skipping missing location: ${loc}" >&2
        return 0
    fi

    # Skip a location that carries no documents so a stale .index dir does not
    # masquerade as a valid, indexed vault.
    if [ -z "$(cd "$loc" && find . -type f -name '*.md' -not -path '*/.*' 2>/dev/null)" ]; then
        echo "  - skipping empty location: ${loc}"
        return 0
    fi

    PYTHONPATH="${REPO_DIR}" "$TARGET_PY" -c "
import time, sys
from pathlib import Path

try:
    from harness.memory.colbert_engine import CPUColBERTIndex
    v = Path('${loc}')
    t0 = time.time()
    idx = CPUColBERTIndex(index_dir=v / '.index')
    count = 0
    for md in v.rglob('*.md'):
        if not any(p.startswith('.') for p in md.relative_to(v).parts):
            try:
                rel = str(md.relative_to(v))
                idx.add_document(rel, md.read_text(errors='replace'))
                count += 1
            except Exception:
                pass
    idx.save()
    dt = time.time() - t0
    print(f'✅ Successfully reindexed {count} documents in {dt:.2f}s -> ${loc}/.index/index.json')
except Exception as e:
    print(f'❌ ColBERT reindexing error: {e}', file=sys.stderr)
    sys.exit(1)
"
}

MODE="all"
targets=()
for arg in "$@"; do
    case "$arg" in
        --all) continue ;;
        --help|-h)
            sed -n '2,11p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *) targets+=("$arg") ;;
    esac
done

if [ "${#targets[@]}" -gt 0 ]; then
    MODE="target"
fi

if [ "$MODE" = "target" ]; then
    for t in "${targets[@]}"; do
        reindex_location "$t"
    done
    exit 0
fi

# Default: reindex every known location.
echo "== home vault (${INDEX_HOME}) =="
reindex_location "${INDEX_HOME}"

reindex_any=0
if [ -d "$INDEX_HOME" ] || [ -d "$INDEX_REPOS" ]; then
    for repo in "${INDEX_REPOS}"/*/; do
        [ -d "$repo" ] || continue
        name="$(basename "$repo")"
        echo "-- source sub-vault: ${name} --"
        reindex_location "$repo"
        reindex_any=1
    done
fi

# Fall back to the repo vault only when the multi-vault layout is absent, so
# the hourly timer never fails on a not-yet-migrated host.
if [ ! -d "${INDEX_HOME}" ] && [ ! -d "${INDEX_REPOS}" ] && [ -d "$REPO_VAULT_DIR" ]; then
    echo "== repo vault fallback (${REPO_VAULT_DIR}) =="
    reindex_location "$REPO_VAULT_DIR"
fi

echo "done"
