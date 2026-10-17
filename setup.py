"""Package setup for agent-harness."""
from setuptools import find_packages, setup

setup(
    name="agent-harness",
    version="0.4.0",
    description="Unified multi-runtime agentic harness supporting Antigravity, Claude Code, and OpenCode",
    packages=find_packages(include=["harness*"]),
)
