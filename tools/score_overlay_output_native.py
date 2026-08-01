#!/usr/bin/env python3
"""Capture-based acceptance: bank-upscaled chrome vs output-native chrome.

Wraps tools/measure_overlay_edge.py lattice-pitch criterion.

TODAY (bank 624x480 → ascal → HDMI): PAUSED archive FAILS — coarse pitch mode
in {3..6} (upscale lattice). That is the user's "very low res" bug, measured.

AFTER option (c) post-scale plane: same UI at output raster must PASS pitch_ok
(no 3..6 lattice mode with share>=0.40) while staying legible.

Usage (parent on host with capture PNG):
  python3 tools/score_overlay_output_native.py CAPTURE.png; echo "true rc=$?"
  python3 tools/score_overlay_output_native.py --selftest; echo "true rc=$?"

Exit: 0 PASS (output-native signature), 1 FAIL (bank-upscale signature),
      2 bad input. Prints true rc=N itself; capture with `; echo` not `|`.
"""
from __future__ import annotations

import argparse
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
EDGE = ROOT / "tools" / "measure_overlay_edge.py"
ARCHIVE = ROOT / "files" / "device-evidence" / "osd_pause_3883f5ab_PAUSED_PASS.png"


def run_edge(path: Path) -> tuple[int, str]:
    p = subprocess.run(
        [sys.executable, str(EDGE), str(path)],
        capture_output=True,
        text=True,
    )
    out = (p.stdout or "") + (p.stderr or "")
    return p.returncode, out


def parse_fields(out: str) -> dict:
    d: dict = {}
    for line in out.splitlines():
        if "pitch_ok=" in line:
            # frame=... pitch_ok=False leg_ok=True ...
            for tok in line.replace(",", " ").split():
                if "=" in tok:
                    k, v = tok.split("=", 1)
                    d[k] = v
        if "VERDICT=" in line:
            d["VERDICT"] = line.split("VERDICT=", 1)[-1].strip()
    return d


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("capture", nargs="?", type=Path, help="HDMI grab PNG")
    ap.add_argument(
        "--selftest",
        action="store_true",
        help="RED: archive PAUSED must FAIL (bank lattice). No GREEN without plane.",
    )
    ap.add_argument(
        "--expect",
        choices=("fail", "pass"),
        default=None,
        help="Optional: require FAIL (today) or PASS (after plane)",
    )
    args = ap.parse_args()

    if args.selftest:
        if not ARCHIVE.is_file():
            print(f"ERROR missing archive {ARCHIVE}", file=sys.stderr)
            print("true rc=2")
            return 2
        rc, out = run_edge(ARCHIVE)
        print(out.rstrip())
        fields = parse_fields(out)
        # RED arm: bank-upscaled silicon MUST fail pitch
        if fields.get("pitch_ok") == "True" or fields.get("VERDICT") == "PASS":
            print(
                "SELFTEST_RED_FAIL: archive PAUSED unexpectedly PASS "
                "(lattice criterion would not catch bank mush)",
                file=sys.stderr,
            )
            print("true rc=1")
            return 1
        if rc == 0:
            print(
                "SELFTEST_RED_FAIL: edge tool rc=0 on archive (want FAIL)",
                file=sys.stderr,
            )
            print("true rc=1")
            return 1
        print(
            "SELFTEST_OK: archive PAUSED = bank-upscale FAIL "
            "(pitch lattice) — baseline for user bug"
        )
        print("true rc=0")
        return 0

    if not args.capture:
        print("usage: score_overlay_output_native.py CAPTURE.png|--selftest", file=sys.stderr)
        print("true rc=2")
        return 2
    if not args.capture.is_file():
        print(f"ERROR missing {args.capture}", file=sys.stderr)
        print("true rc=2")
        return 2

    rc, out = run_edge(args.capture)
    print(out.rstrip())
    fields = parse_fields(out)
    pitch_ok = fields.get("pitch_ok") == "True"
    verdict = fields.get("VERDICT", "FAIL" if rc != 0 else "PASS")

    print("--- acceptance (output-native chrome) ---")
    print(f"pitch_ok={pitch_ok} edge_rc={rc} verdict={verdict}")
    print("PASS band: pitch_ok=True (no coarse 3..6 lattice) AND edge VERDICT=PASS")
    print("FAIL band: pitch_ok=False (bank→ascal mush) — current product")
    print("Grabber: 1920x1080 or 1280x720 OK; do not nearest-downsample before score")

    expect = args.expect
    if expect == "fail":
        ok = not pitch_ok
        print(f"expect=fail → {'OK' if ok else 'MISS'}")
        print(f"true rc={0 if ok else 1}")
        return 0 if ok else 1
    if expect == "pass":
        ok = pitch_ok and rc == 0
        print(f"expect=pass → {'OK' if ok else 'MISS'}")
        print(f"true rc={0 if ok else 1}")
        return 0 if ok else 1

    # Default: report product-fix polarity (PASS only if output-native)
    final = 0 if (pitch_ok and rc == 0) else 1
    print(f"PRODUCT_NATIVE={'PASS' if final == 0 else 'FAIL'}")
    print(f"true rc={final}")
    return final


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except SystemExit:
        raise
    except Exception as e:
        print(f"ERROR {e}", file=sys.stderr)
        print("true rc=2")
        raise SystemExit(2)
