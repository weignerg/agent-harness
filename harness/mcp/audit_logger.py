"""Append-only structured audit logger with automated token and secret redaction."""
from __future__ import annotations

import json
import os
import time
from pathlib import Path
from typing import Any, Dict, Optional

from harness.security.secret_broker import Redactor

class AuditLogger:
    """Writes immutable, redacted JSONL audit records for every tool invocation and result."""

    def __init__(self, log_path: Optional[str | Path] = None, redactor: Optional[Redactor] = None):
        if log_path:
            self.path = Path(log_path)
        else:
            self.path = Path.home() / ".local/state/opencode/audit.jsonl"
        self.path.parent.mkdir(parents=True, exist_ok=True)
        self.redactor = redactor or Redactor()

    def log_invocation(
        self,
        tool_name: str,
        params: Dict[str, Any],
        result: Any,
        status: str = "success",
        caller: str = "opencode-agent",
        duration_ms: float = 0.0,
    ) -> Dict[str, Any]:
        record = {
            "ts": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
            "tool": tool_name,
            "caller": caller,
            "status": status,
            "duration_ms": round(duration_ms, 2),
            "params": params,
            "result": result,
        }
        # Serialize and redact
        raw_json = json.dumps(record, ensure_ascii=False, default=str)
        redacted_json = self.redactor.redact(raw_json)
        
        # Atomic append
        fd = os.open(self.path, os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o600)
        try:
            os.write(fd, (redacted_json + "\n").encode("utf-8"))
            os.fsync(fd)
        finally:
            os.close(fd)

        return json.loads(redacted_json)
