"""Polymorphic context anchor injector for deterministic RadixAttention prefix caching."""
from __future__ import annotations

from pathlib import Path
from typing import List, Optional


class ContextAnchorInjector:
    """Formats immutable prompt prefixes containing repository ground truth rules."""

    @staticmethod
    def detect_charter_path(base_dir: Optional[str | Path] = None) -> Optional[Path]:
        """Auto-detect charter file or root rules across supported agent runtimes.
        
        Priority order:
        1. .orchestration/rules/agent-teams.md (Harness-agnostic canonical)
        2. Root charter files (GEMINI.md, CLAUDE.md, AGENTS.md)
        3. Engine-specific rules (.agents/, .claude/, .opencode/)
        """
        root = Path(base_dir) if base_dir else Path.cwd()
        candidates = [
            root / ".orchestration" / "rules" / "agent-teams.md",
            root / "GEMINI.md",
            root / "CLAUDE.md",
            root / "AGENTS.md",
            root / ".agents" / "rules" / "agent-teams.md",
            root / ".claude" / "rules" / "agent-teams.md",
            root / ".opencode" / "rules" / "agent-teams.md",
        ]
        for candidate in candidates:
            if candidate.is_file():
                return candidate
        return None

    def __init__(
        self,
        rules_path: Optional[str | Path] = None,
        base_dir: Optional[str | Path] = None,
    ):
        if rules_path:
            self.rules_path = Path(rules_path)
        else:
            detected = self.detect_charter_path(base_dir=base_dir)
            if detected:
                self.rules_path = detected
            elif base_dir:
                self.rules_path = Path(base_dir) / "GEMINI.md"
            else:
                self.rules_path = Path("GEMINI.md")

    def get_ground_truth_rules(self) -> str:
        if self.rules_path.is_file():
            return self.rules_path.read_text(errors="replace").strip()
        return "Standard Agent Harness Rules"

    def format_prefix(self, milestone: str, task_id: str) -> str:
        """Deterministic, byte-stable header ensuring RadixAttention cache reuse."""
        rules = self.get_ground_truth_rules()
        return (
            f"=== ANCHOR_START ===\n"
            f"[GROUND_TRUTH]\n{rules}\n\n"
            f"[BOUNDARY]\nMilestone: {milestone}\nTask: {task_id}\n"
            f"=== ANCHOR_END ===\n"
        )

    def reset_context_for_milestone(self, new_milestone: str) -> str:
        """Enforces a hard milestone-based boundary reset to avoid context drift."""
        return self.format_prefix(milestone=new_milestone, task_id="INIT")
