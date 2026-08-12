#!/usr/bin/env python3
"""Control: define-parity must not invent macros from comments.

Parent failure mode (2026-08): test_last_frame_latch_red.sh comment containing a
dash-D FAULT_ glob was grepped as live macro FAULT_ and DEFINE_PARITY_REJECTED
blocked the first enabled-720p exclusive fit.

Negative case a naive scanner fails: a comment containing a dash-D token must
NOT appear in discover_test_macros. Live dash-D on a compile line must still
be reported.

Fixture sources live under tests/fixtures/define_parity_comment_scan/ (outside
the default discover roots) so this control file itself is not a source of
phantom macros when make define-parity scans tests/unit.
"""
from __future__ import annotations

import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))

from check_define_parity import discover_test_macros  # noqa: E402

FIX = ROOT / "tests" / "fixtures" / "define_parity_comment_scan"


def main() -> int:
    fails = 0

    sh = FIX / "comment_trap.sh"
    py = FIX / "comment_trap.py"
    sv = FIX / "comment_trap.sv"
    for p in (sh, py, sv):
        if not p.is_file():
            print(f"FAIL: missing fixture {p}", file=sys.stderr)
            return 1

    found = discover_test_macros([sh, py, sv])
    names = set(found)

    def expect_absent(name: str) -> None:
        nonlocal fails
        if name in names:
            print(f"FAIL: comment macro {name} was reported as live", file=sys.stderr)
            fails += 1
        else:
            print(f"OK absent: {name}")

    def expect_present(name: str) -> None:
        nonlocal fails
        if name not in names:
            print(f"FAIL: live macro {name} was not detected", file=sys.stderr)
            fails += 1
        else:
            print(f"OK present: {name} -> {found[name][0].value!r}")

    expect_absent("COMMENT_ONLY_MACRO")
    expect_absent("PY_COMMENT_ONLY")
    expect_absent("SV_COMMENT_ONLY")
    expect_absent("SV_BLOCK_COMMENT_ONLY")
    expect_absent("SV_PLUSDEFINE_COMMENT")
    expect_present("COMMENT_LIVE_MACRO")
    expect_present("PY_LIVE_MACRO")

    # Real red twin that blocked the fit: comment dash-D FAULT_ glob must not
    # invent FAULT_. Build the needle without embedding a live dash-D token in
    # this file (define-parity scans tests/unit/*.py).
    latch_red = ROOT / "tests" / "unit" / "test_last_frame_latch_red.sh"
    text = latch_red.read_text(encoding="utf-8")
    needle = "-" + "DFAULT_*"
    if needle not in text:
        print(
            f"FAIL: latch red missing regression comment containing {needle}",
            file=sys.stderr,
        )
        fails += 1
    else:
        print(f"OK fixture comment contains {needle}")

    latch_found = discover_test_macros([latch_red])
    if "FAULT_" in latch_found:
        print(
            "FAIL: phantom FAULT_ invented from comment " + needle,
            file=sys.stderr,
        )
        fails += 1
    else:
        print("OK absent: FAULT_ (comment trap)")

    for real in (
        "LAST_FRAME_LATCH_FAULT_IDLE_GEOMETRY",
        "LAST_FRAME_LATCH_FAULT_BANK_BASE",
    ):
        if real not in latch_found:
            print(
                f"FAIL: real macro {real} not detected on live compile line",
                file=sys.stderr,
            )
            fails += 1
        else:
            print(f"OK present: {real}")

    if fails:
        print(f"test_define_parity_comment_scan: FAIL fails={fails}", file=sys.stderr)
        return 1
    print("test_define_parity_comment_scan: OK")
    return 0


if __name__ == "__main__":
    sys.exit(main())
