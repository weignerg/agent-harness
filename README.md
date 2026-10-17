# agent-harness

Canonical unified agent harness providing polymorphic memory, dynamic runtime engine adapters, and harness-agnostic orchestration.

[![License](https://img.shields.io/badge/License-AGPL_3.0-blue.svg)](LICENSE)
[![Python](https://img.shields.io/badge/python-3.11+-blue.svg)](pyproject.toml)
[![Architecture](https://img.shields.io/badge/architecture-polymorphic-green.svg)](docs/unified_architecture.md)

---

## Architecture Overview

`agent-harness` unifies multi-engine agent orchestration under a single canonical repository, eliminating fragmentation across host environments while preserving runtime-specific optimizations.

```
agent-harness/
├── harness/                      # Canonical Python package
│   ├── memory/                   # Polymorphic memory, context anchoring & handoffs
│   ├── runtime/                  # Dynamic runtime engine adapters (agy, claude, opencode)
│   ├── mcp/                      # FastMCP servers (vault, worktree, tool runner)
│   ├── orchestrator/             # State machine, routing, escalation & recovery
│   └── security/                 # Red team perimeter, secret broker
├── templates/
│   ├── shared/                   # Canonical rules & skills across all engines
│   │   ├── rules/                # agent-teams.md, code-quality.md, git-workflow.md, process-safety.md
│   │   └── skills/               # 7 canonical skills (adversarial-review, context-anchoring, etc.)
│   ├── agy/                      # Google Antigravity manifest & Gemini 3.8 profiles
│   ├── claude/                   # Claude Code agent profiles & JSON settings
│   └── opencode/                 # OpenCode agents, slash commands, opencode.json & themes
├── scripts/                      # Autonomous operational tools (worktree_manager, tdd_pipeline, etc.)
├── config/                       # Systemd units, sysctl performance tunings, model catalogs
├── vault/                        # Obsidian-compatible entity knowledge vault
├── docs/                         # System and inference architecture documentation
└── tests/                        # Consolidated unit and integration test suite
```

---

## Supported Runtime Engines

| Runtime | Adapter | Models & Inference Tiers | Primary Config Root |
| :--- | :--- | :--- | :--- |
| **Google Antigravity** | `AgyRuntimeAdapter` | Official Gemini 3.8 (`high`: pro, `medium`: flash, `low`: flash_lite) | `~/.gemini/config/plugins/agy-harness` |
| **Claude Code** | `ClaudeRuntimeAdapter` | Anthropic Claude (`opus`, `sonnet`, `haiku`) | `~/.claude` |
| **OpenCode** | `OpenCodeRuntimeAdapter` | Local SGLang inference (Llama 3.3 70B, Gemma 4 31B/26B NVFP4) | `~/.config/opencode` |

---

## Harness-Agnostic Runtime Directory (`.orchestration/`)

All execution traces, handoffs, isolated worktrees, and memory indexes are standardized under `.orchestration/`:

- `.orchestration/handoffs/`: Inter-session handoff checkpoints (`TASK_HANDOFF_*.md`).
- `.orchestration/memory/`: Semantic memory index and ColBERTv2 database embeddings.
- `.orchestration/worktrees/`: Isolated git worktrees for tasks (`<branch>`).
- `.orchestration/logs/`: Execution traces and diagnostics.
- `.orchestration/tmp/`: Ephemeral scratchpads.

---

## Branch Governance & Worktree Isolation

1. **Branch Governance (`release` vs `develop`)**:
   - `release`: Stable release default branch.
   - `develop`: Active integration branch (must remain checked out in local repository root).
   - All feature/fix branches branch off `develop` and all PRs target `develop`.
2. **Worktree Isolation**: All task implementation occurs in isolated git worktrees (`.orchestration/worktrees/<branch>`) provisioned via `scripts/worktree_manager.py`.
3. **Two-Key Merge Gate**:
   - **Key 1**: Independent `reviewer` adversarial verification pass with 100% test pass.
   - **Key 2**: Explicit human sovereign approval (`Approved :heavy_check_mark:`).

---

## Installation

### Global Deployment (User Environment)
```bash
# Deploy Antigravity (Gemini 3.8) plugin & tools (default)
./install.sh --target=agy

# Deploy Claude Code agents & settings
./install.sh --target=claude

# Deploy OpenCode configurations & commands
./install.sh --target=opencode

# Deploy all supported runtimes
./install.sh --target=all
```

### Local Repository Deployment
```bash
./install.sh --local /path/to/target-repo
```

---

## Verification & Testing

Run the full consolidated test suite:
```bash
python3 -m unittest discover -s tests
```
