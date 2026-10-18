"""
harness.hardware: Hardware discovery, device filtering, and resource sizing.
"""

from typing import TYPE_CHECKING

if TYPE_CHECKING:
    from harness.hardware.probe import (
        GPUInfo,
        SystemResources,
        ProbedProfile,
        HardwareProbe,
        probe_hardware,
        classify_profile,
    )

__all__ = [
    "GPUInfo",
    "SystemResources",
    "ProbedProfile",
    "HardwareProbe",
    "probe_hardware",
    "classify_profile",
]


def __getattr__(name: str):
    if name in __all__:
        import harness.hardware.probe as probe_mod
        return getattr(probe_mod, name)
    raise AttributeError(f"module {__name__!r} has no attribute {name!r}")
