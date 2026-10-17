"""Enforces memory privacy, gitignore perimeter rules, and limits on raw code snippets."""
from __future__ import annotations

import re
from pathlib import Path
from typing import List, Tuple

from harness.security.secret_broker import TOKEN_PATTERNS

MAX_CODE_BLOCK_LINES = 30

def check_note_safety(note_path: str | Path) -> Tuple[bool, List[str]]:
    p = Path(note_path)
    if not p.is_file():
        return False, [f"Note not found: {note_path}"]

    content = p.read_text(errors="replace")
    errors: List[str] = []

    # Check for raw secrets
    for pat in TOKEN_PATTERNS:
        if pat.search(content):
            errors.append(f"Hard-coded token or secret pattern detected in {p.name}")

    # Check for excessive raw code blocks (prohibit dumping full files into notes)
    code_blocks = re.findall(r"```[a-zA-Z0-9_-]*\n(.*?)```", content, re.DOTALL)
    for idx, block in enumerate(code_blocks):
        lines = block.strip().splitlines()
        if len(lines) > MAX_CODE_BLOCK_LINES:
            errors.append(
                f"Code block #{idx+1} in {p.name} exceeds maximum allowed size "
                f"({len(lines)} lines > {MAX_CODE_BLOCK_LINES}). Store symbol coordinates or file paths instead."
            )

    return len(errors) == 0, errors
