#!/usr/bin/env python3
"""Score the MiSTer idle/screensaver screen from real HDMI capture.

Answers, with no human in the loop, the question w-osd-o5 left open:

    "When idle is set to Logo or Screensaver, do you see a dark gray Plex
     chevron/logo instead of a pure black screen?"

Signal-state classification is delegated to capture_preflight.classify_signal
so this tool cannot disagree with the fleet's primary instrument about what
counts as CONTENT_PRESENT / BLACK_SIGNAL / NO_SIGNAL.  On top of that it
measures two named features:

  PLEX_CHEVRON        Plex-brand-orange blob (~#E5A00D) of plausible size,
                      near the vertical centre of the frame.
  LEFT_EDGE_ARTIFACT  Excess dark pixels in the left band of the active
                      picture relative to a control band -- the user-reported
                      "moving jagged black lines on the left edge"
                      (owner: w-arm-o5).  Reported, never fatal: this tool
                      measures the defect, it does not own the fix.

Exit codes:
  0  PASS     CONTENT_PRESENT and the required features were found
  1  FAIL     signal is present but the screen is black, or a required
              feature is missing
  2  REFUSE   no usable signal / capture error -- explicitly NOT a pass and
              explicitly NOT a skip
 77  SKIP     no capture device at all (UNSCORED)
"""
from __future__ import annotations

import argparse
import importlib.util
import json
import sys
from pathlib import Path

import numpy as np
from PIL import Image

ROOT = Path(__file__).resolve().parents[1]
_spec = importlib.util.spec_from_file_location(
    "capture_preflight", ROOT / "scripts" / "capture_preflight.py")
cp = importlib.util.module_from_spec(_spec)
assert _spec.loader is not None
_spec.loader.exec_module(cp)

EXIT_PASS = 0
EXIT_FAIL = 1
EXIT_REFUSE = 2
EXIT_SKIP = 77

# Plex brand orange is #E5A00D.  Measured on the rig through MJPEG: (244,163,2).
# Bounds are deliberately loose enough for capture/JPEG drift but tight enough
# that grey, white and the dark background can never satisfy them.
ORANGE_MIN_R = 150
ORANGE_MAX_B = 80
ORANGE_MIN_RB_GAP = 80
ORANGE_G_RANGE = (90, 200)

# A chevron must be a real blob, not a handful of speckles, and must not be
# the whole screen.
CHEVRON_MIN_PX = 2000
CHEVRON_MAX_FRAC = 0.25
# Vertical centroid must sit within this fraction of frame height from centre.
CHEVRON_CENTRE_TOL = 0.20

# Left-edge artifact bands, in columns of the 1280-wide capture.
ARTIFACT_BAND = (84, 200)
CONTROL_BAND = (300, 1200)
# Ratio of dark-pixel density (artifact band / control band) above which the
# left-edge defect is called PRESENT.
ARTIFACT_RATIO = 5.0


def orange_mask(rgb: np.ndarray) -> np.ndarray:
    r = rgb[..., 0].astype(int)
    g = rgb[..., 1].astype(int)
    b = rgb[..., 2].astype(int)
    return ((r > ORANGE_MIN_R) & (b < ORANGE_MAX_B)
            & (g > ORANGE_G_RANGE[0]) & (g < ORANGE_G_RANGE[1])
            & (r > b + ORANGE_MIN_RB_GAP))


def score_chevron(rgb: np.ndarray) -> dict:
    mask = orange_mask(rgb)
    count = int(mask.sum())
    h, w = mask.shape
    frac = count / mask.size
    out = {"orange_px": count, "orange_frac": round(frac, 6),
           "min_px": CHEVRON_MIN_PX, "present": False, "reason": ""}
    if count < CHEVRON_MIN_PX:
        out["reason"] = f"only {count} Plex-orange px (< {CHEVRON_MIN_PX}); no chevron"
        return out
    if frac > CHEVRON_MAX_FRAC:
        out["reason"] = f"orange covers {frac:.1%} of frame (> {CHEVRON_MAX_FRAC:.0%}); flood, not a logo"
        return out
    ys, xs = np.nonzero(mask)
    cy = float(ys.mean())
    out["bbox"] = [int(xs.min()), int(ys.min()), int(xs.max()), int(ys.max())]
    out["centroid"] = [int(xs.mean()), int(cy)]
    out["mean_rgb"] = [int(rgb[..., i][mask].mean()) for i in range(3)]
    off = abs(cy - h / 2) / h
    out["vertical_offset_frac"] = round(off, 4)
    if off > CHEVRON_CENTRE_TOL:
        out["reason"] = (f"orange blob centroid is {off:.1%} of frame height off centre "
                         f"(> {CHEVRON_CENTRE_TOL:.0%}); not a centred logo")
        return out
    out["present"] = True
    out["reason"] = (f"{count} px of Plex-orange {out['mean_rgb']} centred at "
                     f"{out['centroid']}, bbox {out['bbox']}")
    return out


def score_left_edge(rgb: np.ndarray) -> dict:
    lum = rgb.mean(axis=2)
    w = lum.shape[1]
    a0, a1 = ARTIFACT_BAND
    c0, c1 = CONTROL_BAND
    a1, c1 = min(a1, w), min(c1, w)
    control = lum[:, c0:c1]
    if control.size == 0 or a1 <= a0:
        return {"measurable": False, "reason": "frame too narrow for band analysis"}
    bg = float(np.median(control))
    thr = bg * 0.5
    art = lum[:, a0:a1]
    art_frac = float((art < thr).mean())
    ctl_frac = float((control < thr).mean())
    ratio = art_frac / ctl_frac if ctl_frac > 0 else float("inf")
    present = art_frac > 0.05 and ratio > ARTIFACT_RATIO
    return {
        "measurable": True,
        "background_luma": round(bg, 2),
        "dark_threshold": round(thr, 2),
        "artifact_band": [a0, a1],
        "control_band": [c0, c1],
        "artifact_dark_frac": round(art_frac, 4),
        "control_dark_frac": round(ctl_frac, 4),
        "ratio": (round(ratio, 1) if ratio != float("inf") else "inf"),
        "present": bool(present),
    }


def host_reachable(host: str, timeout_s: int = 3) -> bool:
    """Cheap liveness probe for the video source host.

    Calibration measured on this rig: with the MiSTer powered down and off the
    network, the MS2109 still delivers frames at 1280x720 and they are flat
    RGB(7,7,7) -- byte-identical to the value the classifier calls
    BLACK_SIGNAL.  Luma alone therefore CANNOT distinguish "the core is
    painting black" from "the source is switched off".  Without this probe a
    powered-off device is silently reported as a core defect, which is the
    exact misdiagnosis class this tool exists to prevent.
    """
    import subprocess
    try:
        r = subprocess.run(["ping", "-c", "1", "-W", str(timeout_s), host],
                           capture_output=True, timeout=timeout_s + 3)
        return r.returncode == 0
    except Exception:
        return False


def load_frames(args: argparse.Namespace) -> tuple[list[np.ndarray], str]:
    if args.input:
        frames = []
        for p in args.input:
            frames.append(np.array(Image.open(p).convert("RGB"), dtype=np.uint8))
        return frames, "file"
    dev = args.device
    if dev is None:
        dev = cp.select_capture_node()["dev"] if hasattr(cp, "select_capture_node") else "/dev/video0"
    frames, _log, _neg, dropped = cp.grab_n_frames(
        dev, args.input_format, args.video_size, args.framerate,
        args.frames, Path(args.out_dir) / "frames",
        warmup_discard=args.warmup_discard)
    return frames, f"v4l2:{dev} (warmup dropped {dropped})"


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--input", action="append", default=[],
                    help="score these image files instead of live capture")
    ap.add_argument("--device", default=None)
    ap.add_argument("--input-format", default="mjpeg")
    ap.add_argument("--video-size", default="1280x720")
    ap.add_argument("--framerate", default="60")
    ap.add_argument("--frames", type=int, default=8)
    ap.add_argument("--warmup-discard", type=int, default=12)
    ap.add_argument("--out-dir", default="build/idle_screen")
    ap.add_argument("--expect-chevron", action="store_true",
                    help="require the Plex chevron; without this the tool only "
                         "requires CONTENT_PRESENT")
    ap.add_argument("--host", default=None,
                    help="video source host (e.g. the MiSTer). When a black screen is "
                         "detected this host is probed: if it is unreachable the result "
                         "is REFUSE/UNSCORED rather than a core FAIL, because a "
                         "powered-off source is indistinguishable from a black core on "
                         "this capture device.")
    ap.add_argument("--json-out")
    args = ap.parse_args(argv)

    out_dir = Path(args.out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)

    try:
        frames, source = load_frames(args)
    except cp.PreflightError as e:
        print(f"REFUSE: capture failed: {e}", file=sys.stderr)
        return EXIT_REFUSE
    except FileNotFoundError as e:
        print(f"REFUSE: input missing: {e}", file=sys.stderr)
        return EXIT_REFUSE

    if not frames:
        print("REFUSE: no frames captured", file=sys.stderr)
        return EXIT_REFUSE

    signal = cp.classify_signal(frames)
    frame = frames[-1]
    chevron = score_chevron(frame)
    edge = score_left_edge(frame)

    report = {"source": source, "scored_frames": len(frames),
              "signal": signal, "chevron": chevron, "left_edge_artifact": edge}

    print(f"Scope: {len(frames)} scored frames from {source}")
    print(f"SIGNAL_STATE: {signal['state']}  "
          f"mean_luma={signal['mean_luma']} spatial_std={signal['spatial_std']} "
          f"unique={signal['unique_hashes']}/{signal['total_frames']}")
    print(f"PLEX_CHEVRON: {'PRESENT' if chevron['present'] else 'ABSENT'} — {chevron['reason']}")
    if edge.get("measurable"):
        print(f"LEFT_EDGE_ARTIFACT: {'PRESENT' if edge['present'] else 'clean'} — "
              f"dark {edge['artifact_dark_frac']:.1%} in cols {edge['artifact_band']} vs "
              f"{edge['control_dark_frac']:.1%} in control {edge['control_band']} "
              f"(ratio {edge['ratio']}x)")

    if args.json_out:
        Path(args.json_out).write_text(json.dumps(report, indent=2))
    (out_dir / "idle_screen_report.json").write_text(json.dumps(report, indent=2))

    state = signal["state"]
    if state == "NO_SIGNAL":
        print("REFUSE: no usable HDMI signal; screen state is UNSCORED (not a pass, not a skip)",
              file=sys.stderr)
        return EXIT_REFUSE
    if state == "STALE_CAPTURE":
        print("REFUSE: capture is frozen; screen state is UNSCORED", file=sys.stderr)
        return EXIT_REFUSE
    if state == "BLACK_SIGNAL":
        if args.host and not host_reachable(args.host):
            print(f"REFUSE: frames are flat black BUT source host {args.host} is "
                  f"unreachable — a powered-off MiSTer produces the identical "
                  f"flat RGB(7,7,7) frames on this capture device. Screen state is "
                  f"UNSCORED; this is NOT evidence of a core defect.", file=sys.stderr)
            report["black_attribution"] = "source_host_unreachable"
            (out_dir / "idle_screen_report.json").write_text(json.dumps(report, indent=2))
            return EXIT_REFUSE
        if args.host:
            report["black_attribution"] = "source_host_reachable_core_paints_black"
            print(f"  source host {args.host} IS reachable — black is attributable "
                  f"to the core/daemon, not to a dead source")
        print("FAIL: valid signal but the screen is BLACK — no picture is being presented",
              file=sys.stderr)
        (out_dir / "idle_screen_report.json").write_text(json.dumps(report, indent=2))
        return EXIT_FAIL
    if args.expect_chevron and not chevron["present"]:
        print(f"FAIL: content present but Plex chevron missing — {chevron['reason']}",
              file=sys.stderr)
        return EXIT_FAIL
    print("PASS: valid signal with picture content"
          + (" including the Plex chevron" if chevron["present"] else ""))
    return EXIT_PASS


if __name__ == "__main__":
    raise SystemExit(main())
