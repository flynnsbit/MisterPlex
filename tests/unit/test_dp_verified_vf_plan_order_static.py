#!/usr/bin/env python3
"""Direct-Part deliveryGeometryVerified must reach buildFfmpegVideoFilter.

rd-duck claimed threadMain clears deliveryGeometryVerified_ BEFORE vf plan
(media_player.cpp ~3067 then load ~3098). On product HEAD the order is the
opposite: load+buildFfmpegVideoFilter first, store(false) later for B4
session measure only.

This gate freezes the observation that must FAIL if the claimed regression
lands (or returns):

  FAIL if any deliveryGeometryVerified_.store(false) appears in
  MediaPlayer::threadMain before the first buildFfmpegVideoFilter call.

Also requires:
  - main.cpp sets setDeliveryGeometryVerified from deliveryGeometryVerifiedFromBasis
  - ffmpeg_vf identity/pad paths still key off delivery_geometry_verified

Does NOT claim a full setter→threadMain E2E runtime oracle (w-path owns that).
Post-plan store(false) still wipes the atomic for MEASURED session state —
product may split plan_time vs measured flags; that is a separate w-path item.
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
MP_CPP = ROOT / "arm" / "misterplexd" / "media_player.cpp"
MAIN_CPP = ROOT / "arm" / "misterplexd" / "main.cpp"
VF_HPP = ROOT / "host" / "libmisterplex" / "ffmpeg_vf.hpp"


def _thread_main_body(cpp: str) -> str | None:
    m = re.search(
        r"void\s+MediaPlayer::threadMain\s*\([^)]*\)\s*\{",
        cpp,
    )
    if not m:
        return None
    start = m.end() - 1  # at '{'
    depth = 0
    i = start
    while i < len(cpp):
        c = cpp[i]
        if c == "{":
            depth += 1
        elif c == "}":
            depth -= 1
            if depth == 0:
                return cpp[start : i + 1]
        i += 1
    return None


def main() -> int:
    fails = 0
    if not MP_CPP.is_file():
        print(f"FAIL missing {MP_CPP}", file=sys.stderr)
        return 2
    cpp = MP_CPP.read_text(encoding="utf-8", errors="replace")
    body = _thread_main_body(cpp)
    if not body:
        print("FAIL MediaPlayer::threadMain not found", file=sys.stderr)
        return 2

    # First vf plan in threadMain
    plan_m = re.search(r"buildFfmpegVideoFilter\s*\(", body)
    if not plan_m:
        print("FAIL no buildFfmpegVideoFilter in threadMain", file=sys.stderr)
        fails += 1
    else:
        before = body[: plan_m.start()]
        # Any clear of the flag before plan is the claimed hollow regression.
        clears = list(
            re.finditer(
                r"deliveryGeometryVerified_\s*\.\s*store\s*\(\s*false",
                before,
            )
        )
        if clears:
            print(
                "FAIL deliveryGeometryVerified_.store(false) BEFORE "
                "buildFfmpegVideoFilter in threadMain — Direct-Part plan-time "
                f"verified is erased (n_clears_before_plan={len(clears)}). "
                "Snapshot plan-time trust into vfReq before any session-measure wipe.",
                file=sys.stderr,
            )
            fails += 1
        else:
            print(
                "OK threadMain: no deliveryGeometryVerified_.store(false) "
                "before first buildFfmpegVideoFilter"
            )

        # Must actually read the flag into the request (not a hardcoded true/false).
        if not re.search(
            r"delivery_geometry_verified\s*=\s*deliveryGeometryVerified_\s*\.\s*load",
            before + body[plan_m.start() : plan_m.start() + 200],
        ):
            # Allow load on previous few lines
            window = body[max(0, plan_m.start() - 400) : plan_m.start() + 80]
            if "deliveryGeometryVerified_" not in window:
                print(
                    "FAIL vfReq plan path does not load deliveryGeometryVerified_ "
                    "near buildFfmpegVideoFilter",
                    file=sys.stderr,
                )
                fails += 1
            else:
                print("OK vf plan window references deliveryGeometryVerified_")
        else:
            print("OK vfReq.delivery_geometry_verified loads deliveryGeometryVerified_")

    # Post-plan wipe may exist (B4 session measure) — note, do not forbid.
    after_plan = body[plan_m.start() :] if plan_m else ""
    if re.search(r"deliveryGeometryVerified_\s*\.\s*store\s*\(\s*false", after_plan):
        print(
            "NOTE post-plan deliveryGeometryVerified_.store(false) present "
            "(B4 session measure). Plan snapshot must not depend on the atomic "
            "after this point; E2E setter→thread oracle is still w-path."
        )

    # main must set from basis (direct_play_part path)
    if not MAIN_CPP.is_file():
        print(f"FAIL missing {MAIN_CPP}", file=sys.stderr)
        fails += 1
    else:
        main_t = MAIN_CPP.read_text(encoding="utf-8", errors="replace")
        if "setDeliveryGeometryVerified" not in main_t:
            print("FAIL main.cpp never calls setDeliveryGeometryVerified", file=sys.stderr)
            fails += 1
        elif "deliveryGeometryVerifiedFromBasis" not in main_t:
            print(
                "FAIL main.cpp setDelivery without deliveryGeometryVerifiedFromBasis",
                file=sys.stderr,
            )
            fails += 1
        else:
            print("OK main sets delivery verified via deliveryGeometryVerifiedFromBasis")

    # Planner still gates identity-class on verified (not dead API).
    if VF_HPP.is_file():
        vf = VF_HPP.read_text(encoding="utf-8", errors="replace")
        if "delivery_geometry_verified" not in vf:
            print("FAIL ffmpeg_vf.hpp drops delivery_geometry_verified", file=sys.stderr)
            fails += 1
        elif not re.search(
            r"delivery_geometry_verified\s*\|\|\s*req\.assume_source_matches_coded|"
            r"req\.delivery_geometry_verified",
            vf,
        ):
            print(
                "FAIL ffmpeg_vf.hpp does not consume delivery_geometry_verified",
                file=sys.stderr,
            )
            fails += 1
        else:
            print("OK ffmpeg_vf consumes delivery_geometry_verified")
        # Pad-only (path 1e30caf6) may be absent on older trees — warn only.
        if "verified_same_height_pad_only" not in vf:
            print(
                "NOTE verified_same_height_pad_only absent on this tree "
                "(path owns 426→432 pad-only; not a w-osd product claim)"
            )
        else:
            print("OK verified_same_height_pad_only branch present")
    else:
        print(f"FAIL missing {VF_HPP}", file=sys.stderr)
        fails += 1

    if fails:
        print(f"FAIL test_dp_verified_vf_plan_order_static fails={fails}", file=sys.stderr)
        return 1
    print("PASS test_dp_verified_vf_plan_order_static")
    return 0


if __name__ == "__main__":
    sys.exit(main())
