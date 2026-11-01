---
description: Execute the two-stage TDD verification pipeline and container test sandbox.
agent: tester
---

Run the two-stage TDD verification pipeline on the current repository:

```bash
python3 ~/.config/opencode/tools/tdd_pipeline.py $ARGUMENTS
```

Parse any test tracebacks or compiler errors and provide a summary of passed and failed stages.
