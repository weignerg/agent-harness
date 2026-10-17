"""Adversarial Reviewer node: three evidence-based pillars + consensus + DAG gate.

1. Execution validation  - run the project's tests/sanity command (real exit code).
2. Security & lint audit - py_compile syntax + dangerous-pattern and secret scan.
3. Prompt alignment      - every spec requirement must be demonstrably satisfied
                           and no forbidden deviation present.
The reviewer is deterministic evidence first; an LLM opinion can never overrule
failed evidence. Disagreement between reviewers goes to a human gate.
"""
from __future__ import annotations

import py_compile
import re
import subprocess
import tempfile
from dataclasses import dataclass, field
from enum import Enum
from pathlib import Path
from typing import Callable, Sequence

from harness.security.secret_broker import TOKEN_PATTERNS

from .models import DagSpec, StepResult, StepSpec
from .state_machine import Handler

DANGEROUS = [
    (re.compile(r"\beval\s*\("), "eval() call"),
    (re.compile(r"\bexec\s*\("), "exec() call"),
    (re.compile(r"shell\s*=\s*True"), "subprocess shell=True"),
    (re.compile(r"\bos\.system\s*\("), "os.system call"),
    (re.compile(r"pickle\.loads?\s*\("), "pickle deserialization"),
    (re.compile(r"verify\s*=\s*False"), "TLS verification disabled"),
    (re.compile(r"chmod\s+(-R\s+)?777"), "world-writable chmod"),
    (re.compile(r"curl[^|\n]*\|\s*(ba)?sh"), "curl | sh"),
    (re.compile(r"rm\s+-rf\s+/(\s|$)"), "rm -rf /"),
]
SECRET_ASSIGN = re.compile(r"(?i)(password|secret|api[_-]?key|token)\s*=\s*['\"][^'\"\s]{8,}['\"]")


class Severity(str, Enum):
    BLOCKER = "BLOCKER"
    MUST_FIX = "MUST_FIX"
    WARNING = "WARNING"
    BEST_PRACTICE = "BEST_PRACTICE"


@dataclass
class Finding:
    pillar: str
    message: str
    blocking: bool = True
    severity: Severity = Severity.BLOCKER
    file_anchor: str | None = None
    suggestion: str | None = None

    def __post_init__(self):
        if self.blocking and self.severity not in (Severity.BLOCKER, Severity.MUST_FIX):
            self.severity = Severity.BLOCKER
        elif not self.blocking and self.severity in (Severity.BLOCKER, Severity.MUST_FIX):
            self.severity = Severity.WARNING


@dataclass
class Requirement:
    id: str
    description: str
    path: str                      # file (relative to repo) that must satisfy it
    pattern: str                   # regex that must match in that file
    forbidden: str | None = None   # regex that must NOT appear (deviation)


@dataclass
class Report:
    reviewer: str
    findings: list[Finding] = field(default_factory=list)

    @property
    def passed(self) -> bool:
        return not any(f.blocking for f in self.findings)

    def summary(self) -> str:
        return "PASS" if self.passed else "; ".join(f"[{f.severity.value}] {f.message}" for f in self.findings if f.blocking)

    def format_consolidated_markdown(self, pr_url: str = "") -> str:
        """Format review findings in the 4-tier consolidated response markdown format."""
        if not self.findings:
            return "### Code Review Summary\n\n- Verdict: **APPROVED**\n- No defects or regressions found.\n"

        lines = [f"### Code Review Summary (Reviewer: {self.reviewer})\n"]
        for sev in (Severity.BLOCKER, Severity.MUST_FIX, Severity.WARNING, Severity.BEST_PRACTICE):
            sev_findings = [f for f in self.findings if f.severity == sev]
            if sev_findings:
                icon = "🔴" if sev == Severity.BLOCKER else ("🟠" if sev == Severity.MUST_FIX else ("🟡" if sev == Severity.WARNING else "🟢"))
                lines.append(f"#### {icon} **{sev.value}**")
                for f in sev_findings:
                    anchor = f" ({f.file_anchor})" if f.file_anchor else ""
                    lines.append(f"- **{f.pillar}**{anchor}: {f.message}")
                    if f.suggestion:
                        lines.append(f"  - *Suggestion*: {f.suggestion}")
                lines.append("")
        return "\n".join(lines)


# ---- pillar 1 -------------------------------------------------------------
def check_execution(repo: Path, test_cmd: Sequence[str], timeout: float = 300) -> list[Finding]:
    try:
        p = subprocess.run(list(test_cmd), cwd=repo, capture_output=True, text=True, timeout=timeout, stdin=subprocess.DEVNULL)
    except FileNotFoundError:
        return [Finding("execution", f"test command not found: {test_cmd[0]}")]
    except subprocess.TimeoutExpired:
        return [Finding("execution", f"tests timed out after {timeout:g}s")]
    if p.returncode != 0:
        tail = (p.stdout + p.stderr).strip().splitlines()[-3:]
        return [Finding("execution", f"tests failed (exit {p.returncode}): {' | '.join(tail)}")]
    return []


# ---- pillar 2 -------------------------------------------------------------
def check_security(repo: Path, files: Sequence[str]) -> list[Finding]:
    out: list[Finding] = []
    for rel in files:
        path = repo / rel
        if not path.is_file():
            continue
        text = path.read_text(errors="replace")
        if path.suffix == ".py":
            try:
                with tempfile.TemporaryDirectory() as d:
                    py_compile.compile(str(path), cfile=str(Path(d) / "x.pyc"), doraise=True)
            except py_compile.PyCompileError as exc:
                out.append(Finding("lint", f"{rel}: syntax error: {str(exc).splitlines()[-1]}"))
        for i, line in enumerate(text.splitlines(), 1):
            for pat, label in DANGEROUS:
                if pat.search(line) and not line.lstrip().startswith("#"):
                    out.append(Finding("security", f"{rel}:{i}: {label}"))
            if SECRET_ASSIGN.search(line) or any(p.search(line) for p in TOKEN_PATTERNS[:5]):
                out.append(Finding("security", f"{rel}:{i}: hard-coded credential"))
    return out


# ---- pillar 3 -------------------------------------------------------------
def check_alignment(repo: Path, requirements: Sequence[Requirement]) -> list[Finding]:
    out: list[Finding] = []
    for r in requirements:
        path = repo / r.path
        if not path.is_file():
            out.append(Finding("alignment", f"{r.id}: required file {r.path} missing ({r.description})"))
            continue
        text = path.read_text(errors="replace")
        if not re.search(r.pattern, text, re.M):
            out.append(Finding("alignment", f"{r.id}: not satisfied - {r.description}"))
        if r.forbidden and re.search(r.forbidden, text, re.M):
            out.append(Finding("alignment", f"{r.id}: forbidden deviation present in {r.path}"))
    return out


def review(repo: str | Path, *, test_cmd: Sequence[str] | None, files: Sequence[str],
           requirements: Sequence[Requirement], reviewer: str = "reviewer") -> Report:
    repo = Path(repo)
    rep = Report(reviewer)
    if test_cmd:
        rep.findings += check_execution(repo, test_cmd)
    else:
        rep.findings.append(Finding("execution", "no test command provided; cannot validate execution"))
    rep.findings += check_security(repo, files)
    rep.findings += check_alignment(repo, requirements)
    return rep


# ---- consensus ------------------------------------------------------------
class Decision(str, Enum):
    APPROVED = "approved"
    REJECTED = "rejected"
    HUMAN_GATE = "human_gate"


def consensus(reports: Sequence[Report], human: Callable[[Sequence[Report]], bool] | None = None) -> Decision:
    """First-principles resolution: evidence failures from ANY reviewer reject; unanimous
    passes approve; mixed verdicts (non-evidence disagreement) require a human decision."""
    if not reports:
        return Decision.REJECTED
    hard = any(f.pillar in ("execution", "security", "lint") and f.blocking for r in reports for f in r.findings)
    if hard:
        return Decision.REJECTED
    passes = [r.passed for r in reports]
    if all(passes):
        return Decision.APPROVED
    if not any(passes):
        return Decision.REJECTED
    if human is None:
        return Decision.HUMAN_GATE
    return Decision.APPROVED if human(reports) else Decision.REJECTED


# ---- DAG integration ------------------------------------------------------
def reviewer_handler(repo, test_cmd, files, requirements) -> Handler:
    async def h(env):
        rep = review(repo, test_cmd=test_cmd, files=files, requirements=requirements)
        return StepResult(ok=rep.passed, output={"findings": [f.__dict__ for f in rep.findings]},
                          error=None if rep.passed else rep.summary())
    return h


def with_review_gate(run_id: str, steps: list[StepSpec], review_id: str = "review", done_id: str = "complete") -> DagSpec:
    """Append a reviewer step depending on all work steps and a completion step that
    depends on the reviewer: the run cannot complete without a Reviewer pass."""
    work = [s.id for s in steps]
    return DagSpec(run_id=run_id, steps=[*steps,
                                         StepSpec(id=review_id, deps=work, kind="review", max_attempts=1),
                                         StepSpec(id=done_id, deps=[review_id], kind="complete", max_attempts=1)])
