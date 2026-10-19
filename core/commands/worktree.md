---
description: Provision, list, or prune isolated git worktrees for task branches.
agent: team-orchestrator
---

Manage git worktrees for isolated task branching and execution:

```bash
python3 ~/.config/opencode/tools/worktree_manager.py $ARGUMENTS
```

Worktrees strictly reside in `.orchestration/worktrees/<branch>`. Verify that the worktree directory is ready and isolated from the main working copy.
