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


def parse_anchor_metadata(file_path: Path) -> dict[str, str]:
    """Parse .orchestration_root anchor file returning key-value metadata dictionary."""
    meta: dict[str, str] = {}
    if not file_path.is_file():
        return meta
    try:
        text = file_path.read_text(encoding="utf-8")
        for line in text.splitlines():
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            if "=" in line:
                k, v = line.split("=", 1)
                meta[k.strip().lower()] = v.strip().strip('"\'')
            else:
                val = line.strip().strip('"\'')
                if val.lower() in ("local", "global"):
                    meta["mode"] = val.lower()
                else:
                    meta["root"] = val
    except Exception:
        pass
    return meta


def parse_anchor_file(file_path: Path, base_dir: Optional[Path] = None) -> Optional[Path]:
    """Parse .orchestration_root anchor file to extract authoritative root path."""
    try:
        if not file_path.is_file():
            return None
        anchor_base = base_dir
        if anchor_base is None:
            anchor_base = file_path.parent.parent if file_path.parent.name == ".orchestration" else file_path.parent

        meta = parse_anchor_metadata(file_path)
        if "root" in meta and meta["root"]:
            target = Path(meta["root"]).expanduser()
            return target if target.is_absolute() else (anchor_base / target).resolve()
    except Exception:
        pass
    return None


def is_local_orchestration(repo_path: Optional[Union[Path, str]] = None) -> bool:
    """Check if repository explicitly declares local orchestration mode via .orchestration_root."""
    target_dir = Path(repo_path).resolve() if repo_path else (resolve_true_repo_root() or Path.cwd())
    if target_dir.is_file():
        target_dir = target_dir.parent

    anchors = [
        target_dir / ".orchestration_root",
        target_dir / ".orchestration" / ".orchestration_root",
    ]
    for anchor in anchors:
        if anchor.is_file():
            meta = parse_anchor_metadata(anchor)
            mode = meta.get("mode", "").lower()
            if mode == "local":
                return True
            if mode != "global" and "root" in meta:
                return True
    return False


def resolve_authoritative_orchestration_root(start_path: Optional[Union[Path, str]] = None) -> Path:
    """Resolve authoritative .orchestration root directory strictly adhering to Option A hierarchy:
    
    Priority 1: os.environ.get("ORCHESTRATION_ROOT") if set and non-empty.
    Priority 2: Explicit Local Installation Anchor:
                Check if true_repo / ".orchestration_root" or true_repo / ".orchestration" / ".orchestration_root" exists.
                If and only if it explicitly declares local mode (or root=<path>), return the resolved root.
                CRITICAL CHANGE: Simply having .orchestration/ dir in repo without mode=local anchor
                falls through to Priority 3 (global)!
    Priority 3: Global User Root (~/.orchestration):
                Return (Path.home() / ".orchestration").resolve()
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

    # Priority 2: Explicit Local Installation Anchor
    if true_repo:
        repo_anchors = [
            true_repo / ".orchestration_root",
            true_repo / ".orchestration" / ".orchestration_root",
        ]
        for anchor in repo_anchors:
            if anchor.is_file():
                meta = parse_anchor_metadata(anchor)
                mode = meta.get("mode", "").lower()
                root_val = meta.get("root")
                if mode == "local" or (mode != "global" and root_val is not None):
                    if root_val:
                        target = Path(root_val).expanduser()
                        return target if target.is_absolute() else (true_repo / target).resolve()
                    return (true_repo / ".orchestration").resolve()
    else:
        start_anchors = [
            start / ".orchestration_root",
            start / ".orchestration" / ".orchestration_root",
        ]
        for anchor in start_anchors:
            if anchor.is_file():
                meta = parse_anchor_metadata(anchor)
                mode = meta.get("mode", "").lower()
                root_val = meta.get("root")
                if mode == "local" or (mode != "global" and root_val is not None):
                    if root_val:
                        target = Path(root_val).expanduser()
                        return target if target.is_absolute() else (start / target).resolve()
                    return (start / ".orchestration").resolve()

    # Priority 3: Global User Root (~/.orchestration)
    global_anchor = Path.home() / ".orchestration" / ".orchestration_root"
    if global_anchor.is_file():
        meta = parse_anchor_metadata(global_anchor)
        if "root" in meta and meta["root"]:
            target = Path(meta["root"]).expanduser()
            return target if target.is_absolute() else ((Path.home() / ".orchestration") / target).resolve()

    return (Path.home() / ".orchestration").resolve()


def resolve_canonical_worktree_dir(
    repo_dir: Optional[Union[Path, str]] = None,
    branch_name: Optional[str] = None,
) -> Path:
    """Resolve the canonical worktree directory strictly under authoritative orchestration hierarchy.
    
    If local mode (repo has .orchestration_root with mode=local):
        Worktrees are located at: <repo_dir>/.orchestration/worktrees/<branch_name>
    If global mode (default):
        Worktrees are located at: ~/.orchestration/worktrees/<repo_name>/<branch_name>
    """
    target_repo = Path(repo_dir).resolve() if repo_dir else (resolve_true_repo_root() or Path.cwd())
    if target_repo.is_file():
        target_repo = target_repo.parent

    if is_local_orchestration(target_repo):
        orch_root = resolve_authoritative_orchestration_root(target_repo)
        base = orch_root / "worktrees"
    else:
        orch_root = resolve_authoritative_orchestration_root(target_repo)
        repo_name = target_repo.name
        base = orch_root / "worktrees" / repo_name

    if branch_name:
        return (base / branch_name).resolve()
    return base.resolve()


def resolve_worktree_path(branch_name: str, start_path: Optional[Union[Path, str]] = None) -> Path:
    """Resolve canonical worktree path for branch strictly under canonical worktree directory."""
    return resolve_canonical_worktree_dir(repo_dir=start_path, branch_name=branch_name)
