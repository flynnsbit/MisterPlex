"""Coverage ledger that gates completeness claims for decode stages.

Every feature entry must name a real H.264 decode capability. The gate FAILs
when a stage sets claimed_complete while features are empty or any feature is
still unproven. Soft-skip / empty ledgers are not completeness.
"""
from __future__ import annotations

import json
from pathlib import Path
from typing import Any


SCHEMA = "misterplex.decoder_coverage.v1"
VALID_STATUS = {"unproven", "proven", "waived"}


def load_coverage_ledger(path: Path) -> dict[str, Any]:
    data = json.loads(path.read_text())
    if data.get("schema") != SCHEMA:
        raise ValueError(f"coverage schema want {SCHEMA} got {data.get('schema')}")
    if "stages" not in data or not isinstance(data["stages"], dict):
        raise ValueError("coverage ledger needs stages object")
    return data


def check_coverage_claims(ledger: dict[str, Any]) -> tuple[int, list[str]]:
    """Return (rc, messages). rc=0 clean; rc=1 claim/coverage defect."""
    msgs: list[str] = []
    failures: list[str] = []
    stages = ledger.get("stages") or {}
    if not stages:
        # Empty stages object is allowed only when nothing is claimed delivered.
        msgs.append("COVERAGE_LEDGER stages=(empty) — no completeness claims")
        return 0, msgs

    for name, st in stages.items():
        if not isinstance(st, dict):
            failures.append(f"stage={name} not an object")
            continue
        claimed = bool(st.get("claimed_complete"))
        features = st.get("features") or {}
        rtl_modules = list(st.get("rtl_modules") or [])
        msgs.append(
            f"COVERAGE_STAGE name={name} claimed_complete={int(claimed)} "
            f"n_features={len(features)} n_rtl_modules={len(rtl_modules)}"
        )

        if not isinstance(features, dict):
            failures.append(f"stage={name} features must be object")
            continue

        for feat, meta in features.items():
            if not isinstance(meta, dict):
                failures.append(f"stage={name} feature={feat} not an object")
                continue
            cap = (meta.get("capability") or "").strip()
            status = (meta.get("status") or "unproven").strip().lower()
            if not cap:
                failures.append(
                    f"stage={name} feature={feat}: missing capability name "
                    "(every entry must name the decode capability it gates)"
                )
            if status not in VALID_STATUS:
                failures.append(
                    f"stage={name} feature={feat}: bad status={status!r} "
                    f"want one of {sorted(VALID_STATUS)}"
                )
            if status == "proven" and not (meta.get("evidence") or "").strip():
                failures.append(
                    f"stage={name} feature={feat}: proven without evidence path/test id"
                )

        if claimed:
            if not features:
                failures.append(
                    f"stage={name} claimed_complete=true but features empty "
                    "(empty coverage cannot gate a completeness claim)"
                )
            unproven = [
                f
                for f, meta in features.items()
                if isinstance(meta, dict)
                and (meta.get("status") or "unproven").lower() == "unproven"
            ]
            if unproven:
                failures.append(
                    f"stage={name} claimed_complete=true but unproven features="
                    f"{unproven}"
                )
            # Completeness implies named RTL modules for reachability coupling.
            if not rtl_modules:
                failures.append(
                    f"stage={name} claimed_complete=true but rtl_modules empty "
                    "(must name fabric modules claimed delivered)"
                )

    if failures:
        for f in failures:
            msgs.append(f"COVERAGE_FAIL {f}")
        msgs.append("FAIL decoder_coverage: completeness/coverage claim defect")
        return 1, msgs

    msgs.append("PASS decoder_coverage: no false completeness claims")
    return 0, msgs


def claimed_rtl_modules(ledger: dict[str, Any]) -> list[str]:
    """Union of rtl_modules across stages that claim complete OR list modules."""
    out: list[str] = []
    seen: set[str] = set()
    for _name, st in (ledger.get("stages") or {}).items():
        if not isinstance(st, dict):
            continue
        # Modules listed under any stage are "claimed present" for reachability
        # when claimed_complete OR explicit claim_delivered flag.
        claim = bool(st.get("claimed_complete")) or bool(st.get("claim_delivered"))
        if not claim:
            continue
        for m in st.get("rtl_modules") or []:
            m = str(m)
            if m not in seen:
                seen.add(m)
                out.append(m)
    return out
