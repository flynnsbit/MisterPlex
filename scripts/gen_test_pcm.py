#!/usr/bin/env python3
"""Generate ~1s of 440 Hz stereo s16le PCM @ 48 kHz for MiSTerPlex F2 load."""
from __future__ import annotations

import math
import struct
import argparse
import sys
from pathlib import Path


def main() -> int:
    ap = argparse.ArgumentParser(description="Generate an s16le PCM test tone.")
    ap.add_argument("out", nargs="?", default="plex_test_1s_48k.s16le")
    ap.add_argument("duration", nargs="?", type=float, default=1.0)
    args = ap.parse_args()
    out = Path(args.out)
    rate = 48000
    dur = args.duration
    n = int(rate * dur)
    amp = 8000
    buf = bytearray()
    for i in range(n):
        s = int(amp * math.sin(2 * math.pi * 440.0 * i / rate))
        s = max(-32767, min(32767, s))
        buf += struct.pack("<hh", s, s)  # L, R
    out.write_bytes(buf)
    print(f"wrote {out} ({len(buf)} bytes, {n} stereo frames @ {rate} Hz)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
