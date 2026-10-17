"""FastMCP server with strict JSON schema transpilation, Claude Code filesystem tools,
and auto-mode dangerous command guardrails."""
from __future__ import annotations

import os
import re
import subprocess
from pathlib import Path
from typing import Any, Dict, List, Optional

from fastmcp import FastMCP
from pydantic import BaseModel, ConfigDict, Field

server = FastMCP("opencode-harness-tools")

# Dangerous command patterns for bash guardrail
DANGEROUS_PATTERNS = [
    (re.compile(r"\brm\s+-[rRfF]*[rR][rRfF]*\s+"), "recursive file deletion (rm -rf)"),
    (re.compile(r"\bchmod\s+(-[a-zA-Z0-9]+\s+)?([0-7]{3,4}|[ugoarwx+-=]+)\s+"), "permission mutation (chmod)"),
    (re.compile(r"\bmkfs(\.[a-zA-Z0-9]+)?\b"), "filesystem creation (mkfs)"),
    (re.compile(r"\bgit\s+reset\s+--hard\b"), "destructive git reset (--hard)"),
    (re.compile(r"\bdd\s+if="), "raw device write (dd)"),
    (re.compile(r"\b(shutdown|reboot|poweroff|init\s+0)\b"), "system power cycle"),
]

def check_command_safety(command: str) -> Optional[str]:
    """Returns warning reason if command is deemed potentially destructive, else None."""
    for pattern, reason in DANGEROUS_PATTERNS:
        if pattern.search(command):
            return f"Blocked dangerous command: {reason}"
    return None

class StrictModel(BaseModel):
    model_config = ConfigDict(extra="forbid")

class ViewFileInput(StrictModel):
    path: str = Field(description="Target file path to view")
    start_line: Optional[int] = Field(default=None, ge=1, description="1-indexed starting line number")
    end_line: Optional[int] = Field(default=None, ge=1, description="1-indexed ending line number")

class ReplaceFileContentInput(StrictModel):
    path: str = Field(description="Target file path to edit")
    target: str = Field(description="Exact unique substring to replace")
    replacement: str = Field(description="Replacement string")

class WriteToFileInput(StrictModel):
    path: str = Field(description="Target file path to write")
    content: str = Field(description="File content to write")
    overwrite: bool = Field(default=False, description="Allow overwriting existing file")
    append: bool = Field(default=False, description="Append content to existing file")

class BashInput(StrictModel):
    command: str = Field(description="Shell command to execute")
    cwd: Optional[str] = Field(default=None, description="Working directory")
    allow_dangerous: bool = Field(default=False, description="Explicit approval gate for dangerous operations")

class ColBERTRetrieveInput(StrictModel):
    query: str = Field(description="Search query string for late-interaction semantic retrieval")
    top_k: int = Field(default=5, ge=1, le=20, description="Maximum number of results to return")
    index_dir: Optional[str] = Field(default=None, description="Optional path to persistent index directory or vault")

@server.tool(name="view_file", description="View contents of a file with line-indexed slicing")
def view_file(path: str, start_line: Optional[int] = None, end_line: Optional[int] = None) -> str:
    p = Path(path)
    if not p.is_file():
        raise FileNotFoundError(f"File not found: {path}")
    lines = p.read_text(errors="replace").splitlines()
    total = len(lines)
    s = (start_line - 1) if start_line is not None else 0
    e = end_line if end_line is not None else total
    s = max(0, min(s, total))
    e = max(s, min(e, total))
    selected = lines[s:e]
    output = []
    for idx, line in enumerate(selected, start=s + 1):
        output.append(f"{idx:4d}: {line}")
    return "\n".join(output)

@server.tool(name="replace_file_content", description="Replace exact unique substring in a file")
def replace_file_content(path: str, target: str, replacement: str) -> str:
    p = Path(path)
    if not p.is_file():
        raise FileNotFoundError(f"File not found: {path}")
    content = p.read_text()
    count = content.count(target)
    if count == 0:
        raise ValueError(f"Target substring not found in {path}")
    if count > 1:
        raise ValueError(f"Target substring matched {count} times in {path}; must be unique")
    new_content = content.replace(target, replacement, 1)
    p.write_text(new_content)
    return f"Successfully replaced content in {path}"

@server.tool(name="write_to_file", description="Create or write file content with overwrite/append guards")
def write_to_file(path: str, content: str, overwrite: bool = False, append: bool = False) -> str:
    if overwrite and append:
        raise ValueError("Cannot specify both overwrite=True and append=True")
    p = Path(path)
    if p.exists() and not (overwrite or append):
        raise FileExistsError(f"File {path} exists. Set overwrite=True or append=True.")
    p.parent.mkdir(parents=True, exist_ok=True)
    if append:
        with open(p, "a") as f:
            f.write(content)
        return f"Appended content to {path}"
    else:
        p.write_text(content)
        return f"Wrote content to {path}"

@server.tool(name="bash", description="Safely execute bash command with auto-mode guardrails")
def bash(command: str, cwd: Optional[str] = None, allow_dangerous: bool = False) -> dict[str, Any]:
    warning = check_command_safety(command)
    if warning and not allow_dangerous:
        return {
            "status": "blocked",
            "reason": warning,
            "stdout": "",
            "stderr": "Execution blocked by auto-mode security guardrail. Set allow_dangerous=True to confirm.",
            "returncode": 126
        }
    proc = subprocess.run(
        command,
        shell=True,
        cwd=cwd,
        capture_output=True,
        text=True
    )
    return {
        "status": "executed",
        "stdout": proc.stdout,
        "stderr": proc.stderr,
        "returncode": proc.returncode
    }

@server.tool(name="colbert_retrieve", description="Search memory index or Obsidian knowledge vault using ColBERTv2 CPU MaxSim retrieval")
def colbert_retrieve(query: str, top_k: int = 5, index_dir: Optional[str] = None) -> List[Dict[str, Any]]:
    from harness.memory.colbert_engine import CPUColBERTIndex

    if index_dir:
        idx_path = Path(index_dir)
    elif (Path.home() / "Vaults/home/.index/index.json").exists() or (Path.home() / "Vaults/home").is_dir():
        idx_path = Path.home() / "Vaults/home"
    else:
        idx_path = Path("vault")

    cache_path = idx_path / ".index" if (idx_path / ".index").is_dir() or idx_path.name in ("vault", "home") else idx_path
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

def get_strict_schemas() -> dict[str, Any]:
    """Retrieve all tool schemas ensuring strict: True and additionalProperties: False."""
    import asyncio
    tools = asyncio.run(server.list_tools())
    schemas = {}
    for t in tools:
        schema = dict(getattr(t, "input_schema", getattr(t, "inputSchema", {})))
        schema["additionalProperties"] = False
        schema["strict"] = True
        schemas[t.name] = schema
    return schemas

if __name__ == "__main__":
    server.run()
