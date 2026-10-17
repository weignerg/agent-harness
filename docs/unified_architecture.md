# Unified Agent Harness Architecture

## Overview
`agent-harness` is the canonical, multi-runtime agent harness providing:
1. **Polymorphic Core**: Context anchoring, task handoffs, and session boundaries that automatically adapt to the host runtime engine.
2. **Dynamic Runtime Engine Adapters**: First-class, plug-and-play adapters for:
   - **Google Antigravity (`agy`)**: Powered by official Google Gemini 3.8 models (`gemini-3.8-flash-high`, `gemini-3.8-flash-medium`, `gemini-3.8-flash-low`) with plugin manifest integration.
   - **Claude Code (`claude`)**: Powered by Anthropic Claude models (`opus`, `sonnet`, `haiku`) with declarative JSON settings merges.
   - **OpenCode (`opencode`)**: Powered by local high-speed SGLang inference (e.g. Blackwell FP4 models) with native commands and TUI integrations.
3. **Repository Layout**:
   - `harness/`: Canonical Python orchestrator, MCP servers, security boundaries, and polymorphic memory.
   - `harness/runtime/`: Engine adapters (`BaseRuntimeAdapter`, `AgyRuntimeAdapter`, `ClaudeRuntimeAdapter`, `OpenCodeRuntimeAdapter`) and dynamic resolvers (`get_runtime_adapter`, `detect_runtime_adapter`).
   - `templates/`:
     - `templates/shared/rules/`: Shared markdown rules (`agent-teams.md`, `code-quality.md`, `git-workflow.md`, `process-safety.md`).
     - `templates/shared/skills/`: Canonical 7 agent skills (`adversarial-review`, `context-anchoring`, `read-only-block`, `sglang-management`, `tdd-pipeline`, `vault-retrieval`, `worktree-lifecycle`).
     - `templates/agy/`: Antigravity manifest, agent profiles, and charters.
     - `templates/claude/`: Claude Code subagent definitions, settings, and charters.
     - `templates/opencode/`: OpenCode agents, commands, theme, and config.
   - `scripts/`: Operational tools (`worktree_manager.py`, `tdd_pipeline.py`, `gh_pr_automation.py`, `block_external_writes.py`, etc.).
   - `config/`: Infrastructure definitions (systemd units, sysctl, network, models catalog).
   - `vault/`: Obsidian-compatible Markdown knowledge vault with entity graph.
   - `docs/`: System documentation and architectural specifications.
   - `tests/`: Consolidated test suite for core harness, runtime adapters, and integration workflows.

## Polymorphic Memory & Context Anchoring
The harness decouples orchestration logic from vendor-specific file naming:
- **Charter Detection**: `harness.memory.context_anchor.ContextAnchorInjector` scans for `GEMINI.md`, `CLAUDE.md`, `AGENTS.md`, and rule sets under `.agents/rules/`, `.claude/rules/`, or `.opencode/rules/`.
- **Handoff Directory Resolution**: `harness.memory.handoff.TaskHandoff` dynamically resolves to `.agents/handoffs/`, `.claude/handoffs/`, or `.opencode/handoffs/`, defaulting cleanly to `.agents/handoffs/`.

## Worktree Lifecycle & Branch Governance
- Root is anchored permanently on `develop`.
- `release` is the protected default branch for releases.
- All tasks execute in isolated git worktrees at `.agents/worktrees/<branch>` (or runtime-specific path) via `scripts/worktree_manager.py`.
