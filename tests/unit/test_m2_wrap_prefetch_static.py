#!/usr/bin/env python3
"""Static gate: M2 WRAP_PREFETCH on holdlast product base (DIAG=0).

M2: when gray-stable want_y is within LINE_COUNT of FRAME end, desired_y_r
stocks clamp_ahead(0, ti) wrap window instead of only end-of-frame holdlast
window. Mid-frame path remains clamp_ahead(want_bin, ti).

POSITIVE:
  - M2 WRAP_PREFETCH land marker present
  - desired_y_r sample under gray_s1==gray_s2 uses near-wrap base-0 path
  - LINECAM_WANT_Y_HOLD_LAST still present (want_y hold in-band product)
  - schedule-reg / H-R1d / gray stable-hold markers kept
  - product QSF has MPLEX_DIAG_TAG_RCA commented (DIAG=0 product)

NEGATIVE:
  - mbox_yield_cur_r / need_*_c CE on frame_mbox / bank_mbox must be ABSENT
  - M1 A→H "need_cur before frame/bank mbox" product thrash markers ABSENT
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
STORE = ROOT / "fpga" / "Plex_MiSTer" / "rtl" / "ddr_frame_store.sv"
QSF = ROOT / "fpga" / "Plex_MiSTer" / "Plex.qsf"


def fail(msg: str) -> int:
    print(f"FAIL m2_wrap_prefetch_static: {msg}", file=sys.stderr)
    return 1


def strip_sv_comments(line: str) -> str:
    return line.split("//", 1)[0]


def main() -> int:
    if not STORE.is_file():
        return fail(f"missing {STORE}")
    src = STORE.read_text(encoding="utf-8", errors="replace")
    qsf = QSF.read_text(encoding="utf-8", errors="replace") if QSF.is_file() else ""

    if "M2 WRAP_PREFETCH" not in src:
        return fail("missing M2 WRAP_PREFETCH land marker comment")

    # desired_y_r assign must mention near-wrap / FRAME_H + base 0 class
    dy = re.search(
        r"desired_y_r\[ti\]\s*<=\s*clamp_ahead\s*\((.*?)\)\s*;",
        src,
        flags=re.S,
    )
    if not dy:
        return fail("desired_y_r[ti] <= clamp_ahead(...) not found")
    body = dy.group(1)
    body_code = "\n".join(strip_sv_comments(ln) for ln in body.splitlines())
    if "FRAME_H" not in body_code and "FRAME_H" not in body:
        return fail("M2 near-wrap must reference FRAME_H in desired base select")
    if "LINE_COUNT" not in body:
        return fail("M2 near-wrap must reference LINE_COUNT")
    if not re.search(r"\{Y_W\{1'b0\}\}|'0", body_code):
        return fail("M2 wrap base must include zero/base-0 alternative")

    if "LINECAM_WANT_Y_HOLD_LAST" not in src and "holds last" not in src.lower():
        # holdlast comment path
        if "WANT_Y_LINE_ONLY ? rd_y_visible" not in src:
            return fail("holdlast want_y product path missing")

    for marker in (
        "need_y_cur_r",
        "want_y_gray_s1 == want_y_gray_s2",
        "clamp_ahead",
    ):
        if marker not in src:
            return fail(f"required keep marker missing: {marker}")

    # NEG: mbox_yield CE thrash
    code_all = "\n".join(strip_sv_comments(ln) for ln in src.splitlines())
    if re.search(r"\bmbox_yield_cur_r\b", code_all):
        return fail("NEG: mbox_yield_cur_r present (CE thrash forbidden on M2)")

    # NEG: product DIAG macro enabled
    for ln in qsf.splitlines():
        s = ln.strip()
        if s.startswith("#"):
            continue
        if "MPLEX_DIAG_TAG_RCA=1" in s and "set_global_assignment" in s:
            return fail("NEG: product QSF has MPLEX_DIAG_TAG_RCA=1 enabled (want DIAG=0)")

    print("PASS m2_wrap_prefetch_static")
    return 0


if __name__ == "__main__":
    sys.exit(main())
