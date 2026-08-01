#!/usr/bin/env python3
"""Label ≠ derivation guard (parent 2026-08-01 daily-driver safety class).

Verified instances:
  frames_done     — name=swaps, derivation=vsyncs on c5382bee
  presents        — name=presentation, derivation=function returned
  HISTORICAL FAULT— name=past, may describe present silicon until fitted
  unaccounted     — name=independent term, derivation=residual printed twice

Rule: publish no field name without its derivation in the same breath.
This gate locks known high-blast fields and the three-line pre-retraction check.
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]

# Required derivation markers near the definition / pack / telemetry site.
REQUIRED = [
    (
        "host/libmisterplex/plxd_liveness.hpp",
        [
            "does NOT prove: bank swaps",
            "bank_vsync_count",
            "counter_moving",
        ],
        "plxd_liveness must document fd≠swap",
    ),
    (
        "host/libmisterplex/frame_ledger.hpp",
        [
            "ARM_PUBLISH_NOT_DISPLAY",
            "presentCount_",
        ],
        "frame_ledger must scope presents as ARM publish",
    ),
    (
        "host/libmisterplex/ddr_bank_release_select.hpp",
        [
            "HISTORICAL FAULT",
            "NOT bank_vsync_count",
        ],
        "bank-select must keep HISTORICAL + product pack note",
    ),
    (
        "fpga/Plex_MiSTer/rtl/ddr_frame_store.sv",
        [
            "frames_done_d2",
            "bank_vsync_count",
            "ARM stale detector could not fire",
        ],
        "RTL pack must warn freeze class",
    ),
    (
        "docs/COMMENT_CONTEXT_RULE.md",
        [
            "git log",
            "git show",
            "before retracting",
        ],
        "comment/retract rules present",
    ),
]

PRE_RETRACT_DOC = ROOT / "docs/PRE_RETRACTION_CHECK.md"

# Patterns that print residual into unaccounted without declaring alias
RESIDUAL_ALIAS = re.compile(
    r'unaccounted="\s*\+\s*std::to_string\(residual\)|'
    r'unaccounted=" \+ std::to_string\(residual\)|'
    r'" unaccounted=" \+ std::to_string\(residual\)'
)


def audit() -> list[str]:
    errs: list[str] = []
    for rel, needles, why in REQUIRED:
        p = ROOT / rel
        if not p.is_file():
            errs.append(f"MISSING {rel} ({why})")
            continue
        t = p.read_text(encoding="utf-8", errors="replace")
        for n in needles:
            if n is False:
                continue
            if n not in t:
                errs.append(f"{rel}: missing {n!r} — {why}")

    if not PRE_RETRACT_DOC.is_file():
        errs.append("MISSING docs/PRE_RETRACTION_CHECK.md (three-line pre-retraction)")
    else:
        t = PRE_RETRACT_DOC.read_text(encoding="utf-8", errors="replace")
        for n in (
            "Finding artifact",
            "device-derived",
            "NOT YET FITTED",
        ):
            if n not in t:
                errs.append(f"PRE_RETRACTION_CHECK missing {n!r}")

    # residual/unaccounted alias without derivation tag
    mp = ROOT / "arm/misterplexd/media_player.cpp"
    if mp.is_file():
        text = mp.read_text(encoding="utf-8", errors="replace")
        if "unaccounted=" in text and "residual=" in text:
            # If both print same residual variable without alias declaration
            if re.search(
                r'unaccounted=" \+ std::to_string\(residual\)', text
            ) or re.search(r"unaccounted=\" \+ std::to_string\(residual\)", text):
                # allow if nearby says alias or unaccounted_eq
                if "unaccounted_eq" not in text and "alias_of_residual" not in text:
                    # find line numbers
                    for i, line in enumerate(text.splitlines(), 1):
                        if "unaccounted=" in line and "residual" in line:
                            errs.append(
                                f"media_player.cpp:{i}: unaccounted prints residual "
                                f"without derivation tag (alias_of_residual / unaccounted_eq)"
                            )
                            break

    # fpga_spi must not claim liveness proven from fd alone in comments as swap
    spi = ROOT / "arm/misterplexd/fpga_spi.cpp"
    if spi.is_file():
        t = spi.read_text(encoding="utf-8", errors="replace")
        if "plxdLivenessObserve" not in t:
            errs.append("fpga_spi.cpp: must use plxdLivenessObserve (not fd-only proven)")
        if "SWAP_STUCK" not in t:
            errs.append("fpga_spi.cpp: must emit SWAP_STUCK path for freeze class")
        # banned: set proven true solely with old comment about swaps
        if "never advances, the mailbox is stale" in t and "plxdLivenessObserve" not in t:
            errs.append("fpga_spi.cpp: old degeneracy defence still sole path")

    return errs


def main() -> int:
    findings = audit()
    print("LABEL_DERIVATION_BEGIN")
    print(f"findings={len(findings)}")
    for f in findings:
        print(f"FIND {f}")
    print("LABEL_DERIVATION_END")
    if findings:
        print("LABEL_DERIVATION_FAIL")
        print("true rc=1")
        return 1
    print("LABEL_DERIVATION_OK")
    print("true rc=0")
    return 0


if __name__ == "__main__":
    sys.exit(main())
