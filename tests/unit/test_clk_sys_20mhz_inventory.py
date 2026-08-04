#!/usr/bin/env python3
"""Gate: every hardcoded clk_sys≈20 MHz site is allowlisted (no silent new magic).

Fails if a new 20_000_000 / 20.000000 MHz clk_sys assumption appears outside
ALLOWLIST. When retuning clk_sys, update allowlist + each site together.

Note: 120_000_000 must NOT match 20_000_000 (negative lookbehind).
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
RTL = ROOT / "fpga/Plex_MiSTer"

# (path regex fullmatch, line regex search)
ALLOWLIST: list[tuple[str, str]] = [
    (r"fpga/Plex_MiSTer/rtl/misterplex_clk_hz\.svh", r"20_000_000|20 MHz"),
    (r"fpga/Plex_MiSTer/rtl/plex_clk_status\.sv", r"20|29_700"),

    (r"fpga/Plex_MiSTer/rtl/pll/pll_0002\.v", r"MISTERPLEX_CLK_SYS_PLL_FREQ|20\.000000 MHz"),
    (r"fpga/Plex_MiSTer/rtl/pll/pll_0002\.v", r"clk_sys 20 MHz"),
    (r"fpga/Plex_MiSTer/rtl/pll\.v", r"clk_sys 20 MHz"),
    (r"fpga/Plex_MiSTer/rtl/present_core\.sv", r"CLK_PIX_HZ\(20_000_000\)"),
    (r"fpga/Plex_MiSTer/rtl/present_core\.sv", r"MP_CLK_PIX_HZ = 20_000_000"),
    (r"fpga/Plex_MiSTer/rtl/present_core\.sv", r"20 MHz"),
    (r"fpga/Plex_MiSTer/rtl/present_pix_rate_match\.sv", r"F_SYS_HZ\s*=\s*20_000_000"),
    (r"fpga/Plex_MiSTer/rtl/present_video_timing_720p\.sv", r"CLK_PIX_HZ = 20_000_000"),
    (r"fpga/Plex_MiSTer/rtl/present_video_timing_720p\.sv", r"clk_sys == 20 MHz|@20 MHz"),
    (r"fpga/Plex_MiSTer/rtl/present_video_timing_960\.sv", r"CLK_PIX_HZ = 20_000_000"),
    (r"fpga/Plex_MiSTer/rtl/present_video_timing_960\.sv", r"@ 20 MHz"),
    (r"fpga/Plex_MiSTer/rtl/present_vtotal_bresenham\.sv", r"20 MHz"),
    (r"fpga/Plex_MiSTer/rtl/present_npx_path\.sv", r"F_sys=20 MHz|@20/PPC"),
    (r"fpga/Plex_MiSTer/rtl/present_beam_content_de\.sv", r"20 MHz"),
    (r"fpga/Plex_MiSTer/rtl/present_content_window\.sv", r"20 MHz"),
    (r"fpga/Plex_MiSTer/rtl/ddr_bus_arbiter\.sv", r"20 MHz"),
    (r"fpga/Plex_MiSTer/rtl/tb_arb_beat_conservation\.sv", r"20 MHz"),
    (r"fpga/Plex_MiSTer/rtl/tb_audio_fifo_cdc\.sv", r"~20 MHz"),
]

# Avoid matching 120_000_000 or 200000000 addresses
PATTERNS = [
    re.compile(r"(?<![0-9])20_000_000(?![0-9])"),
    re.compile(r"(?<![0-9])20000000(?![0-9])"),
    re.compile(r'(?<![0-9])20\.000000 MHz'),
    re.compile(r"(?<![0-9.])20 MHz\b"),
    re.compile(r"F_sys=20"),
    re.compile(r"@20/"),
    re.compile(r"@20 MHz"),
]


def main() -> int:
    fails: list[str] = []
    hits: list[tuple[str, int, str]] = []
    scan_roots = [
        RTL / "rtl",
        RTL / "Plex.sv",
        RTL / "pll.v" if (RTL / "pll.v").is_file() else None,
    ]
    # pll is under rtl/pll
    files: list[Path] = []
    for root in [RTL / "rtl", RTL]:
        if root.is_file():
            files.append(root)
            continue
        if not root.is_dir():
            continue
        for path in root.rglob("*"):
            if path.suffix in {".sv", ".v", ".vh"} and "sys/" not in str(path).replace("\\", "/"):
                files.append(path)
    # also Plex.sv
    files.append(RTL / "Plex.sv")
    seen=set()
    for path in files:
        if not path.is_file():
            continue
        key = path.resolve()
        if key in seen:
            continue
        seen.add(key)
        text = path.read_text(errors="ignore")
        rel = str(path.relative_to(ROOT)).replace("\\", "/")
        for i, line in enumerate(text.splitlines(), 1):
            if "32'h20000000" in line or "gamma_bus[20]" in line:
                continue
            if not any(p.search(line) for p in PATTERNS):
                continue
            hits.append((rel, i, line.strip()[:140]))

    for rel, i, line in hits:
        ok = any(re.fullmatch(are, rel) and re.search(aln, line) for are, aln in ALLOWLIST)
        if not ok:
            fails.append(f"UNLISTED 20MHz assumption {rel}:{i}: {line}")

    # Required: PLL product 20 and F_SYS default must remain listed
    required = [
        (r"fpga/Plex_MiSTer/rtl/pll/pll_0002\.v", r"MISTERPLEX_CLK_SYS_PLL_FREQ|20\.000000 MHz"),
        (r"fpga/Plex_MiSTer/rtl/present_pix_rate_match\.sv", r"F_SYS_HZ\s*=\s*20_000_000"),
    ]
    for are, aln in required:
        if not any(re.fullmatch(are, r) and re.search(aln, l) for r, _, l in hits):
            fails.append(f"MISSING required inventory site {are} / {aln}")

    if fails:
        print("FAIL test_clk_sys_20mhz_inventory")
        for f in fails:
            print(" ", f)
        print(f"hits_total={len(hits)}")
        return 1
    print(f"PASS test_clk_sys_20mhz_inventory hits={len(hits)} allowlisted")
    for rel, i, line in hits:
        print(f"  OK {rel}:{i}: {line[:100]}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
