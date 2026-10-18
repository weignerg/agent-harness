"""Agent Harness core library."""
from harness.paths import (
    resolve_authoritative_orchestration_root,
    resolve_true_repo_root,
)

__all__ = [
    "resolve_true_repo_root",
    "resolve_authoritative_orchestration_root",
]
