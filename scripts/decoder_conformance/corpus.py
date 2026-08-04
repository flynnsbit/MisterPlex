"""Runtime-selected corpus with recorded seed (anti demo-path hardcoding).

Subjects are chosen at run time from a declared pool. Selection always records
the seed and chosen IDs. Completeness claims must include at least one subject
that is NOT in dev_fixture_ids — special-casing the pilot bitstream is a
named forbidden pattern (AGENTS.md demo-path hardcoding).
"""
from __future__ import annotations

import json
import random
import secrets
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any


SCHEMA = "misterplex.decoder_corpus.v1"


@dataclass
class CorpusSubject:
    id: str
    path: str
    tags: list[str] = field(default_factory=list)
    kind: str = "annexb"
    width: int = 0
    height: int = 0
    notes: str = ""


@dataclass
class Selection:
    seed: int
    k: int
    selected: list[CorpusSubject]
    non_dev_ids: list[str]
    dev_only: bool
    pool_size: int
    manifest_path: str

    def to_dict(self) -> dict[str, Any]:
        return {
            "schema": "misterplex.decoder_corpus_selection.v1",
            "seed": self.seed,
            "k": self.k,
            "pool_size": self.pool_size,
            "manifest": self.manifest_path,
            "selected_ids": [s.id for s in self.selected],
            "non_dev_ids": list(self.non_dev_ids),
            "dev_only": self.dev_only,
            "subjects": [
                {
                    "id": s.id,
                    "path": s.path,
                    "tags": s.tags,
                    "kind": s.kind,
                    "width": s.width,
                    "height": s.height,
                }
                for s in self.selected
            ],
        }


def load_corpus_manifest(path: Path) -> dict[str, Any]:
    data = json.loads(path.read_text())
    if data.get("schema") != SCHEMA:
        raise ValueError(f"corpus manifest schema want {SCHEMA} got {data.get('schema')}")
    if not isinstance(data.get("pool"), list) or not data["pool"]:
        raise ValueError("corpus manifest pool must be a non-empty list")
    data.setdefault("dev_fixture_ids", [])
    data.setdefault("min_non_dev_when_claiming", 1)
    return data


def _subjects(data: dict[str, Any]) -> list[CorpusSubject]:
    out: list[CorpusSubject] = []
    for raw in data["pool"]:
        out.append(
            CorpusSubject(
                id=str(raw["id"]),
                path=str(raw["path"]),
                tags=list(raw.get("tags") or []),
                kind=str(raw.get("kind") or "annexb"),
                width=int(raw.get("width") or 0),
                height=int(raw.get("height") or 0),
                notes=str(raw.get("notes") or ""),
            )
        )
    return out


def resolve_seed(explicit: int | None) -> int:
    if explicit is not None:
        return int(explicit) & 0xFFFFFFFFFFFFFFFF
    return secrets.randbits(64)


def select_subjects(
    manifest: dict[str, Any],
    *,
    seed: int | None = None,
    k: int = 2,
    manifest_path: str = "",
    require_non_dev: bool = False,
) -> Selection:
    """Select k subjects with Random(seed).sample (deterministic given seed)."""
    pool = _subjects(manifest)
    if k < 1:
        raise ValueError("k must be >= 1")
    if k > len(pool):
        raise ValueError(f"k={k} exceeds pool size {len(pool)}")

    seed_i = resolve_seed(seed)
    rng = random.Random(seed_i)
    chosen = rng.sample(pool, k)
    dev_ids = set(str(x) for x in (manifest.get("dev_fixture_ids") or []))
    non_dev = [s.id for s in chosen if s.id not in dev_ids]
    dev_only = len(non_dev) == 0
    if require_non_dev and dev_only:
        raise RuntimeError(
            "CORPUS_DEV_ONLY: selection contains only dev_fixture_ids "
            f"{[s.id for s in chosen]}; completeness claims require "
            f">= {manifest.get('min_non_dev_when_claiming', 1)} non-dev subject(s). "
            f"seed={seed_i}"
        )
    return Selection(
        seed=seed_i,
        k=k,
        selected=chosen,
        non_dev_ids=non_dev,
        dev_only=dev_only,
        pool_size=len(pool),
        manifest_path=manifest_path,
    )


def paths_exist(root: Path, selection: Selection) -> list[str]:
    """Return missing subject paths (relative to root)."""
    missing: list[str] = []
    for s in selection.selected:
        p = root / s.path
        if not p.is_file():
            missing.append(s.path)
    return missing
