"""Master Unified Installer and Atomic Manifest Engine package."""
from __future__ import annotations

from harness.installer.manifest import (
    InstallManifest,
    ManifestEngine,
    ManifestEntry,
    compute_sha256,
)
from harness.installer.settings import (
    merge_claude_settings_file,
    merge_json_settings,
)

__all__ = [
    "compute_sha256",
    "ManifestEntry",
    "InstallManifest",
    "ManifestEngine",
    "merge_json_settings",
    "merge_claude_settings_file",
]
