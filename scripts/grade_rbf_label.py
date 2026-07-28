#!/usr/bin/env python3
"""Verify the RBF identity label rendered in the HDMI idle screen.

misterplexd computes `md5sum /media/fat/_Utility/Plex.rbf` and renders the
first 8 hex digits as "RBF xxxxxxxx" in the fb0 idle overlay.  This script:
  1. Accepts a pre-captured PNG/JPEG frame (or captures one live).
  2. Crops the label region (caller-specified or full-frame search).
  3. Pre-processes: upscale + contrast-stretch for robust OCR.
  4. Runs tesseract (--psm 7, hex whitelist) to extract text.
  5. Normalises OCR output (common misreads: O↔0, I↔1, l↔1, B↔8).
  6. Asserts extracted md5 prefix matches --expected-md5 (or the live file
     hash fetched via SSH from the MiSTer).

Usage:
  python3 scripts/grade_rbf_label.py [frame.png ...]
      [--region x,y,w,h]     crop in 1280x720 HDMI pixel coords
      [--expected-md5 HEX8]   first-8-hex of RBF md5 (skips SSH fetch)
      [--mister-host H]       MiSTer SSH host [default: MISTER_HOST env / 192.168.1.183]
      [--mister-pass P]       MiSTer SSH password [default: MISTER_PASS env / 1]
      [--capture]             capture a fresh frame before grading
      [--scale N]             upscale factor before OCR [default: 4]
      [--out-dir DIR]         save debug crops here
      [--expect PASS|FAIL]    invert assertion for red-check testing

Exit codes:
  0   PASS  label present and md5 prefix matches
  1   FAIL  label absent, unreadable, or md5 mismatch
  77  SKIP  no capture device / SSH unavailable / --expected-md5 not given and
            MiSTer unreachable

Three-question audit:
  (1) What does it literally compare?
      The first 8 hex digits read via tesseract OCR from a captured HDMI frame,
      normalised for common OCR misreads, against the md5sum of the RBF file.
  (2) What does it NOT cover?
      Font colour, label position accuracy, frame timing, whether the label
      persists across frames (check --frames > 1 in a wrapper).  OCR will miss
      the label if the rendering font is too small (<14px per glyph in capture
      coords) or if the background contrast is too low.
  (3) Can you make it fail?
      Pass --expected-md5 00000000 against any real RBF → exit 1.
      Pass a blank-frame PNG → exit 1 (no label found).
"""

import argparse
import re
import subprocess
import sys
from pathlib import Path

from PIL import Image
import numpy as np

ROOT = Path(__file__).resolve().parent.parent

# ── OCR normalization table (applied to the hex group only, NOT the prefix) ──
# Tesseract commonly confuses these pairs in small monospace hex fonts.
# NOTE: 'B'→'8' is intentionally absent — 'B' is a valid hex digit (11) and
# would corrupt the "RBF" prefix if applied to the full string.  The prefix is
# matched flexibly below (R[B8]F) to handle any B/8 confusion there.
_HEX_NORMALIZE = str.maketrans({
    'O': '0', 'Q': '0',             # 0-lookalikes (D excluded: valid hex)
    'I': '1', 'l': '1',             # 1-lookalikes
    'Z': '2',                        # 2-lookalike
    'S': '5',                        # 5-lookalike
    'G': '6',                        # 6-lookalike
    'T': '7',                        # 7-lookalike
})

# Prefix match: R[B8]F handles the B/8 OCR confusion in the 3-char prefix.
# Hex group: 7-9 chars to absorb one insertion/deletion before validation.
_LABEL_RE = re.compile(r'R[B8]F\s+([0-9a-fA-FBbDdOoQqIilZzSsGgTt]{7,9})',
                       re.IGNORECASE)


def _ocr_frame(img_path: Path, region=None, scale: int = 4, out_dir: Path = None) -> str:
    """Return the OCR'd text from img_path, optionally cropping to region.

    region: (x, y, w, h) in capture-frame pixels (1280x720 coords).
    Returns the raw tesseract output string.
    """
    img = Image.open(img_path).convert('L')

    if region:
        x, y, w, h = region
        img = img.crop((x, y, x + w, y + h))
    # else: search full frame

    # Scale up for OCR accuracy
    new_w = img.width * scale
    new_h = img.height * scale
    img = img.resize((new_w, new_h), Image.NEAREST)

    # Contrast stretch: map 5th–95th percentile to 0–255
    arr = np.array(img, dtype=float)
    p5 = float(np.percentile(arr, 5))
    p95 = float(np.percentile(arr, 95))
    if p95 > p5:
        arr = (arr - p5) / (p95 - p5) * 255.0
        arr = np.clip(arr, 0, 255).astype(np.uint8)
        img = Image.fromarray(arr)

    if out_dir:
        out_dir.mkdir(parents=True, exist_ok=True)
        crop_path = out_dir / f"ocr_crop_{img_path.stem}.png"
        img.save(crop_path)

    # Write to a named path in build/ (never /tmp)
    ocr_tmp = ROOT / "build" / f"_ocr_{img_path.stem}.png"
    ocr_tmp.parent.mkdir(parents=True, exist_ok=True)
    img.save(ocr_tmp)

    result = subprocess.run(
        [
            "tesseract", str(ocr_tmp), "stdout",
            "--psm", "7",          # single text line
            "-l", "eng",
            "-c", "tessedit_char_whitelist=ABCDEFabcdef0123456789 RBF",
        ],
        capture_output=True, text=True,
    )
    # clean up
    ocr_tmp.unlink(missing_ok=True)
    return result.stdout.strip()


def _extract_md5_prefix(raw_ocr: str) -> str | None:
    """Extract the 8-char hex md5 prefix from OCR output.

    Matches "R[B8]F <8-hex-chars>" with normalization of common OCR misreads
    applied only to the hex group (not the fixed "RBF" prefix).
    """
    m = _LABEL_RE.search(raw_ocr)
    if not m:
        return None
    hex_raw = m.group(1)
    # Normalise common misreads in the hex group only
    normalised = hex_raw.translate(_HEX_NORMALIZE).lower()
    # Must be exactly 8 valid hex chars after normalisation
    if len(normalised) == 8 and re.fullmatch(r'[0-9a-f]{8}', normalised):
        return normalised
    return None


def _fetch_expected_md5(host: str, password: str) -> str | None:
    """SSH to MiSTer and return the first 8 hex chars of the RBF md5."""
    cmd = ["sshpass", "-p", password,
           "ssh", "-o", "StrictHostKeyChecking=no", "-o", "ConnectTimeout=8",
           f"root@{host}",
           "md5sum /media/fat/_Utility/Plex.rbf 2>/dev/null | cut -c1-8"]
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=15)
        out = r.stdout.strip()
        if re.fullmatch(r'[0-9a-f]{8}', out):
            return out
    except (subprocess.TimeoutExpired, FileNotFoundError):
        pass
    return None


def _capture_frame(out_dir: Path) -> Path | None:
    """Capture a single frame via capture_preflight.py; return the frame path."""
    capture_dir = out_dir / "live_capture"
    preflight = ROOT / "scripts" / "capture_preflight.py"
    if not preflight.exists():
        return None

    log_path = ROOT / "build" / "_grade_rbf_capture.log"
    r = subprocess.run(
        [sys.executable, str(preflight), "--frames", "1", "--out-dir", str(capture_dir)],
        capture_output=False,
        stdout=open(log_path, "w"),
        stderr=subprocess.STDOUT,
    )
    if r.returncode not in (0, 1):  # 77 = no device
        return None
    frames = sorted(capture_dir.glob("frames/*.png"))
    return frames[0] if frames else None


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("frames", nargs="*", metavar="frame.png",
                    help="Pre-captured frame(s) to analyse")
    ap.add_argument("--region", metavar="x,y,w,h",
                    help="Crop region in 1280x720 coords (omit to search full frame)")
    ap.add_argument("--expected-md5", metavar="HEX8",
                    help="First 8 hex digits of RBF md5 to compare against")
    ap.add_argument("--mister-host", default=None,
                    help="MiSTer SSH host [MISTER_HOST env / 192.168.1.183]")
    ap.add_argument("--mister-pass", default=None,
                    help="MiSTer SSH password [MISTER_PASS env / 1]")
    ap.add_argument("--capture", action="store_true",
                    help="Capture a fresh frame from /dev/video0 first")
    ap.add_argument("--scale", type=int, default=4,
                    help="Upscale factor before OCR [default: 4]")
    ap.add_argument("--out-dir", default=None,
                    help="Save debug crops here")
    ap.add_argument("--expect", choices=["PASS", "FAIL"], default="PASS",
                    help="Invert assertion for red-check mode")
    args = ap.parse_args()

    import os
    mister_host = args.mister_host or os.environ.get("MISTER_HOST", "192.168.1.183")
    mister_pass = args.mister_pass or os.environ.get("MISTER_PASS", "1")
    out_dir = Path(args.out_dir) if args.out_dir else ROOT / "build" / "rbf-label-check"

    region = None
    if args.region:
        parts = [int(v) for v in args.region.split(",")]
        if len(parts) != 4:
            print("ERROR: --region must be x,y,w,h", file=sys.stderr)
            sys.exit(1)
        region = tuple(parts)

    # ── Resolve expected md5 ─────────────────────────────────────────────────
    expected_md5 = None
    if args.expected_md5:
        expected_md5 = args.expected_md5.lower()
        if not re.fullmatch(r'[0-9a-f]{8}', expected_md5):
            print(f"ERROR: --expected-md5 must be 8 hex digits, got {expected_md5!r}",
                  file=sys.stderr)
            sys.exit(1)
    else:
        print(f"Fetching RBF md5 from {mister_host} ...")
        expected_md5 = _fetch_expected_md5(mister_host, mister_pass)
        if expected_md5 is None:
            print("SKIP: MiSTer unreachable and --expected-md5 not given → exit 77")
            sys.exit(77)

    print(f"Expected md5 prefix: {expected_md5}")

    # ── Gather frames ────────────────────────────────────────────────────────
    frame_paths = [Path(f) for f in args.frames]
    if args.capture or not frame_paths:
        captured = _capture_frame(out_dir)
        if captured is None:
            print("SKIP: live capture failed and no frame arguments → exit 77")
            sys.exit(77)
        frame_paths = [captured]
        print(f"Captured: {captured}")

    print(f"Scope: {len(frame_paths)} frame(s)")
    if not frame_paths:
        print("SKIP: Scope: 0 — no frames to examine → exit 77")
        sys.exit(77)

    # ── Grade each frame ─────────────────────────────────────────────────────
    results = []
    for fp in frame_paths:
        if not fp.exists():
            print(f"  SKIP {fp.name}: file not found")
            continue
        raw_ocr = _ocr_frame(fp, region=region, scale=args.scale, out_dir=out_dir)
        extracted = _extract_md5_prefix(raw_ocr)
        match = (extracted == expected_md5) if extracted else False
        status = "PASS" if match else "FAIL"
        print(f"  {fp.name}: ocr={raw_ocr!r} extracted={extracted!r} "
              f"expected={expected_md5!r} → {status}")
        results.append(match)

    if not results:
        print("SKIP: no frames were analysable → exit 77")
        sys.exit(77)

    passed = sum(results)
    total = len(results)
    print(f"\nRBF_LABEL_RESULT: {passed}/{total} frames matched expected md5 prefix")

    overall_pass = passed > 0  # at least one frame has the correct label
    verdict = "PASS" if overall_pass else "FAIL"
    print(f"VERDICT: {verdict}")

    if args.expect == "FAIL":
        # Red-check mode: we expect a failure, so invert
        if overall_pass:
            print("ERROR: expected FAIL but got PASS → exit 1 (red-check broken)")
            sys.exit(1)
        else:
            print("Red-check confirmed: gate correctly detected bad label → exit 0")
            sys.exit(0)

    sys.exit(0 if overall_pass else 1)


if __name__ == "__main__":
    main()
