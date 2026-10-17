"""Dynamic Runtime Engine Adapters for multi-runtime agent orchestration."""
from __future__ import annotations

from pathlib import Path
from typing import Dict, Type, Union

from harness.runtime.agy_adapter import AgyRuntimeAdapter
from harness.runtime.base import BaseRuntimeAdapter
from harness.runtime.claude_adapter import ClaudeRuntimeAdapter
from harness.runtime.opencode_adapter import OpenCodeRuntimeAdapter

SUPPORTED_ADAPTERS: Dict[str, Type[BaseRuntimeAdapter]] = {
    "agy": AgyRuntimeAdapter,
    "claude": ClaudeRuntimeAdapter,
    "opencode": OpenCodeRuntimeAdapter,
}

# Alias resolution mapping
_ALIASES: Dict[str, str] = {
    "agy": "agy",
    "antigravity": "agy",
    "gemini": "agy",
    "claude": "claude",
    "anthropic": "claude",
    "opencode": "opencode",
    "sglang": "opencode",
}


def get_runtime_adapter(target_name: str) -> BaseRuntimeAdapter:
    """Instantiate a runtime adapter by target engine name or alias."""
    normalized = target_name.strip().lower()
    canonical_name = _ALIASES.get(normalized)
    if not canonical_name or canonical_name not in SUPPORTED_ADAPTERS:
        supported = ", ".join(repr(k) for k in SUPPORTED_ADAPTERS.keys())
        raise ValueError(f"Unknown runtime target: {target_name!r}. Supported targets: {supported}")
    return SUPPORTED_ADAPTERS[canonical_name]()


def detect_runtime_adapter(repo_path: Union[str, Path] = ".") -> BaseRuntimeAdapter:
    """Inspect repository structure and auto-detect appropriate runtime engine adapter."""
    root = Path(repo_path).resolve()

    # Claude Code takes priority when CLAUDE.md or .claude/ exists
    if (root / "CLAUDE.md").is_file() or (root / ".claude").is_dir():
        return ClaudeRuntimeAdapter()

    # OpenCode takes priority when opencode.json or .opencode/ exists
    if (root / "opencode.json").is_file() or (root / ".opencode").is_dir():
        return OpenCodeRuntimeAdapter()

    # Google Antigravity takes priority when GEMINI.md or .agents/ exists
    if (root / "GEMINI.md").is_file() or (root / ".agents").is_dir():
        return AgyRuntimeAdapter()

    # If AGENTS.md exists without specific engine markers, map to OpenCode
    if (root / "AGENTS.md").is_file():
        return OpenCodeRuntimeAdapter()

    # Canonical default
    return AgyRuntimeAdapter()


__all__ = [
    "BaseRuntimeAdapter",
    "AgyRuntimeAdapter",
    "ClaudeRuntimeAdapter",
    "OpenCodeRuntimeAdapter",
    "SUPPORTED_ADAPTERS",
    "get_runtime_adapter",
    "detect_runtime_adapter",
]
