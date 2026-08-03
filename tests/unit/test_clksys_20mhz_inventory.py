#!/usr/bin/env python3
"""Allowlist gate: every RTL 20_000_000 / 20.000000 MHz site must be known.

Does not enable 24 MHz. Fails if:
  - product QSF activates PRESENT_CLK_SYS_24 without this gate being updated
  - a new RTL file grows a bare 20e6 constant outside the allowlist
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
RTL = ROOT / "fpga/Plex_MiSTer/rtl"

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
    "fpga/Plex_MiSTer/rtl/pll.v",
}


def main() -> int:
    fails: list[str] = []

    def check(cond: bool, msg: str) -> None:
        if not cond:
            fails.append(msg)
        else:
            print(f"OK {msg}")

    qsf = (ROOT / "fpga/Plex_MiSTer/Plex.qsf").read_text(encoding="utf-8", errors="replace")
    active_sys24 = [
        ln.strip()
        for ln in qsf.splitlines()
        if "PRESENT_CLK_SYS_24" in ln and not ln.strip().startswith("#")
    ]
    check(not active_sys24, "PRESENT_CLK_SYS_24 not active in product QSF")

    pll = (RTL / "pll/pll_0002.v").read_text(encoding="utf-8", errors="replace")
    check('"20.000000 MHz"' in pll, "pll_0002 product string 20.000000 MHz present")
    check('output_clock_frequency2("90.000000 MHz")' in pll, "clk_ddr stays 90 MHz")

    pat = re.compile(r"20_000_000|20\.000000 MHz")
    found: dict[str, int] = {}
    for path in sorted(RTL.rglob("*")):
        if path.suffix not in {".sv", ".v", ".svh", ".vh"}:
            continue
        text = path.read_text(encoding="utf-8", errors="replace")
        n = len(pat.findall(text))
        if n:
            found[str(path.relative_to(ROOT))] = n

    check("fpga/Plex_MiSTer/rtl/pll/pll_0002.v" in found, "inventory hits pll_0002")
    check("fpga/Plex_MiSTer/rtl/present_core.sv" in found, "inventory hits present_core")

    unknown = sorted(set(found) - ALLOW_20)
    for u in unknown:
        fails.append(f"NEW 20 MHz RTL site not allowlisted: {u} (n={found[u]})")
    if not unknown:
        print(f"OK allowlist covers all {len(found)} RTL files with 20 MHz tokens")

    print("--- 20 MHz RTL inventory ---")
    for rel, n in sorted(found.items()):
        print(f"  {rel}: {n}")

    # Documented key knock-ons (must remain findable)
    bres = (RTL / "present_vtotal_bresenham.sv").read_text(encoding="utf-8", errors="replace")
    check("1182" in bres and ("20 MHz" in bres or "20e6" in bres),
          "bresenham still documents H=1182 @ 20 MHz (960 path retune gate)")

    thr = ROOT / "tests/unit/test_decode_throughput_gate.sh"
    if thr.exists():
        tt = thr.read_text(encoding="utf-8", errors="replace")
        check("20_000_000" in tt, "decode thruput gate still encodes 20e6 (update with SYS24)")

    if fails:
        print("FAIL test_clksys_20mhz_inventory:", file=sys.stderr)
        for f in fails:
            print(f"  - {f}", file=sys.stderr)
        return 1
    print("PASS test_clksys_20mhz_inventory")
    return 0


if __name__ == "__main__":
    sys.exit(main())
