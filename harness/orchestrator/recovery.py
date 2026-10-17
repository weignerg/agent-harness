"""Tiered checkpoints, rollback and bounded self-healing.

A checkpoint atomically captures (a) the contents of the named files and (b) the
run's step rows, in one SQLite transaction, BEFORE any mutation. Rollback restores
both and deletes files that did not exist at checkpoint time.
Tiers: "step" (single destructive task) and "run" (before a larger phase).
"""
from __future__ import annotations

import base64
import json
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import Callable, Sequence

from .models import StepResult, StepState
from .state_machine import StateMachine

TIERS = ("step", "run")


class CheckpointError(Exception):
    pass


class CheckpointManager:
    def __init__(self, sm: StateMachine, workdir: str | Path):
        self.sm, self.root = sm, Path(workdir).resolve()
        self.sm.db.execute("CREATE TABLE IF NOT EXISTS checkpoint_meta(id INTEGER PRIMARY KEY, tier TEXT NOT NULL, valid INTEGER NOT NULL DEFAULT 0)")

    def _safe(self, rel: str) -> Path:
        p = (self.root / rel).resolve()
        if self.root != p and self.root not in p.parents:
            raise CheckpointError(f"path escapes workdir: {rel}")
        return p

    def create(self, run_id: str, label: str, paths: Sequence[str], tier: str = "step") -> int:
        if tier not in TIERS:
            raise CheckpointError(f"unknown tier {tier}")
        files: dict[str, str | None] = {}
        for rel in paths:
            p = self._safe(rel)
            files[rel] = base64.b64encode(p.read_bytes()).decode() if p.is_file() else None
        db = self.sm.db
        rows = [list(r) for r in db.execute("SELECT * FROM steps WHERE run_id=?", (run_id,))]
        cols = [c[1] for c in db.execute("PRAGMA table_info(steps)")]
        snap = json.dumps({"files": files, "cols": cols, "rows": rows})
        db.execute("BEGIN IMMEDIATE")
        try:
            cur = db.execute("INSERT INTO checkpoints(run_id,label,snapshot,ts) VALUES(?,?,?,?)", (run_id, label, snap, time.time()))
            db.execute("INSERT INTO checkpoint_meta(id,tier,valid) VALUES(?,?,0)", (cur.lastrowid, tier))
            db.execute("COMMIT")
        except Exception:
            db.execute("ROLLBACK"); raise
        return cur.lastrowid

    def mark_valid(self, ckpt_id: int) -> None:
        self.sm.db.execute("UPDATE checkpoint_meta SET valid=1 WHERE id=?", (ckpt_id,))

    def nearest_valid(self, run_id: str, tier: str | None = None) -> int | None:
        q = ("SELECT c.id FROM checkpoints c JOIN checkpoint_meta m ON m.id=c.id WHERE c.run_id=? AND m.valid=1"
             + (" AND m.tier=?" if tier else "") + " ORDER BY c.id DESC LIMIT 1")
        r = self.sm.db.execute(q, (run_id, tier) if tier else (run_id,)).fetchone()
        return r[0] if r else None

    def rollback(self, run_id: str, ckpt_id: int | None = None) -> int:
        """Restore files + step rows from the given (or nearest valid) checkpoint."""
        ckpt_id = ckpt_id or self.nearest_valid(run_id)
        if ckpt_id is None:
            raise CheckpointError("no valid checkpoint to roll back to")
        row = self.sm.db.execute("SELECT snapshot FROM checkpoints WHERE id=? AND run_id=?", (ckpt_id, run_id)).fetchone()
        if row is None:
            raise CheckpointError(f"checkpoint {ckpt_id} not found for run {run_id}")
        snap = json.loads(row[0])
        for rel, b64 in snap["files"].items():
            p = self._safe(rel)
            if b64 is None:
                p.unlink(missing_ok=True)
            else:
                p.parent.mkdir(parents=True, exist_ok=True)
                tmp = p.with_name(p.name + ".rollback.tmp")
                tmp.write_bytes(base64.b64decode(b64)); tmp.replace(p)
        db = self.sm.db
        db.execute("BEGIN IMMEDIATE")
        try:
            db.execute("DELETE FROM steps WHERE run_id=?", (run_id,))
            ph = ",".join("?" * len(snap["cols"]))
            for r in snap["rows"]:
                db.execute(f"INSERT INTO steps({','.join(snap['cols'])}) VALUES({ph})", r)
            db.execute("INSERT INTO events(run_id,step_id,from_state,to_state,ts,detail) VALUES(?,?,?,?,?,?)",
                       (run_id, "*", None, StepState.ROLLED_BACK.value, time.time(), json.dumps({"checkpoint": ckpt_id})))
            db.execute("COMMIT")
        except Exception:
            db.execute("ROLLBACK"); raise
        return ckpt_id


@dataclass
class FailureHint:
    attempt: int
    error: str
    avoid: str

    def text(self) -> str:
        return f"attempt {self.attempt} failed: {self.error}. Do NOT repeat: {self.avoid}"


@dataclass
class HealOutcome:
    healed: bool
    attempts: int
    rolled_back: bool
    hints: list[FailureHint] = field(default_factory=list)
    reason: str = ""


def self_heal(mgr: CheckpointManager, run_id: str, paths: Sequence[str],
              action: Callable[[list[str]], str], validate: Callable[[], str | None],
              budget: int = 3) -> HealOutcome:
    """Run `action(hints)` (which mutates files and returns a short signature of what it
    did) then `validate()` (returns an error string or None). Retries are bounded by
    `budget`, never repeat an identical failing approach, and exhaustion rolls back."""
    base = mgr.create(run_id, "pre-heal", paths, tier="step")
    mgr.mark_valid(base) if validate() is None else None  # pristine state is a valid rollback target only if it validates
    hints: list[FailureHint] = []
    tried: set[str] = set()
    for attempt in range(1, budget + 1):
        sig = action([h.text() for h in hints])
        err = validate()
        if err is None:
            ck = mgr.create(run_id, f"healed-{attempt}", paths, tier="step"); mgr.mark_valid(ck)
            return HealOutcome(True, attempt, False, hints)
        if sig in tried:
            return _fail(mgr, run_id, base, attempt, hints, "identical approach repeated")
        tried.add(sig)
        hints.append(FailureHint(attempt, err, sig))
    return _fail(mgr, run_id, base, budget, hints, f"self-healing budget ({budget}) exhausted")


def _fail(mgr, run_id, base, attempts, hints, reason) -> HealOutcome:
    target = mgr.nearest_valid(run_id) or base  # fall back to the pre-mutation snapshot
    mgr.rollback(run_id, target)
    return HealOutcome(False, attempts, True, hints, reason)
