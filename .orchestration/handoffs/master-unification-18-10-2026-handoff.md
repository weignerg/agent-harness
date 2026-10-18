# Master Unification Handoff: Universal Multi-Runtime Agent Harness (`agent-harness`)

- **Date**: 2026-10-18
- **Repository**: `agent-harness` (Canonical Root)
- **Current Branch**: `develop`
- **Release Status**: `v0.1.0` tagged on `release` (`24bbbd4`)
- **Merge Status**: Issue #1 and Issue #2 merged into `develop` via formal GitHub PR workflow

---

## 1. Executive Summary & Unification Initiative

The **Agent Harness Unification Initiative** successfully consolidates and deduplicates three historically fragmented, CLI-specific harnesses into a single, canonical, multi-runtime agent harness: `agent-harness`.

Prior to this initiative, agent capabilities, subagent definitions, memory adapters, and tooling were dispersed across:
- `open-code-harness` (reference repo: OpenCode CLI & local SGLang stack)
- `claude-harness` (reference repo: Anthropic Claude Code CLI)
- `agy-harness` (reference repo: Google Antigravity CLI)

This divergence resulted in duplicated configuration logic, drift in agent charters, and separate installation lifecycles. The unified `agent-harness` establishes a **single source of truth** for multi-agent workflows, serving Antigravity CLI (`agy`), Claude Code (`claude`), and OpenCode (`opencode`) through a shared canonical core (`harness/`), modular deployment templates (`templates/`), and a deterministic, manifest-backed universal installer (`install.sh`).

---

## 2. Four Architectural Pillars

### Pillar 1: `.orchestration/` Canonical Convention
- **Single Source of Truth**: Replaced conflicting runtime directories with a standardized `.orchestration/` root in the canonical repository.
- **Unified Structure**:
  - `.orchestration/handoffs/`: Canonical home for inter-session handoffs and phase deliverables.
  - `.orchestration/worktrees/`: Isolated per-issue and per-agent worktree namespaces.
  - `.orchestration/memory/`: Persistent sqlite state, ColBERT index storage, and runtime metrics.
  - `.orchestration/logs/`: Standardized execution and audit trails.
- **Host Repository Cleanliness**: The repository `.gitignore` strictly blocks runtime-installed directories (`.agents/`, `.claude/`, `.opencode/`, `AGENTS.md`, `CLAUDE.md`, `GEMINI.md`) while explicitly whitelisting `.orchestration/handoffs/` and templates, ensuring no active agent state is inadvertently committed to the core codebase.

### Pillar 2: Polymorphic Memory & Context Anchoring
- **Runtime-Agnostic Context Anchors**: Implemented `harness.memory.context_anchor.ContextAnchorInjector`, which detects the target CLI and injects appropriate memory and rule anchors (`GEMINI.md` for Antigravity, `CLAUDE.md` for Claude Code, `AGENTS.md` for OpenCode).
- **Polymorphic Handoffs**: `harness.memory.handoff.TaskHandoff` writes canonical handoffs into `.orchestration/handoffs/` while maintaining compatibility with legacy agent tooling.
- **ColBERTv2 Retrieval Engine**: Fast CPU-bound MaxSim vector search engine (`harness.memory.colbert_engine.ColBERTEngine`) delivering deterministic sub-millisecond retrieval across markdown knowledge vaults without GPU or CUDA initialization dependencies.
- **Secure Secret Brokering**: Zero-plaintext secret broker (`harness.security.secret_broker.SecretBroker`) managing HuggingFace tokens and server credentials with strict `0600` permissions.

### Pillar 3: Plug-and-Play Runtime Adapters
- **Modular Templates**:
  - `templates/agy/`: Antigravity plugin manifest, agent charters (Gemini 3.8 High/Medium/Low tier assignments), rules, skills, and tools.
  - `templates/claude/`: Claude Code subagent definitions, memory rules, and MCP configurations.
  - `templates/opencode/`: OpenCode provider configuration, local Ornith-35B-NVFP4 model parameters, and 10-component configuration hierarchy.
- **FastMCP & Schema Compliance**: FastMCP servers in `harness/mcp/` strictly conform to JSONSchema Draft 2020-12, exposing validated tool runners (`audit_logger`, `tool_runner`, `vault_server`, `worktree_server`).
- **Unified Subagent Tiering**: Consistent 8-agent hierarchy (`supreme-orchestrator`, `team-orchestrator`, `architect`, `worker`, `tester`, `reviewer`, `scout`, `grunt`) mapped across each runtime's model tiers.

### Pillar 4: Atomic Manifest Installer & Rollback Engine
- **Universal Multi-Target Routing**: `install.sh` accepts `--target [agy|claude|opencode|all]` and `--mode [global|local]`, deploying tailored configurations while routing all runtimes to the canonical core.
- **Cryptographic SHA-256 Manifest**: `harness.installer.manifest.ManifestEngine` deterministically hashes and records every installed file, directory, and symlink into `.orchestration/install_manifest.json`.
- **Integrity Verification**: Standalone `--verify` command inspects live filesystem state against manifest checksums to catch tampering, missing assets, or drift.
- **Safe Rollback Engine**: `uninstall.sh` leverages the manifest to cleanly remove harness assets while strictly safeguarding user-modified files, restoring pre-existing configuration backups (`settings.json.pre-harness.bak` and `.agents.pre-harness.bak`), and pruning only empty directories.
- **Trailing Newline Safety**: Robust `.gitignore` patcher detects missing trailing newlines before appending harness ignore rules, preventing line truncation or corruption.

---

## 3. Git History on `develop`

The `develop` branch incorporates all unified core developments and installer implementations:

| Commit Hash | Type | Summary |
|-------------|------|---------|
| `642ec86` | merge | `Merge pull request #1 from feat/master-installer` |
| `4abbe61` | docs | `docs(handoff): add session handoff for Issue #2 master universal installer` |
| `bcc1109` | fix | `fix(installer): safeguard user files and pre-existing settings during uninstall` |
| `105afa3` | feat | `feat(installer): Issue-#2 implement Master Universal Installer and Multi-CLI distribution with Atomic Manifest engine` |
| `cd31313` | docs | `docs(handoff): add session handoff for GitHub remote setup and v0.1.0 release` |
| `24bbbd4` | chore | `chore(release): bump version to 0.1.0 for initial release` (tagged `v0.1.0` on `release`) |
| `0c7bb62` | docs | `docs(handoff): add session handoff for Issue #1 unified canonical core` |
| `45dc407` | fix | `fix(review): resolve Pass 1 review findings for unified core and templates` |
| `7b85335` | feat | `feat(runtime): Issue-#1 add plug-and-play runtime adapters and polymorphic memory` |
| `7fca8c5` | feat | `feat(core): Issue-#1 initialize unified canonical agent-harness structure` |
| `5edf349` | chore | `chore: initial commit on release` |

---

## 4. Test Verification Summary

Both the Python test suite and the shell regression suites pass with 100% compliance:

### Python Unit Test Suite (`unittest`)
- **Command**: `python3 -m unittest discover tests`
- **Result**: `Ran 144 tests in 9.490s — OK (skipped=8, failures=0, errors=0)`
- **Coverage**:
  - `tests/test_universal_installer.py`: 12 integration tests verifying target routing, global/local modes, manifest generation, cryptographic verification, user file preservation, and backup restoration.
  - `tests/test_agy_harness.py`: 13 tests verifying Antigravity plugin manifest, agent charters, skills, and process safety rules.
  - `tests/test_claude_harness.py`: 8 tests verifying Claude Code configuration, model definitions, and settings merging.
  - `tests/test_colbert_engine.py`: CPU-based MaxSim vector retrieval validation.
  - `tests/test_context_anchor.py`: Polymorphic rule and memory injection validation.
  - `tests/test_handoff.py`: Handoff serialization, directory resolution, and persistence.
  - `tests/test_mcp_server.py`, `tests/test_tool_runner.py`: FastMCP server lifecycles, execution, and JSONSchema Draft 2020-12 compliance.
  - `tests/test_state_machine.py`, `tests/test_secret_broker.py`, `tests/test_recovery.py`, `tests/test_perimeter.py`, `tests/test_router.py`, `tests/test_worktree_manager.py`: Core harness security, routing, state transitions, and workspace isolation.

### Shell Regression Suites (11 Suites)
- **Status**: 11/11 Suites Passing (100% Pass Rate)
  1. `tests/test_installer_features.sh` — 22/22 Passed (Flag parsing, sandbox manifest, ColBERT document reporting, multi-runtime deployment, vault schemas).
  2. `tests/test_uninstall_script.sh` — 10/10 Passed (Flag validation, dry-run simulation, standard uninstall, legacy fallback, scoped unit pruning, --purge).
  3. `tests/test_systemd_units.sh` — 5/5 Passed (21 user units verified, zero forbidden HF_TOKEN overrides, EnvironmentFile syntax, section structure).
  4. `tests/test_sglang_service.sh` — 18/18 Passed (NVFP4 model path, 256k context floor, loopback binding, tool-call parsers).
  5. `tests/test_opencode_launchers.sh` — 9/9 Passed (Retirement of external bash wrappers, clean ~/.local/bin pruning, native in-session agent dispatch).
  6. `tests/test_oom_watchdog.sh` — 11/11 Passed (Context degradation from 262144 down to 32k floor, cgroup OOM tracking, unit wiring).
  7. `tests/test_agent_network.sh` — 9/9 Passed (Port 30000 isolation, strict egress denial, netns boundary validation).
  8. `tests/test_cachyos_lifecycle.sh` — 3/3 Passed (Sandbox isolation, install dry-run, uninstall dry-run).
  9. `tests/test_harness_dependencies.sh` — 7/7 Passed (Python module imports, CPU ColBERT retrieval, Draft 2020-12 schema validation, Obsidian vault detection).
  10. `tests/test_kernel_tuning.sh` — 9/9 Passed (Sysctl parameters, systemd user slice weights, drift detection).
  11. `tests/test_pkg_install.sh` — 6/6 Passed (Non-interactive package blocking, input validation, execution safety).

---

## 5. Source Repositories Immutability Audit

Per the strict safety invariant of the unification initiative, all three source repositories were completely isolated from modifications. An audit confirms clean working trees and zero local commits:

- **`open-code-harness` (reference repo)**:
  - Branch: `develop` (matches upstream `develop`)
  - Status: Clean working tree, nothing to commit
  - Latest Commit: `2c20054` (`feat(orchestration): deploy multi-team kickoffs, handoffs, and start/end-of-day orchestration suite`)
- **`claude-harness` (reference repo)**:
  - Branch: `develop` (matches upstream `develop`)
  - Status: Clean working tree, nothing to commit
  - Latest Commit: `6200b0a` (`test(read-only): remove legacy tool checks in test_claude_harness`)
- **`agy-harness` (reference repo)**:
  - Branch: `develop` (matches upstream `develop`)
  - Status: Clean working tree, nothing to commit
  - Latest Commit: `8784190` (`feat(orchestration): deploy multi-team kickoffs, handoffs, and start/end-of-day orchestration suite`)

---

## 6. Two-Key Merge Gate Records

The repository strictly enforces the Two-Key Merge Gate protocol for all changes:

### Issue #1: Unified Canonical Core & Plug-and-Play Runtime Adapters
- **Key 1 (Automated Adversarial Review Gate)**:
  - Adversarial review conducted by `reviewer` subagent on branch `feat/unified-canonical-core`.
  - Pass 1 findings addressed in commit `45dc407` (worktree manager hardening, uninstall safety, test suite cleanup).
  - Pass 2 audit satisfied; Key 1 cleared.
- **Key 2 (Human Operator Approval Gate)**:
  - Review submitted to Human Operator via `ask_question`.
  - Formal human approval received; merged into `develop` in commit `0c7bb62`.

### Issue #2: Master Universal Installer & Multi-CLI Distribution with Atomic Manifest Engine
- **Key 1 (Automated Adversarial Review Gate)**:
  - Adversarial review conducted by `reviewer` subagent on branch `feat/master-installer`.
  - Pass 1 findings addressed in commit `bcc1109` (user file preservation, settings backup/restore, unmanaged directory protection).
  - Pass 2 audit confirmed clean manifest engine and non-destructive rollbacks; Key 1 cleared.
- **Key 2 (Human Operator Approval Gate)**:
  - Branch pushed to remote: `git push -u origin feat/master-installer`.
  - Formal GitHub Pull Request created: PR #1 (`feat/master-installer`).
  - Human Operator directed formal PR merge into `develop`.
  - PR #1 merged via `gh pr merge #1 --merge` into commit `642ec86`.

---

## 7. Next Steps & Governance Protocols

1. **Production Tagging (`release`)**:
   - `release` branch remains anchored at `v0.1.0` (`24bbbd4`).
   - When preparing for `v0.2.0`, fast-forward `release` from `develop` and tag `v0.2.0` with release notes detailing multi-CLI distribution and atomic manifest rollbacks.
2. **Post-Unification Workflow**:
   - All future feature work must branch from `develop` using isolated worktrees (`.orchestration/worktrees/<branch>`).
   - Maintain the Two-Key Merge Gate for all pull requests targeting `develop`.
   - Never commit runtime-installed paths (`.agents/`, `.claude/`, `.opencode/`) to the repository root.
