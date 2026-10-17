# Contributing Guidelines

This project strictly adheres to **Issue-Driven Development**, **Branch Governance (`release` vs `develop`)**, and the **Two-Key Merge Gate** governed by Antigravity (`agy`) AI Agent Teams powered by official **Google Gemini 3.8** models.

## 1. Branch Governance (`release` vs `develop` vs Worktrees)

- **`release` (GitHub Default Branch)**: Reserved exclusively for stable production releases (updated only by merging `develop` -> `release`).
- **`develop` (Permanent Local Root Branch & PR Target)**: Active integration branch. The local repository root (`agent-harness`) **must always remain checked out on `develop`**. All feature and fix Pull Requests target `develop`.
- **`.agents/worktrees/<branch>` (Isolated Worktrees)**: All implementation, refactoring, and testing work occurs inside isolated git worktrees provisioned off `develop` by `team-orchestrator`.

## 2. Issue-Driven Workflow

1. **Every change begins with a GitHub Issue**:
   Before modifying code, create a tracking issue via `gh issue create`.
2. **Dedicated Branch & Worktree**:
   Create a dedicated branch following the convention:
   `<type>/issue-<number>-<description>`
   - Types: `feat/`, `fix/`, `docs/`, `refactor/`, `test/`
   - Example: `fix/issue-3-launcher-race-condition`
   Develop inside an isolated worktree at `.agents/worktrees/<branch-name>`, provisioned by `team-orchestrator` (delegated from `supreme-orchestrator`). The root workspace remains anchored on `develop`.
3. **Commit Messages**:
   Use Conventional Commits referencing the issue:
   `feat(worktree): Issue-#3 isolate worktree under .agents/worktrees`

## 3. Adversarial Code Review & Two-Key Merge Gate

1. **Key 1: Adversarial Reviewer (`reviewer`)**:
   An independent Reviewer Agent audits every PR for:
   - Secret/credential leaks (`HF_TOKEN`, API keys).
   - Process & Orchestrator Non-Termination safety: never kill or terminate `supreme-orchestrator` or `team-orchestrator` (neither via OS commands like `kill`/`pkill`/`killall` nor via `manage_subagents` with `Action: "kill"` or `manage_task` with `Action: "kill"`).
   - Comprehensive test execution (`python3 -m unittest discover -s tests`).
2. **Key 2: Sovereign Human Operator**:
   Only the Human Merge Manager can authorize merges using:
   `Approved :heavy_check_mark:`
