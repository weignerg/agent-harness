"""Claude Code (Anthropic) runtime engine adapter."""
from __future__ import annotations

import copy
from pathlib import Path
from typing import Any, Dict

from harness.runtime.base import BaseRuntimeAdapter


def deep_merge(base: Dict[str, Any], override: Dict[str, Any]) -> Dict[str, Any]:
    """Recursively merge override dictionary into base dictionary."""
    result = copy.deepcopy(base)
    for key, value in override.items():
        if key in result and isinstance(result[key], dict) and isinstance(value, dict):
            result[key] = deep_merge(result[key], value)
        elif key in result and isinstance(result[key], list) and isinstance(value, list):
            # Merge lists uniquely while preserving order
            merged_list = list(result[key])
            for item in value:
                if item not in merged_list:
                    merged_list.append(item)
            result[key] = merged_list
        else:
            result[key] = copy.deepcopy(value)
    return result


class ClaudeRuntimeAdapter(BaseRuntimeAdapter):
    """Runtime engine adapter for Claude Code with Anthropic models."""

    @property
    def target_name(self) -> str:
        return "claude"

    @property
    def display_name(self) -> str:
        return "Claude Code (Anthropic)"

    @property
    def charter_filename(self) -> str:
        return "CLAUDE.md"

    @property
    def config_dir_name(self) -> str:
        return ".claude"

    @property
    def global_config_dir(self) -> Path:
        return Path.home() / ".claude"

    @property
    def model_tiers(self) -> Dict[str, Any]:
        return {
            "architect": {
                "model": "claude-3-7-sonnet",
                "tier": "opus",
                "claude_model": "opus",
            },
            "worker": {
                "model": "claude-3-7-sonnet",
                "tier": "sonnet",
                "claude_model": "sonnet",
            },
            "reviewer": {
                "model": "claude-3-7-sonnet",
                "tier": "sonnet",
                "claude_model": "sonnet",
            },
            "tester": {
                "model": "claude-3-7-sonnet",
                "tier": "sonnet",
                "claude_model": "sonnet",
            },
            "scout": {
                "model": "claude-3-5-haiku",
                "tier": "haiku",
                "claude_model": "haiku",
            },
            "grunt": {
                "model": "claude-3-5-haiku",
                "tier": "haiku",
                "claude_model": "haiku",
            },
        }

    def merge_json_settings(
        self, base_settings: Dict[str, Any], *override_settings: Dict[str, Any]
    ) -> Dict[str, Any]:
        """Merge base and override Claude settings JSON objects."""
        merged = copy.deepcopy(base_settings)
        for override in override_settings:
            merged = deep_merge(merged, override)
        return merged
