---
description: Two-stage TDD pipeline, zero regressions, and 4-tier adversarial review
trigger: always_on
---

# Rule: Code Quality, Testing & Adversarial Review

- **Two-Stage TDD Pipeline**: Stage 1 unit tests and static syntax compilation, Stage 2 integration/container checks, via tools/skills (`tdd_pipeline.py` or the `tdd-pipeline` skill).
- **Traceback Parsing**: Convert compiler errors and test tracebacks directly into patch diffs; no conversational filler.
- **Mock Illusion Hunting**: Tests must verify real behavior, contracts, and boundary conditions. Avoid trivially passing mocks that mask failures.
- **Zero Regression**: All existing tests must pass before declaring work complete.
- **Preserve Documentation Integrity**: Preserve existing comments and docstrings unrelated to your change.

## 4-Tier Adversarial Code Review Standards

Every review audit follows the four-tier severity classification:
1. 🔴 **BLOCKER**: Defect causing runtime crash, compilation/build failure, or safety invariant breach. Blocks merge unconditionally.
2. 🟠 **MUST FIX**: Significant logic flaw, regression risk, unhandled error path, or security regression. Blocks merge.
3. 🟡 **WARNING**: Code smell, performance inefficiency, edge-case gap, or missing test coverage.
4. 🟢 **BEST PRACTICE**: Stylistic improvement, documentation enhancement, or minor refactoring suggestion.

### Finding Citation Requirements
Every finding reported by `reviewer` must cite:
- **Concrete failure scenario**: Specific inputs, execution sequence, and resulting faulty behavior.
- **`file:line` evidence anchor**: Direct pointer to the affected source code or diff hunk.
- **Actionable suggestion**: Concrete code direction for resolving the issue.

### Consolidated PR Review Response
When responding to or posting PR reviews:
- Maintain a single consolidated PR response comment with sections per review round separated by `---`.
- Group addressed items under severity headers (🔴 BLOCKER, 🟠 MUST FIX, 🟡 WARNING, 🟢 BEST PRACTICE).
- Link per-thread inline comments back to the consolidated comment.
