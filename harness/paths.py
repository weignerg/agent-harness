"""Authoritative filesystem path resolution, repository root anchoring, and directory discipline."""
from __future__ import annotations

import os
import subprocess
from pathlib import Path
from typing import Optional, Union


def resolve_true_repo_root(start_path: Optional[Union[Path, str]] = None) -> Optional[Path]:
    """Resolve the true canonical root of the git repository.
    
    If invoked inside a git worktree, submodule, or arbitrary nested subdirectory,
    anchors to the common git directory parent, avoiding worktree-local nesting.
    Falls back to upward directory traversal checking for .git or .orchestration.
    Returns None if no repository root or orchestration anchor is found.
    """
    start = Path(start_path).resolve() if start_path else Path.cwd()
    if start.is_file():
        start = start.parent

    # Attempt git common-dir resolution via git CLI
    try:
        res = subprocess.run(
            ["git", "rev-parse", "--path-format=absolute", "--git-common-dir"],
            cwd=start,
            capture_output=True,
            text=True,
            check=False,
        )
        if res.returncode != 0:
            res = subprocess.run(
                ["git", "rev-parse", "--git-common-dir"],
                cwd=start,
                capture_output=True,
                text=True,
                check=False,
            )
        if res.returncode == 0:
            out = res.stdout.strip()
            if out:
                common_path = Path(out)
                if not common_path.is_absolute():
                    common_path = (start / common_path).resolve()
                else:
                    common_path = common_path.resolve()

                if common_path.name == ".git":
                    return common_path.parent
                return common_path
    except Exception:
        pass

    # Fallback to upward directory traversal
    for d in [start] + list(start.parents):
        git_entry = d / ".git"
        if git_entry.exists():
            if git_entry.is_file():
                try:
                    content = git_entry.read_text(encoding="utf-8").strip()
                    if content.startswith("gitdir:"):
                        gitdir_raw = content.split("gitdir:", 1)[1].strip()
                        gitdir_path = Path(gitdir_raw)
                        if not gitdir_path.is_absolute():
                            gitdir_path = (d / gitdir_path).resolve()
                        parts = gitdir_path.parts
                        if ".git" in parts:
                            idx = parts.index(".git")
                            return Path(*parts[:idx])
                except Exception:
                    pass
            return d
        if (d / ".orchestration").is_dir():
            return d

    return None


def parse_anchor_file(file_path: Path, base_dir: Optional[Path] = None) -> Optional[Path]:
    """Parse .orchestration_root anchor file to extract authoritative root path."""
    try:
        if not file_path.is_file():
            return None
        text = file_path.read_text(encoding="utf-8")
        anchor_base = base_dir
        if anchor_base is None:
            anchor_base = file_path.parent.parent if file_path.parent.name == ".orchestration" else file_path.parent

        for line in text.splitlines():
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            if line.startswith("root="):
                val = line.split("root=", 1)[1].strip().strip('"\'')
                if val:
                    target = Path(val).expanduser()
                    return target if target.is_absolute() else (anchor_base / target).resolve()
            elif "=" not in line:
                val = line.strip().strip('"\'')
                if val:
                    target = Path(val).expanduser()
                    return target if target.is_absolute() else (anchor_base / target).resolve()
    except Exception:
        pass
    return None


def resolve_authoritative_orchestration_root(start_path: Optional[Union[Path, str]] = None) -> Path:
    """Resolve authoritative .orchestration root directory strictly adhering to 4-tier hierarchy.
    
    Priority 1: os.environ.get("ORCHESTRATION_ROOT") if set and non-empty.
    Priority 2: Persistent anchor file .orchestration_root:
                - true_repo / ".orchestration_root"
                - true_repo / ".orchestration" / ".orchestration_root"
                - start_path anchor files if true_repo is None
    Priority 3: True main repository root (true_repo):
                - If (true_repo / ".orchestration").is_dir(), return (true_repo / ".orchestration").resolve()
                - If (true_repo / ".agents").is_symlink() and targets an .orchestration dir, return target
                CRITICAL: Never return or create <worktree>/.orchestration.
    Priority 4: Fallback to global (Path.home() / ".orchestration").resolve()
                (also checking ~/.orchestration/.orchestration_root if present).
    """
    # Priority 1: Environment variable override
    env_root = os.environ.get("ORCHESTRATION_ROOT")
    if env_root and env_root.strip():
        return Path(env_root.strip()).expanduser().resolve()

    start = Path(start_path).resolve() if start_path else Path.cwd()
    if start.is_file():
        start = start.parent

    true_repo = resolve_true_repo_root(start)

    # Priority 2: Persistent anchor file .orchestration_root in repository
    if true_repo:
        repo_anchors = [
            true_repo / ".orchestration_root",
            true_repo / ".orchestration" / ".orchestration_root",
        ]
        for anchor in repo_anchors:
            parsed = parse_anchor_file(anchor, base_dir=true_repo)
            if parsed:
                return parsed
    else:
        start_anchors = [
            start / ".orchestration_root",
            start / ".orchestration" / ".orchestration_root",
        ]
        for anchor in start_anchors:
            parsed = parse_anchor_file(anchor, base_dir=start)
            if parsed:
                return parsed

    # Priority 3: True main repository root
    if true_repo:
        repo_orch = true_repo / ".orchestration"
        if repo_orch.is_dir():
            return repo_orch.resolve()

        repo_agents = true_repo / ".agents"
        if repo_agents.is_symlink():
            try:
                target = repo_agents.resolve()
                if target.name == ".orchestration" or target.is_dir():
                    return target
            except Exception:
                pass

    # Priority 4: Check global anchor file ~/.orchestration/.orchestration_root or fallback
    global_anchor = Path.home() / ".orchestration" / ".orchestration_root"
    parsed_global = parse_anchor_file(global_anchor)
    if parsed_global:
        return parsed_global

    return (Path.home() / ".orchestration").resolve()


def resolve_canonical_worktree_dir(start_path: Optional[Union[Path, str]] = None) -> Path:
    """Resolve the canonical worktree directory strictly under <authoritative_orchestration_root>/worktrees."""
    orch_root = resolve_authoritative_orchestration_root(start_path)
    return (orch_root / "worktrees").resolve()


def resolve_worktree_path(branch_name: str, start_path: Optional[Union[Path, str]] = None) -> Path:
    """Resolve the canonical worktree path for a branch strictly under <authoritative_orchestration_root>/worktrees/<branch_name>."""
    return (resolve_canonical_worktree_dir(start_path) / branch_name).resolve()
