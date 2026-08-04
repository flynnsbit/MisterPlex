#!/usr/bin/env python3
"""G-CHROME-COMPOSE — plex_chrome must compose on reconcile base (not shelfware).

GREEN checks (all required):
  1) sys_top: u_plex_chrome between shadowmask and osd
  2) product default: has_frame_chrome tracks has_frame_hdmi
  3) Plex.sv: u_plxc_ddr_loader present; PLXC_EXT from plxc_core_* nets
  4) files.qip lists plex_chrome*.sv
  5) refresh honesty comment present (16.16 trap named)

NEGATIVE (must FAIL a naive shelfware port):
  - has_frame_chrome hardwired 1'b1 in product else → fail
  - PLXC_EXT_WE assign 1'b0 in Plex.sv → fail
  - chrome missing from files.qip → fail

true rc: echo after python3 ...
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SYS = (ROOT / "fpga/Plex_MiSTer/sys/sys_top.v").read_text()
PLEX = (ROOT / "fpga/Plex_MiSTer/Plex.sv").read_text()
QIP = (ROOT / "fpga/Plex_MiSTer/files.qip").read_text()
CHROME = (ROOT / "fpga/Plex_MiSTer/rtl/plex_chrome.sv").read_text()


def strip(s: str) -> str:
    s = re.sub(r"/\*.*?\*/", "", s, flags=re.S)
    return re.sub(r"//.*?$", "", s, flags=re.M)


def main() -> int:
    fails = 0

    def fail(m: str) -> None:
        nonlocal fails
        fails += 1
        print(f"FAIL: {m}", file=sys.stderr)

    def ok(m: str) -> None:
        print(f"OK: {m}")

    code_sys = strip(SYS)
    code_plex = strip(PLEX)

    if "u_plex_chrome" not in code_sys:
        fail("sys_top missing u_plex_chrome")
    else:
        ok("u_plex_chrome in sys_top")

    if not re.search(r"din\s*\(\s*hdmi_data_mask\s*\)", SYS):
        fail("chrome din not from shadowmask (hdmi_data_mask)")
    else:
        ok("chrome after shadowmask")

    if "hdmi_data_chrome_kept" not in SYS or not re.search(
        r"din\s*\(\s*hdmi_data_chrome_kept\s*\)", SYS
    ):
        fail("osd din not chrome_kept")
    else:
        ok("osd after chrome")

    if not re.search(r"assign\s+has_frame_chrome\s*=\s*has_frame_hdmi", code_sys):
        fail("product has_frame_chrome does not track has_frame_hdmi")
    else:
        ok("has_frame CDC compose")

    # NEGATIVE class: stuck-1 kills idle
    # Find product else body after CHROME elsif
    if re.search(
        r"`else\b[\s\S]{0,400}?assign\s+has_frame_chrome\s*=\s*1'b1",
        SYS,
    ) and "PRODUCT COMPOSE" not in SYS:
        fail("product else still hardwires has_frame=1")
    elif re.search(
        r"// PRODUCT COMPOSE[\s\S]{0,500}?assign\s+has_frame_chrome\s*=\s*1'b1",
        SYS,
    ):
        fail("PRODUCT COMPOSE block hardwires has_frame=1 (neg)")
    else:
        ok("product else not stuck-has_frame-1")

    if "u_plxc_ddr_loader" not in code_plex:
        fail("Plex.sv missing u_plxc_ddr_loader compose instance")
    else:
        ok("u_plxc_ddr_loader present")

    if re.search(r"assign\s+PLXC_EXT_WE\s*=\s*1'b0", code_plex):
        fail("PLXC_EXT_WE tied 0 (dead path neg)")
    elif re.search(r"assign\s+PLXC_EXT_WE\s*=\s*plxc_core_we", code_plex):
        ok("PLXC_EXT from loader nets")
    else:
        fail("PLXC_EXT_WE source unclear")

    for f in (
        "rtl/plex_chrome.sv",
        "rtl/plex_chrome_host_if.sv",
        "rtl/plex_chrome_ddr_loader.sv",
        "rtl/plex_chrome_plxc_cdc.sv",
    ):
        if f not in QIP:
            fail(f"files.qip missing {f}")
    else:
        ok("files.qip chrome set")

    if "16.16" not in CHROME and "16.16 Hz" not in CHROME:
        fail("chrome missing 16.16 Hz refresh honesty note")
    else:
        ok("refresh honesty (16.16 trap) documented")

    if fails:
        print(f"test_plex_chrome_compose_static: {fails} FAIL(s)", file=sys.stderr)
        return 1
    print("test_plex_chrome_compose_static: PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main())
