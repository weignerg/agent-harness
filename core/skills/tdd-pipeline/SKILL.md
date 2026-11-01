---
name: tdd-pipeline
description: Execute two-stage TDD verification and sandbox testing. Use when running unit tests, integration tests, verifying compiler tracebacks, or gating code completion against regressions.
---

# Two-Stage TDD Pipeline Skill

Use this skill to execute rigorous two-stage test-driven development (TDD) verification on the codebase.

## Pipeline Architecture
1. **Stage 1 (Unit & Fast Checks)**: Runs static syntax compilation and unit test discovery without external dependencies.
2. **Stage 2 (Integration & Sandboxed Execution)**: Runs integration test suites, end-to-end scenarios, or containerized execution.

## Execution
Run the TDD pipeline script:
```bash
python3 .agents/tools/tdd_pipeline.py
# or global: python3 ~/.orchestration/tools/tdd_pipeline.py
```

## Traceback Analysis
- When tests fail, parse tool stderr and compiler tracebacks directly into patch diffs.
- Never declare a task complete if any stage in the TDD pipeline fails.
