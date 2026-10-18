"""Master Unified Installer and Atomic Manifest Engine package."""
from __future__ import annotations

import importlib
from typing import Any

__all__ = [
    "compute_sha256",
    "ManifestEntry",
    "InstallManifest",
    "ManifestEngine",
    "merge_json_settings",
    "merge_claude_settings_file",
]


def __getattr__(name: str) -> Any:
    if name in ("compute_sha256", "ManifestEntry", "InstallManifest", "ManifestEngine"):
        mod = importlib.import_module("harness.installer.manifest")
        return getattr(mod, name)
    if name in ("merge_json_settings", "merge_claude_settings_file"):
        mod = importlib.import_module("harness.installer.settings")
        return getattr(mod, name)
    raise AttributeError(f"module {__name__!r} has no attribute {name!r}")

