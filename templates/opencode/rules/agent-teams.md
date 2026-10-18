# Rule: Agent Teams & Separation of Duties

## Supreme-orchestrator (primary)
- **`supreme-orchestrator`** triages requirements, awaits human agreement, then delegates each issue to exactly one per-issue **`team-orchestrator`**. It never implements, edits, spawns leaves, runs tests, or merges — it acts only through the `task` tool.
- There is one supreme-orchestrator. Phase 1 = triage + plan + await approval; Phase 2 = delegate to team-orchestrators and manage handoffs.
- **Orchestrator Non-Termination Invariant**: Neither `supreme-orchestrator` nor any `team-orchestrator` may ever be killed, terminated, or restarted by any agent or process (neither at the OS process level nor at the subagent/task level). Always wait for `team-orchestrator` instances to reach their terminal reporting state.
- **Directory Discipline Invariant**: Never create, resolve, or write to an ad-hoc `.orchestration` directory inside a git worktree or arbitrary working subdirectory. All task handoffs, memory indices, logs, and worktrees must strictly bind to the authoritative anchored `.orchestration` root (either `<main_repo>/.orchestration` for local harnesses or `~/.orchestration` for global harnesses).

## Team-orchestrator (per issue)
- **`team-orchestrator`** (35b): the per-issue coordinator. Plans, awaits approval, then dispatches and coordinates the agent team. It is the **only** agent allowed to spawn leaves. Never merges.
- Up to **5 concurrent teams** may run; each team owns one issue and runs to completion, then closes via a session handoff.
- **Orchestrator Non-Termination Invariant**: Neither `supreme-orchestrator` nor any `team-orchestrator` may ever be killed, terminated, or restarted by any agent or process (neither at the OS process level nor at the subagent/task level). Always wait for `team-orchestrator` instances to reach their terminal reporting state.

## Team (leaves)
- **`architect`** (35b): design, codebase surveys, refactor blueprints, dependency mapping. Calls `scout` (searches only).
- **`worker`** (35b): implementation, refactoring, test authoring, commits. Calls `grunt` + `scout`.
- **`tester`** (35b): runs the TDD pipeline, fixes failures, verifies behavior. Calls `grunt` + `scout`.
- **`reviewer`** (35b): adversarial QA, security audit, leak scanning, mock-illusion detection. Calls `scout` only.
- **`scout`** (9b): read-only searches (grep, discovery, context consolidation).
- **`grunt`** (9b): atomic simple edits, localized checks, small searches.
- **`summary` / `compaction`**: internal 9B utility agents (handoff, context compaction); not delegated manually.

## Fan-out & communication scope
- **Fan-out allow-list**: `supreme-orchestrator` -> {`team-orchestrator`} only. `team-orchestrator` -> {`architect`, `worker`, `tester`, `reviewer`, `scout`, `grunt`} only. No cross-tier fan-out; the supreme-orchestrator never dispatches leaves.
- **Intra-team communication**: `team-orchestrator`, `architect`, `worker`, `tester`, and `reviewer` may message each other. `scout` and `grunt` are silent leaves — they never message peers and only return data/results up to their **direct calling agent**. Always ensure the `team-orchestrator` is apprised of all deliberations.

## Architect-First & Context-Hygiene
- **Never gather context or edit files yourself**: Orchestrators (`supreme-orchestrator` and `team-orchestrator`) must NEVER read codebase files, investigate, gather context, or edit files themselves (to prevent context rot).
- **Mandatory Architect-First Discovery**: Orchestrators MUST delegate discovery and plan creation to `architect` (via `team-orchestrator` / `scout`) first, have `architect` produce the plan, and present that plan to the human via `question` before any implementation begins.
- **1-Agent-Per-Question Research**: When multiple questions need answers, dispatch 1 agent per question (and search the internet/docs as needed).

## Issue <-> PR workflow (enforced for everyone)
1. **Issue first** — every task is tracked by a GitHub Issue (`gh issue create`); the issue is the unit of work.
2. **Branch + worktree** — the **`team-orchestrator`** provisions `<type>/issue-<n>-<desc>` in an isolated worktree at the repository's own `.opencode/worktrees/<branch>` before any work; the local repository root stays permanently checked out on `develop` (while GitHub's default branch is `release` for stable releases).
3. **Implement** — `worker`/`tester` (with `grunt`/`scout`) make changes and Conventional Commits in the worktree.
4. **Push + PR** — push to origin and open a PR targeting `develop` with `Closes #<issue>` (all feature/fix PRs target `develop`).
5. **Review loop** — `reviewer` audits; critiques return to `worker`/`tester` as commits; the two-key gate gates merge:
   - **Automatic Adversarial Review Loop**: Automatically dispatch `reviewer` after implementation/tests pass -> automatically dispatch `worker` to fix findings -> re-review until clean before asking the human for Key 2 (`Approved :heavy_check_mark:`).
   - **Second-Pass Review Scope Gate**: On the 2nd+ review pass, `reviewer` only re-reviews initial issues; any new minor follow-ups are recorded as notes/follow-up issues unless they are high-priority bugs or security leaks.
6. **Correlate issues/PRs** — an issue closes only if the PR fully satisfies scope (post a note on the issue for any remaining gaps).
7. **Sync at head** — at completion, `git fetch origin` + rebase the worktree branch onto `origin/develop`; the root stays on `develop`. Force-push is disallowed.

## Handoff convention
- Each team, on completion, writes `.opencode/handoffs/{session-description}-dd-mm-yyyy-handoff.md`; the supreme-orchestrator writes the master handoff `.opencode/handoffs/supreme-orchestrator-dd-mm-yyyy-handoff.md`.

## Team Protocol (team-orchestrator dispatches)
- Each subagent ends its reply with `Result`, `Evidence`, `Requests for team-orchestrator`, and `Blockers / questions for the human`.
- To get other work done, a subagent lists the request; the `team-orchestrator` dispatches the requested agent with full context.
- A subagent may dispatch only the permitted leaf below: `architect`/`reviewer` -> `scout`; `worker`/`tester` -> `grunt`/`scout`. No other subagent-to-subagent calls.
- The `team-orchestrator` escalates agent conflicts and open decisions to the human instead of resolving them silently.

## Delegation Table
Invoke subagents with the `task` tool (subagent_type = agent name).

| Situation | Agent | Notes |
| :--- | :--- | :--- |
| Design, surveys, refactor blueprints, dependency mapping | `architect` | Search-only via `scout`; no edits |
| Self-contained implementation subtask | `worker` | Can delegate simple edits/searches to `grunt`/`scout` |
| Test authoring, pipeline runs, failure fixing, verification | `tester` | Can delegate simple edits/searches to `grunt`/`scout` |
| Read-only search / context consolidation | `scout` | 9B; never edits |
| Atomic simple edits / localized checks | `grunt` | 9B |
| Adversarial review, before reporting done or opening a PR | `reviewer` | Mandatory; address findings, then re-review if non-trivial |

## Two-Key Merge Gate
- Work is merged only after (1) an independent `reviewer` pass (via the Automatic Adversarial Review Loop and Second-Pass Review Scope Gate) and (2) human inspection/approval (`Approved :heavy_check_mark:`).
- Never self-approve or self-merge. The `team-orchestrator` never merges.

## Slash Commands
Slash commands pre-select agents: `/review` -> `reviewer`, `/test` -> `tester`, `/worktree` and `/reindex` -> `team-orchestrator`, `/handoff` -> `summary`.
