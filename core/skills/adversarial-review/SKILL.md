---
name: adversarial-review
description: Perform adversarial code review, credential leak scanning, 4-tier severity audits, and regression checks. Use when auditing git diffs, checking staged commits, verifying secret boundaries, or evaluating mock integrity before declaring work complete.
---

# Adversarial Code Review Skill

Use this skill to conduct suspicious, rigorous audits of proposed or staged code changes before committing or merging.

## 4-Tier Severity Classification

Group every finding strictly under one of the four severity tiers:
1. 🔴 **BLOCKER**: Defect that causes runtime crash, compilation/build failure, or safety invariant breach. Blocks commit/merge unconditionally.
2. 🟠 **MUST FIX**: Significant logic flaw, regression risk, unhandled error path, or security regression. Blocks commit/merge.
3. 🟡 **WARNING**: Code smell, performance inefficiency, edge-case gap, or missing test coverage.
4. 🟢 **BEST PRACTICE**: Stylistic improvement, documentation enhancement, or minor refactoring suggestion.

## Audit Checklist & Evidence Standards

1. **Secret & Credential Leak Detection**:
   - Check for hardcoded API keys, tokens (`HF_TOKEN`), passwords, or absolute home paths.
   - Credentials must load via secure keyrings or environment files.
2. **Process & Orchestrator Non-Termination Safety**:
   - Scan for dangerous commands like `kill`, `pkill`, `killall`, or `systemctl stop` targeting host `supreme-orchestrator` or `team-orchestrator` sessions, or inference engines.
   - Never use task management tools to kill orchestrator sessions.
3. **Mock Illusion Hunting**:
   - Ensure tests reflect true contracts and boundary conditions, avoiding trivially passing mocks that mask failures.
4. **Platform Portability**:
   - Verify dynamic path resolution using `$HOME` or standard XDG base directory specifications.
5. **Concrete Finding Citation**:
   - Every finding MUST cite:
     - **Concrete failure scenario**: inputs, steps, and resulting faulty behavior.
     - **`file:line` evidence anchor**: exact pointer to affected code or diff hunk.
     - **Actionable fix suggestion**: clear solution path.
6. **Consolidated PR Response Comment**:
   - Maintain a single consolidated review response comment on pull requests with sections per round separated by `---`.
   - Link per-thread comments back to the consolidated comment.
7. **Second-Pass Review Scope Gate**:
   - On Pass 2+, verify only that Pass 1 findings were resolved without regressions; record newly noticed unrelated issues as separate follow-up tickets.
