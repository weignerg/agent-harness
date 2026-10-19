"""Dedicated FastMCP server for Obsidian knowledge vault and ColBERTv2 semantic memory."""
from __future__ import annotations

import contextlib
import fcntl
import hashlib
import logging
import os
import re
import sys
import time
from pathlib import Path
from typing import Any, Dict, List, Optional

# Enforce strict STDIO hygiene: suppress library banners on stdout to preserve JSON-RPC stream
os.environ["TOKENIZERS_PARALLELISM"] = "false"
os.environ["TQDM_DISABLE"] = "1"
os.environ["TRANSFORMERS_VERBOSITY"] = "error"
logging.basicConfig(stream=sys.stderr, level=logging.WARNING)

from fastmcp import FastMCP
from pydantic import BaseModel, ConfigDict, Field

server = FastMCP("vault-memory")

# Canonical default absolute paths
HARNESS_ROOT = Path(os.environ.get("HARNESS_ROOT", Path(__file__).resolve().parent.parent.parent)).resolve()
ORCHESTRATION_ROOT = Path(os.environ.get("ORCHESTRATION_ROOT", Path.home() / ".orchestration")).expanduser().resolve()
OBSIDIAN_VAULT_PATH = Path(os.environ.get("OBSIDIAN_VAULT_PATH", Path.home() / "Vaults/home")).expanduser().resolve()
COLBERT_INDEX_PATH = Path(os.environ.get("COLBERT_INDEX_PATH", OBSIDIAN_VAULT_PATH / ".index")).expanduser().resolve()


class StrictModel(BaseModel):
    model_config = ConfigDict(extra="forbid")


class ColBERTRetrieveInput(StrictModel):
    query: str = Field(description="Search query string for late-interaction semantic retrieval")
    top_k: int = Field(default=5, ge=1, le=20, description="Maximum number of results to return")
    index_dir: Optional[str] = Field(default=None, description="Optional path to persistent index directory or vault")


class SaveDistilledDecisionInput(StrictModel):
    title: str = Field(description="Title of the architectural decision")
    context: str = Field(description="Context and problem statement")
    decision: str = Field(description="The change or architectural decision made")
    consequences: str = Field(description="Resulting tradeoffs, impacts, and follow-ups")
    tags: Optional[List[str]] = Field(default=None, description="Optional categorical tags for Obsidian frontmatter")
    vault_path: Optional[str] = Field(default=None, description="Optional override path to Obsidian vault root")


def _sanitize_slug(title: str) -> str:
    """Sanitize title into lowercase alphanumeric slug."""
    slug = re.sub(r"[^a-zA-Z0-9_-]+", "-", title.strip().lower())
    return slug.strip("-") or "decision"


@server.tool(name="colbert_retrieve", description="Search memory index or Obsidian knowledge vault using ColBERTv2 CPU MaxSim retrieval")
def colbert_retrieve(query: str, top_k: int = 5, index_dir: Optional[str] = None) -> List[Dict[str, Any]]:
    with contextlib.redirect_stdout(sys.stderr):
        from harness.memory.colbert_engine import CPUColBERTIndex

        if index_dir:
            idx_path = Path(index_dir).resolve()
        else:
            # Auto-detect local repository sub-vault if ORCHESTRATION_ROOT or local repo is active
            orch_root = os.environ.get("ORCHESTRATION_ROOT")
            local_vault = None
            if orch_root:
                cand = Path(orch_root).resolve()
                if cand.name == ".orchestration" and (cand.parent / "vault").is_dir():
                    local_vault = cand.parent / "vault"
                elif (cand / "memory").is_dir() and any((cand / "memory").glob("*.md")):
                    local_vault = cand / "memory"
                elif (cand.parent / "vault").is_dir():
                    local_vault = cand.parent / "vault"
            if not local_vault and (Path.cwd() / "vault").is_dir():
                local_vault = Path.cwd() / "vault"

            if local_vault and ((local_vault / ".index/index.json").exists() or any(local_vault.glob("*.md"))):
                idx_path = local_vault
            elif (OBSIDIAN_VAULT_PATH / ".index/index.json").exists() or OBSIDIAN_VAULT_PATH.is_dir():
                idx_path = OBSIDIAN_VAULT_PATH
            else:
                idx_path = (HARNESS_ROOT / "vault").resolve()

        cache_path = idx_path / ".index" if (idx_path / ".index").is_dir() or idx_path.name in ("vault", "home", "memory") else idx_path
        idx = CPUColBERTIndex(index_dir=cache_path if (cache_path / "index.json").exists() else None)

        if (cache_path / "index.json").exists():
            idx.load(cache_path)
        elif idx_path.is_dir():
            for md_file in idx_path.rglob("*.md"):
                try:
                    rel = str(md_file.relative_to(idx_path))
                    text = md_file.read_text(errors="replace")
                    idx.add_document(rel, text)
                except Exception:
                    continue

        return idx.search(query, top_k=top_k)


@server.tool(name="save_distilled_decision", description="Atomically save a distilled architectural decision note with SHA-256 deduplication into Obsidian vault")
def save_distilled_decision(
    title: str,
    context: str,
    decision: str,
    consequences: str,
    tags: Optional[List[str]] = None,
    vault_path: Optional[str] = None,
) -> Dict[str, Any]:
    with contextlib.redirect_stdout(sys.stderr):
        vpath = Path(vault_path).resolve() if vault_path else OBSIDIAN_VAULT_PATH
        decisions_dir = vpath / "decisions"
        decisions_dir.mkdir(parents=True, exist_ok=True)

        slug = _sanitize_slug(title)
        target_file = decisions_dir / f"{slug}.md"
        lock_file = decisions_dir / ".lock"

        # Content hash for deduplication
        raw_content = f"{title.strip()}\n{context.strip()}\n{decision.strip()}\n{consequences.strip()}"
        content_hash = hashlib.sha256(raw_content.encode("utf-8")).hexdigest()

        tag_list = tags or ["decision", "architecture"]
        tags_str = ", ".join(tag_list)
        timestamp = time.strftime("%Y-%m-%d %H:%M:%S")

        note_content = f"""---
title: "{title.replace('"', '\\"')}"
date: {timestamp}
sha256: {content_hash}
tags: [{tags_str}]
---

# {title}

## Context & Problem Statement
{context}

## Decision
{decision}

## Consequences & Tradeoffs
{consequences}
"""

        # Acquire file lock to ensure atomic operations across concurrent subagents
        with open(lock_file, "w") as lock_f:
            fcntl.flock(lock_f, fcntl.LOCK_EX)
            try:
                # Check for existing note with identical SHA-256
                if target_file.is_file():
                    existing_text = target_file.read_text(encoding="utf-8", errors="replace")
                    if f"sha256: {content_hash}" in existing_text:
                        return {
                            "status": "already_exists",
                            "path": str(target_file),
                            "sha256": content_hash,
                            "slug": slug,
                        }

                # Atomic write: write to .tmp then replace
                tmp_file = target_file.with_name(f"{target_file.name}.tmp.{os.getpid()}")
                tmp_file.write_text(note_content, encoding="utf-8")
                os.replace(tmp_file, target_file)

                # Incremental add to ColBERT index if index cache exists
                cache_path = vpath / ".index"
                if (cache_path / "index.json").exists():
                    try:
                        from harness.memory.colbert_engine import CPUColBERTIndex
                        idx = CPUColBERTIndex(index_dir=cache_path)
                        idx.load(cache_path)
                        idx.add_document(f"decisions/{slug}.md", note_content)
                        idx.save(cache_path)
                    except Exception as idx_err:
                        sys.stderr.write(f"[vault-memory] Index update error: {idx_err}\n")

                return {
                    "status": "saved",
                    "path": str(target_file),
                    "sha256": content_hash,
                    "slug": slug,
                }
            finally:
                fcntl.flock(lock_f, fcntl.LOCK_UN)


if __name__ == "__main__":
    server.run()
