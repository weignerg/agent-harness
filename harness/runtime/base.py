"""Abstract Base Runtime Engine Adapter for agent orchestration."""
from __future__ import annotations

from abc import ABC, abstractmethod
from pathlib import Path
from typing import Any, Dict, List, Union


class BaseRuntimeAdapter(ABC):
    """Abstract base class specifying the interface for agent harness runtime engine adapters."""

    @property
    @abstractmethod
    def target_name(self) -> str:
        """Normalized runtime engine identifier (e.g. 'agy', 'claude', 'opencode')."""
        pass

    @property
    @abstractmethod
    def display_name(self) -> str:
        """Human-readable runtime name."""
        pass

    @property
    @abstractmethod
    def charter_filename(self) -> str:
        """Primary charter filename (e.g. 'GEMINI.md', 'CLAUDE.md', 'AGENTS.md')."""
        pass

    @property
    @abstractmethod
    def config_dir_name(self) -> str:
        """Project-local config directory name (e.g. '.agents', '.claude', '.opencode')."""
        pass

    @property
    @abstractmethod
    def global_config_dir(self) -> Path:
        """User-global configuration directory path."""
        pass

    @property
    @abstractmethod
    def model_tiers(self) -> Dict[str, Any]:
        """Mapping of agent role names to model specifications and reasoning effort tiers."""
        pass

    def get_charter_path(self, repo_path: Union[str, Path] = ".") -> Path:
        """Return the path to the runtime charter file within a repository."""
        return Path(repo_path).resolve() / self.charter_filename

    def get_config_dir(self, repo_path: Union[str, Path] = ".") -> Path:
        """Return the project-local config directory path."""
        return Path(repo_path).resolve() / self.config_dir_name

    def get_handoff_path(self, repo_path: Union[str, Path] = ".") -> Path:
        """Return the handoff directory path."""
        return self.get_config_dir(repo_path) / "handoffs"

    def get_rules_path(self, repo_path: Union[str, Path] = ".") -> Path:
        """Return the rules directory path."""
        return self.get_config_dir(repo_path) / "rules"

    def get_worktree_path(self, repo_path: Union[str, Path] = ".", branch_name: str = "") -> Path:
        """Return target worktree path for branch isolation."""
        return self.get_config_dir(repo_path) / "worktrees" / branch_name

    def get_tool_definitions(self) -> List[str]:
        """List canonical operational tool script names provided for this runtime."""
        return [
            "worktree_manager.py",
            "tdd_pipeline.py",
            "gh_pr_automation.py",
            "block_external_writes.py",
            "launch_team_terminal.sh",
            "reindex_vault.sh",
            "sglang_oom_handler.sh",
        ]

    def is_detected(self, repo_path: Union[str, Path] = ".") -> bool:
        """Check if this runtime engine is active or configured in the specified repo."""
        root = Path(repo_path).resolve()
        return (root / self.charter_filename).is_file() or (root / self.config_dir_name).is_dir()
