---
description: Hierarchical epics, worktree isolation, branch and PR naming conventions
trigger: always_on
---

# Rule: Git Workflow

- **Branch Governance (`release` vs `develop`)**: `release` is the GitHub default branch reserved for stable releases (updated only by merging `develop` -> `release`). `develop` is the active integration branch and **must always remain checked out in the local repository root**. Top-level Epic/integration PRs target `develop`.
- **Hierarchical Issue Architecture**:
  - Work is structured hierarchically: **Epic Issues** represent broad initiatives; Epics contain child **Issues** that complete specific objectives for the Epic; any of those issues may additionally have **Nested Sub-issues** for granular tasks.
  - Child and nested issues must explicitly link to their parent issue (e.g. `Parent: #<parent_issue>` or `Part of Epic #<epic_issue>`).
- **Hierarchical Branching & Worktree Provisioning**:
  - A dedicated branch and isolated worktree must be created for **every issue**: `<type>/issue-<number>-<description>` (e.g., `feat/issue-10-agent-harness-core`, `fix/issue-12-permission-findlast`).
  - Top-level Epic branches branch directly from `develop`.
  - Child and nested issue branches branch directly from **their parent issue's branch** (`base: <parent_branch>`), NOT from `develop`.
- **Sequential Execution Order (One at a Time)**:
  - Nested issues must be worked on **one at a time** in strict sequential order. Never run concurrent overlapping edits across sibling nested branches.
- **Hierarchical PR & Merge Lifecycle**:
  - A pull request is created for **every issue**.
  - The PR for a nested issue targets its **parent issue's branch** (`--base <parent_branch>`), NOT `develop`.
  - All nested issue work is merged together into the parent issue's branch after Two-Key approval (`Approved :heavy_check_mark:`).
  - Only when all child/nested issues are completed and merged into the parent branch does the parent issue open or finalize its PR targeting *its* parent (or `develop` for a top-level Epic).
- **Conventional Commits**: `feat(...)`, `fix(...)`, `docs(...)`, `test(...)`, `refactor(...)`, `chore(...)`. Commits must reference their specific issue (`Issue-#<n>`).
- **Pushes**: Never force-push to overwrite remote history. Rebase onto the updated parent branch or create a fresh commit, then make a normal fast-forward push.
- **Sync at Head**: At completion, `git fetch origin` and rebase the worktree branch onto the latest parent branch; leave the local repo root anchored on `develop`.
- Remove worktrees (`worktree_remove`) once the branch is merged into its parent.

