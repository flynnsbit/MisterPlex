#!/usr/bin/env python3
"""w-clock P720 BW contract: headline is 33.1776 MB/s/dir — NACK 3.0 B/clk as DDR."""
from __future__ import annotations

import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
FIX = ROOT / "tests/fixtures/p720_bw_contract.json"
STORE = ROOT / "fpga/Plex_MiSTer/rtl/ddr_frame_store.sv"
LAYOUT = ROOT / "host/libmisterplex/ddr_frame_layout.hpp"


def main() -> int:
    c = json.loads(FIX.read_text())
    fails: list[str] = []

    h = c["headline"]
    if abs(h["value"] - 33.1776) > 1e-6:
        fails.append(f"headline must be 33.1776 MB/s, got {h['value']}")
    if h.get("unit") != "MB/s":
        fails.append("headline unit must be MB/s (not bytes/clk_sys)")

    B = c["geometry"]["i420_bytes_per_frame"]
    fps = c["geometry"]["fps"]
    if B * fps / 1e6 != 33.1776:
        fails.append("arith B*fps/1e6 != 33.1776")
    if B != 1_382_400:
        fails.append("B_frame != 1382400")

    # Fabric SoT stamp (w-clock) + three-lane P720_* alias (w-mem name lock)
    svh = ROOT / "fpga/Plex_MiSTer/rtl/misterplex_bw_contract.svh"
    p720 = ROOT / "fpga/Plex_MiSTer/rtl/plex_720p_bw_contract.svh"
    st = ROOT / "fpga/Plex_MiSTer/rtl/plex_bw_status.sv"
    if not svh.is_file():
        fails.append("missing misterplex_bw_contract.svh")
    else:
        s = svh.read_text(errors="replace")
        if "33177600" not in s and "33_177_600" not in s:
            fails.append("svh missing 33177600 / 33_177_600")
        if "MISTERPLEX_BW_NACK_DE_PEAK" not in s:
            fails.append("svh missing NACK DE peak marker")
    if not p720.is_file():
        fails.append("missing plex_720p_bw_contract.svh")
    else:
        p = p720.read_text(errors="replace")
        for needle in (
            "P720_FABRIC_RD_BPS",
            "MISTERPLEX_BW_DIR_B_PER_S",
            "reader accepted-request steady delta",
            "shared fabric BW",
        ):
            if needle not in p:
                fails.append(f"plex_720p_bw_contract missing {needle}")
    if not st.is_file():
        fails.append("missing plex_bw_status.sv")
    plex = (ROOT / "fpga/Plex_MiSTer/Plex.sv").read_text(errors="replace")
    if "u_plex_bw_status" not in plex:
        fails.append("Plex.sv missing u_plex_bw_status instance")
    core = (ROOT / "fpga/Plex_MiSTer/rtl/present_core.sv").read_text(errors="replace")
    if "plex_720p_bw_contract.svh" not in core:
        fails.append("present_core must include plex_720p_bw_contract.svh")
    if "P720_CODED_W" not in core or "FS_CODED_W" not in core:
        fails.append("present_core must bind FS_* from P720 on 720p path")
    if "DDR_FS_USE_720P_ABI ? P720_CODED_W" not in core and "P720_CODED_W :" not in core.replace(" ", ""):
        # allow either ternary form
        if "P720_CODED_W" not in core or "FS_CODED_W" not in core:
            fails.append("present_core FS_CODED_W must select P720_CODED_W on 720p ABI")
    if "g_p720_bps_gate" not in core and "p720_bw_contract_rd_bps_must_be_33177600" not in core:
        fails.append("present_core needs synthesis-active P720 BPS gate")
    store = (ROOT / "fpga/Plex_MiSTer/rtl/ddr_frame_store.sv").read_text(errors="replace")
    if "plex_720p_bw_contract.svh" not in store:
        fails.append("ddr_frame_store must include plex_720p_bw_contract.svh")
    if "g_p720_store_contract" not in store:
        fails.append("ddr_frame_store needs synthesis-active 720p contract generate")
    bwstat = (ROOT / "fpga/Plex_MiSTer/rtl/plex_bw_status.sv").read_text(errors="replace")
    if "P720_FABRIC_RD_BPS" not in bwstat:
        fails.append("plex_bw_status must load from P720_FABRIC_RD_BPS (not free literals only)")
    if "p720_bw_contract_rd_bps_must_be_33177600" not in bwstat:
        fails.append("plex_bw_status needs synthesis-active BPS gate")
    # audit_ack must not claim rd-duck CLOSED/38.53
    aa = c.get("audit_ack", {})
    if aa.get("rd_duck") != "ARITHMETIC_LABELS_ONLY":
        fails.append("audit_ack.rd_duck must be ARITHMETIC_LABELS_ONLY")
    nack = c.get("NACK", {})
    if isinstance(nack, dict) and "unnormalized_38_53_MBps" not in nack:
        fails.append("fixture must NACK unnormalized 38.53 MB/s")
    if "p720_bw_contract_rd_bps" not in core:
        fails.append("present_core missing p720_bw_contract keep wire")
    qip = (ROOT / "fpga/Plex_MiSTer/files.qip").read_text(errors="replace")
    if "plex_bw_status.sv" not in qip:
        fails.append("files.qip missing plex_bw_status.sv")
    # rd-duck: .svh must NOT be standalone QIP sources (module-local include only)
    if "SYSTEMVERILOG_FILE rtl/plex_720p_bw_contract.svh" in qip:
        fails.append("plex_720p_bw_contract.svh must not be standalone files.qip source")
    if "SYSTEMVERILOG_FILE rtl/misterplex_bw_contract.svh" in qip:
        fails.append("misterplex_bw_contract.svh must not be standalone files.qip source")

    # Host header agrees
    hpp = LAYOUT.read_text(errors="replace")
    if "kPlex720pYuv420pBytes = 1382400" not in hpp:
        fails.append("host layout missing kPlex720pYuv420pBytes = 1382400")

    # Linebuf path exists — 3.0 is not DDR
    sv = STORE.read_text(errors="replace")
    for needle in ("rd_miss_now", "Y_LINE_QWORDS", "DDRAM_RD"):
        if needle not in sv:
            fails.append(f"ddr_frame_store missing {needle}")

    nack = c.get("NACK", {}).get("scaler_headline_3p0_B_per_clk", {})
    if nack.get("value_rejected") != 3.0:
        fails.append("must NACK scaler 3.0 explicitly")

    # Companion beats
    if c["geometry"]["beats_per_frame_i420"] != 172_800:
        fails.append("beats/frame must be 1382400/8 = 172800")
    if c["companion"]["w_mem_ideal_rw_beats"] != 345_600:
        fails.append("R+W beats must be 345600")

    rrp = c.get("real_reader_proof", {})
    g0 = rrp.get("G0", {})
    if g0.get("payload_beats", 0) < 172800:
        fails.append("real_reader G0 payload_beats missing or <172800")
    if g0.get("total_rd_beats", 0) <= g0.get("payload_beats", 0):
        fails.append("real_reader total must include overhead beyond payload")
    if "test_ddr_frame_store_720p_ppc2_bus" not in str(rrp.get("tb", "")):
        fails.append("real_reader tb path missing")

    ps = c.get("proof_status", {})
    # rd-duck: bus beat-delta is refill-demand only (scalar-identical) → PARTIAL_CLOSED_READER
    cls = ps.get("class")
    if cls not in ("STRESS_EVIDENCE", "PARTIAL_CLOSED_READER"):
        fails.append("proof_status.class must be STRESS_EVIDENCE or PARTIAL_CLOSED_READER (not CLOSED)")
    # rd-duck final terminology (three-way claim_split)
    cs = c.get("claim_split", {})
    for src, key, want in (
        (cs, "reader_accepted_request_steady_delta", "OBSERVED/CLOSED"),
        (cs, "reader_PPC2_delivery_correctness_deadline", "OPEN"),
        (cs, "shared_fabric_BW", "OPEN"),
        (ps, "reader_accepted_request_steady_delta", "OBSERVED/CLOSED"),
        (ps, "reader_PPC2_delivery_correctness_deadline", "OPEN"),
        (ps, "shared_fabric_BW", "OPEN"),
    ):
        if src.get(key) != want:
            fails.append(f"{key} must be {want!r} (got {src.get(key)!r})")
    if ps.get("fabric_bw_closed") not in (False, "false", "OPEN"):
        fails.append("fabric_bw_closed must be false/OPEN")
    rstat = str(ps.get("reader_payload_beat_delta_TB", ""))
    if "MEASURED" not in rstat and ps.get("reader_accepted_request_steady_delta") != "OBSERVED/CLOSED":
        fails.append("accepted-request delta must be MEASURED* or OBSERVED/CLOSED")
    if ps.get("reader_delivery_correctness") != "OPEN" and ps.get("reader_PPC2_delivery_correctness_deadline") != "OPEN":
        fails.append("PPC2 delivery/correctness must stay OPEN")
    if ps.get("hps_write_concurrent_same_controller") != "OPEN":
        fails.append("hps_write must stay OPEN")
    if "reader CLOSED" not in str(ps.get("NOT", [])):
        fails.append("proof_status.NOT must forbid bare reader CLOSED")
    g0 = ps.get("G0", {})
    if g0.get("payload_beats") != 173120:
        fails.append("G0 payload must lock 173120 (ideal+2 Y lines)")
    if "w-mem" not in c.get("agreed_by", []):
        fails.append("agreed_by must include w-mem (three-lane lock)")

    # Serial deficit lock (Sweep 118) — T_copy is TIME not rate
    ct = c.get("cpu_time_not_rate", {})
    if float(ct.get("serial_deficit_ms", 0)) <= 0:
        fails.append("serial_deficit_ms must be >0 (e2e not closed serial)")

    # Parent 2026-08-04: one effective ARM core (MiSTer owns the other)
    arm = c.get("arm_capacity", {})
    if arm.get("effective_cores") != 1:
        fails.append("arm_capacity.effective_cores must be 1 (not dual-core free)")
    if int(ct.get("effective_arm_cores", 0)) != 1:
        fails.append("cpu_time_not_rate.effective_arm_cores must be 1")
    strat = c.get("strategic", {})
    pa = strat.get("path_a_overlap", {})
    if isinstance(pa, dict):
        if "INFEASIBLE" not in str(pa.get("status", "")):
            fails.append("path_a_overlap must be INFEASIBLE under one effective core")
    elif str(pa).lower() in ("unproven", "feasible", ""):
        fails.append("path_a_overlap must not remain bare 'unproven'/feasible")
    svh_txt = svh.read_text(errors="replace") if svh.is_file() else ""
    if "MISTERPLEX_BW_EFFECTIVE_ARM_CORES" not in svh_txt:
        fails.append("svh must stamp MISTERPLEX_BW_EFFECTIVE_ARM_CORES=1")
    if "MISTERPLEX_BW_EFFECTIVE_ARM_CORES" in svh_txt and "= 1" not in svh_txt and "=1" not in svh_txt:
        # require the localparam value 1 nearby
        if "EFFECTIVE_ARM_CORES = 1" not in svh_txt and "EFFECTIVE_ARM_CORES=1" not in svh_txt:
            fails.append("EFFECTIVE_ARM_CORES must equal 1")

    # T_copy retire frame-budget PRE-REG (parent strategic convergence)
    pr = c.get("t_copy_retire_prereg", {})
    pred = pr.get("prediction", {})
    if abs(float(pred.get("margin_ms", 0)) - 8.962) > 1e-3:
        fails.append("t_copy_retire_prereg.prediction.margin_ms must be 8.962")
    if pred.get("arm_decode_frame_budget_closes") is not True:
        fails.append("prereg must say arm_decode_frame_budget_closes True under IFs")
    if "e2e 720p24 product CLOSED" not in str(pr.get("does_NOT_claim", [])):
        fails.append("prereg must NOT claim e2e product CLOSED")
    if "MISTERPLEX_BW_AFTER_COPY_RETIRE_MARGIN_US" not in svh_txt:
        fails.append("svh missing AFTER_COPY_RETIRE_MARGIN_US")
    if "8962" not in svh_txt:
        fails.append("svh margin must be 8962 us")

    if fails:
        print("FAIL test_p720_shared_bw_contract")
        for f in fails:
            print(" ", f)
        return 1
    print(
        "PASS p720_bw_contract: headline 33.1776 MB/s/dir; "
        "NACK 3.0; three-lane P720; accepted-delta OBSERVED/CLOSED; PPC2 delivery OPEN; fabric BW OPEN"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
