"""Polymorphic context anchor injector for deterministic RadixAttention prefix caching."""
from __future__ import annotations

import os
from pathlib import Path
from typing import List, Optional

from harness.paths import (
    parse_anchor_file,
    resolve_authoritative_orchestration_root,
    resolve_true_repo_root,
)


class ContextAnchorInjector:
    """Formats immutable prompt prefixes containing repository ground truth rules."""

    @staticmethod
    def detect_charter_path(base_dir: Optional[str | Path] = None) -> Optional[Path]:
        """Auto-detect charter file or root rules across supported agent runtimes.
        
        Priority order:
        1. Authoritative orchestration rules (orch_root / rules / agent-teams.md)
        2. Root charter files (GEMINI.md, CLAUDE.md, AGENTS.md)
        3. Engine-specific rules (.agents/, .claude/, .opencode/)
        """
        env_root = os.environ.get("ORCHESTRATION_ROOT")
        if env_root and env_root.strip():
            env_rules = Path(env_root.strip()).expanduser().resolve() / "rules" / "agent-teams.md"
            if env_rules.is_file():
                return env_rules

        true_repo = resolve_true_repo_root(base_dir)
        target_dir = true_repo if true_repo else (Path(base_dir).resolve() if base_dir else None)

        if target_dir:
            # 1. Authoritative orchestration rules in target_dir
            orch_rule = target_dir / ".orchestration" / "rules" / "agent-teams.md"
            if orch_rule.is_file():
                return orch_rule

            # Check persistent anchor file in target_dir
            anchor = target_dir / ".orchestration_root"
            if not anchor.is_file():
                anchor = target_dir / ".orchestration" / ".orchestration_root"
            if anchor.is_file():
                parsed = parse_anchor_file(anchor, base_dir=target_dir)
                if parsed and (parsed / "rules" / "agent-teams.md").is_file():
                    return parsed / "rules" / "agent-teams.md"

            # 2. Root charter files in target_dir
            for charter in ("GEMINI.md", "CLAUDE.md", "AGENTS.md"):
                if (target_dir / charter).is_file():
                    return target_dir / charter

            # 3. Engine-specific rules in target_dir
            for sub in (".agents", ".claude", ".opencode"):
                cand = target_dir / sub / "rules" / "agent-teams.md"
                if cand.is_file():
                    return cand
        else:
            root = Path.cwd()
            candidates = [
                root / ".orchestration" / "rules" / "agent-teams.md",
                root / "GEMINI.md",
                root / "CLAUDE.md",
                root / "AGENTS.md",
                root / ".agents" / "rules" / "agent-teams.md",
                root / ".claude" / "rules" / "agent-teams.md",
                root / ".opencode" / "rules" / "agent-teams.md",
            ]
            for cand in candidates:
                if cand.is_file():
                    return cand

        # Global anchor file ~/.orchestration/.orchestration_root or ~/.orchestration/rules/agent-teams.md
        global_anchor = Path.home() / ".orchestration" / ".orchestration_root"
        if global_anchor.is_file():
            parsed = parse_anchor_file(global_anchor)
            if parsed and (parsed / "rules" / "agent-teams.md").is_file():
                return parsed / "rules" / "agent-teams.md"

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
