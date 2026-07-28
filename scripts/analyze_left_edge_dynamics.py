#!/usr/bin/env python3
"""Decide whether the left-edge artifact is STATIC or MOVING.

Why this exists
---------------
The user reports "moving jagged black lines on the left edge".  `w-arm-o5`'s
working mechanism is that the ARM daemon writes into the DDR bank currently
being scanned out.  That mechanism predicts the artifact should be STATIC (or
absent) when no ARM writer is running.

Distinguishing "moving" from "static" on an MJPEG capture is not trivial: the
artifact sits near the black threshold, so codec noise alone flips pixels in
and out of a dark mask.  An IoU-of-dark-mask test looks damning and is
worthless -- it mostly measures threshold proximity.  This tool was written
after that exact mistake.

Method (three mutually-supporting statistics)
--------------------------------------------
1. NOISE FLOOR from the capture itself: temporal std inside the saturated
   chevron interior.  If that is ~0, the capture path is not adding noise and
   any temporal variation elsewhere is real signal, not compression.
2. TEMPORAL STD in the artifact band, compared against that floor.
3. AVERAGING TEST: a moving pattern averages out over N frames, so per-row
   raggedness collapses; a static pattern survives averaging intact.

Verdicts / exit codes
---------------------
  0  MOVING      artifact varies over time well above the measured noise floor
  1  STATIC      artifact present but temporally frozen
  2  REFUSE      cannot decide (no artifact, too few frames, or the capture's
                 own noise floor is too high to resolve motion)

REFUSE is deliberate: a noisy capture must not be allowed to masquerade as
either answer.

Scope limits (declared up front, per house standard)
----------------------------------------------------
* Says nothing about WHAT moves the pattern, only that it moves.
* Assumes the chevron is on screen to supply the noise floor; without it the
  tool REFUSES rather than guessing a floor.
* Band geometry is inherited from score_idle_screen.py and is 1280x720
  specific.
"""
from __future__ import annotations

import argparse
import glob
import json
import re
import sys
from pathlib import Path

import numpy as np
from PIL import Image

EXIT_MOVING, EXIT_STATIC, EXIT_REFUSE = 0, 1, 2

ARTIFACT_BAND = (84, 200)
CONTROL_BAND = (300, 1200)
CHEVRON_INTERIOR = (300, 420, 540, 660)  # y0, y1, x0, x1

MIN_FRAMES = 6
# Motion must exceed the capture's own noise floor by this factor.
MOTION_SNR = 4.0
# ...and be a meaningful number of grey levels in absolute terms.
MOTION_ABS_MIN = 1.5
# A capture whose noise floor is above this cannot resolve the question.
MAX_USABLE_NOISE_FLOOR = 3.0


def load_luma(paths: list[str]) -> np.ndarray:
    return np.stack([
        np.asarray(Image.open(p).convert("RGB"), dtype=np.float64).mean(axis=2)
        for p in paths
    ])


def natural_sort(paths: list[str]) -> list[str]:
    def key(p: str):
        m = re.findall(r"(\d+)", Path(p).stem)
        return (int(m[-1]) if m else 0, p)
    return sorted(paths, key=key)


def analyze(a: np.ndarray) -> dict:
    """`a` is (n, H, W) luma of already-warmup-filtered frames."""
    n, h, w = a.shape
    a0, a1 = ARTIFACT_BAND
    c0, c1 = CONTROL_BAND
    a1, c1 = min(a1, w), min(c1, w)
    art = a[:, :, a0:a1]
    ctl = a[:, :, c0:c1]

    out: dict = {"frames": n, "artifact_band": [a0, a1]}

    thr = float(np.median(ctl)) * 0.5
    dark_art = float((art < thr).mean())
    dark_ctl = float((ctl < thr).mean())
    out["dark_frac_artifact"] = round(dark_art, 4)
    out["dark_frac_control"] = round(dark_ctl, 4)
    if dark_ctl > 0:
        out["dark_ratio"] = round(dark_art / dark_ctl, 1)
    elif dark_art > 0:
        # A perfectly clean control band is the STRONGEST artifact evidence,
        # not an absence of evidence.  Returning None here made the self-test
        # REFUSE on its own positive control.
        out["dark_ratio"] = float("inf")
    else:
        out["dark_ratio"] = 0.0

    y0, y1, x0, x1 = CHEVRON_INTERIOR
    if y1 <= h and x1 <= w:
        chev = a[:, y0:y1, x0:x1]
        # Only a genuinely saturated, uniform patch gives a valid noise floor.
        out["chevron_interior_mean"] = round(float(chev.mean()), 2)
        out["noise_floor"] = round(float(chev.std(axis=0).mean()), 4)
    else:
        out["noise_floor"] = None

    out["temporal_std_artifact"] = round(float(art.std(axis=0).mean()), 4)
    out["temporal_std_control"] = round(float(ctl.std(axis=0).mean()), 4)

    widths = np.stack([(art[i] < thr).sum(axis=1) for i in range(n)])
    out["row_width_std_across_frames"] = round(float(widths.std(axis=0).mean()), 2)
    out["row_width_std_across_rows"] = round(float(widths.std(axis=1).mean()), 2)

    mean_img = art.mean(axis=0)
    ragged_single = float(widths.std(axis=1).mean())
    ragged_mean = float((mean_img < thr).sum(axis=1).std())
    out["raggedness_single_frame"] = round(ragged_single, 2)
    out["raggedness_frame_averaged"] = round(ragged_mean, 2)
    out["raggedness_collapse"] = (
        round(1.0 - ragged_mean / ragged_single, 3) if ragged_single > 0 else None)

    # Stable pillar boundary: the column at which the dark region ends.
    prof = [(art[i] < thr).mean(axis=0) for i in range(n)]
    edges = [int(np.argmax(p < 0.5)) if (p < 0.5).any() else -1 for p in prof]
    out["pillar_edge_col"] = [a0 + e if e >= 0 else -1 for e in edges]
    out["pillar_edge_stable"] = len(set(edges)) == 1
    return out


def verdict(m: dict) -> tuple[int, str]:
    if m["frames"] < MIN_FRAMES:
        return EXIT_REFUSE, (f"only {m['frames']} usable frames (< {MIN_FRAMES}); "
                             "cannot separate motion from noise")
    if m["dark_ratio"] is None or m["dark_ratio"] < 5.0:  # inf compares fine
        return EXIT_REFUSE, ("no left-edge artifact to characterise "
                             f"(dark ratio {m['dark_ratio']}); nothing to decide")
    floor = m.get("noise_floor")
    if floor is None:
        return EXIT_REFUSE, "no chevron interior available to measure a noise floor"
    if floor > MAX_USABLE_NOISE_FLOOR:
        return EXIT_REFUSE, (f"capture noise floor {floor} > {MAX_USABLE_NOISE_FLOOR}; "
                             "this capture cannot resolve motion either way")
    ts = m["temporal_std_artifact"]
    # Guard a zero floor without inflating the result.
    snr = ts / max(floor, 0.05)
    m["motion_snr"] = round(snr, 2)
    if ts >= MOTION_ABS_MIN and snr >= MOTION_SNR:
        return EXIT_MOVING, (f"artifact temporal std {ts} vs capture noise floor "
                             f"{floor} (SNR {snr:.1f}x); per-row dark width varies "
                             f"{m['row_width_std_across_frames']} px between frames")
    return EXIT_STATIC, (f"artifact temporal std {ts} is within "
                         f"{MOTION_SNR}x of the noise floor {floor} "
                         f"(SNR {snr:.1f}x); pattern is frozen")


def self_test() -> int:
    """Hermetic red/green: synthetic static and moving artifacts."""
    rng = np.random.default_rng(7)
    H, W, N = 720, 1280, 12
    checks: list[tuple[str, bool, str]] = []

    def build(moving: bool, noise: float = 0.0) -> np.ndarray:
        frames = []
        base = np.full((H, W), 120.0)
        base[300:420, 540:660] = 200.0          # saturated "chevron interior"
        rows = np.arange(H)
        for i in range(N):
            f = base.copy()
            phase = i * 3.0 if moving else 0.0
            widths = 36 + 20 * np.sin((rows + phase) * 0.4)
            for r in range(H):
                f[r, 84:84 + int(max(widths[r], 0))] = 0.0
            if noise:
                f += rng.normal(0, noise, f.shape)
            frames.append(np.clip(f, 0, 255))
        return np.stack(frames)

    rc, why = verdict(analyze(build(moving=True)))
    checks.append(("moving artifact -> MOVING", rc == EXIT_MOVING, f"rc={rc} {why}"))
    rc, why = verdict(analyze(build(moving=False)))
    checks.append(("static artifact -> STATIC", rc == EXIT_STATIC, f"rc={rc} {why}"))
    # A very noisy capture must REFUSE rather than claim motion.
    rc, why = verdict(analyze(build(moving=False, noise=12.0)))
    checks.append(("static + heavy noise -> REFUSE (never MOVING)",
                   rc == EXIT_REFUSE, f"rc={rc} {why}"))
    # No artifact at all -> refuse, not a verdict.
    flat = np.stack([np.full((H, W), 120.0) for _ in range(N)])
    flat[:, 300:420, 540:660] = 200.0
    rc, why = verdict(analyze(flat))
    checks.append(("no artifact -> REFUSE", rc == EXIT_REFUSE, f"rc={rc} {why}"))
    # Too few frames -> refuse.
    rc, why = verdict(analyze(build(moving=True)[:3]))
    checks.append(("too few frames -> REFUSE", rc == EXIT_REFUSE, f"rc={rc} {why}"))

    ok = 0
    for name, passed, detail in checks:
        print(f"{'PASS' if passed else 'FAIL'} {name}" + ("" if passed else f"  [{detail}]"))
        ok += passed
    print(f"\n{ok}/{len(checks)} self-test checks passed")
    return 0 if ok == len(checks) else 1


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--frames-dir", help="directory of captured PNG frames")
    ap.add_argument("--json-out")
    ap.add_argument("--self-test", action="store_true")
    args = ap.parse_args()

    if args.self_test:
        return self_test()
    if not args.frames_dir:
        print("REFUSE: --frames-dir or --self-test required", file=sys.stderr)
        return EXIT_REFUSE

    paths = natural_sort(glob.glob(str(Path(args.frames_dir) / "*.png")))
    if not paths:
        print(f"REFUSE: no PNG frames in {args.frames_dir}", file=sys.stderr)
        return EXIT_REFUSE
    a = load_luma(paths)
    keep = [i for i in range(len(a)) if a[i].std() > 2.0]
    dropped = len(a) - len(keep)
    if not keep:
        print("REFUSE: every frame is flat; no signal to analyse", file=sys.stderr)
        return EXIT_REFUSE
    a = a[keep]

    print(f"Scope: {len(a)} scored frames from {args.frames_dir} "
          f"(dropped {dropped} flat/warmup)")
    m = analyze(a)
    rc, why = verdict(m)
    m["verdict"] = {EXIT_MOVING: "MOVING", EXIT_STATIC: "STATIC",
                    EXIT_REFUSE: "REFUSE"}[rc]
    m["reason"] = why

    print(f"noise floor (chevron interior temporal std): {m.get('noise_floor')}")
    print(f"artifact band temporal std                 : {m['temporal_std_artifact']}")
    print(f"dark frac artifact/control                 : "
          f"{m['dark_frac_artifact']} / {m['dark_frac_control']} "
          f"(ratio {m['dark_ratio']}x)")
    print(f"raggedness single vs frame-averaged        : "
          f"{m['raggedness_single_frame']} -> {m['raggedness_frame_averaged']} "
          f"(collapse {m['raggedness_collapse']})")
    print(f"pillar edge column stable across frames    : {m['pillar_edge_stable']} "
          f"({m['pillar_edge_col'][0]})")
    print(f"LEFT_EDGE_DYNAMICS: {m['verdict']} — {why}")

    if args.json_out:
        safe = dict(m)
        if safe.get("dark_ratio") == float("inf"):
            safe["dark_ratio"] = "inf"
        Path(args.json_out).write_text(json.dumps(safe, indent=2))
    return rc


if __name__ == "__main__":
    raise SystemExit(main())
