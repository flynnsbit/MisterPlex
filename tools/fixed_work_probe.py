#!/usr/bin/env python3
"""Fixed-work CPU probe — contention, not scavenger arithmetic.

Does a CONSTANT amount of userspace work (N iterations of a pure integer
kernel) and reports wall time. Compare:

  idle_wall_s  vs  play_wall_s

If Main is only an elastic scavenger, play_wall ≈ idle_wall (ratio ~1.0).
If Main steals runqueue from this work, play_wall > idle_wall.

Does NOT use %onecpu residual (200 - busy). That mixes inelastic + elastic.

Usage (parent, on device):
  python3 fixed_work_probe.py --iters 80000000 -o /media/fat/misterplex/fw_idle.json
  # start 240p play, settle, then:
  python3 fixed_work_probe.py --iters 80000000 -o /media/fat/misterplex/fw_play240.json
  python3 fixed_work_probe.py --compare fw_idle.json fw_play240.json

Method: ONE wall clock around the fixed loop; no fps scaling.
"""
from __future__ import annotations

import argparse
import json
import os
import time
from pathlib import Path


def burn(iters: int) -> int:
    # Dependent integer chain — hard for the optimizer to delete entirely.
    x = 1
    for i in range(iters):
        x = (x * 1664525 + 1013904223 + i) & 0xFFFFFFFF
    return x


def run(iters: int, label: str) -> dict:
    # Touch sched once so first-call noise is outside the window if possible.
    os.sched_yield()
    t0 = time.perf_counter()
    sink = burn(iters)
    t1 = time.perf_counter()
    dwall = t1 - t0
    return {
        "label": label,
        "iters": iters,
        "dwall_s": round(dwall, 6),
        "sink": sink,  # prevent DCE across process boundary
        "pid": os.getpid(),
        "formula": "fixed_iters_wall; compare ratios only (not %onecpu residual)",
    }


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--iters", type=int, default=80_000_000)
    ap.add_argument("--label", default="fixed_work")
    ap.add_argument("-o", "--output", default="")
    ap.add_argument("--compare", nargs=2, metavar=("IDLE_JSON", "PLAY_JSON"))
    args = ap.parse_args()

    if args.compare:
        a = json.loads(Path(args.compare[0]).read_text())
        b = json.loads(Path(args.compare[1]).read_text())
        if a.get("iters") != b.get("iters"):
            print("MISMATCH iters", a.get("iters"), b.get("iters"))
            return 2
        idle = float(a["dwall_s"])
        play = float(b["dwall_s"])
        ratio = play / idle if idle > 0 else float("inf")
        slowdown_pct = 100.0 * (ratio - 1.0)
        print(
            f"compare idle_s={idle} play_s={play} ratio={ratio:.4f} "
            f"slowdown_pct={slowdown_pct:.2f} "
            f"(~1.0 scavenger; >>1.0 contention on this work)"
        )
        out = {
            "idle": a,
            "play": b,
            "ratio_play_over_idle": round(ratio, 4),
            "slowdown_pct": round(slowdown_pct, 2),
            "interpretation": (
                "scavenger_or_no_delay"
                if ratio < 1.08
                else ("mild_contention" if ratio < 1.25 else "material_contention")
            ),
        }
        if args.output:
            Path(args.output).write_text(json.dumps(out, indent=2) + "\n")
        return 0

    data = run(args.iters, args.label)
    text = json.dumps(data, indent=2) + "\n"
    if args.output:
        Path(args.output).parent.mkdir(parents=True, exist_ok=True)
        Path(args.output).write_text(text)
    print(
        f"fixed_work label={data['label']} iters={data['iters']} "
        f"dwall_s={data['dwall_s']} out={args.output or '-'}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
