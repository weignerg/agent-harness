---
name: vault-retrieval
description: Query and search the Obsidian knowledge vault using CPU ColBERTv2 MaxSim semantic retrieval. Use when looking up architecture decisions, entity notes, system design, or memory in ~/Vaults/home.
---

# Vault Retrieval Skill

Use this skill to query and inspect notes in the local Obsidian Knowledge Vault (`~/Vaults/home`).

## When to Use
- Searching for architecture decisions, design rationale, or protocol guidelines.
- Looking up hardware profiles, entity definitions (`entities/`), or project specs (`projects/`).
- Retrieving context across multi-vault repositories in `~/Vaults/repos/`.

## Retrieval Methods

### 1. Via FastMCP Tool (`colbert_retrieve`)
When the `vault-memory` MCP server is enabled, call `colbert_retrieve`:
```json
{
  "query": "SGLang KV-cache memory fraction",
  "top_k": 5
}
```

### 2. Via Reindexer CLI
To update or rebuild the index over newly modified notes:
```bash
~/.agents/tools/reindex_vault.sh --all
```
