#!/usr/bin/env python3
"""Generate I420 frames for V_STORE even-row ceiling test (no codec).

Product DDR path is planar YUV420p (I420), coded 624×480 (kPlex480pYuv420pBytes
= 449280). RGB24 is refused by push_frame/publishDdrFrame.

PRE-REGISTER (current RBF c5382bee, store_y=py*2 → even store rows only)
----------------------------------------------------------------------
  even_black.i420  → glass solid BLACK   (even Y=16)
  even_white.i420  → glass solid WHITE   (even Y=235)
  odd_black.i420   → glass solid WHITE   (phase shift of even_black)
  odd_white.i420   → glass solid BLACK   (phase shift of even_white)
  mid_grey.i420    → glass uniform MID-GREY  (CONTROL — if this fails, path broken)

If even_black and even_white render IDENTICAL → 240-row ceiling claim FALSIFIED.

Publish (same path as playback)::

  # stop daemon so it does not overwrite the bank
  ssh root@MiSTer 'killall misterplexd'   # parent-owned
  scp build/arm/push_frame even_black.i420 root@MiSTer:/tmp/
  ssh root@MiSTer '/tmp/push_frame --ddr --yuv420p 624x480 /tmp/even_black.i420'
  # capture HDMI, then restore daemon (scripts/deploy_misterplexd.sh or service)

Y levels use video range: black=16, white=235, mid=128; U=V=128 (neutral).
"""
from __future__ import annotations

import argparse
import struct
from pathlib import Path

# Product coded geometry (ddr_frame_layout.hpp)
W, H = 624, 480
Y_BLACK = 16
Y_WHITE = 235
Y_MID = 128
UV_NEUTRAL = 128


def write_i420(path: Path, y_plane: bytes) -> None:
    assert len(y_plane) == W * H
    u = bytes([UV_NEUTRAL]) * ((W // 2) * (H // 2))
    v = bytes([UV_NEUTRAL]) * ((W // 2) * (H // 2))
    path.write_bytes(y_plane + u + v)
    assert path.stat().st_size == W * H * 3 // 2


def y_rows(even_val: int, odd_val: int) -> bytes:
    row_e = bytes([even_val]) * W
    row_o = bytes([odd_val]) * W
    out = bytearray()
    for y in range(H):
        out += row_e if (y % 2 == 0) else row_o
    return bytes(out)


def y_flat(val: int) -> bytes:
    return bytes([val]) * (W * H)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument(
        "-o",
        "--out-dir",
        type=Path,
        default=Path(".agent-work/w-instr/vstore-evenodd-i420"),
    )
    args = ap.parse_args()
    args.out_dir.mkdir(parents=True, exist_ok=True)

    frames = {
        "even_black.i420": y_rows(Y_BLACK, Y_WHITE),  # even black, odd white
        "even_white.i420": y_rows(Y_WHITE, Y_BLACK),
        "odd_black.i420": y_rows(Y_WHITE, Y_BLACK),  # = phase shift of even_black
        "odd_white.i420": y_rows(Y_BLACK, Y_WHITE),  # = phase shift of even_white
        "mid_grey.i420": y_flat(Y_MID),
        # aliases matching parent wording
        "control_mid_grey.i420": y_flat(Y_MID),
    }
    # odd_black is identical to even_white; odd_white identical to even_black.
    # Keep separate files so the parent protocol can name the phase explicitly.

    for name, y in frames.items():
        path = args.out_dir / name
        write_i420(path, y)
        print(f"wrote {path} bytes={path.stat().st_size} src=generator")

    readme = args.out_dir / "README.txt"
    readme.write_text(
        f"""V_STORE even/odd I420 fixtures — coded {W}x{H} planar YUV420p
bytes/frame = {W*H*3//2} (kPlex480pYuv420pBytes=449280)

PRE-REGISTER on c5382bee (store_y=py*2, even rows only):
  even_black → solid BLACK
  even_white → solid WHITE
  odd_black  → solid WHITE  (inversion vs even_black)
  odd_white  → solid BLACK
  mid_grey   → uniform MID-GREY (CONTROL)
If control is not mid-grey, UNSCORE entire run (publish path broken).
If even_black ≡ even_white on glass, ceiling claim FALSIFIED.

Publish path (product):
  build/arm/push_frame --ddr --yuv420p 624x480 FILE.i420
  → FpgaSpi::sendYuv420pFrameDdr → publishDdrFrame → sendDdrFrame
  Same path as MediaPlayer playback DDR present.

Daemon: STOP misterplexd before push (it will overwrite the bank).
Restore after capture. Daily-driver safe if parent restores.

Score captures:
  python3 tools/hdmi_vstore_discriminate.py --flat-suite CAP_DIR
"""
    )
    print(f"wrote {readme}")
    print("PRE-REGISTER even-black→BLACK even-white→WHITE mid-grey→MID control")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
