#!/usr/bin/env python3
"""Ensure clk_pix STA prereg exists and encodes hard fail cuts (no device)."""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path


def die(msg: str, rc: int = 1) -> None:
    print(f"CLK_PIX_STA_PREREG_REJECTED(exit={rc}): {msg}", file=sys.stderr)
    raise SystemExit(rc)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--root", type=Path, default=Path("."))
    ap.add_argument(
        "--contract",
        type=Path,
        default=Path("assets/clk_pix_sta_prereg.json"),
    )
    args = ap.parse_args()
    root = args.root.resolve()
    path = args.contract if args.contract.is_absolute() else root / args.contract
    try:
        c = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        die(f"prereg: {exc}", 2)

    fails: list[str] = []
    print("CLK_PIX_STA_PREREG_BEGIN")

    if c.get("hard_rule") != "negative_slack_equals_hard_fail":
        fails.append("hard_rule must be negative_slack_equals_hard_fail")
    else:
        print("RULE_OK negative_slack_hard_fail")

    s0 = c["stage0_multipixel_same_clock"]["pass"]
    if float(s0["fmax_clk_sys_mhz_min"]) > 20.0:
        fails.append("stage0 must not demand clk_sys Fmax > 20 (constrained rate)")
    if float(s0["fmax_clk_sys_mhz_min"]) < 20.0:
        fails.append("stage0 must require Fmax_sys >= 20")
    if float(s0["setup_slack_clk_sys_ns_min"]) > 0:
        fails.append("do not require positive slack margin as hard cut without evidence")
    print(f"STAGE0_OK fmax_sys_min={s0['fmax_clk_sys_mhz_min']}")

    s1 = c["stage1_pix24"]["pass"]
    if abs(float(s1["fmax_clk_pix_mhz_min"]) - 29.7) > 0.001:
        fails.append("stage1 fmax_pix_min must be 29.7")
    else:
        print("STAGE1_OK fmax_pix_min=29.7")
    if float(s1["fmax_clk_sys_mhz_min"]) != 20.0:
        fails.append("stage1 must keep clk_sys min 20")
    if not s1.get("no_whole_domain_false_path_sys_pix", False):
        fails.append("must forbid whole-domain false_path sys↔pix")
    else:
        print("STAGE1_OK no_whole_domain_false_path")

    s2 = c["stage2_pix60"]["pass"]
    if abs(float(s2["fmax_clk_pix_mhz_min"]) - 74.25) > 0.001:
        fails.append("stage2 fmax_pix_min must be 74.25")
    else:
        print("STAGE2_OK fmax_pix_min=74.25")

    doc = root / ".agent-work/w-clock/CLK_PIX_SHIPPING_GATE.md"
    if not doc.is_file():
        fails.append("missing CLK_PIX_SHIPPING_GATE.md")
    else:
        t = doc.read_text(encoding="utf-8", errors="replace")
        for n in ("29.700000 MHz", "74.250000 MHz", "underrun", "pre-registered", "INCLUDE_SYNC"):
            if n not in t:
                fails.append(f"shipping gate doc missing {n}")
        print("DOC_OK CLK_PIX_SHIPPING_GATE.md")

    # Must not claim multi-pixel Fmax known
    unk = c["stage0_multipixel_same_clock"].get("explicitly_unknown_until_fit", [])
    if not any("Fmax" in u or "fmax" in u.lower() for u in unk):
        fails.append("must list multi-pixel Fmax as unknown until fit")
    else:
        print("HONEST_OK multipixel_fmax_unknown")

    print("CLK_PIX_STA_PREREG_END")
    if fails:
        for f in fails:
            print(f"  FAIL: {f}", file=sys.stderr)
        die(f"{len(fails)} check(s) failed", 1)
    print("PASS clk_pix_sta_prereg")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
