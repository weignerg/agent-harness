"""Dedicated FastMCP server for Obsidian knowledge vault and ColBERTv2 semantic memory."""
from __future__ import annotations

from pathlib import Path
from typing import Any, Dict, List, Optional

from fastmcp import FastMCP
from pydantic import BaseModel, ConfigDict, Field

server = FastMCP("vault-memory")

class StrictModel(BaseModel):
    model_config = ConfigDict(extra="forbid")

class ColBERTRetrieveInput(StrictModel):
    query: str = Field(description="Search query string for late-interaction semantic retrieval")
    top_k: int = Field(default=5, ge=1, le=20, description="Maximum number of results to return")
    index_dir: Optional[str] = Field(default=None, description="Optional path to persistent index directory or vault")

@server.tool(name="colbert_retrieve", description="Search memory index or Obsidian knowledge vault using ColBERTv2 CPU MaxSim retrieval")
def colbert_retrieve(query: str, top_k: int = 5, index_dir: Optional[str] = None) -> List[Dict[str, Any]]:
    from harness.memory.colbert_engine import CPUColBERTIndex

    if index_dir:
        idx_path = Path(index_dir)
    else:
        # Auto-detect local repository sub-vault if ORCHESTRATION_ROOT or local repo is active
        import os
        orch_root = os.environ.get("ORCHESTRATION_ROOT")
        local_vault = None
        if orch_root:
            cand = Path(orch_root)
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
        elif (Path.home() / "Vaults/home/.index/index.json").exists() or (Path.home() / "Vaults/home").is_dir():
            idx_path = Path.home() / "Vaults/home"
        else:
            idx_path = Path("vault")

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

if __name__ == "__main__":
    server.run()
