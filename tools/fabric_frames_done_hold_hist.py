#!/usr/bin/env python3
"""INVALIDATED for hold-length (frames_done=swaps). Fabric-side hold histogram: vsyncs between successive frames_done edges.

WHY
---
Parent HDMI plateau hist (720p60 OCR fixture)::

  {1:43, 2:661, 3:429, 4:123, 5:7}  mean=2.517  ratio2:3=1.54  frac_ge4=0.103

cannot tell capture/tear bias from real DDR hold irregularity. Discriminator:
histogram of *display vsyncs between successive frames_done increments*,
read from PLXD on the device (swap counter), not from the grabber.

RTL FACTS (quoted; do not re-derive)
------------------------------------
- ``ddr_frame_store.sv:271-286`` — swap is ``vsync_pulse && swap_pending &&
  pending_ready_s2``; ``frames_done++`` on that edge. ``present_cadence.sv``
  does NOT drive bank swaps (w-geom / r-misterfin).
- PLXD packs ``frames_done`` in [63:48] (``ddr_frame_store.sv`` PLXD pack).
- ``bank_vsync_count`` exists but is NOT packed into PLXD. Integer vsync holds
  therefore require either:
    (a) T_vsync DEFAULT_ASSUMED (1000/60 or 1000/50) applied to mono_ms deltas, or
    (b) a future RBF packing bank_vsync_count (w-geom owns RTL — not this tool).

COUNTER TO READ
---------------
  frames_done  — PLXD swap counter (measured). Each +1 = one display bank swap.
  Pair with host/device mono_ms at the *same* poll.

  Do NOT use presentCount_ (ARM deliberate presents) or HDMI OCR plateaus.

MODES
-----
  --self-test     synthetic healthy 2/3 vs ~10% ge4 (host gate)
  --csv PATH      mono_ms,frames_done from poll script
  --from-media-log PATH  parse daemon lines with frames_done= + frames_done_mono_ms=

PRE-REGISTER (printed before any binning — do not move below compute)
--------------------------------------------------------------------
  P_fab_ge4_healthy_band     = [0.00, 0.03]   pure async 2/3 + poll noise
  P_fab_ge4_hdmi_match_band  = [0.08, 0.13]   matches parent HDMI 10.3%
  w_geom_lean_device_band    = [0.05, 0.15]   device lean, needs RTL look

  If fabric frac_ge4 ∈ healthy  → capture/tear bias; nothing to fix in DDR hold.
  If fabric ∈ hdmi_match/lean → irregularity is real device behaviour → w-geom.

Exit: 0 scored, 77 UNSCORED (n<50), 2 usage. rc=77 is never a pass.
"""
from __future__ import annotations

import argparse
import csv
import re
import sys
from collections import Counter
from pathlib import Path

# Parent HDMI plateau (caller_supplied, 720p60 OCR fixture) — comparison only.
PARENT_HDMI_PLATEAU = {1: 43, 2: 661, 3: 429, 4: 123, 5: 7}
PARENT_HDMI_FRAC_GE4 = (123 + 7) / float(sum(PARENT_HDMI_PLATEAU.values()))


def pre_register(hdmi_ge4: float) -> None:
    """MUST run before any hold binning."""
    print("PRE-REGISTER fabric hold hist (before any binning):")
    print("  P_fab_ge4_healthy_band=[0.00,0.03]   # pure 2/3 + noise")
    print("  P_fab_ge4_hdmi_match_band=[0.08,0.13]  # matches parent HDMI ~10.3%")
    print("  w_geom_lean_device_band=[0.05,0.15]")
    print(f"  parent_hdmi_frac_ge4_caller_supplied={hdmi_ge4:.6f}")
    print(
        f"  parent_hdmi_plateau_hist_caller_supplied={dict(sorted(PARENT_HDMI_PLATEAU.items()))}"
    )
    print("  T_vsync_tag=DEFAULT_ASSUMED unless --t-vsync-ms provided as measured")
    print("  frames_done_tag=must be PLXD swap counter (measured)")
    print("  bank_vsync_count=NOT_IN_PLXD (w-geom RTL if integer vsync needed)")
    print(
        "  DISCRIMINATOR: fab_ge4 in healthy => capture bias; "
        "in hdmi_match/lean => real device hold irregularity"
    )


def holds_from_series(
    samples: list[tuple[float, int]], t_vsync_ms: float
) -> list[int]:
    """samples: (mono_ms, frames_done). Return hold lengths in vsync units."""
    edges: list[tuple[float, int]] = []
    last_fd = None
    for mono, fd in samples:
        if last_fd is None or fd != last_fd:
            if last_fd is not None and fd < last_fd and (last_fd - fd) < 1000:
                continue  # ignore small backward glitch
            edges.append((mono, int(fd)))
            last_fd = int(fd)
    holds: list[int] = []
    for i in range(1, len(edges)):
        dt_ms = edges[i][0] - edges[i - 1][0]
        dfd = edges[i][1] - edges[i - 1][1]
        if dfd <= 0:
            continue
        # Missed intermediate swaps: split interval evenly across dfd steps
        per = dt_ms / float(dfd)
        h = int(round(per / t_vsync_ms))
        if h < 1:
            h = 1
        for _ in range(dfd):
            holds.append(h)
    return holds


def summarize(holds: list[int], label: str, t_tag: str) -> dict:
    c = Counter(holds)
    n = len(holds)
    mean = sum(holds) / n if n else 0.0
    ge4 = sum(v for k, v in c.items() if k >= 4)
    frac_ge4 = ge4 / n if n else 0.0
    c2, c3 = c.get(2, 0), c.get(3, 0)
    ratio = (c2 / c3) if c3 else float("nan")
    print(
        f"{label} n={n} mean={mean:.4f} frac_ge4={frac_ge4:.4f} "
        f"ratio2_3={ratio:.4f} hist={dict(sorted(c.items()))} "
        f"hold_unit=vsync t_vsync_tag={t_tag} n_src=measured"
    )
    if n < 50:
        print(f"{label}_verdict=UNSCORED n<50 (rc would be 77; never a pass)")
        return {"n": n, "frac_ge4": frac_ge4, "verdict": "UNSCORED", "hist": dict(c)}
    if frac_ge4 <= 0.03:
        v = "FABRIC_HEALTHY_2_3"
        note = "capture/tear bias likely; no DDR hold defect from this metric"
    elif 0.08 <= frac_ge4 <= 0.13:
        v = "FABRIC_MATCHES_HDMI_GE4"
        note = "matches parent HDMI ge4 — irregularity is real device behaviour"
    elif 0.05 <= frac_ge4 <= 0.15:
        v = "FABRIC_DEVICE_LEAN_BAND"
        note = "device lean band — w-geom RTL question"
    else:
        v = "FABRIC_OTHER"
        note = "outside pre-registered bands — publish and inspect"
    print(f"{label}_verdict={v}")
    print(f"{label}_note={note}")
    # Side-by-side with parent HDMI plateau (different domain; comparable shape)
    print(
        f"compare_hdmi_plateau_hist_caller_supplied="
        f"{dict(sorted(PARENT_HDMI_PLATEAU.items()))} "
        f"hdmi_frac_ge4={PARENT_HDMI_FRAC_GE4:.4f}"
    )
    return {"n": n, "frac_ge4": frac_ge4, "verdict": v, "hist": dict(c), "mean": mean}


def load_csv(path: Path) -> list[tuple[float, int]]:
    rows: list[tuple[float, int]] = []
    with path.open(newline="") as f:
        r = csv.DictReader(f)
        for row in r:
            mono = row.get("mono_ms") or row.get("t_ms") or row.get("ms")
            fd = row.get("frames_done") or row.get("fd")
            if mono is None or fd is None:
                raise SystemExit("CSV needs mono_ms,frames_done columns")
            rows.append((float(mono), int(float(fd))))
    return rows


_FD_RE = re.compile(
    r"frames_done=(?P<fd>\d+).*?frames_done_mono_ms=(?P<ms>-?\d+)"
    r"|frames_done_mono_ms=(?P<ms2>-?\d+).*?frames_done=(?P<fd2>\d+)"
)


def load_media_log(path: Path) -> list[tuple[float, int]]:
    """Parse misterplexd media: lines that carry frames_done + mono_ms."""
    rows: list[tuple[float, int]] = []
    text = path.read_text(errors="replace")
    for line in text.splitlines():
        if "frames_done=" not in line:
            continue
        m = _FD_RE.search(line)
        if not m:
            # looser: separate finds
            mfd = re.search(r"frames_done=(\d+)", line)
            mms = re.search(r"frames_done_mono_ms=(-?\d+)", line)
            if not mfd or not mms:
                mms = re.search(r"\bmono_ms=(-?\d+)", line)
            if mfd and mms:
                rows.append((float(mms.group(1)), int(mfd.group(1))))
            continue
        fd = m.group("fd") or m.group("fd2")
        ms = m.group("ms") or m.group("ms2")
        if fd is not None and ms is not None:
            rows.append((float(ms), int(fd)))
    return rows


def main() -> int:
    ap = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    ap.add_argument("--csv", type=Path, help="mono_ms,frames_done CSV from poll script")
    ap.add_argument(
        "--from-media-log",
        type=Path,
        help="parse daemon log for frames_done= + frames_done_mono_ms=",
    )
    ap.add_argument(
        "--t-vsync-ms",
        type=float,
        default=None,
        help="measured vsync period ms; default 1000/60 DEFAULT_ASSUMED",
    )
    ap.add_argument(
        "--hdmi-ge4",
        type=float,
        default=PARENT_HDMI_FRAC_GE4,
        help="caller_supplied parent HDMI frac hold>=4",
    )
    ap.add_argument(
        "--self-test",
        action="store_true",
        help="synthetic healthy + jitter series; expect band separation",
    )
    args = ap.parse_args()

    print(
        "INVALIDATED_HOLD: frames_done is swap counter (vsync&&pending&&ready only); "
        "delta carries ZERO hold-length. Use media: publish_interval verdict=."
    )
    if not getattr(args, "self_test", False):
        print("FAIL: hold-via-frames_done mode disabled", file=sys.stderr)
        return 2

    # PRE-REGISTER first — before any compute
    pre_register(float(args.hdmi_ge4))

    if args.t_vsync_ms is None:
        t_vsync = 1000.0 / 60.0
        t_tag = "DEFAULT_ASSUMED_1_60"
    else:
        t_vsync = float(args.t_vsync_ms)
        t_tag = "caller_supplied_measured"

    print(f"t_vsync_ms={t_vsync:.6f} tag={t_tag}")

    if args.self_test:
        # Constructive healthy: edges at cumulative 2,3,2,3...
        healthy: list[tuple[float, int]] = [(0.0, 0)]
        mono = 0.0
        fd = 0
        for h in [2, 3] * 500:
            mono += h * t_vsync
            fd += 1
            healthy.append((mono, fd))
        dense: list[tuple[float, int]] = []
        for i in range(len(healthy) - 1):
            t0, f0 = healthy[i]
            t1, _ = healthy[i + 1]
            dense.append((t0, f0))
            dense.append(((t0 + t1) / 2, f0))
        dense.append(healthy[-1])
        Hs = holds_from_series(dense, t_vsync)
        r1 = summarize(Hs, "selftest_healthy", t_tag)

        import random

        rng = random.Random(1)
        jitter: list[tuple[float, int]] = [(0.0, 0)]
        mono = 0.0
        fd = 0
        for i in range(1000):
            h = 2 if (i % 2 == 0) else 3
            if rng.random() < 0.10:
                h = 4 if rng.random() < 0.7 else 5
            mono += h * t_vsync
            fd += 1
            jitter.append((mono, fd))
        dense_j: list[tuple[float, int]] = []
        for i in range(len(jitter) - 1):
            t0, f0 = jitter[i]
            t1, _ = jitter[i + 1]
            dense_j.append((t0, f0))
            dense_j.append((t0 * 0.7 + t1 * 0.3, f0))
        dense_j.append(jitter[-1])
        Hj = holds_from_series(dense_j, t_vsync)
        r2 = summarize(Hj, "selftest_jitter", t_tag)

        ok = True
        if r1["verdict"] != "FABRIC_HEALTHY_2_3":
            print("FAIL selftest_healthy expected FABRIC_HEALTHY_2_3", file=sys.stderr)
            ok = False
        if r2["frac_ge4"] < 0.05:
            print("FAIL selftest_jitter expected ge4>=0.05", file=sys.stderr)
            ok = False
        if not ok:
            print("SELF_TEST_FAIL")
            return 1
        print("OK fabric_frames_done_hold_hist self-test")
        print("SELF_TEST_OK")
        return 0

    samples: list[tuple[float, int]] = []
    src = ""
    if args.csv:
        samples = load_csv(args.csv)
        src = f"csv:{args.csv}"
    elif args.from_media_log:
        samples = load_media_log(args.from_media_log)
        src = f"media_log:{args.from_media_log}"
    else:
        print("FAIL: provide --csv, --from-media-log, or --self-test", file=sys.stderr)
        return 2

    print(f"input={src} rows={len(samples)} tag=measured_file")
    if len(samples) < 3:
        print("UNSCORED insufficient samples")
        return 77
    holds = holds_from_series(samples, t_vsync)
    r = summarize(holds, "fabric_from_input", t_tag)
    if r["verdict"] == "UNSCORED":
        print("OK fabric_frames_done_hold_hist unscored")
        return 77
    print("OK fabric_frames_done_hold_hist scored")
    return 0


if __name__ == "__main__":
    sys.exit(main())
