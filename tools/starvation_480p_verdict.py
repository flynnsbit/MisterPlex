#!/usr/bin/env python3
"""Apply pre-registered starvation gates to a schedstat_sample JSON.

Does NOT touch the device. Parent runs schedstat_sample during 480p play, then:
  python3 tools/starvation_480p_verdict.py schedstat_play.json \\
      --vfps 23.0 --wall-s 30.88 --frames 713 --drops 7 --fps 24

Exit codes:
  0 = ran; verdict printed (including REFUTED / CONFIRMED / INCONCLUSIVE)
  2 = bad args / unreadable input
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Any, Dict, Optional


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("schedstat_json")
    ap.add_argument("--vfps", type=float, default=None)
    ap.add_argument("--wall-s", type=float, default=None)
    ap.add_argument("--frames", type=int, default=None, help="daemon frames= (pipe completes)")
    ap.add_argument("--drops", type=int, default=None, help="pacer drops only")
    ap.add_argument("--fps", type=float, default=24.0)
    ap.add_argument("--presents", type=int, default=None)
    args = ap.parse_args()

    path = Path(args.schedstat_json)
    if not path.is_file():
        print(f"NO_FILE {path}")
        return 2
    data: Dict[str, Any] = json.loads(path.read_text(encoding="utf-8"))

    ff = data.get("ffmpeg_agg") or {}
    mp = data.get("misterplexd_agg") or {}
    mi = data.get("mister_agg") or {}

    def line(name: str, agg: Dict[str, Any]) -> None:
        if agg.get("NO_DATA") or agg.get("agg_wait_frac_pct") is None:
            print(f"{name}: NO_DATA")
            return
        print(
            f"{name}: agg_wait_frac_pct={agg['agg_wait_frac_pct']} "
            f"max_busy_wf={agg.get('max_busy_thread_wait_frac_pct')} "
            f"sum_run_pct_wall={agg.get('sum_run_pct_wall')} "
            f"sum_wait_pct_wall={agg.get('sum_wait_pct_wall')} "
            f"n_busy={agg.get('n_busy_threads')}"
        )

    print(f"label={data.get('label')} dwall_s={data.get('dwall_s')}")
    line("ffmpeg", ff)
    line("misterplexd", mp)
    line("MiSTer", mi)

    # Production arithmetic (parent's method)
    if args.wall_s is not None and args.frames is not None and args.fps:
        expected = args.wall_s * args.fps
        under = expected - args.frames
        print(
            f"prod: wall_s={args.wall_s} fps={args.fps} expected_frames={expected:.1f} "
            f"frames={args.frames} under_prod={under:.1f} vfps={args.vfps} drops={args.drops}"
        )
        if args.presents is not None and args.drops is not None:
            gap = args.frames - args.presents
            print(f"prod: presents={args.presents} frames-presents={gap} (expect == drops if only pacer)")

    # --- Pre-registered gates (see STARVATION_480P_EXPERIMENT.md) ---
    # CONFIRM starvation requires ffmpeg agg_wait_frac in band AND not NO_DATA.
    # REFUTE requires low wait with ffmpeg present and under-production still true.
    wf: Optional[float] = ff.get("agg_wait_frac_pct")
    wwall: Optional[float] = ff.get("sum_wait_pct_wall")
    if ff.get("NO_DATA") or wf is None:
        verdict = "INVALID_NO_FFMPEG"
        detail = "ffmpeg threads absent in window — NO-DATA, not 0.0"
    else:
        # Primary discriminator
        if wf >= 15.0 or (wwall is not None and wwall >= 10.0):
            verdict = "STARVATION_CONSISTENT"
            detail = (
                f"ffmpeg agg_wait_frac={wf}% (>=15) or wait_pct_wall={wwall} (>=10): "
                "runnable threads spent material time on runqueue — CPU delay is real"
            )
        elif wf <= 8.0 and (wwall is None or wwall <= 5.0):
            if args.vfps is not None and args.vfps < args.fps - 0.3:
                verdict = "STARVATION_REFUTED"
                detail = (
                    f"ffmpeg agg_wait_frac={wf}% (<=8) while vfps={args.vfps} < {args.fps}-0.3: "
                    "under-production without runqueue delay — bottleneck elsewhere"
                )
            else:
                verdict = "NO_STARVE_NO_DEFICIT"
                detail = f"low wait_frac={wf}% and no clear vfps deficit in args"
        else:
            verdict = "INCONCLUSIVE"
            detail = f"ffmpeg agg_wait_frac={wf}% in grey band (8,15) — extend window or SUSPEND A/B"

    print(f"VERDICT={verdict}")
    print(f"DETAIL={detail}")
    print(
        "NEXT="
        + (
            "run SUSPEND A/B causal (STARVATION_480P_EXPERIMENT.md §C) before Main patch"
            if verdict == "STARVATION_CONSISTENT"
            else (
                "open non-CPU branch: PMS rate, read_eagain, ddr_total_us tails"
                if verdict == "STARVATION_REFUTED"
                else "re-run 20s window mid-soak; do not patch Main yet"
            )
        )
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
