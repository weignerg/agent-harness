"""Append-only structured JSON-lines metrics logger for SGLang/OpenCode inference.

Each record is one JSON line written with O_APPEND in a single write() so
concurrent writers never interleave; values are redacted before hitting disk.
Optionally mirrors a one-line summary to journald via `logger -t`.
"""
from __future__ import annotations

import json
import os
import subprocess
import time
from pathlib import Path

from harness.security.secret_broker import Redactor

DEFAULT_PATH = Path(os.environ.get("OPENCODE_METRICS_LOG",
                                   str(Path.home() / ".local/state/opencode/metrics.jsonl")))


class MetricsLogger:
    def __init__(self, path: Path | str = DEFAULT_PATH, max_bytes: int = 50 * 1024 * 1024,
                 backups: int = 5, journald: bool = False, redactor: Redactor | None = None):
        self.path = Path(path)
        self.max_bytes, self.backups, self.journald = max_bytes, backups, journald
        self.redactor = redactor or Redactor()
        self.path.parent.mkdir(parents=True, exist_ok=True)

    def _rotate(self) -> None:
        if not self.path.exists() or self.path.stat().st_size < self.max_bytes:
            return
        for i in range(self.backups - 1, 0, -1):
            src = self.path.with_name(f"{self.path.name}.{i}")
            if src.exists():
                src.replace(self.path.with_name(f"{self.path.name}.{i + 1}"))
        self.path.replace(self.path.with_name(f"{self.path.name}.1"))

    def log(self, model: str, latency_s: float, prompt_tokens: int, completion_tokens: int,
            **extra) -> dict:
        tps = round(completion_tokens / latency_s, 2) if latency_s > 0 else 0.0
        rec = {"ts": time.strftime("%Y-%m-%dT%H:%M:%S%z"), "model": model,
               "latency_s": round(latency_s, 4), "prompt_tokens": prompt_tokens,
               "completion_tokens": completion_tokens, "tokens_per_s": tps}
        rec.update(extra)
        line = self.redactor.redact(json.dumps(rec, separators=(",", ":"), ensure_ascii=False)) + "\n"
        self._rotate()
        fd = os.open(self.path, os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o600)
        try:
            os.write(fd, line.encode())
            os.fsync(fd)
        finally:
            os.close(fd)
        if self.journald:
            subprocess.run(["logger", "-t", "opencode-metrics", "-p", "user.info",
                            f"model={model} tps={tps} latency={rec['latency_s']}s"],
                           check=False, stdin=subprocess.DEVNULL)
        return json.loads(line)
