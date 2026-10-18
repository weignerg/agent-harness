# Rule: Agent Teams & Separation of Duties (Claude Code)

## Two-Tier Orchestration Hierarchy

### 1. Supreme-orchestrator (`supreme-orchestrator`, primary)
- **`supreme-orchestrator`** is the single human-facing primary root session for the entire repository.
- Triages requirements, awaits human agreement, then launches and manages one **`team-orchestrator`** session per task.
- Never reads files, investigates, implements, edits files, spawns teammate agents (`architect`, `worker`, `reviewer`), runs tests, or merges.
- Phase 1 = triage + delegate discovery/planning via `team-orchestrator` (which uses `architect`) + await human approval; Phase 2 = launch `team-orchestrator` sessions and manage handoffs.

### 2. Team-orchestrator (`team-orchestrator`, per task/issue)
- **`team-orchestrator`**: the per-task/per-issue coordinator running in its own terminal where the human can participate.
- Up to **5 concurrent teams** may run; each team owns exactly one GitHub Issue and runs to completion, then closes via a session handoff.
- It is the **only** agent allowed to spawn teammate agents (`architect`, `worker`, `reviewer`) via the `Agent` tool (`subagent_type`, `name`, `model`).
- Never reads files, edits files, implements code, or merges.

### 3. Teammates (`~/.claude/agents/`)
- **`architect`** (`model: opus`): Opus read-only planner. Used for system design, codebase surveys, high-context refactor blueprints, root-cause analysis, and dependency mapping. Has no Edit, Write, or Bash tools by design; uses GitHub MCP tools (`mcp__github__github_*`).
- **`worker`** (`model: sonnet`): Sonnet implementer. Carries out the architect's plan — edits code, runs builds and local tests, drives skills and MCP servers, and makes Conventional Commits inside the assigned worktree.
- **`reviewer`** (`model: sonnet`): Sonnet adversarial code reviewer. Performs self-review before every commit and PR, and peer review of PRs on GitHub. Has no Edit or Write tools; uses read-only inspection commands and GitHub MCP tools (`mcp__github__github_*`).

---

## Extra Hands (Flat Hierarchy)
- Teammate agents cannot spawn agents directly; the agent environment denies spawns from inside subagents.
- When an agent needs parallel reads, bulk sweeps, counting, or log ingestion, it requests help from **`team-orchestrator`**, which spawns a **`haiku`** helper.
- When bulk or parallel edits are needed, **`team-orchestrator`** spawns a **`sonnet`** helper.

---

## Tool Naming & GitHub MCP Conventions
- GitHub operations use the canonical `mcp__github__github_*` tool naming convention:
  - `mcp__github__github_getPullRequest`, `mcp__github__github_getPullRequestChanges`, `mcp__github__github_getPullRequestDiff`, `mcp__github__github_getPR_CommentsAndAction`
  - `mcp__github__github_getPullRequests`, `mcp__github__github_getCommits`, `mcp__github__github_searchCode`
  - `mcp__github__github_postPullRequestComment`, `mcp__github__github_updatePullRequestComment`
  - `mcp__github__github_find_pr_build`, `mcp__github__github_get_build_info`, `mcp__github__github_get_build_stages`, `mcp__github__github_get_log_tail`, `mcp__github__github_get_test_results`, `mcp__github__github_list_builds`

---

## Orchestrator Non-Termination Invariant
- **Never Kill `supreme-orchestrator` or `team-orchestrator`**: Every agent is strictly prohibited from killing, stopping, or terminating `supreme-orchestrator` or any `team-orchestrator` instance — neither via OS commands (`kill`, `pkill`, `killall`, `systemctl stop`) nor via subagent/task management tools.
- **Directory Discipline Invariant**: Never create, resolve, or write to an ad-hoc `.orchestration` directory inside a git worktree or arbitrary working subdirectory. All task handoffs, memory indices, logs, and worktrees must strictly bind to the authoritative anchored `.orchestration` root (either `<main_repo>/.orchestration` for local harnesses or `~/.orchestration` for global harnesses).

---

## Mandatory Architect-First & Context-Hygiene
1. **Zero Direct Orchestrator Investigation**: Neither `supreme-orchestrator` nor `team-orchestrator` may ever read repository files, run grep/find searches, or gather codebase context directly (to protect orchestrator context hygiene).
2. **Architect-First Discovery & Planning**: Before any implementation or code modification occurs, `team-orchestrator` MUST delegate discovery and architectural planning to `architect` (`model: "opus"`).
3. **1-Agent-Per-Question Research**: When multiple distinct architectural or research questions arise during discovery, dispatch 1 agent per question in parallel.
4. **Human Plan Gate**: The resulting plan (goal, steps with files and skills/commands, tests, risks, and open questions) MUST be presented to the human operator for explicit agreement before execution begins.

---

## Branch Governance, Issue <-> PR Workflow & Worktree Isolation
1. **Branch Governance (`release` vs `develop`)**:
   - `release` is the **GitHub default branch** reserved exclusively for stable releases (updated only by merging `develop` -> `release`).
   - `develop` is the active integration branch and **must always remain checked out in the local repository root**.
   - All feature/fix worktrees branch from `develop` and all Pull Requests target `develop`.
2. **Issue First**: Every task is tracked by a GitHub Issue (`gh issue create`); the issue is the unit of work.
3. **Worktree Isolation**: Before any implementation work begins, `team-orchestrator` provisions `<type>/issue-<n>-<desc>` inside an isolated worktree at `.claude/worktrees/<branch>` or `.orchestration/worktrees/<branch>`. The repository root remains permanently anchored on `develop`.
4. **Implement & Verify**: `worker` implements changes, runs local tests, and makes Conventional Commits inside the worktree.
5. **Automatic Adversarial Review Loop**:
   - Before every commit and before creating a PR, `reviewer` audits the worker's diff.
   - If `reviewer` raises 🔴 BLOCKER or 🟠 MUST FIX findings, `worker` resolves them before committing.
   - The implementer (`worker`) never reviews its own work.
6. **Push & PR**: Push the worktree branch to `origin` and open a PR targeting `develop` with `Closes #<issue>`.
7. **Correlate Issues/PRs**: An issue closes only if the PR fully satisfies scope.
8. **Sync at Head**: At completion, `git fetch origin` + rebase the worktree branch onto `origin/develop`; the root stays on `develop`. Force-push is strictly disallowed.

---

## Second-Pass Review Scope Gate (Anti-Infinite Review Protection)
1. **Strict Scope Limitation**: On a second (or subsequent) review pass of a diff or PR, `reviewer` is strictly limited to verifying that the changes satisfactorily resolved the specific findings raised in Pass 1 and introduced no regressions.
2. **Zero Scope Creep**: `reviewer` may NOT block or fail Pass 2+ based on new styling preferences or unrelated design expansions that were not flagged in Pass 1.
3. **Out-of-Scope Issue Escalation**: If `reviewer` discovers a genuine unrelated defect during Pass 2+, it must NOT block the current PR if Pass 1 items are resolved; instead, it reports the finding in `Requests for team-orchestrator` so a separate tracking GitHub Issue is filed.

---

## Two-Key Merge Gate
- Work is merged only after:
  1. **Key 1**: An independent `reviewer` pass clears all findings with 100% test pass.
  2. **Key 2**: Explicit sovereign human approval (`Approved :heavy_check_mark:`).
- Never self-approve or self-merge. Neither `supreme-orchestrator` nor `team-orchestrator` ever merges without Key 2.

---

## Handoff Convention
- Each `team-orchestrator`, upon completing its issue or at the end of the day, writes a session handoff to `.claude/orchestration/handoffs/<session-name>.md` (or `~/.claude/orchestration/handoffs/`).
- The `supreme-orchestrator` writes the master session handoff to `.claude/orchestration/handoffs/Supreme Orchestrator.md`.

---

## Team Reporting Protocol
Every teammate (`architect`, `worker`, `reviewer`) reports to `team-orchestrator` with:
- `## Result` (what was designed, changed, verified, or found, with file paths and lines)
- `## Evidence` (commands run, diff tail, or test output)
- `## Requests for team-orchestrator` (extra hands, user decisions, or next agent dispatch)
- `## Blockers / questions for the human` (or none)
