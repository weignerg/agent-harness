#!/usr/bin/env bash
# ==============================================================================
# scripts/scaffold_subvault.sh
# Scaffolds a repository sub-vault and registers it with Obsidian & ColBERT.
#
# Usage:
#   scripts/scaffold_subvault.sh [<repo_path>]
#
# Actions:
#   1. Creates <repo>/vault/ and <repo>/.orchestration/memory/ with standard subdirs
#   2. Populates starter templates (overview.md, workflow.md, 0001-baseline.md)
#   3. Safely auto-registers <repo>/vault in ~/.config/obsidian/obsidian.json
#   4. Symlinks <repo>/vault to ~/Vaults/repos/<repo_name>
#   5. Runs initial indexing via scripts/reindex_vault.sh
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

TARGET_REPO="${1:-$(pwd)}"
if [ ! -d "$TARGET_REPO" ]; then
    echo "❌ Error: Target repository path does not exist: ${TARGET_REPO}" >&2
    exit 1
fi

TARGET_REPO="$(cd "$TARGET_REPO" && pwd)"
REPO_NAME="$(basename "$TARGET_REPO")"
USER_HOME="${USER_HOME:-${HOME}}"

SUBVAULT="${TARGET_REPO}/vault"
ORCH_MEM="${TARGET_REPO}/.orchestration/memory"

echo "================================================================================"
echo "📚 SCAFFOLDING REPOSITORY SUB-VAULT: ${REPO_NAME}"
echo "   Target Path   : ${TARGET_REPO}"
echo "   Vault Dir     : ${SUBVAULT}"
echo "   Orchestration : ${ORCH_MEM}"
echo "================================================================================"

# 1. Create standard subdirectories
SUBDIRS=("entities" "decisions" "protocols" "projects" ".obsidian" ".index")
for sd in "${SUBDIRS[@]}"; do
    mkdir -p "${SUBVAULT}/${sd}"
    mkdir -p "${ORCH_MEM}/${sd}"
done

# 2. Populate starter templates
DATE_STAMP="$(date +%Y-%m-%d)"

# overview.md
if [ ! -f "${SUBVAULT}/overview.md" ]; then
    cat << EOF > "${SUBVAULT}/overview.md"
# ${REPO_NAME} Knowledge Vault Overview

## Executive Summary
This repository sub-vault anchors architectural memory, component registries, design decisions, and standing protocols for **${REPO_NAME}**.

## Sub-Vault Navigation
- **Entities** (\`entities/\`): Architectural domains, services, data models, and component boundaries.
- **Decisions** (\`decisions/\`): Architectural Decision Records (ADRs) capturing rationale and trade-offs.
- **Protocols** (\`protocols/\`): Operational runbooks, release procedures, and hygiene checklists.
- **Projects** (\`projects/\`): Cross-milestone roadmaps, initiatives, and implementation plans.
- **Index** (\`.index/\`): ColBERTv2 CPU semantic memory vector index for MaxSim retrieval.
EOF
    echo "  ✅ Created ${SUBVAULT}/overview.md"
fi

# workflow.md
if [ ! -f "${SUBVAULT}/workflow.md" ]; then
    cat << EOF > "${SUBVAULT}/workflow.md"
# ${REPO_NAME} Agent Teams & Git Workflow Protocol

## 1. Worktree Isolation & Branch Governance
- All implementation and refactoring work occurs strictly in isolated worktrees: \`.orchestration/worktrees/<branch>\`.
- The repository root remains anchored on \`develop\` or primary integration branch.
- Branch naming follows \`feat/<issue-id>-<slug>\`, \`fix/<issue-id>-<slug>\`, or \`chore/<issue-id>-<slug>\`.

## 2. Polymorphic Multi-Agent Hierarchy
- **Supreme Orchestrator**: Root governance, user communication, charter enforcement. Read-only.
- **Team Orchestrator**: Per-issue lead, worktree provisioning, subagent delegation. Read-only.
- **Architect**: System survey, codebase analysis, refactor blueprints. Read-only.
- **Worker**: Test-Driven Development (TDD), discrete implementation, conventional commits.
- **Reviewer**: Adversarial code audit, security gates, mock illusion detection. Read-only.
- **Tester**: Two-stage verification, regression reproduction, behavioral auditing.
EOF
    echo "  ✅ Created ${SUBVAULT}/workflow.md"
fi

# decisions/0001-baseline.md
if [ ! -f "${SUBVAULT}/decisions/0001-baseline.md" ]; then
    cat << EOF > "${SUBVAULT}/decisions/0001-baseline.md"
# ADR 0001: Baseline Repository Architecture & Memory Standards

- **Status**: Accepted
- **Date**: ${DATE_STAMP}
- **Deciders**: Autonomous Agent Teams & Engineering Lead

## Context
Standardized knowledge management and late-interaction vector retrieval require structured repository-local documentation synchronized with the central Obsidian knowledge vault.

## Decision
1. Establish a dedicated repository sub-vault under \`vault/\` mirrored in \`.orchestration/memory/\`.
2. Symlink \`vault/\` to \`~/Vaults/repos/${REPO_NAME}\` for unified Obsidian desktop access.
3. Automatically index markdown assets using ColBERTv2 CPU MaxSim indexing via \`scripts/reindex_vault.sh\`.

## Consequences
- High-fidelity context injection available to local agents via FastMCP \`colbert_retrieve\`.
- Zero context pollution between independent repositories.
EOF
    echo "  ✅ Created ${SUBVAULT}/decisions/0001-baseline.md"
fi

# Synchronize templates to .orchestration/memory
cp -u "${SUBVAULT}/overview.md" "${ORCH_MEM}/overview.md" 2>/dev/null || cp "${SUBVAULT}/overview.md" "${ORCH_MEM}/overview.md"
cp -u "${SUBVAULT}/workflow.md" "${ORCH_MEM}/workflow.md" 2>/dev/null || cp "${SUBVAULT}/workflow.md" "${ORCH_MEM}/workflow.md"
cp -u "${SUBVAULT}/decisions/0001-baseline.md" "${ORCH_MEM}/decisions/0001-baseline.md" 2>/dev/null || cp "${SUBVAULT}/decisions/0001-baseline.md" "${ORCH_MEM}/decisions/0001-baseline.md"

# 3. Auto-register in ~/.config/obsidian/obsidian.json safely
python3 - "${SUBVAULT}" "${USER_HOME}" << 'PYEOF'
import sys, os, json, hashlib, time
from pathlib import Path

vault_path = sys.argv[1]
user_home = sys.argv[2]
obsidian_cfg_dir = Path(user_home) / ".config" / "obsidian"
obsidian_cfg = obsidian_cfg_dir / "obsidian.json"

try:
    obsidian_cfg_dir.mkdir(parents=True, exist_ok=True)
    data = {"vaults": {}}
    if obsidian_cfg.is_file():
        try:
            data = json.loads(obsidian_cfg.read_text(encoding="utf-8"))
        except Exception:
            data = {"vaults": {}}
    
    vaults = data.setdefault("vaults", {})
    already_registered = any(v.get("path") == vault_path for v in vaults.values())
    if not already_registered:
        v_id = hashlib.md5(vault_path.encode("utf-8")).hexdigest()[:16]
        vaults[v_id] = {
            "path": vault_path,
            "ts": int(time.time() * 1000),
            "open": False
        }
        obsidian_cfg.write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")
        print(f"  ✅ Registered {vault_path} in {obsidian_cfg}")
    else:
        print(f"  ℹ️  Sub-vault already registered in {obsidian_cfg}")
except Exception as e:
    print(f"  ⚠️  Notice: Could not update obsidian.json ({e})")
PYEOF

# 4. Symlink <repo>/vault into ~/Vaults/repos/<repo_name>
REPOS_VAULT_DIR="${USER_HOME}/Vaults/repos"
mkdir -p "${REPOS_VAULT_DIR}"
ln -sfn "${SUBVAULT}" "${REPOS_VAULT_DIR}/${REPO_NAME}"
echo "  🔗 Symlinked ${SUBVAULT} -> ${REPOS_VAULT_DIR}/${REPO_NAME}"

# 5. Trigger initial indexing via scripts/reindex_vault.sh
if [ -x "${REPO_DIR}/scripts/reindex_vault.sh" ]; then
    echo "  🔍 Generating initial ColBERT index for ${SUBVAULT}..."
    "${REPO_DIR}/scripts/reindex_vault.sh" "${SUBVAULT}"
fi

echo "================================================================================"
echo "🎉 SUB-VAULT READY: ${SUBVAULT}"
echo "   Obsidian Vault : ${REPOS_VAULT_DIR}/${REPO_NAME}"
echo "   Vector Index   : ${SUBVAULT}/.index/index.json"
echo "================================================================================"
