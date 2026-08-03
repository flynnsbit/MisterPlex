#!/usr/bin/env python3
"""Inventory gate: 20 MHz hardcodes vs PRESENT_CLK_SYS_24 default-OFF.

Positive:
  - Product QSF does not enable PRESENT_CLK_SYS_24
  - PLL SoT defaults to 20.000000 MHz string in the else branch
  - Known RTL sites that encode 20e6 are listed (inventory completeness)

Negative:
  - If PRESENT_CLK_SYS_24 is active in QSF without allowlist bump → FAIL
  - If a new bare 20_000_000 appears in rtl/ present_* or pll without inventory → FAIL

This does not prove every consumer is rate-safe at 24 MHz; it proves we know
where the constants live so a silent enable cannot land unnoticed.
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
RTL = ROOT / "fpga/Plex_MiSTer/rtl"

# Allowlisted files that may contain 20_000_000 / "20.000000 MHz" (path relative ROOT)
ALLOW_20 = {
    "fpga/Plex_MiSTer/rtl/pll/pll_0002.v",
    "fpga/Plex_MiSTer/rtl/present_core.sv",
    "fpga/Plex_MiSTer/rtl/present_video_timing_720p.sv",
    "fpga/Plex_MiSTer/rtl/present_video_timing_960.sv",
    "fpga/Plex_MiSTer/rtl/present_pix_rate_match.sv",
    "fpga/Plex_MiSTer/rtl/present_vtotal_bresenham.sv",
    "fpga/Plex_MiSTer/rtl/present_beam_content_de.sv",
    "fpga/Plex_MiSTer/rtl/present_npx_path.sv",
    "fpga/Plex_MiSTer/rtl/ddr_bus_arbiter.sv",
}


def main() -> int:
    fails: list[str] = []

    def check(cond: bool, msg: str) -> None:
        if not cond:
            fails.append(msg)
        else:
            print(f"OK {msg}")

    qsf = (ROOT / "fpga/Plex_MiSTer/Plex.qsf").read_text(encoding="utf-8", errors="replace")
    active = [
        ln.strip()
        for ln in qsf.splitlines()
        if "PRESENT_CLK_SYS_24" in ln and not ln.strip().startswith("#")
    ]
    check(not active, "product QSF PRESENT_CLK_SYS_24 default OFF")

    pll = (ROOT / "fpga/Plex_MiSTer/rtl/pll/pll_0002.v").read_text(encoding="utf-8", errors="replace")
    check("PRESENT_CLK_SYS_24" in pll, "pll_0002 defines PRESENT_CLK_SYS_24")
    check('"20.000000 MHz"' in pll, "pll_0002 still has 20.000000 MHz product string")
    check('"24.000000 MHz"' in pll, "pll_0002 has 24.000000 MHz optional string")
    check("PRESENT_CLK_PIX_PLL" not in pll, "no PRESENT_CLK_PIX_PLL in pll SoT")

    # Sweep RTL for 20_000_000 and 20.000000 MHz
    pat = re.compile(r"20_000_000|20\.000000 MHz")
    found: dict[str, int] = {}
    for path in sorted(RTL.rglob("*")):
        if path.suffix not in {".sv", ".v", ".svh", ".vh"}:
            continue
        text = path.read_text(encoding="utf-8", errors="replace")
        n = len(pat.findall(text))
        if n:
            rel = str(path.relative_to(ROOT))
            found[rel] = n

    # Must find at least pll + present_core
    check("fpga/Plex_MiSTer/rtl/pll/pll_0002.v" in found, "inventory sees pll_0002 20 MHz")
    check("fpga/Plex_MiSTer/rtl/present_core.sv" in found, "inventory sees present_core 20 MHz")

    unknown = sorted(set(found) - ALLOW_20)
    for u in unknown:
        fails.append(f"NEW 20 MHz site not in allowlist: {u} (count={found[u]})")
    if not unknown:
        print(f"OK no unknown 20 MHz RTL sites ({len(found)} allowlisted files)")

    # Print inventory for humans
    print("--- inventory (allowlisted) ---")
    for rel in sorted(found):
        mark = "OK" if rel in ALLOW_20 else "NEW"
        print(f"  [{mark}] {rel}: {found[rel]}")

    # Documented consumers outside rtl/ (tests) — presence check only
    thr = ROOT / "tests/unit/test_decode_throughput_gate.sh"
    if thr.exists():
        tt = thr.read_text(encoding="utf-8", errors="replace")
        check("20_000_000" in tt or "20000000" in tt, "decode thruput gate still encodes 20e6")

    if fails:
        print("FAIL test_clksys_20mhz_inventory:", file=sys.stderr)
        for f in fails:
            print(f"  - {f}", file=sys.stderr)
        return 1
    print("PASS test_clksys_20mhz_inventory")
    return 0


if __name__ == "__main__":
    sys.exit(main())
