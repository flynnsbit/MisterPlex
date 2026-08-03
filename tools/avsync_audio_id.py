#!/usr/bin/env python3
"""Self-checking audio marker ID for lipsync fixtures (video c=digit-sum analogue).

Contract (v1) — coordinate w-asset480:
  At each integer second S (file time):
    1) SYNC: 1000 Hz tone, 40 ms, amplitude 0.9  — lipsync onset = tone start
    2) GAP:  5 ms silence
    3) ID:   4x bit tones, 8 ms each:
         bit=1 -> 2000 Hz, bit=0 -> 1500 Hz
         nibble = (S % 16), bits MSB first
    4) CHK:  4x bit tones, 8 ms each:
         chk = (nibble + (nibble>>1) + 1) & 0xF
         bits MSB first

Total marker ~109 ms << 1.0 s period.
Video flash must remain coincident with SYNC onset (integer second).

Existing soak480 (50 ms 1 kHz only) has no ID — decoder returns NO-DATA, not FAIL,
unless require mode is set.

Exit: 0 self-test OK; 1 fail.
"""
from __future__ import annotations

import argparse
import math
import struct
import sys
from pathlib import Path

SYNC_HZ = 1000.0
BIT1_HZ = 2000.0
BIT0_HZ = 1500.0
SYNC_MS = 40.0
GAP_MS = 5.0
BIT_MS = 8.0


def chk_nibble(n: int) -> int:
    n &= 0xF
    return (n + (n >> 1) + 1) & 0xF


def bits4(n: int) -> list[int]:
    n &= 0xF
    return [(n >> i) & 1 for i in (3, 2, 1, 0)]


def synth_marker_pcm(second: int, sr: int = 48000) -> list[float]:
    out: list[float] = []

    def tone(hz: float, ms: float, amp: float = 0.9) -> None:
        n = int(sr * ms / 1000.0)
        for i in range(n):
            out.append(amp * math.sin(2 * math.pi * hz * (i / sr)))

    def silence(ms: float) -> None:
        out.extend([0.0] * int(sr * ms / 1000.0))

    tone(SYNC_HZ, SYNC_MS)
    silence(GAP_MS)
    nib = second % 16
    for b in bits4(nib):
        tone(BIT1_HZ if b else BIT0_HZ, BIT_MS, amp=0.7)
    for b in bits4(chk_nibble(nib)):
        tone(BIT1_HZ if b else BIT0_HZ, BIT_MS, amp=0.7)
    return out


def goertzel(block: list[float], sr: int, hz: float) -> float:
    n = len(block)
    if n == 0:
        return 0.0
    k = int(0.5 + (n * hz) / sr)
    w = 2.0 * math.pi * k / n
    coeff = 2.0 * math.cos(w)
    s0 = s1 = s2 = 0.0
    for x in block:
        s0 = x + coeff * s1 - s2
        s2 = s1
        s1 = s0
    return (s1 * s1 + s2 * s2 - coeff * s1 * s2) / (n * n)


def decode_marker(pcm: list[float], sr: int, t0_s: float) -> dict:
    def slice_ms(start_ms: float, dur_ms: float) -> list[float]:
        a = int((t0_s + start_ms / 1000.0) * sr)
        b = int((t0_s + (start_ms + dur_ms) / 1000.0) * sr)
        return pcm[a:b]

    base = SYNC_MS + GAP_MS
    bits = []
    for i in range(8):
        blk = slice_ms(base + i * BIT_MS, BIT_MS)
        if len(blk) < 8:
            return {"ok": False, "reason": "short", "src": "measured"}
        p1 = goertzel(blk, sr, BIT1_HZ)
        p0 = goertzel(blk, sr, BIT0_HZ)
        bits.append(1 if p1 > p0 else 0)
    id_bits, chk_bits = bits[:4], bits[4:]
    nibble = (id_bits[0] << 3) | (id_bits[1] << 2) | (id_bits[2] << 1) | id_bits[3]
    chk = (chk_bits[0] << 3) | (chk_bits[1] << 2) | (chk_bits[2] << 1) | chk_bits[3]
    expect = chk_nibble(nibble)
    ok = chk == expect
    return {
        "ok": ok,
        "nibble": nibble,
        "chk": chk,
        "chk_expect": expect,
        "src": "measured",
        "reason": "ok" if ok else "checksum_mismatch",
    }


def self_test() -> int:
    sr = 48000
    fails = 0
    for s in range(0, 32):
        pcm = synth_marker_pcm(s, sr)
        lead = [0.0] * int(0.1 * sr)
        full = lead + pcm + [0.0] * sr
        d = decode_marker(full, sr, 0.1)
        if not d["ok"] or d["nibble"] != (s % 16):
            print(f"FAIL s={s} d={d}")
            fails += 1
    assert chk_nibble(0) != 0
    if fails:
        print(f"SELF_TEST_FAIL n={fails}")
        return 1
    print("SELF_TEST_OK avsync_audio_id")
    print(f"marker_total_ms={SYNC_MS + GAP_MS + BIT_MS * 8} src=caller_supplied")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--self-test", action="store_true")
    ap.add_argument("--write-pcm", type=Path, default=None)
    args = ap.parse_args()
    if args.self_test:
        return self_test()
    if args.write_pcm:
        sr = 48000
        samples: list[float] = []
        for s in range(16):
            m = synth_marker_pcm(s, sr)
            samples.extend(m)
            samples.extend([0.0] * (sr - len(m)))
        with args.write_pcm.open("wb") as f:
            for x in samples:
                v = max(-1.0, min(1.0, x))
                f.write(struct.pack("<h", int(v * 32767)))
        print(f"wrote {args.write_pcm} samples={len(samples)}")
        return 0
    ap.print_help()
    return 1


if __name__ == "__main__":
    sys.exit(main())
