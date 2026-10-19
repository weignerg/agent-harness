"""Dedicated FastMCP server for autonomous git worktree lifecycle management."""
from __future__ import annotations

import contextlib
import logging
import os
import re
import subprocess
import sys
from pathlib import Path
from typing import Any, Dict, List, Optional

# Strict STDIO stream hygiene: redirect non-JSON logs to stderr
logging.basicConfig(stream=sys.stderr, level=logging.WARNING)

from fastmcp import FastMCP
from pydantic import BaseModel, ConfigDict, Field

server = FastMCP("worktree-manager")

HARNESS_ROOT = Path(os.environ.get("HARNESS_ROOT", Path(__file__).resolve().parent.parent.parent)).resolve()
ORCHESTRATION_ROOT = Path(os.environ.get("ORCHESTRATION_ROOT", Path.home() / ".orchestration")).expanduser().resolve()


class StrictModel(BaseModel):
    model_config = ConfigDict(extra="forbid")


class WorktreeCreateInput(StrictModel):
    branch: str = Field(description="Name of the new git branch to create in the worktree (<type>/issue-<n>-<desc>)")
    path: Optional[str] = Field(default=None, description="Target directory path for the worktree. Defaults to canonical worktree path")
    base: Optional[str] = Field(default="develop", description="Base branch or commit to branch from (default: develop, or parent issue branch for nested issues)")


class WorktreeListInput(StrictModel):
    pass


class WorktreeRemoveInput(StrictModel):
    path: str = Field(description="Path of the worktree directory to prune")


class WorktreeCommitInput(StrictModel):
    commit_type: str = Field(description="Conventional Commit type (feat, fix, docs, refactor, test)")
    scope: str = Field(description="Commit scope (e.g. worktree, mcp, vault)")
    message: str = Field(description="Brief imperative commit description")
    path: Optional[str] = Field(default=None, description="Working tree directory where commit should be amended")


BRANCH_NAME_RE = re.compile(r"^(feat|fix|docs|test|refactor|chore|task)/issue-[0-9]+-[a-z0-9._-]+$")


@server.tool(name="worktree_create", description="Provision an isolated git worktree for a branch")
def worktree_create(branch: str, path: Optional[str] = None, base: Optional[str] = "develop") -> Dict[str, Any]:
    with contextlib.redirect_stdout(sys.stderr):
        from harness.paths import resolve_true_repo_root, resolve_worktree_path
        from scripts.worktree_manager import WorktreeManager

        repo_root = resolve_true_repo_root()
        if not repo_root:
            return {
                "status": "error",
                "branch": branch,
                "error": "Not inside a valid git repository or orchestration root"
            }

        manager = WorktreeManager(repo_dir=repo_root)
        target_path = Path(path).resolve() if path else resolve_worktree_path(branch, repo_root)

        # Validate branch name format and log recommendation to stderr
        if not BRANCH_NAME_RE.match(branch):
            sys.stderr.write(
                f"[worktree-manager] Notice: Branch '{branch}' does not strictly match recommended pattern "
                f"<type>/issue-<n>-<desc> (e.g., feat/issue-42-login-flow).\n"
            )

        # Verify whether base branch exists locally or on origin
        base_ref = base or "develop"
        check_local = subprocess.run(
            ["git", "show-ref", "--verify", "--quiet", f"refs/heads/{base_ref}"],
            cwd=repo_root,
            check=False,
        )
        if check_local.returncode != 0:
            check_remote = subprocess.run(
                ["git", "rev-parse", "--verify", f"origin/{base_ref}"],
                cwd=repo_root,
                capture_output=True,
                check=False,
            )
            if check_remote.returncode == 0:
                base_ref = f"origin/{base_ref}"

        try:
            manager.provision_worktree(branch_name=branch, target_dir=target_path, base=base_ref)
            return {
                "status": "created",
                "branch": branch,
                "base": base or "develop",
                "path": str(target_path)
            }
        except Exception as exc:
            return {
                "status": "error",
                "branch": branch,
                "error": str(exc)
            }


@server.tool(name="worktree_list", description="List all active git worktrees")
def worktree_list() -> List[Dict[str, str]]:
    with contextlib.redirect_stdout(sys.stderr):
        from harness.paths import resolve_true_repo_root
        repo_dir = resolve_true_repo_root() or Path.cwd()
        res = subprocess.run(["git", "worktree", "list", "--porcelain"], cwd=repo_dir, capture_output=True, text=True, check=False)
        worktrees = []
        current: Dict[str, str] = {}
        for line in res.stdout.splitlines():
            if line.startswith("worktree "):
                if current:
                    worktrees.append(current)
                current = {"path": line.split(" ", 1)[1]}
            elif line.startswith("branch "):
                current["branch"] = line.split(" ", 1)[1]
            elif line.startswith("HEAD "):
                current["head"] = line.split(" ", 1)[1]
        if current:
            worktrees.append(current)
        return worktrees


@server.tool(name="worktree_remove", description="Prune and remove an isolated git worktree")
def worktree_remove(path: str) -> Dict[str, Any]:
    with contextlib.redirect_stdout(sys.stderr):
        from harness.paths import resolve_true_repo_root
        from scripts.worktree_manager import WorktreeManager
        manager = WorktreeManager(repo_dir=resolve_true_repo_root())
        target_path = Path(path).resolve()
        manager.prune_worktree(target_dir=target_path)
        return {
            "status": "removed",
            "path": str(target_path)
        }


@server.tool(name="worktree_commit", description="Create or amend a Conventional Commit in a worktree")
def worktree_commit(commit_type: str, scope: str, message: str, path: Optional[str] = None) -> Dict[str, Any]:
    with contextlib.redirect_stdout(sys.stderr):
        from harness.paths import resolve_true_repo_root
        from scripts.worktree_manager import WorktreeManager
        manager = WorktreeManager(repo_dir=resolve_true_repo_root())
        target_path = Path(path).resolve() if path else Path.cwd()
        manager.semantic_squash_commit(commit_type, scope, message, cwd=target_path)
        return {
            "status": "committed",
            "message": f"{commit_type}({scope}): {message}",
            "path": str(target_path)
        }


if __name__ == "__main__":
    server.run()
