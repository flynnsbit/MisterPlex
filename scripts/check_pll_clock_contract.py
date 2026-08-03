#!/usr/bin/env python3
"""Enforce fabric PLL shipping contract + 720p overclock arithmetic gates.

Source of truth for applied frequencies is pll_0002.v (NOT stale pll.v megawizard
strings). This gate:

1. Parses pll_0002.v out0/out2/ref and requires they match assets/pll_clock_contract.json
   shipping values (blocks accidental untested PLL bumps).
2. Recomputes the min related-edge Δ between clk_sys and clk_ddr and checks the
   contract table + Plex.sdc comment stay consistent with shipping.
3. Derives the 720p present-path clk_sys need from colorbars H_TOTAL and states
   the ceiling vs measured Fmax (no invented STA).
4. Optional --sta-rpt: require clk_sys/clk_ddr Fmax ≥ constrained shipping rates
   and, if a proposed target is --activate-target NAME, ≥ that target (fit grant).

Exit codes:
  0  PASS
  1  FAIL contract / arithmetic / STA floor
  2  usage / bad inputs
  77 SKIP-NOT-PASS only when --sta-rpt given but unreadable (unit path never skips
     the PLL file check)
"""
from __future__ import annotations

import argparse
import json
import math
import re
import sys
from pathlib import Path

SKIP_RC = 77


def load_json(path: Path) -> dict:
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        print(f"PLL_CONTRACT_REFUSED(exit=2): {path}: {exc}", file=sys.stderr)
        raise SystemExit(2) from exc
    if not isinstance(data, dict):
        print(f"PLL_CONTRACT_REFUSED(exit=2): {path} not an object", file=sys.stderr)
        raise SystemExit(2)
    return data


def parse_pll_mhz(pll_path: Path) -> dict[str, float]:
    text = pll_path.read_text(errors="ignore")
    def grab(key: str) -> float:
        # Match .reference_clock_frequency("50.0 MHz") or output_clock_frequency0("20.000000 MHz")
        pat = rf'\.{re.escape(key)}\("([0-9]+(?:\.[0-9]+)?)\s*MHz"\)'
        m = re.search(pat, text)
        if not m:
            raise ValueError(f"missing {key} in {pll_path}")
        return float(m.group(1))

    return {
        "reference_mhz": grab("reference_clock_frequency"),
        "clk_sys_mhz": grab("output_clock_frequency0"),
        "clk_ddr_mhz": grab("output_clock_frequency2"),
    }


def min_related_edge_ns(f_sys: float, f_ddr: float, max_mult: int = 800) -> float:
    """Minimum positive |i/f_sys - j/f_ddr| in nanoseconds (rising edges)."""
    best: float | None = None
    for i in range(0, max_mult + 1):
        for j in range(0, max_mult + 1):
            if i == 0 and j == 0:
                continue
            d_us = i / f_sys - j / f_ddr
            if d_us <= 1e-15:
                continue
            d_ns = d_us * 1000.0
            if best is None or d_ns < best - 1e-12:
                best = d_ns
    if best is None:
        raise RuntimeError("related-edge search failed")
    return best


def parse_fmax_mhz(sta_path: Path) -> dict[str, float]:
    """Map clock name → Fmax MHz from Quartus Fmax Summary."""
    text = sta_path.read_text(errors="ignore")
    out: dict[str, float] = {}
    in_fmax = False
    saw_header = False
    for line in text.splitlines():
        if line.startswith("; Fmax Summary"):
            in_fmax = True
            saw_header = False
            continue
        if in_fmax and "Fmax" in line and "Clock Name" in line:
            saw_header = True
            continue
        if in_fmax and saw_header and line.startswith("+---"):
            # end after first separator following rows; keep scanning until blank after rows
            if out:
                break
            continue
        if in_fmax and saw_header and line.startswith(";"):
            parts = [c.strip() for c in line.strip().strip(";").split(";")]
            if len(parts) >= 3 and parts[0] and parts[0] != "Fmax":
                try:
                    fmax = float(re.search(r"[0-9]+(?:\.[0-9]+)?", parts[0]).group(0))  # type: ignore[union-attr]
                except (AttributeError, ValueError):
                    continue
                clock = parts[2] if len(parts) > 2 else parts[1]
                out[clock] = fmax
    return out


def find_fmax(fmax_map: dict[str, float], needle: str) -> float | None:
    for name, val in fmax_map.items():
        if needle in name:
            return val
    return None


def approx_equal(a: float, b: float, tol: float) -> bool:
    return abs(a - b) <= tol


def check_720p_arithmetic(contract: dict, failures: list[str]) -> None:
    pt = contract.get("present_timing") or {}
    h_total = int(pt.get("H_TOTAL", 638))
    reqs = contract.get("p720_clk_sys_requirements") or {}
    native = reqs.get("native_720_line_de_template_h_60hz") or {}
    cands = native.get("V_TOTAL_candidates") or {}
    print("P720_CLK_ARITH_BEGIN")
    print(f"| mode | formula | clk_sys_mhz |")
    print(f"|---|---|---:|")
    for v_tot_s, expected in sorted(cands.items(), key=lambda kv: int(kv[0])):
        v_tot = int(v_tot_s)
        got = h_total * v_tot * 60 / 1e6
        exp = float(expected)
        status = "ok" if approx_equal(got, exp, 0.02) else "MISMATCH"
        print(f"| 720-line DE H={h_total} V={v_tot} @60 | {h_total}*{v_tot}*60 | {got:.4f} |")
        if status != "ok":
            failures.append(
                f"720p arith V={v_tot}: got {got:.4f} MHz want {exp:.4f} MHz"
            )
    wide = reqs.get("native_1280_wide_de_60hz") or {}
    h_wide = int(wide.get("H_TOTAL_scaled", 1544))
    cea = float((wide.get("clk_sys_mhz_required") or {}).get("cea_60", 74.25))
    got_cea = 1650 * 750 * 60 / 1e6
    print(f"| CEA 1280x720@60 | 1650*750*60 | {got_cea:.4f} |")
    if not approx_equal(got_cea, cea, 0.02):
        failures.append(f"CEA 720p60 arith got {got_cea:.4f} want {cea}")
    got_wide60 = h_wide * 750 * 60 / 1e6
    exp_wide60 = float((wide.get("clk_sys_mhz_required") or {}).get("scaled_porch_60", 69.48))
    print(f"| 1280-DE scaled H={h_wide} V=750 @60 | {h_wide}*750*60 | {got_wide60:.4f} |")
    if not approx_equal(got_wide60, exp_wide60, 0.05):
        failures.append(f"1280 DE 60 arith got {got_wide60:.4f} want {exp_wide60}")
    bw = reqs.get("ddr_bw_720p24_yuv420") or {}
    frame = int(bw.get("frame_bytes", 1382400))
    mb_s = frame * 24 / 1e6
    exp_mb = float(bw.get("mb_s", 33.1776))
    print(f"| DDR 720p24 YUV420 | {frame}*24/1e6 | {mb_s:.4f} MB/s |")
    if not approx_equal(mb_s, exp_mb, 0.05):
        failures.append(f"720p24 BW got {mb_s:.4f} want {exp_mb}")
    # Fabric-decode cy/MB budgets (mandate: evacuate ARM decode)
    fd = reqs.get("fabric_decode_720p24") or {}
    mb_pf = int(fd.get("mb_per_frame", 3600))
    ref_cy = float(fd.get("reference_cy_per_mb", 259.391))
    budgets = fd.get("budget_cy_per_mb") or {}
    for fsys_s, exp_budget in sorted(budgets.items(), key=lambda kv: float(kv[0])):
        fsys = float(fsys_s)
        got_budget = (fsys * 1e6 / 24.0) / mb_pf
        print(
            f"| fabric-decode 720p24 @{fsys:g}MHz | "
            f"({fsys}*1e6/24)/{mb_pf} | {got_budget:.2f} cy/MB |"
        )
        if not approx_equal(got_budget, float(exp_budget), 0.5):
            failures.append(
                f"fabric decode budget @{fsys:g}: got {got_budget:.2f} want {exp_budget}"
            )
    print(
        f"| fabric-decode vs ref {ref_cy:.3f} cy/MB | "
        f"20MHz={'MISS' if float(budgets.get('20', 231)) < ref_cy else 'PASS'} "
        f"30MHz={'MISS' if float(budgets.get('30', 347)) < ref_cy else 'PASS'} | — |"
    )
    if float(budgets.get("20", 231.48)) >= ref_cy:
        failures.append("contract: 20 MHz fabric-decode budget must stay MISS vs ref cy/MB")
    if float(budgets.get("30", 347.22)) < ref_cy:
        failures.append("contract: 30 MHz fabric-decode budget must PASS vs ref cy/MB")
    # Ceiling honesty vs measured nostub Fmax
    nostub = float(
        ((contract.get("measured_fmax") or {}).get("nostub_c74c6863") or {}).get(
            "clk_sys_mhz", 32.59
        )
    )
    print(f"| nostub measured Fmax (evidence) | STA c74c6863 | {nostub:.2f} |")
    print(f"| WALL: 1280-wide DE @60 1pix/clk | need ≥{got_wide60:.1f} | above Fmax |")
    print(f"| mandate end-state | fabric decode + native 720p | ARM out |")
    print("P720_CLK_ARITH_END")
    if got_wide60 <= nostub:
        failures.append(
            "contract inconsistency: 1280-wide@60 should exceed nostub Fmax ceiling"
        )


def main(argv: list[str]) -> int:
    root = Path(__file__).resolve().parents[1]
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument(
        "--contract",
        type=Path,
        default=root / "assets" / "pll_clock_contract.json",
    )
    ap.add_argument(
        "--pll",
        type=Path,
        default=root / "fpga" / "Plex_MiSTer" / "rtl" / "pll" / "pll_0002.v",
    )
    ap.add_argument(
        "--sdc",
        type=Path,
        default=root / "fpga" / "Plex_MiSTer" / "Plex.sdc",
    )
    ap.add_argument(
        "--sta-rpt",
        type=Path,
        default=None,
        help="Optional Quartus Plex.sta.rpt for Fmax floor checks",
    )
    ap.add_argument(
        "--activate-target",
        type=str,
        default=None,
        help="Name of proposed_targets key; requires STA Fmax ≥ target (fit grant path)",
    )
    ap.add_argument(
        "--allow-pll-bump",
        action="store_true",
        help="Permit pll_0002.v to differ from shipping (still checks activate-target)",
    )
    args = ap.parse_args(argv[1:])

    if not args.contract.exists():
        print(f"PLL_CONTRACT_REFUSED(exit=2): missing {args.contract}", file=sys.stderr)
        return 2
    if not args.pll.exists():
        print(f"PLL_CONTRACT_REFUSED(exit=2): missing {args.pll}", file=sys.stderr)
        return 2

    contract = load_json(args.contract)
    shipping = contract.get("shipping") or {}
    failures: list[str] = []

    try:
        pll = parse_pll_mhz(args.pll)
    except ValueError as exc:
        print(f"PLL_CONTRACT_REJECTED(exit=1): {exc}", file=sys.stderr)
        return 1

    print("PLL_CONTRACT_SHIPPING_BEGIN")
    print(
        f"| field | pll_0002.v | contract shipping |"
    )
    print("|---|---:|---:|")
    for key in ("reference_mhz", "clk_sys_mhz", "clk_ddr_mhz"):
        got = pll[key]
        want = float(shipping[key])
        ok = approx_equal(got, want, 1e-6)
        print(f"| {key} | {got:g} | {want:g} |")
        if not ok and not args.allow_pll_bump:
            failures.append(f"pll {key}={got} != shipping {want} (no ALLOW bump)")
        elif not ok and args.allow_pll_bump:
            print(f"PLL_CONTRACT_NOTE: {key} bumped under --allow-pll-bump")
    print("PLL_CONTRACT_SHIPPING_END")

    # Related edge for shipping (and live pll if bumped)
    edge_ship = min_related_edge_ns(
        float(shipping["clk_sys_mhz"]), float(shipping["clk_ddr_mhz"])
    )
    edge_live = min_related_edge_ns(pll["clk_sys_mhz"], pll["clk_ddr_mhz"])
    edge_want = float(shipping.get("related_edge_ns", 5.555556))
    print("PLL_CONTRACT_RELATED_EDGE_BEGIN")
    print(f"shipping_edge_ns={edge_ship:.6f} contract={edge_want:.6f} live_pll_edge_ns={edge_live:.6f}")
    print("PLL_CONTRACT_RELATED_EDGE_END")
    if not approx_equal(edge_ship, edge_want, 0.01):
        failures.append(
            f"shipping related edge {edge_ship:.6f} != contract {edge_want:.6f}"
        )

    # Proposed target table integrity
    print("PLL_CONTRACT_TARGETS_BEGIN")
    print("| target | sys | ddr | related_ns | recomputed | cdc_vs_data_delay |")
    print("|---|---:|---:|---:|---:|---|")
    delay_lo = float((contract.get("cdc_data_delay_class_ns") or {}).get("typical_min_ns", 3.5))
    for name, spec in (contract.get("proposed_targets") or {}).items():
        fs = float(spec["clk_sys_mhz"])
        fd = float(spec["clk_ddr_mhz"])
        edge_c = float(spec["related_edge_ns"])
        edge_r = min_related_edge_ns(fs, fd)
        if edge_r + 1e-9 < delay_lo:
            cdc = "TIGHTER_THAN_DATA_DELAY"
        elif edge_r < delay_lo + 0.5:
            cdc = "MARGINAL"
        else:
            cdc = "SETUP_HEADROOM"
        print(
            f"| {name} | {fs:g} | {fd:g} | {edge_c:.6f} | {edge_r:.6f} | {cdc} |"
        )
        if not approx_equal(edge_c, edge_r, 0.02):
            failures.append(f"target {name} related_edge contract {edge_c} != {edge_r}")
        if spec.get("status") != "PROPOSED_NOT_APPLIED" and not args.allow_pll_bump:
            failures.append(f"target {name} status must stay PROPOSED_NOT_APPLIED until fit grant")
    print("PLL_CONTRACT_TARGETS_END")

    # SDC must not claim a stale related-edge that disagrees with shipping,
    # and must name both clock rates so a bump forces a comment edit.
    if args.sdc.exists():
        sdc = args.sdc.read_text(errors="ignore")
        print("PLL_CONTRACT_SDC_BEGIN")
        if "5.556" not in sdc and "5.555" not in sdc:
            failures.append("Plex.sdc must document shipping related-edge ~5.556 ns")
            print("sdc_related_edge_comment=MISSING")
        else:
            print("sdc_related_edge_comment=present")
        if "20 MHz" not in sdc or "90 MHz" not in sdc:
            failures.append("Plex.sdc must name shipping clk_sys 20 MHz and clk_ddr 90 MHz")
            print("sdc_rate_comment=MISSING")
        else:
            print("sdc_rate_comment=present")
        if "check_pll_clock_contract" not in sdc and "pll_clock_contract" not in sdc:
            failures.append(
                "Plex.sdc must reference pll_clock_contract / check_pll_clock_contract"
            )
            print("sdc_contract_ptr=MISSING")
        else:
            print("sdc_contract_ptr=present")
        # Guard: no silent false_path expansion — only the known async_fifo cut
        fp_count = len(re.findall(r"set_false_path", sdc))
        print(f"sdc_false_path_count={fp_count}")
        if fp_count > 1:
            failures.append(
                f"Plex.sdc has {fp_count} set_false_path; only async_fifo mem→rd_data_r is authorised here"
            )
        print("PLL_CONTRACT_SDC_END")
    else:
        failures.append(f"missing SDC {args.sdc}")

    check_720p_arithmetic(contract, failures)

    # Measured Fmax table must keep the two known proof points
    mf = contract.get("measured_fmax") or {}
    for key, want in (("stub_in_8fdf440f", 23.46), ("nostub_c74c6863", 32.59)):
        got = float((mf.get(key) or {}).get("clk_sys_mhz", -1))
        if not approx_equal(got, want, 0.05):
            failures.append(f"measured_fmax {key} clk_sys {got} != {want}")

    # Optional STA floors
    if args.sta_rpt is not None:
        if not args.sta_rpt.exists():
            print(
                f"SKIP-NOT-PASS pll_clock_contract: STA absent {args.sta_rpt}",
                file=sys.stderr,
            )
            return SKIP_RC
        try:
            fmax_map = parse_fmax_mhz(args.sta_rpt)
        except OSError as exc:
            print(f"SKIP-NOT-PASS pll_clock_contract: {exc}", file=sys.stderr)
            return SKIP_RC
        if not fmax_map:
            print(
                "SKIP-NOT-PASS pll_clock_contract: no Fmax Summary rows",
                file=sys.stderr,
            )
            return SKIP_RC
        sys_f = find_fmax(fmax_map, "general[0]")
        ddr_f = find_fmax(fmax_map, "general[2]")
        print("PLL_CONTRACT_STA_FMAX_BEGIN")
        print(f"clk_sys_fmax_mhz={sys_f} clk_ddr_fmax_mhz={ddr_f}")
        print("PLL_CONTRACT_STA_FMAX_END")
        need_sys = pll["clk_sys_mhz"]
        need_ddr = pll["clk_ddr_mhz"]
        if args.activate_target:
            t = (contract.get("proposed_targets") or {}).get(args.activate_target)
            if not t:
                print(
                    f"PLL_CONTRACT_REFUSED(exit=2): unknown target {args.activate_target}",
                    file=sys.stderr,
                )
                return 2
            need_sys = float(t["clk_sys_mhz"])
            need_ddr = float(t["clk_ddr_mhz"])
        if sys_f is None or sys_f + 1e-9 < need_sys:
            failures.append(
                f"STA clk_sys Fmax {sys_f} < required {need_sys} MHz"
            )
        if ddr_f is None or ddr_f + 1e-9 < need_ddr:
            failures.append(
                f"STA clk_ddr Fmax {ddr_f} < required {need_ddr} MHz"
            )

    # Ceiling statement (always printed)
    nostub_f = float(
        ((contract.get("measured_fmax") or {}).get("nostub_c74c6863") or {}).get(
            "clk_sys_mhz", 32.59
        )
    )
    stub_f = float(
        ((contract.get("measured_fmax") or {}).get("stub_in_8fdf440f") or {}).get(
            "clk_sys_mhz", 23.46
        )
    )
    print("PLL_CONTRACT_CEILING_BEGIN")
    print(
        f"stub_in_fmax={stub_f} nostub_fmax={nostub_f} "
        f"wall_1280de_60={1650*750*60/1e6:.2f} "
        f"need_720line_template_h_60≈28.7-30.1 "
        f"preferred_target=B_30_90"
    )
    print("PLL_CONTRACT_CEILING_END")

    if failures:
        print("PLL_CONTRACT_REJECTED(exit=1):", file=sys.stderr)
        for f in failures:
            print(f"  {f}", file=sys.stderr)
        return 1

    print("PASS pll_clock_contract: shipping PLL, related-edge, 720p arith, SDC ptr OK")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
