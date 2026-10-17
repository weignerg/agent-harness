---
name: context-anchoring
description: Structure persistent RadixAttention context anchors and generate durable TASK_HANDOFF.md checkpoints. Use when managing long multi-turn sessions, handing off tasks between agents, or preserving KV cache attention prefixes.
---

# Context Anchoring & Task Handoff Skill

Use this skill to optimize KV-cache prefix caching and maintain durable session handoffs across agent turns.

## RadixAttention Prefix Anchoring
- Standardize system instructions (`AGENTS.md`) and prompt prefixes at the very top of each turn.
- Static system prefixes allow SGLang RadixAttention to match 100% of KV-cache tokens across multi-turn exchanges, eliminating TTFT prefill latency.

## Task Handoff Protocol
When transferring work between agents or ending a major orchestration milestone:
1. Generate a handoff checkpoint in `.opencode/handoffs/{session-description}-dd-mm-yyyy-handoff.md` (or `TASK_HANDOFF.md` when requested).
2. Structure the document with:
   - **Task Objective**: What was requested.
   - **Current State**: What was executed, modified, or tested.
   - **Key Artifacts**: Specific file paths modified.
   - **Pending Work & Gaps**: Exactly what remains to be completed.
