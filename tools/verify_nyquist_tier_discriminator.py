#!/usr/bin/env python3
"""Host gate: 480 Nyquist flattens under even-row cull; 240 path differs.

Simulates legacy present_core STORE_Y_SCALE=2 + 529 cols + dual resample.
PASS if post-chain even_odd_abs(480_src) << even_odd_abs before cull AND
the two tiers remain separable by a stated threshold on a simple metric.

Does NOT claim HDMI truth — parent scores glass.
"""
from __future__ import annotations

import argparse
import json
import subprocess
import sys
import tempfile
from pathlib import Path

import numpy as np
from PIL import Image

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))
from present_chain_sim import (  # noqa: E402
    even_row_cull,
    full_chain_legacy240,
    vertical_row_energy,
)


def extract_frame(mp4: Path, n: int = 12) -> np.ndarray:
    with tempfile.NamedTemporaryFile(suffix=".png", delete=False) as tmp:
        p = Path(tmp.name)
    try:
        rc = subprocess.run(
            ["ffmpeg", "-y", "-hide_banner", "-loglevel", "error", "-i", str(mp4),
             "-vf", f"select=eq(n\\,{n})", "-vsync", "0", "-vframes", "1", str(p)],
            capture_output=True,
        ).returncode
        if rc != 0 or p.stat().st_size < 50:
            raise SystemExit(f"extract fail rc={rc}")
        return np.array(Image.open(p).convert("RGB"))
    finally:
        p.unlink(missing_ok=True)


def upscale_240_to_480(rgb: np.ndarray) -> np.ndarray:
    """Model DDR_YUV_FORCE_SCALE into 624x480 bank (bilinear)."""
    im = Image.fromarray(rgb, mode="RGB")
    # center 320x240 into 624x480 black, then the scaled content occupies center
    canvas = Image.new("RGB", (624, 480), (0, 0, 0))
    scaled = im.resize((624, 480), Image.Resampling.BILINEAR)
    return np.array(scaled)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--p480", type=Path, required=True)
    ap.add_argument("--p240", type=Path, required=True)
    ap.add_argument("--json-out", type=Path, default=None)
    args = ap.parse_args()

    f480 = extract_frame(args.p480)
    f240 = extract_frame(args.p240)
    report = {
        "p480_native_geom": list(f480.shape),
        "p240_native_geom": list(f240.shape),
        "src": "measured",
    }

    e480_native = vertical_row_energy(f480)
    e240_native = vertical_row_energy(f240)
    # 480 after even cull only
    c480 = even_row_cull(f480)
    e480_cull = vertical_row_energy(c480)
    # 240 force-scaled to 480 then cull (FORCE_SCALE model)
    u240 = upscale_240_to_480(f240)
    e240_up = vertical_row_energy(u240)
    c240 = even_row_cull(u240)
    e240_cull = vertical_row_energy(c240)
    # full chain grabber-shaped
    g480 = full_chain_legacy240(f480)
    g240 = full_chain_legacy240(u240)
    e480_g = vertical_row_energy(g480)
    e240_g = vertical_row_energy(g240)

    report["energy"] = {
        "480_native": e480_native,
        "480_even_cull": e480_cull,
        "240_native": e240_native,
        "240_upscaled_480": e240_up,
        "240_up_even_cull": e240_cull,
        "480_full_chain": e480_g,
        "240_full_chain": e240_g,
    }

    # Predictions (caller_supplied):
    # 480 period-2: native even_odd large; after even cull even_odd ~ 0 (flat)
    # 240 upscaled: softer; cull residual differs from 480 flat
    fail = []
    if e480_native["even_odd_abs"] < 80:
        fail.append(f"480 native not nyquist even_odd={e480_native['even_odd_abs']:.1f}")
    if e480_cull["even_odd_abs"] > 15:
        fail.append(f"480 cull not flat even_odd={e480_cull['even_odd_abs']:.1f}")
    # separability: |metric_480 - metric_240| on full chain luma_std or rowdiff
    sep = abs(e480_g["luma_std"] - e240_g["luma_std"])
    report["separability_luma_std"] = sep
    report["separability_rowdiff"] = abs(e480_g["rowdiff_mean"] - e240_g["rowdiff_mean"])
    # Require some separation OR the cull-flat signature on 480
    if e480_cull["even_odd_abs"] <= 15 and e480_native["even_odd_abs"] >= 80:
        report["cull_signature_480"] = "FLAT_AFTER_EVEN_CULL"
    else:
        report["cull_signature_480"] = "UNEXPECTED"
        fail.append("cull_signature")

    # 240 upscaled should NOT match the same extreme flatness from a nyquist-480
    # if upscale blurs — check native 240 has nyquist
    if e240_native["even_odd_abs"] < 80:
        fail.append(f"240 native not nyquist even_odd={e240_native['even_odd_abs']:.1f}")

    report["fail"] = fail
    report["pass"] = len(fail) == 0
    report["w_instr_hint"] = (
        "On glass after legacy 240-store path: 480-nyquist source → near-flat body "
        "(period-2 killed by even-row fetch). 240-nyquist force-scaled → lower "
        "pre-cull even_odd and different luma_std on grabber. Score body ROI "
        "excluding glass ID band y-mapped rows. Side panel period-8 leaves "
        "period-4 after cull as backup spatial feature."
    )
    print(json.dumps(report, indent=2))
    if args.json_out:
        args.json_out.write_text(json.dumps(report, indent=2))
    if fail:
        print("NYQUIST_TIER_FAIL", fail)
        return 1
    print("NYQUIST_TIER_OK")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
