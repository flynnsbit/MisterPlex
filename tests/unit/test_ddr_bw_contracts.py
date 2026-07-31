#!/usr/bin/env python3
"""Static contracts for w-bw: DDR mmap policy, doorbell order, PMS ladder, pg kill.

Host-only. Does not open /dev/mem or touch the device. Locks the evidence-backed
frame-push contracts so a future edit cannot silently regress:
  - product DDR frame map opens /dev/mem with O_SYNC by default
  - payload fence before doorbell; hi (metadata) before lo (magic)
  - universal URL forces transcode + videoResolution=
  - ffmpeg children killed via process group (kill(-pid))
  - YUV420p byte volumes (not BGRA) for bandwidth arithmetic
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
FPGA_SPI = ROOT / "arm" / "misterplexd" / "fpga_spi.cpp"
FPGA_HPP = ROOT / "arm" / "misterplexd" / "fpga_spi.hpp"
MEDIA = ROOT / "arm" / "misterplexd" / "media_player.cpp"
RESOLVE = ROOT / "arm" / "misterplexd" / "plex_resolve.cpp"
LAYOUT = ROOT / "host" / "libmisterplex" / "ddr_frame_layout.hpp"
FFMPEG_VF = ROOT / "host" / "libmisterplex" / "ffmpeg_vf.hpp"
MAIN = ROOT / "arm" / "misterplexd" / "main.cpp"


def fail(msg: str) -> None:
    print(f"FAIL ddr_bw_contracts: {msg}", file=sys.stderr)
    sys.exit(1)


def must_contain(path: Path, pattern: str, label: str, flags: int = 0) -> re.Match[str]:
    text = path.read_text(encoding="utf-8", errors="replace")
    m = re.search(pattern, text, flags)
    if not m:
        fail(f"{path.relative_to(ROOT)}: missing {label}\n  pattern: {pattern}")
    return m


def main() -> int:
    # --- mmap / O_SYNC product default ---
    must_contain(
        FPGA_HPP,
        r"bool\s+ddrMemSync_\s*=\s*true\s*;",
        "ddrMemSync_ default true",
    )
    must_contain(
        FPGA_SPI,
        r"if\s*\(\s*ddrMemSync_\s*\)\s*\n\s*flags\s*\|\=\s*O_SYNC\s*;",
        "ensureDdrMap adds O_SYNC when ddrMemSync_",
    )
    must_contain(
        FPGA_SPI,
        r'ddrMemFd_\s*=\s*::open\(\s*"/dev/mem"\s*,\s*flags\s*\)\s*;',
        'ensureDdrMap opens "/dev/mem"',
    )
    must_contain(
        FPGA_SPI,
        r"mmap\(\s*nullptr\s*,\s*kLen\s*,\s*PROT_READ\s*\|\s*PROT_WRITE\s*,\s*MAP_SHARED\s*,\s*ddrMemFd_",
        "ensureDdrMap MAP_SHARED PROT_READ|WRITE",
    )

    # --- payload fence then doorbell; metadata before magic ---
    send = must_contain(
        FPGA_SPI,
        r"std::memcpy\(\s*ddrMap_\s*\+\s*bankOff\s*,\s*payload\s*,\s*len\s*\)\s*;"
        r"\s*__sync_synchronize\s*\(\s*\)\s*;",
        "memcpy then __sync_synchronize before kick",
        flags=re.S,
    )
    kick = must_contain(
        FPGA_SPI,
        r"bool\s+FpgaSpi::kickDdrDoorbell\s*\(\s*int\s+bank\s*\)\s*\{(?P<body>.*?)^\}\s*$",
        "kickDdrDoorbell body",
        flags=re.S | re.M,
    )
    body = kick.group("body")
    # Order inside kick: dw[1]=hi, barrier, dw[0]=magic, barrier
    hi_pos = body.find("dw[1] = hi;")
    lo_pos = body.find("dw[0] = kDdrDoorbellMagic;")
    if hi_pos < 0 or lo_pos < 0 or hi_pos > lo_pos:
        fail("kickDdrDoorbell must assign dw[1]=hi before dw[0]=magic")
    between = body[hi_pos:lo_pos]
    if "__sync_synchronize()" not in between:
        fail("kickDdrDoorbell must barrier between hi and magic")
    after_lo = body[lo_pos:]
    if "__sync_synchronize()" not in after_lo:
        fail("kickDdrDoorbell must barrier after magic")

    # sendDdrFrame must call kick after the payload fence (source order)
    spi_text = FPGA_SPI.read_text(encoding="utf-8", errors="replace")
    if spi_text.find("std::memcpy(ddrMap_ + bankOff, payload, len);") > spi_text.find(
        "if (kickDdrDoorbell(bank))"
    ):
        # There may be multiple kick sites; require the hot-path pair order via nearby window.
        window = spi_text[
            spi_text.find("std::memcpy(ddrMap_ + bankOff, payload, len);") : spi_text.find(
                "std::memcpy(ddrMap_ + bankOff, payload, len);"
            )
            + 800
        ]
        if "kickDdrDoorbell" not in window:
            fail("sendDdrFrame hot path must kick doorbell after payload memcpy")
    _ = send  # used for side-effect assert above

    # --- process group kill ---
    must_contain(MEDIA, r"kill\(\s*-\s*p\s*,\s*sig\s*\)\s*;", "kill(-p, sig) for ffmpeg group")
    must_contain(MEDIA, r"kill\(\s*-\s*sp\s*,\s*sig\s*\)\s*;", "kill(-sp, sig) for stream group")
    must_contain(MEDIA, r"setpgid\(\s*0\s*,\s*0\s*\)\s*;", "child setpgid(0,0)")
    must_contain(MEDIA, r"setpgid\(\s*pid\s*,\s*pid\s*\)\s*;", "parent setpgid(pid,pid)")

    # --- PMS universal ladder asks for videoResolution, forces transcode ---
    must_contain(
        RESOLVE,
        r'/video/:/transcode/universal/start\.mp4',
        "universal start.mp4 path",
    )
    must_contain(RESOLVE, r"directPlay=0&directStream=0", "force transcode flags")
    must_contain(
        RESOLVE,
        r'&videoResolution="\s*<<\s*urlEncodeQuery\(\s*weak\.videoResolution\s*\)',
        "videoResolution from weak ladder",
    )

    # --- scale defaults + silicon canvas ignore DECODE ---
    must_contain(
        MAIN,
        r'std::string\s+ffmpegScaleMode\s*=\s*"skip_identity"\s*;',
        'default FFMPEG_SCALE skip_identity',
    )
    must_contain(
        MAIN,
        r"std::string\s+ffmpegSwsFlags\s*;\s*//\s*empty\s*=\s*ffmpeg default",
        "default FFMPEG_SWS_FLAGS empty (not fast_bilinear product default)",
    )
    must_contain(
        LAYOUT,
        r"return\s+productDdrFrameStoreGeometry\s*\(\s*\)\s*;",
        "ddrFrameGeometryForFpgaPresent ignores DECODE and returns silicon canvas",
    )
    must_contain(
        FFMPEG_VF,
        r"SkipIdentity",
        "SkipIdentity scale mode exists",
    )

    # --- YUV420p byte volumes (not BGRA 4·W·H) ---
    layout = LAYOUT.read_text(encoding="utf-8", errors="replace")
    if "kPlex480pYuv420pBytes = 449280" not in layout:
        fail("kPlex480pYuv420pBytes must stay 449280 (624*480*3/2)")
    # 320x240 I420
    b240 = 320 * 240 * 3 // 2
    if b240 != 115200:
        fail(f"internal: 320x240 I420 bytes={b240}")
    b720 = 1280 * 720 * 3 // 2
    if b720 != 1382400:
        fail(f"internal: 1280x720 I420 bytes={b720}")
    # Arithmetic freeze vs archive ~60 MiB/s class (rule-0: pure math, not device claim)
    mibps = 60.0
    ms_480 = (449280 / (mibps * 1024 * 1024)) * 1000.0
    ms_720 = (1382400 / (mibps * 1024 * 1024)) * 1000.0
    if not (7.0 <= ms_480 <= 7.3):
        fail(f"480p @60MiB/s expected ~7.14ms got {ms_480:.3f}")
    if not (21.5 <= ms_720 <= 22.5):
        fail(f"720p @60MiB/s expected ~21.97ms got {ms_720:.3f}")
    # 720p60 needs >60 MiB/s just for copy
    need_720_60 = (1382400 * 60) / (1024 * 1024)
    if need_720_60 <= 60.0:
        fail("720p60 copy need must exceed 60 MiB/s")

    print(
        "test_ddr_bw_contracts: OK "
        "mmap_O_SYNC_default doorbell_hi_before_lo payload_fence "
        f"kill_pg yuv_bytes 240={b240} 480=449280 720={b720} "
        f"ms@60MiB/s 480={ms_480:.3f} 720={ms_720:.3f} "
        f"720p60_need_MiBps={need_720_60:.2f}"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
