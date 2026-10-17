"""OpenCode (SGLang Local Inference) runtime engine adapter."""
from __future__ import annotations

from pathlib import Path
from typing import Any, Dict, Union

from harness.runtime.base import BaseRuntimeAdapter


class OpenCodeRuntimeAdapter(BaseRuntimeAdapter):
    """Runtime engine adapter for OpenCode with local SGLang inference."""

    @property
    def target_name(self) -> str:
        return "opencode"

    @property
    def display_name(self) -> str:
        return "OpenCode (SGLang Local Inference)"

    @property
    def charter_filename(self) -> str:
        return "AGENTS.md"

    @property
    def config_dir_name(self) -> str:
        return ".opencode"

    @property
    def global_config_dir(self) -> Path:
        return Path.home() / ".config" / "opencode"

    @property
    def model_tiers(self) -> Dict[str, Any]:
        return {
            "supreme-orchestrator": {
                "model": "llama-3.3-70b-instruct-nvfp4",
                "tier": "High / Precision",
                "sglang_port": 30000,
            },
            "team-orchestrator": {
                "model": "llama-3.3-70b-instruct-nvfp4",
                "tier": "High / Precision",
                "sglang_port": 30000,
            },
            "architect": {
                "model": "llama-3.3-70b-instruct-nvfp4",
                "tier": "High / Precision",
                "sglang_port": 30000,
            },
            "worker": {
                "model": "gemma-4-31b-it-nvfp4",
                "tier": "Medium / Workhorse",
                "sglang_port": 30000,
            },
            "reviewer": {
                "model": "gemma-4-31b-it-nvfp4",
                "tier": "Medium / Workhorse",
                "sglang_port": 30000,
            },
            "tester": {
                "model": "gemma-4-31b-it-nvfp4",
                "tier": "Medium / Workhorse",
                "sglang_port": 30000,
            },
            "scout": {
                "model": "gemma-4-26b-a4b-it-nvfp4",
                "tier": "Low / Fast",
                "sglang_port": 30000,
            },
            "grunt": {
                "model": "gemma-4-26b-a4b-it-nvfp4",
                "tier": "Low / Fast",
                "sglang_port": 30000,
            },
        }

    def is_detected(self, repo_path: Union[str, Path] = ".") -> bool:
        """Detect OpenCode presence by checking AGENTS.md, opencode.json, or .opencode/."""
        root = Path(repo_path).resolve()
        return (
            (root / "opencode.json").is_file()
            or (root / ".opencode").is_dir()
            or (root / "AGENTS.md").is_file()
        )
