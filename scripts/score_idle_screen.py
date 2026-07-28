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
import os
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
# Shape gates.  Colour + pixel count + centroid alone are NOT sufficient: the
# MiSTer main menu is a full-height column of orange text that satisfies all
# three and was scored PLEX_CHEVRON: PRESENT on 2026-xx by this gate.
# Measured separation (real chevron vs MENU false positive):
#   aspect w/h  0.929 vs 0.165      fill count/bbox_area  0.277 vs 0.105
CHEVRON_ASPECT_RANGE = (0.40, 2.50)
CHEVRON_MIN_FILL = 0.18

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
    bw = int(xs.max() - xs.min()) + 1
    bh = int(ys.max() - ys.min()) + 1
    aspect = bw / bh
    fill = count / (bw * bh)
    out["bbox_wh"] = [bw, bh]
    out["aspect"] = round(aspect, 3)
    out["fill"] = round(fill, 3)
    lo, hi = CHEVRON_ASPECT_RANGE
    if not (lo <= aspect <= hi):
        out["reason"] = (f"orange bbox {bw}x{bh} has aspect {aspect:.2f} outside "
                         f"[{lo}, {hi}]; a streak or column of text, not a logo")
        return out
    if fill < CHEVRON_MIN_FILL:
        out["reason"] = (f"orange fills only {fill:.1%} of its {bw}x{bh} bbox "
                         f"(< {CHEVRON_MIN_FILL:.0%}); scattered text, not a solid logo")
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


def loaded_core_identity(host: str, timeout_s: int = 10) -> dict:
    """Read the CURRENTLY LOADED core identity from the device.

    Signal state and provenance are independent axioms.  A capture can be
    perfectly valid and still be about the wrong bitstream: on 2026-07-28 this
    rig rebooted mid-shift, came back on the MENU core, and a capture taken
    minutes later was briefly attributed to the Plex RBF sitting unloaded on the
    SD card.  Pixels alone cannot detect that; only the loaded-core identity can.

    Returns {"ok": bool, "corename": str, "rbf_md5": str, "uptime_s": int,
             "error": str}.  Never raises.
    """
    import subprocess
    cmd = ("echo \"CORENAME=$(cat /tmp/CORENAME 2>/dev/null)\"; "
           "echo \"RBFMD5=$(md5sum /media/fat/_Utility/Plex.rbf 2>/dev/null | cut -d' ' -f1)\"; "
           "echo \"UPTIME=$(cut -d. -f1 /proc/uptime 2>/dev/null)\"")
    info = {"ok": False, "corename": "", "rbf_md5": "", "uptime_s": -1, "error": ""}
    try:
        r = subprocess.run(
            ["sshpass", "-p", os.environ.get("MISTER_PASS", "1"), "ssh",
             "-o", "StrictHostKeyChecking=no", "-o", f"ConnectTimeout={timeout_s}",
             f"root@{host}", cmd],
            capture_output=True, text=True, timeout=timeout_s + 10)
        if r.returncode != 0:
            info["error"] = (r.stderr or "ssh failed").strip()[:200]
            return info
        for line in r.stdout.splitlines():
            if line.startswith("CORENAME="):
                info["corename"] = line.split("=", 1)[1].strip()
            elif line.startswith("RBFMD5="):
                info["rbf_md5"] = line.split("=", 1)[1].strip()
            elif line.startswith("UPTIME="):
                try:
                    info["uptime_s"] = int(line.split("=", 1)[1].strip())
                except ValueError:
                    pass
        info["ok"] = bool(info["corename"])
        if not info["ok"]:
            info["error"] = "device returned no CORENAME"
    except Exception as e:  # noqa: BLE001
        info["error"] = f"{type(e).__name__}: {e}"[:200]
    return info


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
    ap.add_argument("--expect-corename", default=None,
                    help="REFUSE unless the device's loaded core matches (e.g. Plex). "
                         "Pixels are only evidence about a bitstream if the loaded "
                         "core is verified AT CAPTURE TIME; a rebooted device can "
                         "come back on MENU with the RBF unloaded on disk.")
    ap.add_argument("--expect-rbf-md5", default=None,
                    help="REFUSE unless /media/fat/_Utility/Plex.rbf matches this md5.")
    ap.add_argument("--json-out")
    args = ap.parse_args(argv)

    out_dir = Path(args.out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)

    # Provenance BEFORE pixels: a capture is only evidence about a bitstream if
    # the loaded core is verified at capture time.
    if args.expect_corename or args.expect_rbf_md5:
        if not args.host:
            print("REFUSE: --expect-corename/--expect-rbf-md5 require --host",
                  file=sys.stderr)
            return EXIT_REFUSE
        ident = loaded_core_identity(args.host)
        if not ident["ok"]:
            print(f"REFUSE: cannot verify loaded core on {args.host}: "
                  f"{ident['error']}; screen state is UNSCORED", file=sys.stderr)
            return EXIT_REFUSE
        print(f"PROVENANCE: corename={ident['corename']!r} "
              f"rbf_md5={ident['rbf_md5'][:8]} uptime={ident['uptime_s']}s")
        if args.expect_corename and ident["corename"] != args.expect_corename:
            print(f"REFUSE: loaded core is {ident['corename']!r}, expected "
                  f"{args.expect_corename!r}. The capture would be about the WRONG "
                  f"core, so it is UNSCORED — not a pass and not a core defect.",
                  file=sys.stderr)
            return EXIT_REFUSE
        if args.expect_rbf_md5 and not ident["rbf_md5"].startswith(args.expect_rbf_md5):
            print(f"REFUSE: resident RBF md5 {ident['rbf_md5'][:8]} != expected "
                  f"{args.expect_rbf_md5[:8]}; screen state is UNSCORED",
                  file=sys.stderr)
            return EXIT_REFUSE

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
    if signal.get("note"):
        print(f"  note: {signal['note']}")
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
