"""Autonomous git worktree lifecycle manager with Conventional Commits semantic squashing."""
from __future__ import annotations

import argparse
import subprocess
from pathlib import Path
from typing import Optional

try:
    from harness.paths import resolve_true_repo_root
except ImportError:
    def resolve_true_repo_root(start_path: Optional[str | Path] = None) -> Optional[Path]:
        start = Path(start_path).resolve() if start_path else Path.cwd()
        if start.is_file():
            start = start.parent
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
            if res.returncode == 0 and res.stdout.strip():
                p = Path(res.stdout.strip())
                if not p.is_absolute():
                    p = (start / p).resolve()
                if p.name == ".git":
                    return p.parent
                return p
        except Exception:
            pass
        for d in [start] + list(start.parents):
            if (d / ".git").exists() or (d / ".orchestration").is_dir():
                return d
        return None


class WorktreeManager:
    def __init__(self, repo_dir: Optional[str | Path] = None, runtime: Optional[str] = None):
        self.repo_dir = Path(repo_dir).resolve() if repo_dir else (resolve_true_repo_root(Path.cwd()) or Path.cwd())
        self.runtime = runtime

    def default_worktree_path(self, branch_name: str, runtime: Optional[str] = None) -> Path:
        target_runtime = runtime or self.runtime
        if target_runtime == "claude":
            return (self.repo_dir / ".claude" / "worktrees" / branch_name).resolve()
        if target_runtime == "opencode":
            return (self.repo_dir / ".opencode" / "worktrees" / branch_name).resolve()

        # Authoritative Directive: Option A (Strict Global Centralization)
        try:
            from harness.paths import (
                is_local_orchestration,
                resolve_authoritative_orchestration_root,
                resolve_true_repo_root,
            )
            true_repo = resolve_true_repo_root(self.repo_dir) or self.repo_dir
            orch_root = resolve_authoritative_orchestration_root(true_repo)
            if is_local_orchestration(true_repo):
                return (orch_root / "worktrees" / branch_name).resolve()
            repo_name = true_repo.name
            return (orch_root / "worktrees" / repo_name / branch_name).resolve()
        except ImportError:
            anchors = [
                self.repo_dir / ".orchestration_root",
                self.repo_dir / ".orchestration" / ".orchestration_root",
            ]
            is_local = False
            for anchor in anchors:
                if anchor.is_file():
                    try:
                        content = anchor.read_text(encoding="utf-8")
                        for line in content.splitlines():
                            line_clean = line.strip().lower()
                            if line_clean == "mode=local" or line_clean.startswith("mode=local"):
                                is_local = True
                                break
                    except Exception:
                        pass
            if is_local:
                return (self.repo_dir / ".orchestration" / "worktrees" / branch_name).resolve()
            repo_name = self.repo_dir.name
            orch_root = Path.home() / ".orchestration"
            return (orch_root / "worktrees" / repo_name / branch_name).resolve()

    def provision_worktree(
        self,
        branch_name: str,
        target_dir: Optional[Path | str] = None,
        runtime: Optional[str] = None,
        base: Optional[str] = None,
    ) -> Path:
        resolved_target = Path(target_dir) if target_dir is not None else self.default_worktree_path(branch_name, runtime=runtime)
        resolved_target.parent.mkdir(parents=True, exist_ok=True)
        base_ref = base or "develop"
        check_branch = subprocess.run(
            ["git", "show-ref", "--verify", "--quiet", f"refs/heads/{branch_name}"],
            cwd=self.repo_dir,
            check=False,
        )
        if check_branch.returncode == 0:
            cmd = ["git", "worktree", "add", str(resolved_target), branch_name]
        else:
            cmd = ["git", "worktree", "add", "-b", branch_name, str(resolved_target), base_ref]
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
    parser.add_argument("--runtime", "-r", dest="runtime", default=None, help="Target runtime adapter (agy, claude, opencode)")
    subparsers = parser.add_subparsers(dest="command", required=True)

    create_p = subparsers.add_parser("create", help="Provision an isolated git worktree")
    create_p.add_argument("pos_branch", nargs="?", default=None, help="Branch name (positional)")
    create_p.add_argument("pos_path", nargs="?", default=None, help="Target worktree path (positional)")
    create_p.add_argument("--branch", "-b", dest="opt_branch", default=None, help="Branch name")
    create_p.add_argument("--path", "-p", dest="opt_path", default=None, help="Target worktree path (defaults to .orchestration/worktrees/<branch>)")
    create_p.add_argument("--runtime", "-r", dest="opt_runtime", default=None, help="Target runtime adapter")
    create_p.add_argument("--base", "-B", dest="base", default=None, help="Base commit/branch to start from (defaults to develop, or parent issue branch for nested issues)")

    subparsers.add_parser("list", help="List active git worktrees")

    for cmd_name in ("prune", "remove"):
        rm_p = subparsers.add_parser(cmd_name, help="Prune and remove a git worktree")
        rm_p.add_argument("pos_path", nargs="?", default=None, help="Worktree path to remove (positional)")
        rm_p.add_argument("--path", "-p", dest="opt_path", default=None, help="Worktree path to remove")

    commit_p = subparsers.add_parser("commit", help="Amend commit with Conventional Commit message")
    commit_p.add_argument("--type", "-t", required=True, dest="commit_type", help="Commit type (feat, fix, etc.)")
    commit_p.add_argument("--scope", "-s", required=True, help="Commit scope")
    commit_p.add_argument("--message", "-m", required=True, help="Commit description")

    args = parser.parse_args()
    mgr = WorktreeManager(runtime=getattr(args, "runtime", None))

    if args.command == "create":
        branch = args.opt_branch or args.pos_branch
        path = args.opt_path or args.pos_path
        runtime = args.opt_runtime or getattr(args, "runtime", None)
        base = getattr(args, "base", None)
        if not branch:
            parser.error("Branch name is required to create a worktree")
        created = mgr.provision_worktree(branch_name=branch, target_dir=path, runtime=runtime, base=base)
        print(f"Created worktree at: {created}")

    elif args.command == "list":
        res = subprocess.run(["git", "worktree", "list"], cwd=mgr.repo_dir, capture_output=True, text=True, check=False)
        print(res.stdout.strip())

    elif args.command in ("prune", "remove"):
        path = args.opt_path or args.pos_path
        if not path:
            parser.error(f"Worktree path is required to {args.command}")
        mgr.prune_worktree(path)
        print(f"Pruned worktree: {path}")

    elif args.command == "commit":
        mgr.semantic_squash_commit(
            commit_type=args.commit_type,
            scope=args.scope,
            description=args.message,
        )
        print(f"Amended commit: {args.commit_type}({args.scope}): {args.message}")


if __name__ == "__main__":
    main()
