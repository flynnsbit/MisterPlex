#!/usr/bin/env python3
"""Pre-fit survival gate for multi-pixel 720p (no STA slack claims).

Checks SDC async_fifo false_path, RTL CDC/hierarchy markers, H/edge arithmetic,
and 720p60 @4ppc rate table. Negative STA slack is parent's post-fit-timing job.
"""
from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path


def die(msg: str, rc: int = 1) -> None:
    print(f"PRESENT_720P_FIT_REJECTED(exit={rc}): {msg}", file=sys.stderr)
    raise SystemExit(rc)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--root", type=Path, default=Path("."))
    ap.add_argument(
        "--contract",
        type=Path,
        default=Path("assets/present_720p_fit_contract.json"),
    )
    args = ap.parse_args()
    root = args.root.resolve()
    cpath = args.contract if args.contract.is_absolute() else root / args.contract
    try:
        contract = json.loads(cpath.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        die(f"contract: {exc}", 2)

    fails: list[str] = []
    print("PRESENT_720P_FIT_BEGIN")

    # --- SDC ---
    sdc_rel = contract["sdc"]["plex_sdc"]
    sdc_path = root / sdc_rel
    if not sdc_path.is_file():
        fails.append(f"missing {sdc_rel}")
        sdc = ""
    else:
        sdc = sdc_path.read_text(encoding="utf-8", errors="ignore")
    for sub in contract["sdc"]["require_false_path_substrings"]:
        if sub not in sdc:
            fails.append(f"Plex.sdc missing false_path marker {sub!r}")
        else:
            print(f"SDC_OK {sub}")
    # Must be a set_false_path involving both ends (not commented-out only).
    fp_ok = bool(
        re.search(
            r"set_false_path\s*\\\s*\n\s*-from\s+\[get_keepers\s+\{\*async_fifo\*mem\*\}\]",
            sdc,
        )
        or (
            "set_false_path" in sdc
            and "async_fifo*mem" in sdc
            and "async_fifo*rd_data_r" in sdc
            and not re.search(
                r"^\s*#\s*set_false_path[^\n]*async_fifo\*mem",
                sdc,
                flags=re.M,
            )
        )
    )
    # Stronger: active (non-comment) line with set_false_path near async_fifo
    active_fp = False
    for line in sdc.splitlines():
        code = line.split("#", 1)[0].strip()
        if "set_false_path" in code:
            active_fp = True
    if not (active_fp and "async_fifo*mem" in sdc and "async_fifo*rd_data_r" in sdc):
        fails.append("Plex.sdc lacks active set_false_path async_fifo mem→rd_data_r")
    else:
        print("SDC_OK active_async_fifo_false_path")

    # --- RTL markers ---
    rtl = contract["rtl_markers"]
    pc = root / rtl["present_core"]
    pct = pc.read_text(encoding="utf-8", errors="ignore") if pc.is_file() else ""
    if not pc.is_file():
        fails.append(f"missing {rtl['present_core']}")
    for m in rtl["must_contain"]:
        if m not in pct:
            fails.append(f"present_core missing {m!r}")
        else:
            print(f"RTL_OK present_core:{m[:40]}")
    # Macro must not be bare-defined ON
    no_block = re.sub(r"/\*.*?\*/", "", pct, flags=re.S)
    for line in no_block.splitlines():
        code = line.split("//", 1)[0]
        if re.search(r"`define\s+PRESENT_MULTI_PIXEL\b", code):
            fails.append("present_core bare `define PRESENT_MULTI_PIXEL (must default OFF)")
            break

    npx_p = root / rtl["present_npx_path"]
    npx_t = npx_p.read_text(encoding="utf-8", errors="ignore") if npx_p.is_file() else ""
    if not npx_p.is_file():
        fails.append(f"missing {rtl['present_npx_path']}")
    for m in rtl["npx_must_contain"]:
        if m not in npx_t:
            fails.append(f"present_npx_path missing {m!r}")
        else:
            print(f"RTL_OK npx:{m}")

    lb = root / rtl["line_buf"]
    lbt = lb.read_text(encoding="utf-8", errors="ignore") if lb.is_file() else ""
    if not lb.is_file():
        fails.append(f"missing {rtl['line_buf']}")
    for m in rtl["line_buf_must_contain"]:
        if m not in lbt:
            fails.append(f"line_buf_ram missing {m!r}")
        else:
            print(f"RTL_OK line_buf:{m}")

    # --- Edge arithmetic ---
    e = contract["edge_arith"]
    h_de, h_tot = int(e["h_de"]), int(e["h_total"])
    checks = {
        "h_de_mod_8": h_de % 8,
        "h_de_mod_2": h_de % 2,
        "h_de_mod_4": h_de % 4,
        "h_total_mod_2": h_tot % 2,
        "h_total_mod_4": h_tot % 4,
        "last_y_qword_index": h_de // 8 - 1,
    }
    for k, got in checks.items():
        want = int(e[k])
        if got != want:
            fails.append(f"edge {k}: got {got} want {want}")
        else:
            print(f"EDGE_OK {k}={got}")
    # Aligned last groups stay in one qword
    for ppc in (2, 4):
        x0 = h_de - ppc
        q0 = x0 // 8
        q1 = (h_de - 1) // 8
        if q0 != q1:
            fails.append(f"last DE group ppc={ppc} straddles Y qword {q0}..{q1}")
        else:
            print(f"EDGE_OK last_group_ppc{ppc}_qword={q0}")

    # --- Rates ---
    r = contract["rates_mhz"]
    cea = 1650 * 750 * 60 / 1e6
    if abs(cea - float(r["cea_720p60"])) > float(contract["tolerance_mhz"]):
        fails.append(f"cea_720p60 rate {cea} != contract {r['cea_720p60']}")
    ppc4 = cea / 4.0
    if abs(ppc4 - float(r["cea_720p60_ppc4"])) > float(contract["tolerance_mhz"]):
        fails.append(f"ppc4 {ppc4} != {r['cea_720p60_ppc4']}")
    else:
        print(f"RATE_OK cea720p60_ppc4={ppc4:.4f}")
    if float(r["cea_720p60_ppc2"]) <= float(r["nostub_fmax_parent"]):
        fails.append("contract must keep cea60_ppc2 FAIL vs nostub")
    if float(r["cea_720p60_ppc4"]) >= float(r["ship_clk_sys"]):
        # 18.56 < 20 → OK fabric
        fails.append("cea60_ppc4 should be under ship 20 for OK_FABRIC_ONLY")
    if r["verdict_cea60_ppc2_vs_nostub"] != "FAIL":
        fails.append("verdict_cea60_ppc2_vs_nostub must be FAIL (no self-weaken)")
    if r["verdict_same_clock_out_74"] != "FAIL_NEED_CLK_PIX":
        fails.append("must not claim same-clock 74.25 out")
    print(
        f"VERDICT cea60_ppc2={r['verdict_cea60_ppc2_vs_nostub']} "
        f"cea60_ppc4_fabric={r['verdict_cea60_ppc4_vs_ship20']} "
        f"same_clk_out={r['verdict_same_clock_out_74']}"
    )

    # DDR BW sanity
    bw = contract["ddr_bw_mib_s"]
    frame = 1280 * 720 * 1.5
    b60 = frame * 60 / 1e6
    if abs(b60 - float(bw["yuv420_720p60"])) > 0.01:
        fails.append(f"ddr bw60 {b60} != {bw['yuv420_720p60']}")
    else:
        print(f"BW_OK yuv420_720p60={b60:.3f} MB/s vs peak {bw['clk_ddr_peak_90x8']}")

    print("PRESENT_720P_FIT_END")
    if fails:
        for f in fails:
            print(f"FAIL: {f}", file=sys.stderr)
        die(f"{len(fails)} check(s) failed", 1)
    print("PASS present_720p_fit_contract")
    print(
        "NOTE: STA slack unknown until parent make post-fit-timing on integration RBF"
    )
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except BrokenPipeError:
        raise SystemExit(0)
