#!/usr/bin/env python3
"""ERROR 20 guard: HISTORICAL comment blocks are not present-tense defects.

Parent withdrew T5 after mis-reading ddr_bank_release_select.hpp without the
enclosing HISTORICAL FAULT block. This test locks:

  1) The HISTORICAL FAULT marker remains on the bank-select header.
  2) No present-tense claim that frames_done *is* bank_vsync_count outside
     a historical documentation context.
  3) Self-test: a synthetic HISTORICAL block is NOT flagged; a bare present-
     tense false claim IS flagged.

See docs/COMMENT_CONTEXT_RULE.md.
"""
from __future__ import annotations

import re
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
TARGET = ROOT / "host" / "libmisterplex" / "ddr_bank_release_select.hpp"

HIST_MARKERS = re.compile(
    r"HISTORICAL(?:\s+FAULT)?|DO NOT REINTRODUCE|FIXED in product|older pack",
    re.I,
)
# Present-tense false claim (the ERROR 20 misread pattern).
PRESENT_FALSE = re.compile(
    r"frames_done\s+(?:field\s+)?is\s+actually\s+bank_vsync_count"
    r"|frames_done\s+is\s+bank_vsync_count",
    re.I,
)


def comment_blocks(text: str) -> list[str]:
    """Return contiguous // comment blocks (approx)."""
    blocks: list[str] = []
    cur: list[str] = []
    for line in text.splitlines():
        if line.lstrip().startswith("//"):
            cur.append(line)
        else:
            if cur:
                blocks.append("\n".join(cur))
                cur = []
    if cur:
        blocks.append("\n".join(cur))
    return blocks


def audit_text(text: str, path_label: str) -> list[str]:
    errs: list[str] = []
    for block in comment_blocks(text):
        if not PRESENT_FALSE.search(block):
            continue
        if HIST_MARKERS.search(block):
            # Historical documentation of the old fault — OK
            continue
        errs.append(
            f"{path_label}: present-tense frames_done==bank_vsync_count "
            f"outside HISTORICAL block"
        )
    return errs


def audit_target() -> list[str]:
    errs: list[str] = []
    if not TARGET.is_file():
        return [f"MISSING {TARGET}"]
    text = TARGET.read_text(encoding="utf-8", errors="replace")
    if "HISTORICAL FAULT" not in text:
        errs.append(
            f"{TARGET.relative_to(ROOT)}: missing HISTORICAL FAULT marker "
            f"(do not strip the corrected historical note — ERROR 20)"
        )
    if "Do not reintroduce vsync-as-frames_done" not in text and "NOT bank_vsync_count" not in text:
        errs.append(
            f"{TARGET.relative_to(ROOT)}: missing DO NOT REINTRODUCE / NOT bank_vsync_count warning"
        )
    errs.extend(audit_text(text, TARGET.relative_to(ROOT).as_posix()))
    return errs


def run_self_test() -> int:
    errors: list[str] = []
    hist = """
// HISTORICAL FAULT (fixed):
// frames_done field is actually bank_vsync_count in the OLD pack.
// Product now packs real swaps. Do not reintroduce.
"""
    bare = """
// Root class notes:
// frames_done field is actually bank_vsync_count so liveness never detects.
"""
    if audit_text(hist, "hist"):
        errors.append("RBG_RED_FAIL: HISTORICAL block was flagged")
    else:
        print("RBG_OK HISTORICAL block not flagged")
    if not audit_text(bare, "bare"):
        errors.append("RBG_RED_MISS: bare present-tense claim not flagged")
    else:
        print("RBG_OK bare present-tense claim flagged")

    real = audit_target()
    if real:
        errors.extend(real)
        print("RBG_REAL_FAIL", real)
    else:
        print("RBG_REAL_OK ddr_bank_release_select HISTORICAL FAULT intact")

    if errors:
        print("SELFTEST_FAIL")
        for e in errors:
            print(e)
        return 1
    print("SELFTEST_OK comment_context_guard")
    return 0


def main(argv: list[str] | None = None) -> int:
    if argv and "--self-test" in argv:
        rc = run_self_test()
        print(f"true rc={rc}")
        return rc
    findings = audit_target()
    print("COMMENT_CONTEXT_BEGIN")
    print(f"findings={len(findings)}")
    for f in findings:
        print(f"FIND {f}")
    print("COMMENT_CONTEXT_END")
    if findings:
        print("COMMENT_CONTEXT_FAIL")
        print("true rc=1")
        return 1
    print("COMMENT_CONTEXT_OK")
    print("true rc=0")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
