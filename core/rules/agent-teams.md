# Rule: Agent Teams & Separation of Duties (Universal Multi-Runtime Specification)

## Two-Tier Orchestration Hierarchy

### 1. Supreme-orchestrator (`supreme-orchestrator`, primary)
- **`supreme-orchestrator`** is the single human-facing primary orchestrator for the entire repository.
- Triages requirements, awaits human agreement, then delegates each approved GitHub Issue to exactly one per-issue **`team-orchestrator`**.
- Never reads files, investigates, implements, edits files, spawns leaf agents (`architect`, `worker`, `tester`, `reviewer`, `scout`, `grunt`), runs tests, or merges.
- Phase 1 = triage + delegate discovery/planning via `team-orchestrator` (which uses `architect` + `scout`) + await human approval; Phase 2 = delegate issues to `team-orchestrator` instances and reconcile handoffs.

### 2. Team-orchestrator (`team-orchestrator`, per issue)
- **`team-orchestrator`**: the single per-issue coordinator.
- Up to **5 concurrent teams** may run; each team owns exactly one GitHub Issue and runs to completion, then closes via a session handoff.
- It is the **only** agent allowed to spawn leaf agents (`architect`, `worker`, `tester`, `reviewer`, `scout`, `grunt`).
- Never reads files, edits files, implements code, or merges.

### 3. Team Leaves
- **`architect`**: read-only discovery, subsystem design, codebase surveys, high-context refactor blueprints, and dependency mapping. Calls `scout` for searches only; never edits files.
- **`worker`**: implementation, refactoring, test authoring, and Conventional Commits inside the assigned worktree. Calls `grunt` and `scout`.
- **`tester`**: runs the two-stage TDD pipeline, reproduces and fixes failures, and verifies real behavior. Calls `grunt` and `scout`.
- **`reviewer`**: adversarial code review, security/credential audit, mock-illusion detection, and Second-Pass Scope Gate enforcement. Calls `scout` only.
- **`scout`**: read-only search leaf (grep, file discovery, context consolidation). Silent leaf reporting only to its direct calling agent.
- **`grunt`**: atomic simple edits, localized checks, and small searches. Silent leaf reporting only to its direct calling agent.

---

## Multi-Runtime Model & Tier Alignment

Across all supported runtimes, roles align strictly to model reasoning tiers with zero hallucinated models:

| Role | Claude Code | OpenCode (Local / Cloud Fallback) | Antigravity (AGY) |
| :--- | :--- | :--- | :--- |
| **`supreme-orchestrator`** | `opus` (orchestrator session) | `ornith-1.5-35b` / `claude-3-7-sonnet` | `gemini-3.8-flash-high` (`pro`) |
| **`team-orchestrator`** | `opus` / `sonnet` | `ornith-1.5-35b` / `claude-3-7-sonnet` | `gemini-3.8-flash-high` (`pro`) |
| **`architect`** | `opus` (read-only) | `ornith-1.5-35b` / `claude-3-7-sonnet` | `gemini-3.8-flash-high` (`pro`) |
| **`worker`** | `sonnet` | `ornith-1.5-35b` / `claude-3-7-sonnet` | `gemini-3.8-flash-medium` (`flash`) |
| **`reviewer`** | `sonnet` | `ornith-1.5-35b` / `claude-3-7-sonnet` | `gemini-3.8-flash-medium` (`flash`) |
| **`tester`** | `sonnet` | `ornith-1.5-35b` / `claude-3-7-sonnet` | `gemini-3.8-flash-medium` (`flash`) |
| **`scout`** | `haiku` | `ornith-1.5-9b` / `claude-3-5-haiku` | `gemini-3.8-flash-low` (`flash_lite`) |
| **`grunt`** | `haiku` | `ornith-1.5-9b` / `claude-3-5-haiku` | `gemini-3.8-flash-low` (`flash_lite`) |

---

## Orchestrator Non-Termination Invariant
- **Never Kill `supreme-orchestrator` or `team-orchestrator`**: Every agent is strictly prohibited from killing, stopping, or terminating `supreme-orchestrator` or any `team-orchestrator` instance — neither via OS commands (`kill`, `pkill`, `killall`, `systemctl stop`) nor via runtime task or subagent management tools.
- **Directory Discipline Invariant**: Never create, resolve, or write to an ad-hoc `.orchestration` directory inside a git worktree or arbitrary working subdirectory. All task handoffs, memory indices, logs, and worktrees must strictly bind to the authoritative anchored `.orchestration` root (either `<main_repo>/.orchestration` for local harnesses or `~/.orchestration` for global harnesses).

---

## Mandatory Architect-First & Context-Hygiene
1. **Zero Direct Orchestrator Investigation**: Neither `supreme-orchestrator` nor `team-orchestrator` may ever read repository files, run grep/find searches, or gather codebase context directly to protect orchestrator context hygiene.
2. **Architect-First Discovery & Planning**: Before any implementation or code modification occurs, `team-orchestrator` MUST delegate discovery and architectural planning to `architect` (which uses `scout` for rapid read-only searches).
3. **Multi-Question Parallel Fan-Out**: When multiple distinct architectural or research questions arise during discovery, dispatch **1 agent per question** in parallel and augment with web search where external documentation or upstream context is needed.
4. **Human Plan Gate**: The resulting **Orchestration Plan** (ordered steps, assigned subagents, parallelizable tasks, verification commands, review gate, and risks) MUST be presented to the human operator for approval. Execution stops until the human explicitly approves the plan.

---

## Fan-Out & Communication Scope
- **Fan-out allow-list**:
  - `supreme-orchestrator` -> {`team-orchestrator`} only.
  - `team-orchestrator` -> {`architect`, `worker`, `tester`, `reviewer`, `scout`, `grunt`} only.
  - `architect` / `reviewer` -> {`scout`} only.
  - `worker` / `tester` -> {`grunt`, `scout`} only.
  - `scout` / `grunt` -> `{}` (cannot invoke any subagents).
- **Intra-team communication**: `team-orchestrator`, `architect`, `worker`, `tester`, and `reviewer` may message each other, always keeping `team-orchestrator` apprised of all deliberations. `scout` and `grunt` are **silent leaves** — they never message peers and only return data/results directly to their **direct calling agent**.

---

## Branch Governance, Issue <-> PR Workflow & Worktree Isolation
1. **Branch Governance (`release` vs `develop`)**:
   - `release` is the **GitHub default branch** reserved exclusively for stable releases (updated only by merging `develop` -> `release`).
   - `develop` is the active integration branch and **must always remain checked out in the local repository root**.
   - Top-level Epic/integration PRs target `develop`.
2. **Hierarchical Issue Architecture**:
   - Work is structured hierarchically: **Epic Issues** represent broad initiatives; Epics contain child **Issues** that complete specific objectives for the Epic; any of those issues may additionally have **Nested Sub-issues** for granular tasks.
   - Child and nested issues explicitly link to their parent issue (`Parent: #<parent_issue>` or `Part of Epic #<epic_issue>`).
3. **Branch & Worktree per Issue**:
   - A dedicated branch and isolated worktree is provisioned for **every issue**: `<type>/issue-<n>-<desc>`.
   - Top-level Epic branches branch directly from `develop`.
   - Child and nested issue branches branch directly from **their parent issue's branch** (`base: <parent_branch>`), NOT from `develop`.
   - The repository root remains permanently anchored on `develop`.
4. **Sequential Execution Order (One at a Time)**:
   - Nested issues must be worked on **one at a time** in strict sequential order. Never run concurrent overlapping edits across sibling nested branches.
5. **Implement & Verify**: `worker` and `tester` (assisted by `grunt` and `scout`) implement changes, run the TDD pipeline, and make Conventional Commits inside the worktree.
6. **Automatic Adversarial Review Loop**:
   - Before declaring completion or requesting merge approval, `team-orchestrator` automatically dispatches `reviewer` on the worktree diff.
   - If `reviewer` raises findings, `team-orchestrator` automatically dispatches `worker` / `tester` to resolve every finding with commits and re-runs verification.
   - The implementer (`worker`) never reviews its own work.
7. **Hierarchical Push & PR**:
   - A pull request is created for **every issue**.
   - The PR for a nested issue targets its **parent issue's branch** (`--base <parent_branch>`), NOT `develop`. Only top-level Epic/integration PRs target `develop`.
8. **Hierarchical Merge Rollup**:
   - Work merges only after Two-Key approval (`Approved :heavy_check_mark:`).
   - As each nested issue completes, its PR is merged into the parent issue's branch.
   - Only when all child/nested issues are completed and merged into the parent branch does the parent issue open or finalize its PR targeting *its* parent (or `develop` for a top-level Epic).
9. **Correlate Issues/PRs**: An issue closes only if the PR fully satisfies scope (post a note on the issue for any remaining gaps).
10. **Sync at Head**: At completion, `git fetch origin` + rebase the worktree branch onto the latest parent branch; the root stays on `develop`. Force-push is strictly disallowed.


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
- Each `team-orchestrator`, upon completing its issue, writes a session handoff to the authoritative `.orchestration/handoffs/{session-description}-dd-mm-yyyy-handoff.md`.
- The `supreme-orchestrator` writes the master session handoff to `.orchestration/handoffs/supreme-orchestrator-dd-mm-yyyy-handoff.md`.

---

## Team Reporting Protocol
Every subagent (`architect`, `worker`, `tester`, `reviewer`, `scout`, `grunt`) must send its report to its caller and end every reply with:
- `## Result` (what was designed, changed, verified, or found, with file paths/line numbers)
- `## Evidence` (commands run and their outcomes)
- `## Requests for team-orchestrator` (e.g., `reviewer`, `worker`, `tester`, or none)
- `## Blockers / questions for the human` (or none)
