"""Secret broker: fetch short-lived secrets from 1Password (`op`) or KDE Wallet
(`kwalletcli`) into ephemeral child-process environments, never touching disk,
and redact them from any captured output or log text."""
from __future__ import annotations

import re
import subprocess
from dataclasses import dataclass, field
from typing import Mapping, Sequence

KWALLET_TIMEOUT_S = 2.0  # headless/SSH D-Bus guard: never block longer than this
OP_TIMEOUT_S = 10.0
MASK = "[REDACTED]"

# Generic token shapes masked even when the literal value is unknown.
TOKEN_PATTERNS = [
    re.compile(r"hf_[A-Za-z0-9]{20,}"),
    re.compile(r"gh[pousr]_[A-Za-z0-9]{20,}"),
    re.compile(r"sk-[A-Za-z0-9_-]{20,}"),
    re.compile(r"AKIA[0-9A-Z]{16}"),
    re.compile(r"(?i)(bearer\s+)[A-Za-z0-9._~+/=-]{16,}"),
    re.compile(r"(?i)((?:api[_-]?key|token|secret|password)\s*[=:]\s*)[^\s'\"]{6,}"),
]


class SecretBrokerError(RuntimeError):
    """Clean diagnostic failure from a secret backend."""


@dataclass
class Redactor:
    """Masks registered literal secrets and common token patterns."""
    literals: set[str] = field(default_factory=set)

    def register(self, value: str) -> None:
        if value and len(value) >= 4:
            self.literals.add(value)

    def redact(self, text: str) -> str:
        for lit in sorted(self.literals, key=len, reverse=True):
            text = text.replace(lit, MASK)
        for pat in TOKEN_PATTERNS:
            if pat.groups:
                text = pat.sub(lambda m: m.group(1) + MASK, text)
            else:
                text = pat.sub(MASK, text)
        return text


def _run(cmd: Sequence[str], timeout: float, what: str) -> str:
    try:
        proc = subprocess.run(
            list(cmd), capture_output=True, text=True, timeout=timeout,
            stdin=subprocess.DEVNULL, check=False,
        )
    except FileNotFoundError:
        raise SecretBrokerError(f"{what}: '{cmd[0]}' is not installed") from None
    except subprocess.TimeoutExpired:
        raise SecretBrokerError(
            f"{what}: timed out after {timeout:g}s (headless session or locked wallet? "
            "unlock it or run in an interactive desktop session)"
        ) from None
    if proc.returncode != 0:
        raise SecretBrokerError(f"{what}: backend exited with status {proc.returncode}")
    return proc.stdout.rstrip("\n")


def fetch_op(reference: str) -> str:
    """Read an `op://vault/item/field` reference via the 1Password CLI."""
    if not reference.startswith("op://"):
        raise SecretBrokerError("1Password reference must start with op://")
    return _run(["op", "read", "--no-newline", reference], OP_TIMEOUT_S, "1Password")


def fetch_kwallet(folder: str, entry: str) -> str:
    """Read a KDE Wallet entry via kwalletcli with a strict 2s timeout."""
    return _run(["kwalletcli", "-f", folder, "-e", entry], KWALLET_TIMEOUT_S, "KWallet")


class SecretBroker:
    """Resolve env-var -> secret specs and run children with ephemeral env.

    spec examples: {"HF_TOKEN": "op://Dev/hf/token", "API": "kwallet://folder/entry"}
    """

    def __init__(self) -> None:
        self.redactor = Redactor()

    def resolve(self, spec: Mapping[str, str]) -> dict[str, str]:
        env: dict[str, str] = {}
        for name, ref in spec.items():
            if ref.startswith("op://"):
                value = fetch_op(ref)
            elif ref.startswith("kwallet://"):
                folder, _, entry = ref[len("kwallet://"):].partition("/")
                if not folder or not entry:
                    raise SecretBrokerError("kwallet reference must be kwallet://folder/entry")
                value = fetch_kwallet(folder, entry)
            else:
                raise SecretBrokerError(f"unsupported secret reference for {name}")
            self.redactor.register(value)
            env[name] = value
        return env

    def run_child(self, cmd: Sequence[str], spec: Mapping[str, str],
                  base_env: Mapping[str, str] | None = None, timeout: float | None = None):
        """Run cmd with secrets only in its environment; returns redacted (rc, out, err)."""
        import os
        env = dict(os.environ if base_env is None else base_env)
        env.update(self.resolve(spec))
        proc = subprocess.run(list(cmd), env=env, capture_output=True, text=True,
                              stdin=subprocess.DEVNULL, timeout=timeout, check=False)
        return proc.returncode, self.redactor.redact(proc.stdout), self.redactor.redact(proc.stderr)
