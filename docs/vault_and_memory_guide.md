# Knowledge Vault & Polymorphic Semantic Memory Guide

## 1. Executive Summary & Architectural Overview

The **Polymorphic Memory Engine** in `agent-harness` delivers long-term episodic and semantic memory across disparate autonomous agent environments (**Google Antigravity**, **Anthropic Claude Code**, and **OpenCode / SGLang**).

Unlike naive text grep or lossy vector embeddings that compress entire markdown files into a single dense vector, `agent-harness` couples:
1. **Hierarchical Obsidian Knowledge Vaults**: Markdown-native entities, decisions (ADRs), protocols, and project trackers.
2. **CPU-Accelerated ColBERTv2 Late-Interaction Retrieval**: High-precision token-level late-interaction search running exclusively on host CPU cores with zero GPU VRAM consumption.
3. **Automated 5-Minute Systemd Reindexing**: Background reindexing maintaining fresh vector indexes without developer intervention.
4. **FastMCP `colbert_retrieve` Integration**: Model Context Protocol tool enabling agents to inject exact semantic context directly into their context windows.

---

## 2. Primary Vault vs. Repository Sub-Vaults

Memory in `agent-harness` is partitioned to prevent cross-project context pollution while preserving global knowledge access:

```
~/Vaults/
├── home/                         # Primary Personal / System Knowledge Vault
│   ├── entities/                 # Hardware specs, backend models, agent rosters
│   ├── decisions/                # Global architectural decision records (ADRs)
│   ├── protocols/                # Standing operating procedures (SOPs)
│   ├── projects/                 # Cross-repository initiatives & roadmaps
│   ├── .obsidian/                # Obsidian workspace, graph, appearance settings
│   └── .index/                   # ColBERTv2 index (home/ scope)
│       └── index.json
└── repos/                        # Per-Repository Sub-Vault Category
    ├── wow-forever-controller/   # Symlink -> /path/to/wow-forever-controller/vault
    ├── agent-harness/            # Symlink -> /path/to/agent-harness/vault
    └── <repo_name>/              # Symlink -> <repo_path>/vault
        ├── entities/             # Repo-specific modules, boundaries, domain logic
        ├── decisions/            # Repo-specific ADRs
        ├── protocols/            # Repo testing, branch hygiene, release SOPs
        ├── projects/             # Active sprint plans & implementation designs
        ├── .obsidian/            # Sub-vault workspace configuration
        └── .index/               # ColBERTv2 index (<repo>/ scope)
            └── index.json
```

### 2.1 The Primary Vault (`~/Vaults/home`)
- Anchored at `~/Vaults/home` (scaffolded automatically during global installation).
- Contains host-wide reference material, hardware specs (e.g. RTX 5090 Blackwell profiling), model catalogs, and personal workflows.
- Registered as the default open vault in Obsidian Desktop (`~/.config/obsidian/obsidian.json`).

### 2.2 Repository Sub-Vaults (`<repo>/vault`)
- Resides directly inside each project repository at `<repo>/vault` (and mirrored in `<repo>/.orchestration/memory`).
- Commits project architectural memory alongside source code for version-controlled traceability.
- Symlinked into `~/Vaults/repos/<repo_name>` so all project vaults are accessible inside Obsidian Desktop in one click.

---

## 3. Sub-Vault Scaffolding with `scripts/scaffold_subvault.sh`

To provision a new repository sub-vault, execute `scripts/scaffold_subvault.sh`:

```bash
# Scaffold sub-vault for current repository
./scripts/scaffold_subvault.sh

# Or specify a targeted repository path:
./scripts/scaffold_subvault.sh /path/to/target-repo
```

### Scaffolding Actions Performed:
1. **Directory Tree Creation**: Generates `entities/`, `decisions/`, `protocols/`, `projects/`, `.obsidian/`, and `.index/` in both `<repo>/vault/` and `<repo>/.orchestration/memory/`.
2. **Template Population**:
   - `overview.md`: Repository mission, executive architecture overview, and navigation index.
   - `workflow.md`: Polymorphic agent roles, branch governance (`.orchestration/worktrees/<branch>`), and git workflows.
   - `decisions/0001-baseline.md`: Initial ADR establishing repository standards.
3. **Obsidian Auto-Registration**: Safely updates `~/.config/obsidian/obsidian.json` with MD5 vault identifier.
4. **Symlink Wiring**: Creates `~/Vaults/repos/<repo_name> -> <repo>/vault`.
5. **Initial Vector Indexing**: Immediately indexes markdown assets via `scripts/reindex_vault.sh`.

---

## 4. ColBERTv2 CPU MaxSim Retrieval Engine & Math

Traditional dense retrieval averages token embeddings into a single 768-dimensional or 1536-dimensional vector:
$$\mathbf{v}_{\text{doc}} = \frac{1}{|D|} \sum_{j=1}^{|D|} \mathbf{e}_j$$

This averaging causes severe "semantic blurring" on technical documentation containing specific variable names, flags, and architecture boundaries.

### 4.1 Late-Interaction MaxSim Scoring
ColBERTv2 preserves token-level bag-of-embeddings for both query $Q = (q_1, q_2, \dots, q_m)$ and document $D = (d_1, d_2, \dots, d_n)$:

$$S(Q, D) = \sum_{i=1}^{|Q|} \max_{j=1}^{|D|} \left( \frac{\mathbf{E}_Q(q_i) \cdot \mathbf{E}_D(d_j)}{\|\mathbf{E}_Q(q_i)\| \|\mathbf{E}_D(d_j)\|} \right)$$

For each query token embedding, ColBERT finds the maximum cosine similarity across all document token embeddings (**MaxSim**) and sums them. This enables:
- Exact symbol matching without keyword search brittle failures.
- Fine-grained semantic alignment across disparate phrasing.
- Robust multi-hop architectural reasoning.

### 4.2 Pure CPU Execution Invariant
All vector operations and token similarity computations execute on host CPU cores via NumPy vectorization:
- **Zero GPU VRAM Consumption**: The local SGLang inference server (e.g. Ornith 35B NVFP4 on RTX 5090) maintains 100% of GPU memory for LLM weights and KV cache.
- **Sub-10ms Latency**: Queries execute in under 10 milliseconds across thousands of documents.

---

## 5. Automated 5-Minute Reindexing

Memory indexing runs both automatically on a 5-minute systemd timer and on-demand via CLI:

### 5.1 Systemd Timer & Service Units
- `config/systemd/opencode-colbert-reindex.timer`: Fires every 5 minutes (`OnUnitActiveSec=5min`, `RandomizedDelaySec=15`).
- `config/systemd/opencode-colbert-reindex.service`: Executes `scripts/reindex_vault.sh` across all vaults.

```bash
# Check timer status
systemctl --user status opencode-colbert-reindex.timer

# View reindex execution logs
journalctl --user -u opencode-colbert-reindex.service -n 20
```

### 5.2 Manual / On-Demand Reindexing
```bash
# Reindex all vaults (home + all repos)
./scripts/reindex_vault.sh

# Reindex a specific repository sub-vault:
./scripts/reindex_vault.sh /path/to/target-repo/vault
```

---

## 6. FastMCP Tool Server: `colbert_retrieve`

The `vault-memory` FastMCP server exposes semantic retrieval directly to AI agents:

### 6.1 Tool Specification
- **Tool Name**: `colbert_retrieve`
- **Arguments**:
  - `query` (`string`, required): Search query string for late-interaction semantic retrieval.
  - `top_k` (`integer`, optional, default 5, range 1-20): Maximum documents to return.
  - `index_dir` (`string`, optional): Explicit path to persistent index directory or vault.

### 6.2 Dynamic Sub-Vault Auto-Detection
When `index_dir` is omitted, `colbert_retrieve` auto-detects the active repository scope:
1. If `ORCHESTRATION_ROOT` is set and points to `<repo>/.orchestration`, it resolves `<repo>/vault` or `<repo>/.orchestration/memory`.
2. If the current working directory contains `./vault`, it scopes search to the local repository vault.
3. If no local vault is active, it defaults to `~/Vaults/home`.

---

## 7. Context Injection & Autonomous Agent Workflows

Autonomous agents query `colbert_retrieve` during the initial survey phase:
- **Architect Subagent**: Queries architectural decisions (`ADR 0001`) and entity boundaries before writing implementation blueprints.
- **Worker Subagent**: Retrieves standing protocols (`workflow.md`, coding standards) to ensure generated commits comply with project rules.
- **Reviewer Subagent**: Cross-references pull requests against security protocols and historical regression records.
