#!/usr/bin/env python3
"""Static geometry audit for plex_chrome HDMI_OUT 720p path (w-osd).

Positive: product counters are 12-bit (or wider via XW=12), layout from
HDMI_WIDTH/HEIGHT ACTIVE ports (not H_TOTAL), no bare 640/480 paint canvas,
compose present. Documents 720p24 compact totals (1600×750@28.8) vs ACTIVE.

Negative: FAULT_NARROW_BEAM_X (10b wrap); FAULT_LAYOUT_FROM_HTOTAL must drive
layout_w (total-derived centering trap). Dead fault params fail this gate.

true rc: python3 ...; echo "true rc=$?"
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
CHROME = (ROOT / "fpga/Plex_MiSTer/rtl/plex_chrome.sv").read_text()
SYS = (ROOT / "fpga/Plex_MiSTer/sys/sys_top.v").read_text()
QIP = (ROOT / "fpga/Plex_MiSTer/files.qip").read_text()


def main() -> int:
    fails = 0

    def fail(m: str) -> None:
        nonlocal fails
        fails += 1
        print(f"FAIL: {m}", file=sys.stderr)

    def ok(m: str) -> None:
        print(f"OK: {m}")

    # --- audit table (quoted) ---
    checks = [
        (
            "x_cnt width product 12b",
            r"localparam\s+int\s+XW\s*=\s*FAULT_NARROW_BEAM_X\s*\?\s*10\s*:\s*12",
            "plex_chrome.sv: XW ternary 10:12",
        ),
        (
            "y_cnt 12b",
            r"reg\s+\[11:0\]\s+y_cnt",
            "plex_chrome.sv: y_cnt[11:0]",
        ),
        (
            "HDMI beam ports 12b",
            r"input\s+wire\s+\[11:0\]\s+HDMI_WIDTH",
            "plex_chrome.sv: HDMI_WIDTH[11:0]",
        ),
        (
            "layout tracks beam ACTIVE",
            r"layout_w\s*=\s*[\s\S]{0,400}?HDMI_WIDTH",
            "plex_chrome.sv: layout_w ← HDMI_WIDTH (product ACTIVE)",
        ),
        (
            "body_scale /240",
            r"h\s*/\s*12'd240",
            "plex_chrome.sv: body_scale_f half-even /240",
        ),
        (
            "cmd x compare 16b",
            r"\{4'd0,\s*px\}\s*>=\s*cx",
            "plex_chrome.sv: px widened to 16b vs cmd x",
        ),
        (
            "narrow fault present",
            r"parameter\s+bit\s+FAULT_NARROW_BEAM_X\s*=\s*1'b0",
            "plex_chrome.sv: FAULT_NARROW_BEAM_X default 0",
        ),
        (
            "htotal layout fault present",
            r"parameter\s+bit\s+FAULT_LAYOUT_FROM_HTOTAL\s*=\s*1'b0",
            "plex_chrome.sv: FAULT_LAYOUT_FROM_HTOTAL default 0",
        ),
        (
            "htotal default 1600 compact",
            r"parameter\s+int\s+FAULT_HTOTAL_W\s*=\s*1600",
            "plex_chrome.sv: FAULT_HTOTAL_W=1600 (720p24 compact)",
        ),
        (
            "compose chain",
            r"u_plex_chrome",
            "sys_top.v: u_plex_chrome instance",
        ),
        (
            "qip lists chrome",
            r"rtl/plex_chrome\.sv",
            "files.qip: plex_chrome.sv",
        ),
    ]

    print("=== chrome 720p geometry audit ===")
    print(
        "ACTIVE 1280×720 | CORE_DE compact H_TOTAL=1600 V_TOTAL=750 @28.8 MHz "
        "(H_BLANK=320); retired compact 1650 blank=370; CEA VIC4 1650@74.25 still ok"
    )
    for name, pat, where in checks:
        if "sys_top" in where:
            src = SYS
        elif "files.qip" in where:
            src = QIP
        else:
            src = CHROME
        if re.search(pat, src, re.M):
            ok(f"{name} @ {where}")
        else:
            fail(f"{name} missing @ {where}")

    # 11-bit is enough for 0..1279 — document so nobody "fixes" 12→11 wrongly.
    # Trap is 10-bit. Product must not use bare reg [9:0] x_cnt.
    if re.search(r"reg\s+\[9:0\]\s+x_cnt", CHROME):
        fail("product x_cnt is 10-bit bare (wraps before 1280)")
    else:
        ok("no bare 10-bit product x_cnt")

    # Bare screen-dimension literals used as paint canvas (not fault/layout helpers)
    # Allow FAULT_* and comments; reject `HDMI_WIDTH = 12'd640` style product pins.
    if re.search(r"HDMI_WIDTH\s*=\s*12'd(?:640|624|480|1600|1650)\b", CHROME):
        fail("HDMI_WIDTH hardcoded to legacy/total width")
    else:
        ok("HDMI_WIDTH not hardcoded legacy/total")

    # H_TOTAL-derived values: product must NOT center on total.
    # idle_ox uses layout_w; product layout_w = HDMI_WIDTH (ACTIVE).
    if not re.search(r"idle_ox\s*=\s*\(layout_w\s*-", CHROME):
        fail("idle_ox not from layout_w (expected ACTIVE-centered)")
    else:
        ok("idle_ox from layout_w (ACTIVE when faults off)")

    # Pipeline: 1-cycle dout — comment contract
    if "1-cycle" not in CHROME and "1 cycle" not in CHROME:
        fail("missing 1-cycle pipeline contract comment")
    else:
        ok("1-cycle pipeline contract mentioned")

    # NEGATIVE: fault params must drive logic (not dead)
    if "FAULT_NARROW_BEAM_X" in CHROME and not re.search(
        r"XW\s*=\s*FAULT_NARROW_BEAM_X", CHROME
    ):
        fail("FAULT_NARROW_BEAM_X declared but not driving XW (tautological)")
    else:
        ok("FAULT_NARROW_BEAM_X drives XW")

    if not re.search(
        r"FAULT_LAYOUT_FROM_HTOTAL\s*\?\s*FAULT_HTOTAL_W", CHROME
    ):
        fail("FAULT_LAYOUT_FROM_HTOTAL declared but not driving layout_w")
    else:
        ok("FAULT_LAYOUT_FROM_HTOTAL drives layout_w")

    # Math control: ACTIVE vs TOTAL origins (not executed RTL — arithmetic pin)
    size = min(1280, 720) // 3  # 240
    ox_act = (1280 - size) // 2  # 520
    ox_1600 = (1600 - size) // 2  # 680
    ox_1650 = (1650 - size) // 2  # 705
    if ox_act != 520 or ox_1600 != 680:
        fail(f"origin math drift act={ox_act} tot1600={ox_1600}")
    else:
        ok(f"origin math ACTIVE ox={ox_act} HTOTAL1600 ox={ox_1600} (Δ{ox_1600 - ox_act})")
    if (ox_1650 - ox_1600) != 25:
        fail(f"1650→1600 center delta expected 25 got {ox_1650 - ox_1600}")
    else:
        ok("1650→1600 center Δ=25; blank Δ=50 (parent blank shrink)")

    if fails:
        print(f"test_plex_chrome_geom_audit_static: {fails} FAIL(s)", file=sys.stderr)
        return 1
    print("test_plex_chrome_geom_audit_static: PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main())
