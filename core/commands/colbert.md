---
description: Semantic late-interaction query across the Obsidian knowledge vault.
agent: team-orchestrator
---

Query the Obsidian knowledge vault using CPU ColBERTv2 MaxSim semantic retrieval:

```bash
python3 -c "from harness.mcp.vault_server import colbert_retrieve; import json, sys; print(json.dumps(colbert_retrieve('$ARGUMENTS', top_k=5), indent=2))"
```

Summarize the retrieved notes, architecture decisions, and relevance scores.
