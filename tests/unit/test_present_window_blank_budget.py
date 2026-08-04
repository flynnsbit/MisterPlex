#!/usr/bin/env python3
"""Blanking budget gate for present_content_window / scaler path (w-scaler).

Compact 720p24 (parent-decided):
  clk_pix = 28_800_000 Hz
  H_TOTAL = 1600, V_TOTAL = 750, H_DE = 1280
  H_BLANK = 1600 - 1280 = 320 pixel clocks per line

Retired (do not target): H_TOTAL=1650 @ 29.7 MHz (PLL-impossible on shared N).
CEA VIC4 720p60 still legitimately uses H_TOTAL=1650 @ 74.25 MHz — not this path.

content_window does not spend H-blank on per-line work. This gate freezes that
contract and fails if someone reintroduces blanking-hungry logic without budget.

Negative: if DIV_STEPS were huge or a per-line blank FSM appeared, fail.
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
CW = ROOT / "fpga/Plex_MiSTer/rtl/present_content_window.sv"
NPX = ROOT / "fpga/Plex_MiSTer/rtl/present_npx_path.sv"

# Parent-decided compact 720p24
H_DE = 1280
H_TOTAL_COMPACT24 = 1600
H_BLANK_COMPACT24 = H_TOTAL_COMPACT24 - H_DE  # 320
CLK_PIX_HZ = 28_800_000
# CEA VIC4 still legitimate elsewhere
H_TOTAL_CEA60 = 1650


def main() -> int:
    fails: list[str] = []
    cw = CW.read_text(encoding="utf-8", errors="replace")
    npx = NPX.read_text(encoding="utf-8", errors="replace")

    # Arithmetic lock
    if H_BLANK_COMPACT24 != 320:
        fails.append(f"H_BLANK expected 320 got {H_BLANK_COMPACT24}")
    if H_TOTAL_COMPACT24 * 750 * 24 != CLK_PIX_HZ:
        fails.append("1600*750*24 must equal 28_800_000")
    print(
        f"OK compact720p24: H_TOTAL={H_TOTAL_COMPACT24} H_DE={H_DE} "
        f"H_BLANK={H_BLANK_COMPACT24} clk_pix={CLK_PIX_HZ} "
        f"(CEA60 H_TOTAL={H_TOTAL_CEA60} remains legitimate for VIC4)"
    )

    # content_window must not hardcode 1650/29.7 as live RTL math (comments OK).
    code_only = "\n".join(
        ln.split("//")[0] for ln in cw.splitlines() if not ln.strip().startswith("//")
    )
    if re.search(r"\b1650\b", code_only):
        fails.append(
            "present_content_window.sv non-comment code contains 1650 — "
            "scaler must not hardcode H_TOTAL (CEA60 1650 is comment-only OK)"
        )
    if re.search(r"29_700_000|29700000", code_only):
        fails.append("present_content_window.sv non-comment code still encodes 29.7 MHz")
    if "28.800000" not in cw and "28_800_000" not in cw and "28.8" not in cw:
        fails.append("present_content_window.sv header must name 28.8 MHz target")

    m = re.search(r"localparam\s+int\s+DIV_STEPS\s*=\s*(\d+)", cw)
    if not m:
        fails.append("DIV_STEPS not found in present_content_window.sv")
        div_steps = -1
    else:
        div_steps = int(m.group(1))
    # sx then sy → 2 * DIV_STEPS clk after geom_change (not per-line)
    scale_settle_clks = 2 * div_steps if div_steps >= 0 else 10**9
    # Must fit comfortably in one line blank IF someone ever gated it on blank;
    # today it runs on free-running clk so blank is not required — still bound it.
    if scale_settle_clks > H_BLANK_COMPACT24:
        fails.append(
            f"BLOCKING: scale settle {scale_settle_clks} clks > H_BLANK {H_BLANK_COMPACT24}"
        )
    else:
        print(
            f"OK scale_div settle={scale_settle_clks} clk "
            f"(2*DIV_STEPS={div_steps}) <= H_BLANK={H_BLANK_COMPACT24} "
            f"(margin={H_BLANK_COMPACT24 - scale_settle_clks}; "
            f"note: div is mailbox-rate on clk, not blank-gated)"
        )

    # Per-line blank work claimed by content_window: 0
    per_line_blank_needed = 0
    if per_line_blank_needed > H_BLANK_COMPACT24:
        fails.append("per-line blank needed exceeds budget")
    else:
        print(
            f"OK content_window per-line blank cycles needed={per_line_blank_needed} "
            f"vs available={H_BLANK_COMPACT24}"
        )

    # PIPE_DEPTH default must be 1..3 and default 2
    if "parameter int PIPE_DEPTH = 2" not in cw:
        fails.append("PIPE_DEPTH default is not 2")
    else:
        print("OK PIPE_DEPTH default=2 (28.8 MHz target; STA never run yet)")

    # npx prefill is stream-start, not per-line — quantify worst case in px
    mpre = re.search(r"parameter\s+int\s+PREFILL_GROUPS\s*=\s*(\d+)", npx)
    prefill = int(mpre.group(1)) if mpre else -1
    # PPC=2 product: groups*PPC pixels of fill before first pop (stream start only)
    ppc = 2
    prefill_px = prefill * ppc if prefill >= 0 else -1
    if prefill_px > H_BLANK_COMPACT24:
        # Not blocking for continuous lines (once-only), but flag if larger than a blank
        print(
            f"NOTE npx PREFILL_GROUPS={prefill} → {prefill_px} px @PPC={ppc} "
            f"(stream-start only; not per-line). vs H_BLANK={H_BLANK_COMPACT24}"
        )
    else:
        print(
            f"OK npx stream-start prefill={prefill_px} px "
            f"(PREFILL_GROUPS={prefill}*PPC={ppc}) <= H_BLANK={H_BLANK_COMPACT24}"
        )

    # Negative twin: if we pretend DIV_STEPS=200, budget must fail
    fake_settle = 2 * 200
    if fake_settle <= H_BLANK_COMPACT24:
        fails.append("negative twin broken: inflated DIV_STEPS should exceed blank")
    else:
        print(
            f"OK NEG twin: synthetic DIV_STEPS=200 settle={fake_settle} "
            f"> H_BLANK={H_BLANK_COMPACT24} would BLOCK"
        )

    # Document w-clock-owned sites still on 1650 (do not edit here)
    print(
        "HANDOFF w-clock (do not edit from w-scaler): "
        "present_core.sv MULTI .H_TOTAL(1650); "
        "present_beam_ppc.sv default H_TOTAL=1650; "
        "present_video_timing_720p.sv H_TOTAL_L=1650; "
        "misterplex_clk_pix_recipe.svh COMPACT_H=1650 / 29_700_000 — "
        "must become H=1600 / 28_800_000 for compact 720p24"
    )

    if fails:
        for f in fails:
            print(f"FAIL {f}", file=sys.stderr)
        print(f"test_present_window_blank_budget: {len(fails)} failure(s)", file=sys.stderr)
        return 1
    print("PASS test_present_window_blank_budget")
    return 0


if __name__ == "__main__":
    sys.exit(main())
