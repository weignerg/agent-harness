"""Durable external IDE handoff protocol generating discrete per-task handoff files."""
from __future__ import annotations

import re
import time
from pathlib import Path
from typing import List, Optional


def sanitize_task_id(name: str) -> str:
    """Sanitize task ID or title into safe filesystem slug."""
    slug = re.sub(r"[^a-zA-Z0-9._-]+", "_", name.strip().lower())
    return slug.strip("_") or "unnamed_task"


class TaskHandoff:
    """Manages discrete per-task handoffs stored in polymorphic handoff directory.
    
    Priority resolution:
    1. .orchestration/handoffs (Harness-agnostic canonical)
    2. .agents/handoffs
    3. .claude/handoffs
    4. .opencode/handoffs
    Defaults cleanly to .orchestration/handoffs if none exists yet.
    """

    @staticmethod
    def detect_handoff_dir(base_dir: Optional[str | Path] = None) -> Path:
        """Auto-detect existing handoff directory across supported runtimes, defaulting to .orchestration/handoffs/."""
        root = Path(base_dir) if base_dir else Path.cwd()
        candidate_dirs = [
            root / ".orchestration" / "handoffs",
            root / ".agents" / "handoffs",
            root / ".claude" / "handoffs",
            root / ".opencode" / "handoffs",
        ]
        for candidate in candidate_dirs:
            if candidate.is_dir():
                return candidate
        return (root / ".orchestration" / "handoffs") if base_dir else Path(".orchestration/handoffs")

    def __init__(
        self,
        handoff_dir: Optional[str | Path] = None,
        handoff_path: Optional[str | Path] = None,
        base_dir: Optional[str | Path] = None,
    ):
        if handoff_path:
            p = Path(handoff_path)
            if p.suffix == ".md":
                self.explicit_file: Optional[Path] = p
                self.handoff_dir: Path = p.parent
            else:
                self.explicit_file = None
                self.handoff_dir = p
        elif handoff_dir:
            self.explicit_file = None
            self.handoff_dir = Path(handoff_dir)
        else:
            self.explicit_file = None
            self.handoff_dir = self.detect_handoff_dir(base_dir=base_dir)

        self.handoff_dir.mkdir(parents=True, exist_ok=True)

    def get_task_file_path(self, task_id: Optional[str] = None, task_title: Optional[str] = None) -> Path:
        """Resolve discrete per-task markdown file path."""
        if self.explicit_file and not task_id:
            return self.explicit_file

        slug_source = task_id or task_title or "unnamed_task"
        slug = sanitize_task_id(slug_source)
        return self.handoff_dir / f"TASK_HANDOFF_{slug}.md"

    def write_handoff(
        self,
        task_title: str,
        status: str,
        affected_files: List[str],
        summary: str,
        remaining_todos: List[str],
        task_id: Optional[str] = None,
    ) -> str:
        """Write discrete per-task handoff markdown file."""
        target_file = self.get_task_file_path(task_id=task_id, task_title=task_title)
        target_file.parent.mkdir(parents=True, exist_ok=True)

        todos_md = (
            "\n".join(f"- [ ] {todo}" for todo in remaining_todos)
            if remaining_todos
            else "- [x] All todos completed"
        )
        files_md = (
            "\n".join(f"- `file://{Path(f).resolve()}`" for f in affected_files)
            if affected_files
            else "None"
        )
        identifier_line = f"**Task ID**: `{task_id}`  \n" if task_id else ""

        content = f"""# Task Handoff: {task_title}

{identifier_line}**Generated**: {time.strftime("%Y-%m-%d %H:%M:%S %Z")}  
**Status**: {status}  

## Summary
{summary}

## Affected Files (CLI / Editor Links)
{files_md}

## Remaining Todos
{todos_md}
"""
        target_file.write_text(content, encoding="utf-8")
        return str(target_file)

    def get_handoff(self, task_id: str) -> Optional[str]:
        """Read handoff markdown content for a specific task."""
        target_file = self.get_task_file_path(task_id=task_id)
        if target_file.exists():
            return target_file.read_text(encoding="utf-8")
        return None

    def list_handoffs(self) -> List[Path]:
        """List all discrete handoff files ordered by modification time."""
        if not self.handoff_dir.exists():
            return []
        files = list(self.handoff_dir.glob("TASK_HANDOFF_*.md"))
        if self.explicit_file and self.explicit_file.exists() and self.explicit_file not in files:
            files.append(self.explicit_file)
        return sorted(files, key=lambda f: f.stat().st_mtime, reverse=True)

    def clean_handoff(self, task_id: str) -> bool:
        """Remove handoff file for a completed task."""
        target_file = self.get_task_file_path(task_id=task_id)
        if target_file.exists():
            target_file.unlink()
            return True
        return False
