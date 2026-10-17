"""Zero-bloat async state machine: asyncio + Pydantic + SQLite (WAL).

Every transition is one atomic SQLite transaction that updates the step row and
appends an event, so state survives crashes/restarts exactly at a transition
boundary. Synthetic handlers drive the machine; richer nodes (router, reviewer)
plug in as handlers in later tasks.
"""
from __future__ import annotations

import asyncio
import json
import sqlite3
import time
from pathlib import Path
from typing import Any, Awaitable, Callable, Mapping

from .models import ALLOWED, TERMINAL, DagSpec, Envelope, Event, StepResult, StepState

Handler = Callable[[Envelope], Awaitable[StepResult]]

SCHEMA = """
CREATE TABLE IF NOT EXISTS runs(run_id TEXT PRIMARY KEY, created REAL NOT NULL);
CREATE TABLE IF NOT EXISTS steps(
  run_id TEXT NOT NULL, step_id TEXT NOT NULL, state TEXT NOT NULL, kind TEXT NOT NULL,
  deps TEXT NOT NULL, payload TEXT NOT NULL, result TEXT, attempts INTEGER NOT NULL DEFAULT 0,
  max_attempts INTEGER NOT NULL, hints TEXT NOT NULL DEFAULT '[]', updated REAL NOT NULL,
  PRIMARY KEY(run_id, step_id));
CREATE TABLE IF NOT EXISTS events(
  seq INTEGER PRIMARY KEY AUTOINCREMENT, run_id TEXT NOT NULL, step_id TEXT NOT NULL,
  from_state TEXT, to_state TEXT NOT NULL, ts REAL NOT NULL, detail TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS checkpoints(
  id INTEGER PRIMARY KEY AUTOINCREMENT, run_id TEXT NOT NULL, label TEXT NOT NULL,
  snapshot TEXT NOT NULL, ts REAL NOT NULL);
CREATE INDEX IF NOT EXISTS idx_events_run ON events(run_id, seq);
"""


class InvalidTransition(Exception):
    pass


class StateMachine:
    def __init__(self, db_path: str | Path = "harness.db"):
        self.db_path = str(db_path)
        self.db = sqlite3.connect(self.db_path, isolation_level=None, check_same_thread=False)
        self.db.execute("PRAGMA journal_mode=WAL")
        self.db.execute("PRAGMA synchronous=NORMAL")
        self.db.execute("PRAGMA foreign_keys=ON")
        self.db.executescript(SCHEMA)

    def close(self) -> None:
        self.db.close()

    # ---- DAG lifecycle -------------------------------------------------
    def create_run(self, dag: DagSpec) -> None:
        now = time.time()
        with self._tx():
            self.db.execute("INSERT INTO runs VALUES(?,?)", (dag.run_id, now))
            for s in dag.steps:
                self.db.execute(
                    "INSERT INTO steps(run_id,step_id,state,kind,deps,payload,max_attempts,updated)"
                    " VALUES(?,?,?,?,?,?,?,?)",
                    (dag.run_id, s.id, StepState.PENDING.value, s.kind, json.dumps(s.deps),
                     json.dumps(s.payload), s.max_attempts, now))

    def _tx(self):
        db = self.db

        class _T:
            def __enter__(self_):
                db.execute("BEGIN IMMEDIATE")

            def __exit__(self_, et, ev, tb):
                db.execute("ROLLBACK" if et else "COMMIT")
                return False
        return _T()

    # ---- state access --------------------------------------------------
    def state(self, run_id: str, step_id: str) -> StepState:
        row = self.db.execute("SELECT state FROM steps WHERE run_id=? AND step_id=?", (run_id, step_id)).fetchone()
        if row is None:
            raise KeyError(f"unknown step {run_id}/{step_id}")
        return StepState(row[0])

    def states(self, run_id: str) -> dict[str, StepState]:
        return {r[0]: StepState(r[1]) for r in
                self.db.execute("SELECT step_id,state FROM steps WHERE run_id=?", (run_id,))}

    def attempts(self, run_id: str, step_id: str) -> int:
        return self.db.execute("SELECT attempts FROM steps WHERE run_id=? AND step_id=?", (run_id, step_id)).fetchone()[0]

    def result(self, run_id: str, step_id: str) -> StepResult | None:
        r = self.db.execute("SELECT result FROM steps WHERE run_id=? AND step_id=?", (run_id, step_id)).fetchone()
        return StepResult.model_validate_json(r[0]) if r and r[0] else None

    def events(self, run_id: str) -> list[Event]:
        out = []
        for r in self.db.execute("SELECT seq,run_id,step_id,from_state,to_state,ts,detail FROM events WHERE run_id=? ORDER BY seq", (run_id,)):
            out.append(Event(seq=r[0], run_id=r[1], step_id=r[2], from_state=StepState(r[3]) if r[3] else None,
                             to_state=StepState(r[4]), ts=r[5], detail=json.loads(r[6])))
        return out

    def hints(self, run_id: str, step_id: str) -> list[str]:
        return json.loads(self.db.execute("SELECT hints FROM steps WHERE run_id=? AND step_id=?", (run_id, step_id)).fetchone()[0])

    # ---- transitions ---------------------------------------------------
    def transition(self, run_id: str, step_id: str, to: StepState, *, result: StepResult | None = None,
                   hint: str | None = None, detail: Mapping[str, Any] | None = None) -> None:
        """Atomically move a step to `to`; raises InvalidTransition if not allowed."""
        with self._tx():
            row = self.db.execute("SELECT state,attempts,hints FROM steps WHERE run_id=? AND step_id=?", (run_id, step_id)).fetchone()
            if row is None:
                raise KeyError(f"unknown step {run_id}/{step_id}")
            cur = StepState(row[0])
            if to not in ALLOWED[cur]:
                raise InvalidTransition(f"{cur.value} -> {to.value} not allowed for {step_id}")
            attempts = row[1] + (1 if to is StepState.RUNNING else 0)
            hints = json.loads(row[2])
            if hint:
                hints.append(hint)
            now = time.time()
            self.db.execute(
                "UPDATE steps SET state=?, attempts=?, hints=?, updated=?, result=COALESCE(?,result) WHERE run_id=? AND step_id=?",
                (to.value, attempts, json.dumps(hints), now, result.model_dump_json() if result else None, run_id, step_id))
            self.db.execute("INSERT INTO events(run_id,step_id,from_state,to_state,ts,detail) VALUES(?,?,?,?,?,?)",
                            (run_id, step_id, cur.value, to.value, now, json.dumps(dict(detail or {}))))

    def ready_steps(self, run_id: str) -> list[str]:
        """Steps that are PENDING with every dependency SUCCEEDED."""
        st = self.states(run_id)
        ready = []
        for sid, deps in self.db.execute("SELECT step_id,deps FROM steps WHERE run_id=?", (run_id,)):
            if st[sid] is StepState.PENDING and all(st[d] is StepState.SUCCEEDED for d in json.loads(deps)):
                ready.append(sid)
        return sorted(ready)

    def is_finished(self, run_id: str) -> bool:
        """No step can make further progress without outside action."""
        st = self.states(run_id)
        return not self.ready_steps(run_id) and not any(s is StepState.RUNNING for s in st.values())

    def recover_interrupted(self, run_id: str) -> list[str]:
        """After a crash, steps left RUNNING are failed so they can be retried."""
        stuck = [s for s, v in self.states(run_id).items() if v is StepState.RUNNING]
        for s in stuck:
            self.transition(run_id, s, StepState.FAILED, detail={"reason": "interrupted"})
        return stuck

    # ---- async execution ----------------------------------------------
    async def run_step(self, run_id: str, step_id: str, handler: Handler) -> StepState:
        row = self.db.execute("SELECT payload,max_attempts FROM steps WHERE run_id=? AND step_id=?", (run_id, step_id)).fetchone()
        self.transition(run_id, step_id, StepState.RUNNING)
        env = Envelope(run_id=run_id, step_id=step_id, attempt=self.attempts(run_id, step_id),
                       payload=json.loads(row[0]), hints=self.hints(run_id, step_id))
        try:
            res = await handler(env)
        except Exception as exc:  # handler crash is a failed step, never a dead loop
            res = StepResult(ok=False, error=f"{type(exc).__name__}: {exc}")
        end = StepState.SUCCEEDED if res.ok else StepState.FAILED
        self.transition(run_id, step_id, end, result=res, hint=None if res.ok else res.error)
        return end

    async def run(self, run_id: str, handlers: Mapping[str, Handler], *, retry_failed: bool = True) -> dict[str, StepState]:
        """Run ready steps concurrently until the DAG settles. Failed steps are
        retried up to max_attempts, then left FAILED for escalation logic."""
        while True:
            ready = self.ready_steps(run_id)
            if retry_failed:
                for sid, att, mx in self.db.execute("SELECT step_id,attempts,max_attempts FROM steps WHERE run_id=? AND state=?", (run_id, StepState.FAILED.value)).fetchall():
                    if att < mx:
                        ready.append(sid)
            if not ready:
                return self.states(run_id)
            kinds = dict(self.db.execute("SELECT step_id,kind FROM steps WHERE run_id=?", (run_id,)).fetchall())
            await asyncio.gather(*(self.run_step(run_id, s, handlers[kinds[s]]) for s in ready))
