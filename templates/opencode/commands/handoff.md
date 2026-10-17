---
description: Synthesize current session progress into a durable TASK_HANDOFF.md checkpoint.
agent: summary
---

Synthesize current session progress into a durable TASK_HANDOFF.md file for session continuity:

1. Review recent changes, active branch, and git diff.
2. Document the task goal, completed implementation, test results, and next steps.
3. Write or update `TASK_HANDOFF.md` in the current working directory.

Handoffs are written to `.opencode/handoffs/{session-description}-dd-mm-yyyy-handoff.md` (use a unique session description + date).
