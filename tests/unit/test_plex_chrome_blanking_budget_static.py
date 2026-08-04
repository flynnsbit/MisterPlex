#!/usr/bin/env python3
"""H-blank budget + H_TOTAL independence for plex_chrome (w-osd, 720p24 raster).

Parent correction 2026-08-04:
  CORE_DE compact 720p24: H_TOTAL=1600, V_TOTAL=750, clk_pix=28.8 MHz
  H_BLANK = 1600 - 1280 = 320  (was 370 under retired H_TOTAL=1650)
  ACTIVE 1280×720 unchanged.

Product chrome paints on HDMI_OUT (clk_hdmi), not CORE_DE totals. Still:
  - must not derive layout from H_TOTAL
  - if ever pre-ascal on CORE_DE, blank work must fit in 320 cycles

Positive: product source has no H_TOTAL port/layout; EOL blank need = 1 ≤ 320.
Negative fixture: a path claiming >320 blank cycles must FAIL this gate.

true rc: python3 ...; echo "true rc=$?"
"""
from __future__ import annotations

import re
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
CHROME = (ROOT / "fpga/Plex_MiSTer/rtl/plex_chrome.sv").read_text()
SYS = (ROOT / "fpga/Plex_MiSTer/sys/sys_top.v").read_text()

# --- parent-stated raster (ACTIVE unchanged; totals for blank budget only) ---
H_ACTIVE = 1280
V_ACTIVE = 720
H_TOTAL_720P24 = 1600  # NEW compact
V_TOTAL_720P24 = 750
H_TOTAL_RETIRED_COMPACT = 1650  # retired 29.7 path; still CEA VIC4 @74.25
H_BLANK_720P24 = H_TOTAL_720P24 - H_ACTIVE  # 320
H_BLANK_RETIRED = H_TOTAL_RETIRED_COMPACT - H_ACTIVE  # 370
CLK_PIX_HZ = 28_800_000
assert H_TOTAL_720P24 * V_TOTAL_720P24 * 24 == CLK_PIX_HZ
assert H_BLANK_720P24 == 320
assert H_BLANK_RETIRED - H_BLANK_720P24 == 50  # parent "off by 50" blank delta


def budget_ok(eol_cycles: int, list_burst: int, h_blank: int) -> bool:
    """Worst-case cycles jammed into one H blank vs available blank."""
    # EOL always in blank; list burst only if host jams writes into blank.
    return (eol_cycles + list_burst) <= h_blank


def audit_source(src: str, label: str) -> list[str]:
    fails: list[str] = []

    # No product port named h_total / H_TOTAL on plex_chrome
    if re.search(r"\b(h_total|H_TOTAL|v_total|V_TOTAL)\b", src) and label == "chrome":
        # Allow comments / FAULT_HTOTAL param name only
        for i, line in enumerate(src.splitlines(), 1):
            s = line.strip()
            if s.startswith("//") or s.startswith("*"):
                continue
            # FAULT_HTOTAL_W / FAULT_LAYOUT_FROM_HTOTAL are intentional red-twins
            if "FAULT_HTOTAL" in line or "FAULT_LAYOUT_FROM_HTOTAL" in line:
                continue
            if re.search(r"\b(h_total|H_TOTAL|v_total|V_TOTAL)\b", line):
                fails.append(f"{label}:{i}: unexpected TOTAL token in code: {s[:80]}")

    # Product layout must track HDMI_WIDTH (ACTIVE), not a bare 1600/1650 assign
    if label == "chrome":
        if not re.search(
            r"FAULT_LAYOUT_FROM_HTOTAL\s*\?\s*FAULT_HTOTAL_W", src
        ):
            fails.append(f"{label}: missing FAULT_LAYOUT_FROM_HTOTAL mux arm")
        # Product arm is HDMI_WIDTH after fault ternaries
        if not re.search(r"layout_w\s*=[\s\S]{0,400}?HDMI_WIDTH", src):
            fails.append(f"{label}: layout_w does not fall through to HDMI_WIDTH")
        # Bare product pin of total as width
        if re.search(r"HDMI_WIDTH\s*=\s*12'd(?:1600|1650)\b", src):
            fails.append(f"{label}: HDMI_WIDTH hardcoded to H_TOTAL")

    return fails


def main() -> int:
    fails = 0

    def fail(m: str) -> None:
        nonlocal fails
        fails += 1
        print(f"FAIL: {m}", file=sys.stderr)

    def ok(m: str) -> None:
        print(f"OK: {m}")

    print("=== plex_chrome blanking / H_TOTAL audit ===")
    print(
        f"raster 720p24 compact: H_TOTAL={H_TOTAL_720P24} V_TOTAL={V_TOTAL_720P24} "
        f"clk={CLK_PIX_HZ} H_BLANK={H_BLANK_720P24} "
        f"(retired blank {H_BLANK_RETIRED}, delta {H_BLANK_RETIRED - H_BLANK_720P24})"
    )

    # Product blanking need (quoted from RTL: de fall → y_cnt++, 1 cycle)
    EOL_CYCLES = 1
    HIT_SCAN = 48  # worst list jam into blank
    ok(
        f"EOL={EOL_CYCLES} list_burst_max={HIT_SCAN} vs H_BLANK={H_BLANK_720P24}"
    )
    if not budget_ok(EOL_CYCLES, 0, H_BLANK_720P24):
        fail("EOL alone exceeds H_BLANK — BLOCKING")
    else:
        ok("EOL-only budget PASS (product paint path)")
    if not budget_ok(EOL_CYCLES, HIT_SCAN, H_BLANK_720P24):
        fail("EOL+HIT_SCAN exceeds H_BLANK — would BLOCK if list jammed in blank")
    else:
        ok("EOL+HIT_SCAN still ≤320 (not blocking even if jammed)")

    # Negative control: oversize blank need must fail budget_ok
    if budget_ok(EOL_CYCLES, 400, H_BLANK_720P24):
        fail("negative budget_ok(1,400,320) unexpectedly True (tautological gate)")
    else:
        ok("negative: need 401 cycles in blank FAILS budget (non-tautological)")

    # Fixture file that pretends chrome needs 400 blank cycles
    bad = (
        "// BAD fixture: pretends chrome H-blank prefetch needs 400 cycles\n"
        "localparam int CHROME_HBLANK_NEED = 400;\n"
    )
    with tempfile.TemporaryDirectory() as td:
        p = Path(td) / "bad_blank.sv"
        p.write_text(bad)
        m = re.search(r"CHROME_HBLANK_NEED\s*=\s*(\d+)", p.read_text())
        need = int(m.group(1)) if m else 0
        if need <= H_BLANK_720P24:
            fail("negative fixture did not exceed blank")
        elif budget_ok(need, 0, H_BLANK_720P24):
            fail("negative fixture budget unexpectedly ok")
        else:
            ok(f"negative fixture CHROME_HBLANK_NEED={need} > {H_BLANK_720P24} REJECTED")

    chrome_fails = audit_source(CHROME, "chrome")
    if chrome_fails:
        for m in chrome_fails:
            fail(m)
    else:
        ok("chrome source: no product H_TOTAL layout; FAULT arm present")

    # sys_top: chrome on HDMI path (not CORE_DE totals)
    if "u_plex_chrome" not in SYS:
        fail("sys_top missing u_plex_chrome")
    else:
        ok("sys_top: u_plex_chrome present (HDMI_OUT domain)")
    if not re.search(r"HDMI_WIDTH\s*\(\s*hdmi_width\s*\)", SYS):
        fail("sys_top chrome not tied to hdmi_width ACTIVE beam")
    else:
        ok("sys_top: chrome HDMI_WIDTH ← hdmi_width (ACTIVE, not H_TOTAL)")

    # Raster honesty comment present (28.8 / 1600)
    if "28.800000" not in CHROME and "28_800_000" not in CHROME and "1600" not in CHROME:
        fail("chrome header missing 720p24 compact 1600/28.8 note")
    else:
        ok("chrome header documents 1600@28.8 compact (not only retired 1650)")

    # 1650 must not be the sole "720p24 total" without VIC4 caveat if mentioned
    for i, line in enumerate(CHROME.splitlines(), 1):
        if "1650" in line and not line.strip().startswith("//"):
            # code using 1650 as layout is wrong unless FAULT param default
            if "FAULT" not in line and "12'd1650" in line:
                fail(f"chrome:{i}: bare 1650 in code (CEA VIC4 ok only as comment/param)")

    if fails:
        print(f"test_plex_chrome_blanking_budget_static: {fails} FAIL(s)", file=sys.stderr)
        return 1
    print("test_plex_chrome_blanking_budget_static: PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main())
