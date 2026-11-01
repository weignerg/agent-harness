---
name: context-anchoring
description: Structure persistent RadixAttention context anchors and generate durable handoff checkpoints. Use when managing long multi-turn sessions, handing off tasks between agents, or preserving KV cache attention prefixes.
---

# Context Anchoring & Task Handoff Skill

Use this skill to optimize KV-cache prefix caching and maintain durable session handoffs across agent turns.

## RadixAttention Prefix Anchoring
- Standardize system instructions and prompt prefixes (`GEMINI.md`) at the very top of each turn via `ContextAnchorInjector(rules_path="GEMINI.md")`.
- Static system prefixes allow RadixAttention to match 100% of KV-cache tokens across multi-turn exchanges, eliminating TTFT prefill latency.

## Task Handoff Protocol
When transferring work between agents or closing a session:
1. Write discrete handoffs inside `.agents/handoffs/` (`supreme-orchestrator-dd-mm-yyyy-handoff.md` for `supreme-orchestrator`, or `{session-description}-dd-mm-yyyy-handoff.md` for `team-orchestrator`).
2. Structure the document with:
   - **Task Objective**: What was requested.
   - **Current State**: What was executed, modified, or tested.
   - **Key Artifacts**: Specific file paths modified.
   - **Pending Work & Gaps**: Exactly what remains to be completed.
