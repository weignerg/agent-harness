"""Automated adversarial security verification and bounded red-team scanner."""
from __future__ import annotations

import re
from pathlib import Path
from typing import Dict, List, Tuple

from harness.security.secret_broker import TOKEN_PATTERNS

MOCK_ILLUSION_PATTERNS = [
    re.compile(r"unittest\.mock\.patch\s*\(\s*['\"]builtins\.open['\"]"),
    re.compile(r"return_value\s*=\s*['\"]mock_success['\"]"),
    re.compile(r"class\s+MockSGLangClient"),
]

def scan_for_vulnerabilities(repo_dir: Path) -> Tuple[bool, List[str]]:
    findings = []
    py_files = list(repo_dir.glob("harness/**/*.py")) + list(repo_dir.glob("scripts/**/*.py"))
    
    for f in py_files:
        content = f.read_text(errors="replace")
        for idx, line in enumerate(content.splitlines(), start=1):
            for pat in TOKEN_PATTERNS:
                if pat.search(line):
                    findings.append(f"[SECRET LEAK] {f.relative_to(repo_dir)}:{idx} matches token pattern")
            for mock_pat in MOCK_ILLUSION_PATTERNS:
                if mock_pat.search(line):
                    findings.append(f"[MOCK ILLUSION] {f.relative_to(repo_dir)}:{idx} suspicious mock bypass")

    return len(findings) == 0, findings
