#!/usr/bin/env python3
"""PRESENT PPC2 fit blocker (rd-duck): synthesis can green while picture is wrong.

Quoted defect class (w-scaler present_core.sv):
  - PPC!=1 $error is under synthesis translate_off (sim-only; Quartus ignores)
  - mp_npx_{r,g,b} = {PRESENT_PPC{fr/fg/fb}} duplicates scalar store sample
  - MULTI glass x/y unused; fstore still on legacy store_x/y Template path

Fit release must NOT treat PPC2 as follow-up. This gate:
  - Always prints BLOCKER_PRESENT_PPC2 status
  - If QSF claims MULTI + PPC>=2 while hollow patterns remain → exit 1
  - If PPC>=2 claimed without dual-lane store contract markers → exit 1
  - Prints PARTIAL_CLOSED_READER / fabric_bw_closed=false until odd/even proof
  - Soft-skip 77 is never a pass

rd-duck (corrected): w-clock/dc2ae85d *does* instantiate PX_PER_CLK=2 and
rd_*_n (scalar-instantiation claim WITHDRAWN). Narrower NACK stands:
  - C++ scorer never observes rd_*_n, lane-valid, RGB, or underrun
  - w-scaler scalar *adaptation* can yield identical accepted-request/beat counts
  - accepted-request counts prove refill *demand*, not PPC2 output correctness
    or deadline
Split:
  - accepted-request steady delta: may be CLOSED (demand metric)
  - PPC2 delivery/correctness + shared-controller BW: OPEN
  - fabric_bw_closed=false until shared-controller BW proven
  - PPC2_READER_CORRECTNESS_CLOSED=false until scorer observes lanes/RGB/underrun
    and odd/even (or equivalent) discrimination vs scalar control
A true PPC2 correctness gate must FAIL a scalar negative control via
odd/even output checksum / lane-valid — not via request-count match alone.

Exit: 0 = blocker documented and no false PPC2 claim; 1 = hollow PPC2 claim; 2 = bad inputs
"""
from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def parse_qsf_macros(qsf: Path) -> dict[str, str]:
    macros: dict[str, str] = {}
    if not qsf.is_file():
        return macros
    for line in qsf.read_text(errors="ignore").splitlines():
        s = line.strip()
        if s.startswith("#") or "VERILOG_MACRO" not in s:
            continue
        # strip trailing comments
        if "#" in s:
            # keep quoted region only
            pass
        m = re.search(r'VERILOG_MACRO\s+"([^"=]+)(?:=([^"]*))?"', s)
        if not m:
            continue
        # ignore fully commented assignments: line must not start with #
        if line.lstrip().startswith("#"):
            continue
        name, val = m.group(1), (m.group(2) if m.group(2) is not None else "1")
        macros[name] = val
    return macros


def find_hollow_patterns(text: str) -> list[str]:
    hits: list[str] = []
    # sim-only PPC!=1 guard
    if re.search(
        r"synthesis\s+translate_off[\s\S]{0,400}?PRESENT_PPC\s*!=\s*1[\s\S]{0,200}?\$error",
        text,
        re.I,
    ):
        hits.append("sim_only_ppc_ne_1_error_under_translate_off")
    # scalar replicate into N lanes
    if re.search(r"mp_npx_r\s*=\s*\{PRESENT_PPC\{fr\}\}", text):
        hits.append("scalar_fr_replicated_to_mp_npx_r")
    if re.search(r"mp_npx_g\s*=\s*\{PRESENT_PPC\{fg\}\}", text):
        hits.append("scalar_fg_replicated_to_mp_npx_g")
    if re.search(r"mp_npx_b\s*=\s*\{PRESENT_PPC\{fb\}\}", text):
        hits.append("scalar_fb_replicated_to_mp_npx_b")
    # glass unused + legacy store
    if "_unused_mp_glass" in text and re.search(
        r"fstore still wired to store_x|store_x/y from Template|legacy Template",
        text,
        re.I,
    ):
        hits.append("multi_glass_unused_fstore_legacy_store_xy")
    elif "_unused_mp_glass" in text:
        hits.append("multi_glass_coords_marked_unused")
    return hits


def has_dual_lane_contract_markers(text: str) -> bool:
    """Positive markers that hollow PPC2 was replaced — require several.

    Markers alone never set fabric_bw_closed or PPC2_READER_CORRECTNESS_CLOSED.
    Odd/even checksum + scalar NEG control must exist in the *test* path too.
    """
    markers = [
        r"dual_lane_store",
        r"store_x0",
        r"store_x1",
        r"odd_even.*checksum|checksum.*odd_even|lane_valid",
        r"mp_npx_r\s*=\s*\{[^}]*fr1|lane1_r|px1_r",
        r"scalar_neg_control|SCALAR_NEG|fail_scalar",
    ]
    return sum(1 for p in markers if re.search(p, text, re.I)) >= 2


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--root", type=Path, default=ROOT)
    ap.add_argument("--present-core", type=Path, default=None)
    ap.add_argument("--qsf", type=Path, default=None)
    ap.add_argument("--self-test", action="store_true")
    args = ap.parse_args(argv[1:])

    root = args.root.resolve()
    qsf = args.qsf or (root / "fpga/Plex_MiSTer/Plex.qsf")
    pc = args.present_core or (root / "fpga/Plex_MiSTer/rtl/present_core.sv")

    print("PRESENT_PPC2_FIT_BLOCKER_EXECUTED")
    print(f"ROOT={root}")
    print(f"QSF={qsf}")
    print(f"PRESENT_CORE={pc}")

    if args.self_test:
        hollow = """
// synthesis translate_off
initial begin
  if (PRESENT_PPC != 1)
    $error("PRESENT_MULTI_PIXEL land requires PRESENT_PX_PER_CLK=1");
end
// synthesis translate_on
wire [PRESENT_PPC*8-1:0] mp_npx_r = {PRESENT_PPC{fr}};
wire [PRESENT_PPC*8-1:0] mp_npx_g = {PRESENT_PPC{fg}};
wire [PRESENT_PPC*8-1:0] mp_npx_b = {PRESENT_PPC{fb}};
wire _unused_mp_glass = |{mp_glass_x0, mp_glass_y};
// Note: fstore still wired to store_x/y from Template regs above
"""
        h = find_hollow_patterns(hollow)
        assert "sim_only_ppc_ne_1_error_under_translate_off" in h
        assert "scalar_fr_replicated_to_mp_npx_r" in h
        assert "multi_glass_unused_fstore_legacy_store_xy" in h
        print("SELFTEST_HOLLOW_DETECT ok", h)
        print("PASS PRESENT_PPC2_FIT_BLOCKER self-test")
        return 0

    if not pc.is_file():
        print(f"FAIL missing present_core {pc}", file=sys.stderr)
        return 2

    text = pc.read_text(errors="ignore")
    macros = parse_qsf_macros(qsf)
    multi = macros.get("PRESENT_MULTI_PIXEL") == "1" or "PRESENT_MULTI_PIXEL" in macros and macros.get(
        "PRESENT_MULTI_PIXEL", ""
    ) in ("1", "")
    # present if key exists with 1
    multi = False
    for k, v in macros.items():
        if k == "PRESENT_MULTI_PIXEL" and v in ("1", ""):
            multi = True
    ppc = 1
    if "PRESENT_PX_PER_CLK" in macros:
        try:
            ppc = int(macros["PRESENT_PX_PER_CLK"])
        except ValueError:
            ppc = -1

    hollow = find_hollow_patterns(text)
    dual_ok = has_dual_lane_contract_markers(text)

    print(f"QSF_PRESENT_MULTI_PIXEL={int(multi)}")
    print(f"QSF_PRESENT_PX_PER_CLK={ppc}")
    print(f"HOLLOW_PATTERNS={hollow}")
    print(f"DUAL_LANE_CONTRACT_MARKERS={int(dual_ok)}")

    # Always an explicit fit blocker until dual-lane contract + synthesis-active gate.
    print("BLOCKER_PRESENT_PPC2=required")
    print("PPC2_STATUS=PARTIAL_CLOSED_READER")
    print("PPC2_ACCEPTED_REQUEST_STEADY_DELTA=CLOSED_IF_PROVEN  # demand metric only (rd-duck)")
    print("fabric_bw_closed=false  # shared-controller BW OPEN")
    print("PPC2_READER_CORRECTNESS_CLOSED=false  # delivery/correctness OPEN")
    print("PPC2_DEADLINE_CLOSED=false")
    print("PPC2_ACCEPT_dual_lane_store_outputs=required")
    print("PPC2_ACCEPT_multi_beam_to_store_coords=required")
    print("PPC2_ACCEPT_odd_even_distinct_pixel_checksum=required")
    print("PPC2_ACCEPT_synthesis_active_recipe_gate=required  # not translate_off $error")
    print("PPC2_ACCEPT_scorer_observes_rd_n_lane_rgb_underrun=required")
    print("PPC2_ACCEPT_scalar_NEG_control=required  # must FAIL scalar; count match insufficient")
    print("NOTE: rd-duck RETRACTED 'dc2ae85d is scalar' — w-clock has PX_PER_CLK=2 + rd_*_n")
    print("NOTE: narrower NACK: C++ scorer never watches rd_*_n/lane-valid/RGB/underrun")
    print("NOTE: scaler scalar adaptation can match beat counts — proves demand not correctness")
    print("NOTE: do not call PPC2 reader/delivery closed on accepted-request counts alone")
    print("NOTE: DMA source->bank mover is R+W; prefer dynamic-base direct fabric read")

    fail = 0
    if multi and ppc >= 2:
        if hollow:
            print(
                "FAIL PRESENT_PPC2_HOLLOW_CLAIM: QSF MULTI+PPC>=2 while present_core "
                f"still has hollow patterns {hollow}",
                file=sys.stderr,
            )
            fail = 1
        if not dual_ok:
            print(
                "FAIL PRESENT_PPC2_NO_DUAL_LANE_CONTRACT: QSF claims PPC>=2 without "
                "dual-lane store contract markers in present_core",
                file=sys.stderr,
            )
            fail = 1
        if fail:
            print("FIT_SLOT_GRANT=NO  # PPC2 hollow or incomplete")
            return 1
        print("PRESENT_PPC2_CLAIM_MARKERS_OK still requires sim checksum + synthesis gate evidence")
    elif hollow:
        print(
            "PRESENT_PPC2_STATUS=hollow_patterns_present_ppc1_or_multi_off "
            "— blocker remains; do not fit PPC2"
        )
    else:
        print("PRESENT_PPC2_STATUS=no_hollow_markers_in_tree — still require accept checklist before PPC2 fit")

    print("PASS PRESENT_PPC2_FIT_BLOCKER (no false PPC2 claim; PARTIAL_CLOSED_READER; fabric_bw_closed=false)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
