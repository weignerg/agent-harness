---
description: Perform an adversarial security and regression audit on staged changes or git diff.
agent: reviewer
---

Perform a rigorous adversarial code review and security audit on the current git diff:

1. Inspect git status and git diff ($ARGUMENTS).
2. Scan for secret leaks, tokens, hardcoded paths, and credentials.
3. Audit for subtle regressions, process safety hazards, and test mock illusions.
4. Output a clear findings table with file links, severity levels, and concrete remediation advice.
