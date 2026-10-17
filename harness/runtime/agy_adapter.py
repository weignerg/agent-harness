"""Google Antigravity (Gemini 3.8) runtime engine adapter."""
from __future__ import annotations

from pathlib import Path
from typing import Any, Dict

from harness.runtime.base import BaseRuntimeAdapter


class AgyRuntimeAdapter(BaseRuntimeAdapter):
    """Runtime engine adapter for Google Antigravity with official Gemini 3.8 models."""

    @property
    def target_name(self) -> str:
        return "agy"

    @property
    def display_name(self) -> str:
        return "Google Antigravity (Gemini 3.8)"

    @property
    def charter_filename(self) -> str:
        return "GEMINI.md"

    @property
    def config_dir_name(self) -> str:
        return ".agents"

    @property
    def global_config_dir(self) -> Path:
        return Path.home() / ".gemini" / "config" / "plugins" / "agy-harness"

    @property
    def model_tiers(self) -> Dict[str, Any]:
        return {
            "supreme-orchestrator": {
                "model": "gemini-3.8-flash-high",
                "tier": "Gemini 3.8 High",
                "profile_model": "pro",
            },
            "team-orchestrator": {
                "model": "gemini-3.8-flash-high",
                "tier": "Gemini 3.8 High",
                "profile_model": "pro",
            },
            "architect": {
                "model": "gemini-3.8-flash-high",
                "tier": "Gemini 3.8 High",
                "profile_model": "pro",
            },
            "worker": {
                "model": "gemini-3.8-flash-medium",
                "tier": "Gemini 3.8 Medium",
                "profile_model": "flash",
            },
            "reviewer": {
                "model": "gemini-3.8-flash-medium",
                "tier": "Gemini 3.8 Medium",
                "profile_model": "flash",
            },
            "tester": {
                "model": "gemini-3.8-flash-medium",
                "tier": "Gemini 3.8 Medium",
                "profile_model": "flash",
            },
            "scout": {
                "model": "gemini-3.8-flash-low",
                "tier": "Gemini 3.8 Low",
                "profile_model": "flash_lite",
            },
            "grunt": {
                "model": "gemini-3.8-flash-low",
                "tier": "Gemini 3.8 Low",
                "profile_model": "flash_lite",
            },
        }

    def get_plugin_manifest_path(self, repo_path: Path | str = ".") -> Path:
        """Return the path to the Antigravity plugin manifest template."""
        return Path(repo_path).resolve() / "templates" / "agy" / "plugins" / "agy-harness" / "plugin.json"
