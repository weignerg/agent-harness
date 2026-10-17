# ~/Vault.md — Personal Memory Vault Design & Ops

Document: 2026-10-12
Purpose: record the design, structure, and maintenance routine of the personal
ColBERT knowledge vault.

## 1. What this is
`~/Vaults/` is the personal memory / knowledge vault. It powers memory search
(`harness-tools_colbert_retrieve`) via a CPU-only ColBERTv2 index.

- It is a **home-user vault** (personal), **not** part of any installable repo.
- The old install location was the `open-code-harness/vault` directory (a symlink
  at `~/.config/opencode-backends/vault`). That contents were migrated here.

## 2. Why
The original vault lived inside the open-source `open-code-harness` repo, which
is meant to *install* on a system, not to carry personal tracker notes. We moved
the personal vault to a home-user location so personal notes never pollute the
installable repo.

## 3. Layout
```
~/Vaults/
  home/                       # THE home user vault (its own .index)
    .obsidian/                # migrated (workspace, core-plugins, appearance, graph, app)
    entities/                 # models, servers, agent catalog (migrated)
    templates/                # front-matter templates (migrated)
    decisions/                # architectural / operational decisions
    protocols/                # standing procedures (maintenance)
    projects/                 # home-ops / cross-source notes
    .index/                   # ColBERT index for home/
  repos/                      # category: one independent per-source sub-vault
    wow-forever-controller/   .obsidian/ .index/ projects/ docs/
    wow-ui-source/            .obsidian/ .index/ projects/ docs/
    ...                        # add sources here
```

Design: the home vault holds cross-source reference content; each source has its
own sub-vault under `repos/` with a separate `.index` (one vault per source,
queried individually).

### 3.1 Location rationale
- `~/.data` or `~/.vault` were considered. Chose `~/Vaults/` as the home-user
  root. The key requirement was: **personal notes live under the home user's
  home directory, outside any installable git repo.** `~/Vaults/` satisfies that.

## 4. How memory search works
Memory search loads an index from an `index_dir` that contains `index.json`, then
runs ColBERT MaxSim retrieval. Each location is queried by its `index_dir`:

| Location | index_dir |
|----------|-----------|
| home vault | `~/Vaults/home/.index` |
| wow-forever-controller | `~/Vaults/repos/wow-forever-controller/.index` |
| wow-ui-source | `~/Vaults/repos/wow-ui-source/.index` |

Sub-vaults are searched independently (per-source). Pass the target `index_dir`
to `harness-tools_colbert_retrieve` to scope a query to one source.

## 5. Adding a source
1. Create the sub-vault directory:
   ```
   mkdir -p ~/Vaults/repos/<name>/{projects,docs,.obsidian,.index}
   ```
2. Copy a sibling sub-vault's `.obsidian/` config (they are independent vaults).
3. Write `projects/<name>.md` (dossier: purpose, build/test, source map,
   open-issue snapshot) and `docs/README.md` (maintenance note).
4. Reindex just that source:
   ```
   scripts/reindex_vault.sh ~/Vaults/repos/<name>
   ```

## 6. Maintenance (reindex)
The engine writes `index.json` into `index_dir` (a sub-vault's `.index/`).
After any edit to a `.md` note, rebuild the index.

- Single location:
  ```
  scripts/reindex_vault.sh ~/Vaults/home
  scripts/reindex_vault.sh ~/Vaults/repos/wow-forever-controller
  scripts/reindex_vault.sh ~/Vaults/repos/wow-ui-source
  ```
- Everything (home + all source sub-vaults):
  ```
  scripts/reindex_vault.sh --all
  ```

Scripts:
- `scripts/reindex_vault.sh <path>...` — rebuild one or more locations.
- `scripts/reindex_vault.sh --all` — rebuild the home vault + every `repos/*/`.
- Both reuse the CPU-only ColBERT engine from the harness environment (override with `ENGINE_REPO=`).

### 6.1 Automation
- Manual cadence (after material edits) is the default.
- The systemd hourly timer (`opencode-colbert-reindex.timer`, unit
  `opencode-colbert-reindex.service`) is already wired to run
  `scripts/reindex_vault.sh --all` on each run, reindexing the home vault + every
  `repos/*/` sub-vault. No manual setup is required.

## 7. Per-source maintenance files
Each source sub-vault carries `docs/README.md` documenting how that source's
notes are kept updated (source-map refresh, issue-snapshot refresh, reindex
commands). See each sub-vault's `docs/README.md`.

## 8. Open questions (not yet decided)
- Whether to also index source *code* (currently only `.md` notes are indexed).
