"""Autonomous git worktree lifecycle manager with Conventional Commits semantic squashing."""
from __future__ import annotations

import argparse
import subprocess
from pathlib import Path
from typing import Optional


class WorktreeManager:
    def __init__(self, repo_dir: Optional[str | Path] = None):
        self.repo_dir = Path(repo_dir) if repo_dir else Path.cwd()

    def default_worktree_path(self, branch_name: str) -> Path:
        if (self.repo_dir / ".claude").is_dir() or (self.repo_dir / "templates" / "claude").is_dir() or (self.repo_dir / "files" / ".claude").is_dir():
            return (self.repo_dir / ".claude" / "worktrees" / branch_name).resolve()
        if (self.repo_dir / ".opencode").is_dir() or (self.repo_dir / "templates" / "opencode").is_dir():
            return (self.repo_dir / ".opencode" / "worktrees" / branch_name).resolve()
        return (self.repo_dir / ".agents" / "worktrees" / branch_name).resolve()

    def provision_worktree(self, branch_name: str, target_dir: Optional[Path | str] = None) -> Path:
        resolved_target = Path(target_dir) if target_dir is not None else self.default_worktree_path(branch_name)
        resolved_target.parent.mkdir(parents=True, exist_ok=True)
        cmd = ["git", "worktree", "add", "-b", branch_name, str(resolved_target), "develop"]
        subprocess.run(cmd, cwd=self.repo_dir, check=True, capture_output=True)
        return resolved_target

    def prune_worktree(self, target_dir: Path | str):
        resolved_target = Path(target_dir)
        cmd = ["git", "worktree", "remove", "--force", str(resolved_target)]
        subprocess.run(cmd, cwd=self.repo_dir, check=False, capture_output=True)
        subprocess.run(["git", "worktree", "prune"], cwd=self.repo_dir, check=False, capture_output=True)

    def semantic_squash_commit(self, commit_type: str, scope: str, description: str, cwd: Optional[Path | str] = None):
        work_dir = Path(cwd) if cwd is not None else self.repo_dir
        msg = f"{commit_type}({scope}): {description}"
        subprocess.run(["git", "commit", "--amend", "-m", msg], cwd=work_dir, check=False, capture_output=True)


def main():
    parser = argparse.ArgumentParser(description="Autonomous git worktree lifecycle manager")
    subparsers = parser.add_subparsers(dest="command", required=True)

    create_p = subparsers.add_parser("create", help="Provision an isolated git worktree")
    create_p.add_argument("pos_branch", nargs="?", default=None, help="Branch name (positional)")
    create_p.add_argument("pos_path", nargs="?", default=None, help="Target worktree path (positional)")
    create_p.add_argument("--branch", "-b", dest="opt_branch", default=None, help="Branch name")
    create_p.add_argument("--path", "-p", dest="opt_path", default=None, help="Target worktree path (defaults to .agents/worktrees/<branch>)")

    subparsers.add_parser("list", help="List active git worktrees")

    for cmd_name in ("prune", "remove"):
        rm_p = subparsers.add_parser(cmd_name, help="Prune and remove a git worktree")
        rm_p.add_argument("pos_path", nargs="?", default=None, help="Worktree path to remove (positional)")
        rm_p.add_argument("--path", "-p", dest="opt_path", default=None, help="Worktree path to remove")

    commit_p = subparsers.add_parser("commit", help="Amend commit with Conventional Commit message")
    commit_p.add_argument("--type", "-t", required=True, dest="commit_type", help="Commit type (feat, fix, etc.)")
    commit_p.add_argument("--scope", "-s", required=True, help="Commit scope")
    commit_p.add_argument("--message", "-m", required=True, help="Commit description")
    commit_p.add_argument("--path", "-p", default=None, help="Worktree path")

    args = parser.parse_args()
    mgr = WorktreeManager()

    if args.command == "create":
        branch = args.opt_branch or args.pos_branch
        if not branch:
            parser.error("create requires --branch <branch> or positional <branch>")
        target = args.opt_path or args.pos_path
        out = mgr.provision_worktree(branch_name=branch, target_dir=Path(target) if target else None)
        print(str(out))
    elif args.command == "list":
        res = subprocess.run(["git", "worktree", "list"], cwd=mgr.repo_dir, capture_output=True, text=True, check=False)
        print(res.stdout, end="")
    elif args.command in ("prune", "remove"):
        target = args.opt_path or args.pos_path
        if not target:
            parser.error(f"{args.command} requires --path <path> or positional <path>")
        mgr.prune_worktree(Path(target))
        print(f"Removed worktree: {target}")
    elif args.command == "commit":
        mgr.semantic_squash_commit(args.commit_type, args.scope, args.message, cwd=Path(args.path) if args.path else None)
        print(f"{args.commit_type}({args.scope}): {args.message}")


if __name__ == "__main__":
    main()
