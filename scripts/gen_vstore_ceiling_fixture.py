#!/usr/bin/env python3
"""Generate V_STORE ceiling before/after discrimination fixtures.

PREFERRED publish path (no codec): scripts/gen_vstore_evenodd_i420.py +
  build/arm/push_frame --ddr --pattern mid_grey|even_black|even_white
  (product I420 → publishDdrFrame). Do NOT cast 1-row stripes as H.264.

Coordinate with w-asset480 (fixture ownership). This script defines the
pixel contract; packaging into a playable asset may be w-asset480's job.

Core constraint (quoted)
------------------------
present_core.sv:161-164
  H_DE=529  V_STORE=240
  STORE_Y_SCALE=(FRAME_H*65536)/240  → at FRAME_H=480 scale=2.0
  store_y = py*2  → only EVEN store rows of 480 are fetched (50% never read)
  STORE_X_SCALE → 529 of 640 columns (17.3% never fetched)
Then ascal + grabber resample — markers must be thick.

Fixtures (FRAME 640×480 store space; encode as you like)
--------------------------------------------------------
  even_only.rgb24  — bars on even rows only (visible BEFORE and AFTER fix)
  odd_only.rgb24   — bars on odd rows only  (invisible BEFORE; visible AFTER)
  full.rgb24       — bars on all rows
  id_ramp.rgb24    — unique luma per pair of rows (low-phase scorer)

Bar geometry: 8-row-tall full-width horizontal bars (4 even+4 odd) with
high-contrast luma so 529-col crop + 2 resamples still leave energy.

Parent before/after protocol
----------------------------
  BEFORE (current c5382bee / V_STORE=240):
    python3 tools/hdmi_vstore_discriminate.py BEFORE/f_*.png --odd-even
    expect: odd_only capture odd_over_even << 1; low-phase class 240
  AFTER (new RBF full fetch):
    same commands on AFTER bank
    expect: odd_only odd_over_even rises toward even_only; class may leave 240

  Bank the BEFORE capture NOW so the fix is not shippable without proof.
"""
from __future__ import annotations

import argparse
import struct
from pathlib import Path

W, H = 640, 480


def write_rgb24(path: Path, px: list[list[tuple[int, int, int]]]) -> None:
    with path.open("wb") as f:
        for row in px:
            for r, g, b in row:
                f.write(struct.pack("BBB", r, g, b))


def bars(which: str) -> list[list[tuple[int, int, int]]]:
    """which in even|odd|full|ramp."""
    px: list[list[tuple[int, int, int]]] = []
    for y in range(H):
        # 8-row block index
        blk = y // 8
        on = (blk % 2 == 0)
        base = 220 if on else 24
        if which == "even":
            if y % 2 == 1:
                base = 16  # odd rows black
        elif which == "odd":
            if y % 2 == 0:
                base = 16
        elif which == "ramp":
            # unique per 2-row pair
            base = 16 + ((y // 2) * 37) % 220
        elif which == "full":
            pass
        else:
            raise SystemExit(f"bad which={which}")
        # side markers survive H crop: left/right 32px different
        row = []
        for x in range(W):
            v = base
            if x < 32:
                v = min(255, base + 30)
            if x >= W - 32:
                v = max(0, base - 30)
            row.append((v, v, v))
        px.append(row)
    return px


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument(
        "-o",
        "--out-dir",
        type=Path,
        default=Path(".agent-work/w-instr/vstore-ceiling-fixture"),
    )
    args = ap.parse_args()
    args.out_dir.mkdir(parents=True, exist_ok=True)
    for name, which in (
        ("even_only", "even"),
        ("odd_only", "odd"),
        ("full", "full"),
        ("id_ramp", "ramp"),
    ):
        path = args.out_dir / f"{name}_{W}x{H}.rgb24"
        write_rgb24(path, bars(which))
        print(f"wrote {path} bytes={path.stat().st_size}")
    meta = args.out_dir / "README.txt"
    meta.write_text(
        "V_STORE ceiling fixtures 640x480 rgb24.\n"
        "even_only: content on even rows — visible on broken V_STORE=240 path.\n"
        "odd_only: content on odd rows — BLACK/empty on broken path; visible after fix.\n"
        "full / id_ramp: structure for low-phase B2 scorer.\n"
        "Score: tools/hdmi_vstore_discriminate.py CAP.png --odd-even\n"
        "w-asset480: package into playable H.264 if needed for on-device cast.\n"
    )
    print(f"wrote {meta}")
    print("PRE-REGISTER before/after:")
    print("  BEFORE odd_only: odd_over_even << 1 (measured on glass)")
    print("  AFTER  odd_only: odd_over_even rises (toward even_only)")
    print("  UNSCORED if capture idle/black — never PASS on empty")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
