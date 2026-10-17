"""4-tier hybrid cascade router.

Tier 0 explicit override  -> specialist agent, no LLM
Tier 1 deterministic rule -> tool/script, no LLM
Tier 2 semantic match     -> agent domain, no LLM (pluggable embedder; default lexical)
Tier 3 orchestrator LLM   -> fast-profile dispatch to local SGLang (port 30000)

Also provides canonical, byte-stable prefix assembly so SGLang RadixAttention
reuses cached KV across turns.
"""
from __future__ import annotations

import json
import math
import re
import time
import urllib.request
from collections import Counter
from dataclasses import dataclass, field
from typing import Callable, Sequence

SGLANG_URL = "http://127.0.0.1:30000/v1"
FAST_PROFILE = {"max_tokens": 256, "temperature": 0.0, "top_p": 1.0}          # Tier-3 router
FULL_PROFILE = {"max_tokens": 8192, "temperature": 0.6, "top_p": 0.95}        # worker roles
AGENTS = ("architect", "worker", "reviewer", "sub-agent")


@dataclass(frozen=True)
class Route:
    tier: int
    kind: str            # "agent" | "tool" | "llm-plan"
    target: str
    reason: str
    plan: tuple[str, ...] = ()
    llm_ms: float = 0.0


OVERRIDE_RE = re.compile(r"^\s*@(" + "|".join(AGENTS) + r")\b[:\s]*", re.I)


def tier0(text: str) -> Route | None:
    m = OVERRIDE_RE.match(text)
    return Route(0, "agent", m.group(1).lower(), "explicit @agent override") if m else None


@dataclass
class Rule:
    pattern: re.Pattern
    tool: str


DEFAULT_RULES = [
    Rule(re.compile(r"^\s*(run|execute)\s+(the\s+)?(unit\s+)?tests?\b", re.I), "scripts/run_tests"),
    Rule(re.compile(r"^\s*git\s+status\b", re.I), "git status"),
    Rule(re.compile(r"^\s*(show|check)\s+(gpu|vram)\b", re.I), "scripts/harness_diagnostics.sh"),
]


def tier1(text: str, rules: Sequence[Rule] = DEFAULT_RULES) -> Route | None:
    for r in rules:
        if r.pattern.search(text):
            return Route(1, "tool", r.tool, f"deterministic rule /{r.pattern.pattern}/")
    return None


DOMAINS = {
    "architect": "design architecture plan roadmap tradeoff structure interface decompose milestone",
    "worker": "implement write code function fix bug refactor feature add module test unit",
    "reviewer": "review audit security vulnerability regression lint verify check diff leak",
    "sub-agent": "grep find search list rename small quick lookup locate file",
}


def _vec(t: str) -> Counter:
    return Counter(re.findall(r"[a-z]{3,}", t.lower()))


def _cos(a: Counter, b: Counter) -> float:
    dot = sum(a[k] * b.get(k, 0) for k in a)
    na, nb = math.sqrt(sum(v * v for v in a.values())), math.sqrt(sum(v * v for v in b.values()))
    return dot / (na * nb) if na and nb else 0.0


def tier2(text: str, threshold: float = 0.2, domains: dict[str, str] = DOMAINS,
          similarity: Callable[[str, str], float] | None = None) -> Route | None:
    sim = similarity or (lambda q, d: _cos(_vec(q), _vec(d)))
    scored = sorted(((sim(text, d), a) for a, d in domains.items()), reverse=True)
    if scored and scored[0][0] >= threshold and (len(scored) == 1 or scored[0][0] > scored[1][0]):
        return Route(2, "agent", scored[0][1], f"semantic score {scored[0][0]:.2f}")
    return None


# ---- canonical prefix -----------------------------------------------------
def canonical_prefix(system: str, tools: Sequence[dict], history: Sequence[dict]) -> str:
    """Deterministic serialization: tools sorted by name with sorted keys, fixed separators,
    history append-only. Turn N+1's prefix is byte-identical to turn N's full text."""
    parts = [f"<system>\n{system.strip()}\n</system>\n"]
    for t in sorted(tools, key=lambda t: t.get("name", "")):
        parts.append("<tool>" + json.dumps(t, sort_keys=True, separators=(",", ":"), ensure_ascii=False) + "</tool>\n")
    for m in history:
        parts.append(f"<{m['role']}>\n{m['content'].rstrip()}\n</{m['role']}>\n")
    return "".join(parts)


def build_messages(system: str, tools: Sequence[dict], history: Sequence[dict], user: str) -> list[dict]:
    """OpenAI messages whose system content is the canonical (cache-stable) prefix."""
    return [{"role": "system", "content": canonical_prefix(system, tools, history)},
            {"role": "user", "content": user}]


# ---- tier 3 ---------------------------------------------------------------
ROUTER_SYSTEM = ("You are a task router. Reply with ONLY compact JSON: "
                 '{"agent":"architect|worker|reviewer|sub-agent","plan":["step",...]}.')


def tier3(text: str, base_url: str = SGLANG_URL, model: str = "ornith-1.5-35b", timeout: float = 60.0) -> Route:
    body = {"model": model, "messages": build_messages(ROUTER_SYSTEM, [], [], text), **FAST_PROFILE}
    req = urllib.request.Request(base_url.rstrip("/") + "/chat/completions", data=json.dumps(body).encode(),
                                 headers={"Content-Type": "application/json", "Authorization": "Bearer EMPTY"})
    t = time.perf_counter()
    with urllib.request.urlopen(req, timeout=timeout) as r:
        content = json.load(r)["choices"][0]["message"]["content"]
    ms = (time.perf_counter() - t) * 1000
    m = re.search(r"\{.*\}", content, re.S)
    try:
        data = json.loads(m.group(0)) if m else {}
    except json.JSONDecodeError:
        data = {}
    agent = data.get("agent") if data.get("agent") in AGENTS else "worker"
    plan = tuple(str(s) for s in data.get("plan", []) if isinstance(s, (str, int)))[:20]
    return Route(3, "llm-plan", agent, "orchestrator LLM dispatch", plan, ms)


@dataclass
class CascadeRouter:
    base_url: str = SGLANG_URL
    rules: Sequence[Rule] = field(default_factory=lambda: list(DEFAULT_RULES))
    threshold: float = 0.2
    llm: Callable[[str], Route] | None = None

    def route(self, text: str) -> Route:
        return (tier0(text) or tier1(text, self.rules) or tier2(text, self.threshold)
                or (self.llm(text) if self.llm else tier3(text, self.base_url)))
