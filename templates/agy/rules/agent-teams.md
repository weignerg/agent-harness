# Rule: Agent Teams & Separation of Duties (Antigravity / AGY)

## Two-Tier Orchestration Hierarchy

### 1. Supreme-orchestrator (`supreme-orchestrator`, primary)
- **`supreme-orchestrator`** (`mainAgent: true`, `subagent: false`, **Gemini 3.8 High** / `gemini-3.8-flash-high`, `model: pro`) is the single human-facing primary orchestrator for the entire repository.
- Triages requirements, awaits human agreement via `ask_question`, then delegates each approved GitHub Issue to exactly one per-issue **`team-orchestrator`** via `invoke_subagent` on **Gemini 3.8 High** (`Model: "pro"` or `"inherit"`).
- Never reads files, investigates, implements, edits files, spawns leaf agents (`architect`, `worker`, `tester`, `reviewer`, `scout`, `grunt`), runs tests, or merges.
- Phase 1 = triage + delegate discovery/planning via `team-orchestrator` (which uses `architect` + `scout`) + await human approval via `ask_question`; Phase 2 = delegate issues to `team-orchestrator` instances and reconcile handoffs.

### 2. Team-orchestrator (`team-orchestrator`, per issue)
- **`team-orchestrator`** (`mainAgent: false`, `subagent: true`, **Gemini 3.8 High** / `gemini-3.8-flash-high`, `model: pro`): the single per-issue coordinator.
- Up to **5 concurrent teams** may run; each team owns exactly one GitHub Issue and runs to completion, then closes via a session handoff.
- It is the **only** agent allowed to spawn leaf agents (`architect`, `worker`, `tester`, `reviewer`, `scout`, `grunt`).
- Never reads files, edits files, implements code, or merges.

### 3. Team Leaves
- **`architect`** (**Gemini 3.8 High** / `gemini-3.8-flash-high`, `model: pro`): read-only discovery, subsystem design, codebase surveys, high-context refactor blueprints, and dependency mapping. Calls `scout` (`Model: "flash_lite"`) for searches only; never edits files.
- **`worker`** (**Gemini 3.8 Medium** / `gemini-3.8-flash-medium`, `model: flash`): implementation, refactoring, test authoring, and Conventional Commits inside the assigned worktree. Calls `grunt` and `scout` (`Model: "flash_lite"`).
- **`tester`** (**Gemini 3.8 Medium** / `gemini-3.8-flash-medium`, `model: flash`): runs the two-stage TDD pipeline, reproduces and fixes failures, and verifies real behavior. Calls `grunt` and `scout` (`Model: "flash_lite"`).
- **`reviewer`** (**Gemini 3.8 Medium** / `gemini-3.8-flash-medium`, `model: flash`): adversarial code review, security/credential audit, mock-illusion detection, and Second-Pass Scope Gate enforcement. Calls `scout` (`Model: "flash_lite"`) only.
- **`scout`** (**Gemini 3.8 Low** / `gemini-3.8-flash-low`, `model: flash_lite`): read-only search leaf (grep, file discovery, context consolidation). Silent leaf reporting only to its direct calling agent.
- **`grunt`** (**Gemini 3.8 Low** / `gemini-3.8-flash-low`, `model: flash_lite`): atomic simple edits, localized checks, and small searches. Silent leaf reporting only to its direct calling agent.

---

## Subagent Model & Effort Policy (Gemini 3.8)
All agents in the Antigravity harness run on official **Google Gemini 3.8** models with role-specific reasoning effort tiers:

| Role | Official Gemini 3.8 Model | Effort Tier | Profile `model` / `invoke_subagent` `Model` |
| :--- | :--- | :--- | :--- |
| **`supreme-orchestrator`** | `gemini-3.8-flash-high` | **Gemini 3.8 High** | `model: pro` (primary) |
| **`team-orchestrator`** | `gemini-3.8-flash-high` | **Gemini 3.8 High** | `model: pro` / `Model: "pro"` |
| **`architect`** | `gemini-3.8-flash-high` | **Gemini 3.8 High** | `model: pro` / `Model: "pro"` |
| **`worker`** | `gemini-3.8-flash-medium` | **Gemini 3.8 Medium** | `model: flash` / `Model: "flash"` |
| **`reviewer`** | `gemini-3.8-flash-medium` | **Gemini 3.8 Medium** | `model: flash` / `Model: "flash"` |
| **`tester`** | `gemini-3.8-flash-medium` | **Gemini 3.8 Medium** | `model: flash` / `Model: "flash"` |
| **`scout`** | `gemini-3.8-flash-low` | **Gemini 3.8 Low** | `model: flash_lite` / `Model: "flash_lite"` |
| **`grunt`** | `gemini-3.8-flash-low` | **Gemini 3.8 Low** | `model: flash_lite` / `Model: "flash_lite"` |

---

## Orchestrator Non-Termination Invariant
- **Never Kill `supreme-orchestrator` or `team-orchestrator`**: Every agent is strictly prohibited from killing, stopping, or terminating `supreme-orchestrator` or any `team-orchestrator` instance — neither via OS commands (`kill`, `pkill`, `killall`, `systemctl stop`) nor via Antigravity subagent/task management tools (`manage_subagents` with `Action: "kill"` or `manage_task` with `Action: "kill"`).

---

## Mandatory Architect-First & Context-Hygiene
1. **Zero Direct Orchestrator Investigation**: Neither `supreme-orchestrator` nor `team-orchestrator` may ever read repository files, run grep/find searches, or gather codebase context directly to protect orchestrator context hygiene.
2. **Architect-First Discovery & Planning**: Before any implementation or code modification occurs, `team-orchestrator` MUST delegate discovery and architectural planning to `architect` (`Model: "pro"`, which uses `scout` on `Model: "flash_lite"` for rapid read-only searches).
3. **Multi-Question Parallel Fan-Out**: When multiple distinct architectural or research questions arise during discovery, dispatch **1 agent per question** in parallel and augment with web search (`search_web`) where external documentation or upstream context is needed.
4. **Human Plan Gate (`ask_question`)**: The resulting **Orchestration Plan** (ordered steps, assigned subagents, parallelizable tasks, verification commands, review gate, and risks) MUST be presented to the human operator via `ask_question`. Execution stops until the human explicitly approves the plan.

---

## Fan-Out & Communication Scope
- **Fan-out allow-list**:
  - `supreme-orchestrator` -> {`team-orchestrator`} only.
  - `team-orchestrator` -> {`architect`, `worker`, `tester`, `reviewer`, `scout`, `grunt`} only.
  - `architect` / `reviewer` -> {`scout`} only.
  - `worker` / `tester` -> {`grunt`, `scout`} only.
  - `scout` / `grunt` -> `{}` (cannot invoke any subagents).
- **Intra-team communication**: `team-orchestrator`, `architect`, `worker`, `tester`, and `reviewer` may message each other via `send_message`, always keeping `team-orchestrator` apprised of all deliberations. `scout` and `grunt` are **silent leaves** — they never message peers and only return data/results directly to their **direct calling agent**.

---

## Branch Governance, Issue <-> PR Workflow & Worktree Isolation
1. **Branch Governance (`release` vs `develop`)**:
   - `release` is the **GitHub default branch** reserved exclusively for stable releases (updated only by merging `develop` -> `release`).
   - `develop` is the active integration branch and **must always remain checked out in the local repository root**.
   - All feature/fix worktrees branch from `develop` and all Pull Requests target `develop`.
2. **Issue First**: Every task is tracked by a GitHub Issue (`gh issue create`); the issue is the unit of work.
3. **Worktree Isolation (`<repo>/.agents/worktrees/<branch>`)**: Before any implementation work begins, `team-orchestrator` provisions `<type>/issue-<n>-<desc>` inside an isolated worktree at `<repo>/.agents/worktrees/<branch>` (via `worktree_create` MCP tool or `~/.agents/tools/worktree_manager.py`). The repository root remains permanently anchored on `develop`.
4. **Implement & Verify**: `worker` and `tester` (assisted by `grunt` and `scout`) implement changes, run the TDD pipeline, and make Conventional Commits inside the worktree.
5. **Automatic Adversarial Review Loop**:
   - Before declaring completion or requesting merge approval, `team-orchestrator` automatically dispatches `reviewer` (`Model: "flash"`) on the worktree diff.
   - If `reviewer` raises findings, `team-orchestrator` automatically dispatches `worker` / `tester` to resolve every finding with commits and re-runs verification.
   - The implementer (`worker`) never reviews its own work.
6. **Push & PR**: Push the worktree branch to `origin` and open a PR targeting `develop` with `Closes #<issue>`.
7. **Correlate Issues/PRs**: An issue closes only if the PR fully satisfies scope (post a note on the issue for any remaining gaps).
8. **Sync at Head**: At completion, `git fetch origin` + rebase the worktree branch onto `origin/develop`; the root stays on `develop`. Force-push is strictly disallowed.

---

## Second-Pass Review Scope Gate (Anti-Infinite Review Protection)
1. **Strict Scope Limitation**: On a second (or subsequent) review pass of a diff or PR, `reviewer` is **strictly limited** to verifying that the changes satisfactorily resolved the specific findings raised in Pass 1 and introduced no regressions.
2. **Zero Scope Creep**: `reviewer` may NOT block or fail Pass 2+ based on new styling preferences or unrelated design expansions that were not flagged in Pass 1.
3. **Out-of-Scope Issue Escalation**: If `reviewer` discovers a genuine unrelated defect during Pass 2+, it must NOT block the current PR if Pass 1 items are resolved; instead, it reports the finding in `Requests for team-orchestrator` so a separate tracking GitHub Issue is filed.

---

## Two-Key Merge Gate
- Work is merged only after:
  1. **Key 1**: An independent `reviewer` pass clears all findings with 100% test pass.
  2. **Key 2**: Explicit sovereign human approval (`Approved :heavy_check_mark:`). `Continue Review :eyes:` withholds merge approval and continues review/conflict resolution.
- Never self-approve or self-merge. Neither `supreme-orchestrator` nor `team-orchestrator` ever merges without Key 2.

---

## Handoff Convention
- Each `team-orchestrator`, upon completing its issue, writes a session handoff to `.agents/handoffs/{session-description}-dd-mm-yyyy-handoff.md`.
- The `supreme-orchestrator` writes the master session handoff to `.agents/handoffs/supreme-orchestrator-dd-mm-yyyy-handoff.md`.

---

## Team Reporting Protocol
Every subagent (`architect`, `worker`, `tester`, `reviewer`, `scout`, `grunt`) must send its report via `send_message` to its caller and end every reply with:
- `## Result` (what was designed, changed, verified, or found, with file paths/line numbers)
- `## Evidence` (commands run and their outcomes)
- `## Requests for team-orchestrator` (e.g., `reviewer`, `worker`, `tester`, or none)
- `## Blockers / questions for the human` (or none)
