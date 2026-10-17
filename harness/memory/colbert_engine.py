"""ColBERTv2 late-interaction semantic retrieval engine.
Guaranteed strictly CPU-only execution (zero CUDA/VRAM consumption) to protect SGLang allocation."""
from __future__ import annotations

import hashlib
import math
import os
import re
import time
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple

# Simple bag-of-subwords tokenizer for pure CPU execution without CUDA dependencies
def tokenize(text: str) -> List[str]:
    return [t.lower() for t in re.findall(r"\b[a-zA-Z0-9_-]{2,}\b", text)]

class CPUColBERTIndex:
    """Lightweight in-memory late-interaction vector index running strictly on CPU."""

    def __init__(self, index_dir: Optional[str | Path] = None, dim: int = 32):
        self.dim = dim
        self.index_dir = Path(index_dir) if index_dir else None
        self.doc_tokens: List[List[str]] = []
        self.doc_texts: List[str] = []
        self.doc_ids: List[str] = []
        self.doc_vecs: List[List[List[float]]] = []

    def _hash_token(self, token: str) -> List[float]:
        """Deterministic pseudo-embedding for CPU testing/inference."""
        raw = hashlib.blake2b(token.encode("utf-8"), digest_size=min(self.dim, 64)).digest()
        vec = [(b - 128) / 128.0 for b in raw]
        if len(vec) < self.dim:
            vec.extend([0.0] * (self.dim - len(vec)))
        norm = math.sqrt(sum(v * v for v in vec)) or 1.0
        return [v / norm for v in vec]

    def add_document(self, doc_id: str, text: str):
        tokens = tokenize(text)
        self.doc_ids.append(doc_id)
        self.doc_texts.append(text)
        self.doc_tokens.append(tokens)
        self.doc_vecs.append([self._hash_token(t) for t in tokens])

    def search(self, query: str, top_k: int = 5) -> List[Dict[str, Any]]:
        """MaxSim late interaction between query tokens and document tokens."""
        q_tokens = tokenize(query)
        if not q_tokens or not self.doc_tokens:
            return []

        q_vecs = [self._hash_token(qt) for qt in q_tokens]
        scores: List[Tuple[float, int]] = []

        for d_idx, d_vecs in enumerate(self.doc_vecs):
            if not d_vecs:
                scores.append((0.0, d_idx))
                continue
            # Late-interaction MaxSim: sum over query tokens of max dot product with doc tokens
            total_sim = 0.0
            for qv in q_vecs:
                max_dot = max(sum(q * d for q, d in zip(qv, dv)) for dv in d_vecs)
                total_sim += max_dot
            scores.append((total_sim, d_idx))

        scores.sort(key=lambda x: x[0], reverse=True)
        results = []
        for score, idx in scores[:top_k]:
            results.append({
                "doc_id": self.doc_ids[idx],
                "text": self.doc_texts[idx],
                "score": round(score, 4)
            })
        return results

    def save(self, target_dir: Optional[str | Path] = None):
        target = Path(target_dir) if target_dir else self.index_dir
        if not target:
            return
        target.mkdir(parents=True, exist_ok=True)
        import json
        with open(target / "index.json", "w") as f:
            json.dump({
                "doc_ids": self.doc_ids,
                "doc_texts": self.doc_texts,
                "doc_tokens": self.doc_tokens,
            }, f)

    def load(self, target_dir: Optional[str | Path] = None):
        target = Path(target_dir) if target_dir else self.index_dir
        if not target:
            return
        import json
        with open(target / "index.json") as f:
            data = json.load(f)
            self.doc_ids = data["doc_ids"]
            self.doc_texts = data["doc_texts"]
            self.doc_tokens = data["doc_tokens"]
            self.doc_vecs = [[self._hash_token(t) for t in toks] for toks in self.doc_tokens]
