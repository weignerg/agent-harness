---
name: worktree-lifecycle
description: Manage isolated git worktree branching, development, and Conventional Commit squashing. Use when isolating feature work, running parallel agent tasks, or managing git branches without dirtying the main working tree.
---

# Git Worktree Lifecycle Skill

Use this skill to create and manage isolated git worktrees for development tasks.

## Why Worktrees?
- Completely isolates experimental code changes from the primary working tree.
- Prevents conflicts when multiple agent sessions or subagents execute concurrently.

## Commands & Workflows
1. **Provision Worktree**:
   ```bash
   python3 ~/.agents/tools/worktree_manager.py create feat/issue-42 .orchestration/worktrees/feat/issue-42
   ```
2. **List Worktrees**:
   ```bash
   git worktree list
   ```
3. **Prune Worktree**:
   ```bash
   python3 ~/.agents/tools/worktree_manager.py prune .orchestration/worktrees/feat/issue-42
   ```

When the `worktree-manager` MCP server is active, call `worktree_create`, `worktree_list`, and `worktree_remove` directly (default worktree path is `.orchestration/worktrees/<branch>`).
