"""Obsidian vault frontmatter validator and directory layout enforcer."""
from __future__ import annotations

import re
from pathlib import Path
from typing import List, Tuple

VALID_DIRS = {"decisions", "projects", "protocols", "entities", "templates"}
FRONTMATTER_RE = re.compile(r"^---\n(.*?)\n---\n", re.DOTALL)

def validate_vault(vault_dir: str | Path) -> Tuple[bool, List[str]]:
    vpath = Path(vault_dir)
    errors: List[str] = []

    if not vpath.is_dir():
        return False, [f"Vault directory not found: {vault_dir}"]

    # Check top-level directories
    for child in vpath.iterdir():
        if child.is_dir() and not child.name.startswith("."):
            if child.name not in VALID_DIRS:
                errors.append(f"Invalid directory '{child.name}'. Allowed: {VALID_DIRS}")

    # Inspect all markdown files
    for md_file in vpath.rglob("*.md"):
        rel = md_file.relative_to(vpath)
        if any(part.startswith(".") for part in rel.parts):
            continue

        # Check slug naming (lowercase, hyphens/underscores/dots/alphanumeric)
        slug = md_file.stem
        if not re.match(r"^[a-z0-9_.-]+$", slug):
            errors.append(f"File '{md_file.name}' is not slug-cased")

        # Must be exactly directly inside a valid top category directory
        if len(rel.parts) != 2 or rel.parts[0] not in VALID_DIRS:
            errors.append(f"File '{rel}' must be located directly inside one of {VALID_DIRS}")

        # Check frontmatter
        content = md_file.read_text(errors="replace")
        match = FRONTMATTER_RE.match(content)
        if not match:
            errors.append(f"File '{rel}' missing valid YAML frontmatter")
        else:
            fm_text = match.group(1)
            if "title:" not in fm_text:
                errors.append(f"File '{rel}' frontmatter missing 'title:' key")

    return len(errors) == 0, errors
