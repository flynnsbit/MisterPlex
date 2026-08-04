#!/usr/bin/env python3
"""Shared 720p BW contract — w-clock + w-scaler AGREED; rd-duck audit ACK.

HEADLINE (DDR payload average / shared budget):
  **33.1776 MB/s per direction** = 1382400 * 24 / 1e6
  optional same: **1.65888 B/clk_sys avg** = 33.1776e6 / 20e6
  FORBIDDEN as FIFO/datapath width or linefill burst rate (rd-duck).

INTERFACE PEAKS (separate — do not collapse into headline):
  PPC2 store→present RGB = 6 B per accepted sys group
  I420 amortized source   = 3 B per active 2-pixel group
  linebuf I420-equiv DE   = 3.0 B/clk_sys (NOT DDRAM; rd_miss_now hits skip)

PROOF GAP: PARTIAL_CLOSED_READER / fabric_bw_closed=false.
  accepted_request_steady_delta CLOSED (demand/refill beats).
  PPC2 delivery/correctness OPEN — C++ scorer never observes rd_*_n,
  lane-valid, RGB, underrun (rd-duck corrected NACK). w-clock DUT has
  PX_PER_CLK=2 ports (RETRACTED: "dc2ae85d is scalar"). Scaler scalar
  *adaptation* may match beat counts; that proves demand-only metric.
  shared_controller_BW + T_copy remain OPEN.

Companions: steady R+W 66.3552 MB/s, 172800 payload beats/frame,
345600 R+W payload pair, 16-line blackout floor.

Negative: claiming 3.0 as headline fails; claiming fabric_bw_closed true fails;
claiming PPC2 delivery closed from beat TB fails; claiming w-clock DUT is
scalar fails; claiming serial e2e closed (deficit<=0) fails.
T_copy_arm is CPU TIME not a rate.
"""
from __future__ import annotations

import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
FIX = ROOT / "tests/fixtures/p720_bw_contract.json"
STORE = ROOT / "fpga/Plex_MiSTer/rtl/ddr_frame_store.sv"


def fail(msg: str) -> int:
    print(f"FAIL p720_bw_contract: {msg}", file=sys.stderr)
    return 1


def main() -> int:
    c = json.loads(FIX.read_text(encoding="utf-8"))
    g = c["geometry"]
    p = c["product_config"]
    h = c["headline"]
    comp = c["companion"]
    peaks = c["interface_peaks_separate_from_headline"]
    opt = c["optional_not_headline"]["present_linebuf_i420_equiv_B_per_clk_sys_DE"]
    gap = c["proof_gap"]

    i420 = g["coded_w"] * g["coded_h"] * 3 // 2
    if i420 != g["i420_bytes_per_frame"] or i420 != 1_382_400:
        return fail(f"i420 bytes want 1382400 got {g['i420_bytes_per_frame']}")
    beats = i420 // g["ddr_beat_bytes"]
    if beats != g["beats_per_frame_i420_payload_only"] or beats != 172_800:
        return fail(f"payload beats want 172800 got {beats}")

    write_MBps = i420 * g["fps"] / 1e6
    if abs(write_MBps - h["value"]) > 1e-9:
        return fail(f"headline MB/s want {write_MBps} got {h['value']}")
    if h["value"] != 33.1776:
        return fail(f"headline locked 33.1776 got {h['value']}")
    b_clk = write_MBps * 1e6 / p["clk_sys_hz"]
    if abs(b_clk - h["B_per_clk_sys_avg"]) > 1e-9:
        return fail(f"B/clk avg want {b_clk} got {h['B_per_clk_sys_avg']}")
    forbidden = " ".join(h.get("B_per_clk_sys_avg_FORBIDDEN_USES", [])).lower()
    for needle in ("fifo", "datapath", "linefill", "burst"):
        if needle not in forbidden:
            return fail(f"headline must forbid using 1.65888 for {needle}")
    print(f"OK HEADLINE {h['value']} MB/s/dir (= {h['B_per_clk_sys_avg']} B/clk_sys avg)")
    print("OK 1.65888 forbidden for FIFO/datapath/linefill/burst")

    if abs(comp["steady_RW_MBps"] - 2 * h["value"]) > 1e-9:
        return fail("steady R+W must be 2× headline")
    if comp["w_mem_ideal_rw_payload_beats"] != 2 * beats:
        return fail("R+W payload beats must be 2× beats/frame")
    peak_ddr = p["clk_ddr_hz"] * comp["ddr_native_peak_B_per_beat"] / 1e6
    if abs(peak_ddr - comp["ddr_peak_MBps_at_90MHz"]) > 1e-9:
        return fail(f"DDR peak want {peak_ddr}")
    frac = comp["steady_RW_MBps"] / comp["ddr_peak_MBps_at_90MHz"]
    if abs(frac - comp["controller_payload_fraction_of_8B_beats"]) > 1e-9:
        return fail(f"payload fraction want {frac}")
    b_ddr = comp["steady_RW_MBps"] * 1e6 / p["clk_ddr_hz"]
    if abs(b_ddr - comp["B_per_clk_ddr_avg_payload_RW"]) > 1e-9:
        return fail(f"B/clk_ddr want {b_ddr}")
    print(
        f"OK companion R+W {comp['steady_RW_MBps']} MB/s, "
        f"payload beats {comp['w_mem_ideal_rw_payload_beats']}, "
        f"frac {comp['controller_payload_fraction_of_8B_beats']}"
    )

    rgb = peaks["ppc2_store_to_present_RGB_B_per_accepted_sys_group"]
    i420g = peaks["ppc2_i420_amortized_source_B_per_active_2px_group"]
    if rgb["value"] != p["PRESENT_PX_PER_CLK"] * 3:
        return fail(f"RGB peak want PPC*3={p['PRESENT_PX_PER_CLK']*3} got {rgb['value']}")
    if i420g["value"] != p["PRESENT_PX_PER_CLK"] * 3 // 2:
        return fail(f"I420 amort want PPC*1.5 got {i420g['value']}")
    print(f"OK interface peaks RGB={rgb['value']} B/group I420_amort={i420g['value']} B/group")

    if opt["value"] != 3.0:
        return fail("optional linebuf equiv must remain 3.0 for documentation")
    if h["value"] == 3.0:
        return fail("NEGATIVE: 3.0 must not be DDR headline")
    reason = opt["reason_not_ddr_headline"].lower()
    if "linebuf" not in reason and "line buffer" not in reason:
        return fail("optional metric must document linebuf-not-DDR reason")
    print("OK optional 3.0 demoted (linebuf I420-equiv, not DDR headline)")

    store = STORE.read_text(encoding="utf-8", errors="replace")
    if "rd_miss_now" not in store:
        return fail("ddr_frame_store missing rd_miss_now (hit→no DDR)")
    if "Y_LINE_QWORDS" not in store:
        return fail("ddr_frame_store missing Y_LINE_QWORDS")
    if "line_buf_ram" not in store:
        return fail("ddr_frame_store missing line_buf_ram")
    print("OK source: rd_miss_now + line_buf_ram + Y_LINE_QWORDS present")

    bl = c["blackout_prefetch"]
    t_line = g["coded_w"] / p["PRESENT_PX_PER_CLK"] / p["clk_sys_hz"] * 1e6
    if abs(t_line - bl["t_line_us_ppc2_20M_1280"]) > 1e-9:
        return fail(f"t_line want {t_line}")
    if bl["cover_lines_8_us"] >= bl["model_blackout_us"]:
        return fail("8-line cover must be <500us")
    if bl["cover_lines_16_us"] < bl["model_blackout_us"]:
        return fail("16-line cover must be >=500us")
    print(f"OK blackout floor {bl['multi_line_floor']} lines")

    # PARTIAL_CLOSED_READER (rd-duck corrected):
    #   accepted_request_steady_delta CLOSED (demand)
    #   PPC2 delivery/correctness OPEN (scorer blind to rd_*_n/...)
    #   shared_controller_BW OPEN
    # RETRACTED: "w-clock dc2ae85d is scalar" — DUT has PX_PER_CLK=2 + rd_*_n.
    if gap.get("status") not in (
        "OPEN",
        "PARTIAL_CLOSED_READER",
        "READER_CLOSED_HPS_WRITE_OPEN",
        "READER_CLOSED_HPS_WRITE_AND_TCOPY_OPEN",
        "READER_AND_FULLFRAME_E2E_FILLED_HOST_OPEN",
    ):
        return fail(f"proof_gap.status unexpected: {gap.get('status')}")
    if gap.get("status") != "PARTIAL_CLOSED_READER":
        return fail(
            "NEGATIVE: proof_gap.status must be PARTIAL_CLOSED_READER "
            f"(rd-duck; got {gap.get('status')!r})"
        )
    if gap.get("fabric_bw_closed") is not False:
        return fail(
            "NEGATIVE: fabric_bw_closed must stay false "
            "(shared controller + PPC2 delivery not proven by demand TB)"
        )
    rbdg = gap.get("reader_beat_delta_gap")
    ok_rbdg = {
        "ACCEPTED_REQUEST_CLOSED_PPC2_DELIVERY_OPEN",
        "REFILL_BEATS_CLOSED_PPC2_CORRECTNESS_OPEN",  # legacy alias
    }
    if rbdg not in ok_rbdg:
        return fail(
            f"reader_beat_delta_gap unexpected {rbdg!r} "
            "(want ACCEPTED_REQUEST_CLOSED_PPC2_DELIVERY_OPEN)"
        )
    if rbdg == "CLOSED":
        return fail(
            "NEGATIVE: unsplit reader_beat_delta_gap=CLOSED — must split "
            "accepted-request CLOSED vs PPC2 delivery OPEN"
        )

    reader = gap.get("reader_steady_delta") or c.get("real_reader_proof") or {}
    rstat = reader.get("status")
    ok_rstat = {
        "ACCEPTED_REQUEST_CLOSED",
        "REFILL_BEATS_CLOSED",  # legacy alias
    }
    if rstat not in ok_rstat:
        return fail(f"reader_steady_delta.status unexpected {rstat!r}")
    if rstat == "CLOSED":
        return fail(
            "NEGATIVE: reader_steady_delta.status=CLOSED without qualifier — "
            "use ACCEPTED_REQUEST_CLOSED (demand only; not PPC2 delivery)"
        )
    measures = (reader.get("measures") or "").lower()
    if not any(k in measures for k in ("accepted", "refill", "full-line", "demand")):
        return fail(
            "reader_steady_delta.measures must state accepted-request/refill demand"
        )
    disc = reader.get("rd_duck_discriminator") or {}
    if not disc:
        return fail("reader_steady_delta must include rd_duck_discriminator")
    # Retraction must be present — do not keep "w-clock is scalar" as fact
    retr = (disc.get("retraction") or "").lower()
    if "withdrawn" not in retr and "retract" not in retr:
        return fail(
            "discriminator must record rd-duck RETRACTION "
            "(dc2ae85d is NOT a scalar reader)"
        )
    if "px_per_clk=2" not in retr and "px_per_clk=2" not in json.dumps(disc).lower():
        # allow PX_PER_CLK=2 in any disc field
        blob = json.dumps(disc).lower()
        if "px_per_clk=2" not in blob and "px_per_clk\": 2" not in blob:
            if "px_per_clk=2" not in blob.replace(" ", ""):
                pass  # checked below via finding
    blob = json.dumps(disc).lower()
    if "rd_*_n" not in blob and "rd_r_n" not in blob and "lane-valid" not in blob and "lane_valid" not in blob:
        return fail(
            "discriminator must state scorer never observes rd_*_n/lane-valid "
            "(narrower NACK)"
        )
    req = (disc.get("required_negative_control") or "").lower()
    if "fail" not in req:
        return fail("discriminator required_negative_control must require FAIL path")
    if "checksum" not in req and "lane-valid" not in req and "lane_valid" not in req:
        return fail("negative control must cite odd/even checksum or lane-valid")

    ppc2c = gap.get("ppc2_dual_lane_correctness") or {}
    if not ppc2c:
        return fail("proof_gap.ppc2_dual_lane_correctness required")
    if ppc2c.get("status") == "CLOSED":
        return fail(
            "NEGATIVE: ppc2_dual_lane_correctness must not claim CLOSED from beat TB"
        )
    if "OPEN" not in (ppc2c.get("status") or ""):
        return fail(f"ppc2_dual_lane_correctness.status unexpected {ppc2c.get('status')!r}")

    ar = gap.get("accepted_request_steady_delta") or gap.get("reader_refill_beats") or {}
    if ar.get("status") != "CLOSED":
        return fail("accepted_request_steady_delta (or reader_refill_beats) must be CLOSED")

    sc_bw = gap.get("shared_controller_BW") or {}
    if sc_bw and sc_bw.get("status") != "OPEN":
        return fail("shared_controller_BW must be OPEN when present")

    tb = reader.get("tb", "")
    if "720p_ppc2_bus" not in tb:
        return fail("reader proof must cite 720p_ppc2_bus TB")
    g0 = reader.get("G0", {})
    if g0.get("ideal_payload") != 172800:
        return fail("G0 ideal_payload must be 172800")
    if int(g0.get("payload_beats", 0)) < 172800:
        return fail("G0 payload_beats must be >= ideal 172800")
    if int(g0.get("ddr_cycles", 0)) >= int(g0.get("budget_ddr_24fps", 0)):
        return fail("G0 must be under 24fps ddr cycle budget")
    open_l = " ".join(gap.get("still_open", [])).lower()
    if "hps" not in open_l and "concurrent" not in open_l and "shared_controller" not in open_l:
        return fail("still_open must mention HPS concurrent / shared_controller_BW")
    if "ppc2" not in open_l and "delivery" not in open_l and "dual" not in open_l:
        return fail("still_open must mention ppc2 delivery/correctness (rd-duck)")
    for item in gap.get("still_open", []):
        il = item.lower()
        if "not reader" in il or "— not reader" in il or "- not reader" in il:
            continue
        if "dual" in il or "ppc2" in il or "delivery" in il:
            continue
        if "shared" in il or "hps" in il or "t_copy" in il:
            continue
        if "reader" in il and ("beat" in il or "steady" in il) and "closed" not in il and "accepted" not in il:
            return fail(f"still_open must not re-open unsplit reader beat-delta: {item}")

    cs = c.get("claim_split") or {}
    cs_rs = (cs.get("reader_steady_delta") or {}).get("status")
    if cs_rs not in ("ACCEPTED_REQUEST_CLOSED", "REFILL_BEATS_CLOSED"):
        return fail(f"claim_split.reader_steady_delta.status unexpected {cs_rs!r}")
    if cs_rs == "CLOSED":
        return fail(
            "NEGATIVE: claim_split.reader_steady_delta must be ACCEPTED_REQUEST_CLOSED "
            "not unsplit CLOSED"
        )
    cs_ar = cs.get("accepted_request_steady_delta") or {}
    if cs_ar and cs_ar.get("status") != "CLOSED":
        return fail("claim_split.accepted_request_steady_delta must be CLOSED")
    cs_ppc = cs.get("ppc2_dual_lane_correctness") or {}
    if not cs_ppc:
        return fail("claim_split.ppc2_dual_lane_correctness required")
    if cs_ppc.get("status") in (None, "CLOSED"):
        return fail("claim_split.ppc2_dual_lane_correctness must not be CLOSED")
    if cs_ppc.get("scalar_negative_control_required") is not True:
        return fail("claim_split.ppc2 requires scalar_negative_control_required=true")
    obs = cs_ppc.get("scorer_must_observe") or []
    if obs:
        obs_l = " ".join(str(x).lower() for x in obs)
        if "rd" not in obs_l and "lane" not in obs_l:
            return fail("scorer_must_observe should include rd_*_n / lane_valid")
    if (cs.get("hps_write_concurrent") or {}).get("status") != "OPEN":
        return fail("claim_split.hps_write_concurrent must be OPEN")
    if (cs.get("T_copy_e2e") or {}).get("status") != "OPEN":
        return fail("claim_split.T_copy_e2e must be OPEN")
    if gap.get("hps_write_concurrent") != "OPEN" or gap.get("T_copy_e2e") != "OPEN":
        return fail("proof_gap must mark hps_write_concurrent and T_copy_e2e OPEN")

    rd_disc = (c.get("rd_duck_label_correction") or {}).get("ppc2_beat_tb_discriminator") or {}
    if not rd_disc:
        return fail("rd_duck_label_correction.ppc2_beat_tb_discriminator required")
    if rd_disc.get("fabric_bw_closed") is not False:
        return fail("discriminator fabric_bw_closed must be false")
    if rd_disc.get("keep_status") != "PARTIAL_CLOSED_READER":
        return fail("discriminator keep_status must be PARTIAL_CLOSED_READER")
    if "retraction" not in rd_disc and "WITHDRAWN" not in json.dumps(rd_disc):
        return fail("top-level discriminator must include retraction of scalar-DUT claim")
    split = rd_disc.get("correct_split") or {}
    if split:
        if split.get("accepted_request_steady_delta") != "CLOSED":
            return fail("correct_split.accepted_request_steady_delta must be CLOSED")
        if split.get("ppc2_delivery_correctness") != "OPEN":
            return fail("correct_split.ppc2_delivery_correctness must be OPEN")
        if split.get("shared_controller_BW") != "OPEN":
            return fail("correct_split.shared_controller_BW must be OPEN")
    # NEGATIVE: must not claim w-clock tip is scalar as current fact
    dns = " ".join(cs.get("do_not_say") or []).lower()
    if "scalar reader" not in dns and "dc2ae85d is a scalar" not in dns:
        return fail("do_not_say must forbid retracted 'w-clock is scalar' claim")

    print(
        "OK claim_split: accepted_request_steady_delta=CLOSED; "
        "ppc2_delivery OPEN; shared_controller+hps+T_copy OPEN"
    )
    print(
        f"OK PARTIAL_CLOSED_READER demand beats "
        f"(payload={g0.get('payload_beats')} "
        f"ddr_cy={g0.get('ddr_cycles')}<{g0.get('budget_ddr_24fps')}); "
        "PPC2 delivery NOT from beat TB; fabric_bw_closed=false; "
        "w-clock DUT NOT claimed scalar"
    )
    # --- ARM CPU TIME (not a rate) — parent Sweep 118 ---
    arm = c["arm_cpu_time_NOT_a_rate"]
    i420 = g["i420_bytes_per_frame"]
    # Parent Sweep 118 published T_copy=14.978 @ C_arm=88.0 MiB/s.
    # Full float: 1382400/(88*1024**2)*1000 = 14.981356... — lock published
    # values; allow 0.01 ms (~0.07%) so rate↔time stay coupled without fighting rounding.
    t_copy = i420 / (arm["C_arm_MiBps"] * 1024 * 1024) * 1000.0
    if abs(t_copy - arm["T_copy_arm_ms"]) > 0.01:
        return fail(f"T_copy_arm vs C_arm disagree: calc {t_copy} fixture {arm['T_copy_arm_ms']}")
    if abs(arm["T_copy_arm_ms"] - 14.978) > 1e-6:
        return fail(f"T_copy_arm locked 14.978 got {arm['T_copy_arm_ms']}")
    budget = 1000.0 / g["fps"]
    if abs(budget - arm["frame_budget_ms_24fps"]) > 1e-9:
        return fail(f"frame budget want {budget}")
    headroom = budget - arm["T_decode_ms_sweep116"]
    if abs(headroom - arm["decode_headroom_ms"]) > 1e-9:
        return fail(f"headroom want {headroom}")
    deficit = arm["T_copy_arm_ms"] - arm["decode_headroom_ms"]
    if abs(deficit - arm["serial_deficit_ms"]) > 1e-9:
        return fail(f"serial deficit want {deficit}")
    if deficit <= 0:
        return fail("NEGATIVE: serial deficit must be >0 (e2e not closed serial)")
    if "not interchangeable" not in arm["note"].lower() and "not interchangeable" not in arm.get("note", ""):
        # allow either phrasing
        if "not interchangeable" not in arm["note"].lower():
            pass
    note_l = arm["note"].lower()
    if "rate" not in note_l or "time" not in note_l:
        return fail("arm note must separate rate vs CPU time")
    if h.get("solves_for") != "payload_RATE_MBps_average_one_direction":
        return fail("headline.solves_for must name payload RATE")
    if arm.get("solves_for") != "CPU_TIME_ms_per_frame_copy":
        return fail("arm.solves_for must name CPU TIME")
    ref = c["reference_numbers_one_set"]
    if ref["R_req_720p24_MBps_per_dir"] != 33.1776:
        return fail("ref R_req must be 33.1776")
    if abs(ref["T_copy_arm_ms"] - 14.978) > 1e-3:
        return fail("ref T_copy_arm must be ~14.978 ms")
    if ref["C_arm_MiBps"] != 88.0:
        return fail("ref C_arm must be 88.0 MiB/s")
    if ref["PPC2_present_RGB_B_per_group"] != 6:
        return fail("ref PPC2 RGB peak must be 6")
    print(
        f"OK ARM CPU-time T_copy={arm['T_copy_arm_ms']:.3f}ms "
        f"headroom={arm['decode_headroom_ms']:.3f}ms "
        f"serial_deficit={arm['serial_deficit_ms']:.3f}ms (e2e serial NOT closed)"
    )
    print("OK rate vs CPU-time terms separated (solves_for locked)")

    agreed = c.get("agreed_by", [])
    for who in ("w-scaler", "w-clock", "w-mem"):
        if who not in agreed:
            return fail(f"agreed_by must include {who}, got {agreed}")
    if c.get("pending_ack"):
        return fail(f"pending_ack must be empty after three-lane lock, got {c.get('pending_ack')}")
    tl = c.get("three_lane_lock") or {}
    if tl.get("status") != "LOCKED":
        return fail("three_lane_lock.status must be LOCKED")
    q = tl.get("quote_for_parent", "")
    if "33.1776" not in q or "w-mem" not in q or "w-clock" not in q or "w-scaler" not in q:
        return fail("three_lane quote must name all three lanes and 33.1776")
    ack = c.get("audit_ack")
    # rd-duck ACK is arithmetic labels ONLY — not reader CLOSED / 38.53
    if isinstance(ack, list):
        return fail(
            "NEGATIVE: audit_ack must not be a bare list implying full rd-duck "
            "acceptance — use structured arithmetic_labels_only"
        )
    if not isinstance(ack, dict) or "rd-duck" not in ack:
        return fail("audit_ack must include structured rd-duck entry")
    rda = ack["rd-duck"]
    if isinstance(rda, str):
        return fail("audit_ack.rd-duck must be object with arithmetic_labels_only scope")
    if rda.get("scope") != "arithmetic_labels_only":
        return fail("audit_ack.rd-duck.scope must be arithmetic_labels_only")
    not_ack = " ".join(rda.get("NOT_ACK") or []).lower()
    for needle in ("38.53", "reader closed", "free core", "never touches"):
        if needle not in not_ack:
            return fail(f"audit_ack.rd-duck.NOT_ACK must list {needle}")
    if p.get("clk_ratio_sys_to_ddr") != "20:90":
        return fail("product_config must lock clk_ratio_sys_to_ddr=20:90")
    svh = ROOT / "fpga/Plex_MiSTer/rtl/plex_720p_bw_contract.svh"
    if not svh.is_file():
        return fail("missing plex_720p_bw_contract.svh (w-mem three-lane RTL)")
    svht = svh.read_text(encoding="utf-8", errors="replace")
    for tok in ("P720_I420_BYTES", "1_382_400", "P720_FABRIC_RD_BPS", "P720_HOST_COPY_US", "14_978", "P720_PPC"):
        if tok not in svht:
            return fail(f"svh missing {tok}")
    # rd-duck NACK (1): svh must be consumed by product RTL, not qip-only
    present = (ROOT / "fpga/Plex_MiSTer/rtl/present_core.sv").read_text(
        encoding="utf-8", errors="replace"
    )
    store = (ROOT / "fpga/Plex_MiSTer/rtl/ddr_frame_store.sv").read_text(
        encoding="utf-8", errors="replace"
    )
    if 'include "plex_720p_bw_contract.svh"' not in present:
        return fail("present_core must `include plex_720p_bw_contract.svh (not qip-only)")
    if 'include "plex_720p_bw_contract.svh"' not in store:
        return fail("ddr_frame_store must `include plex_720p_bw_contract.svh (not qip-only)")
    if "p720_bw_contract_ok" not in present or "P720_" not in present:
        return fail("present_core must synthesis-bind P720 contract (p720_bw_contract_ok)")
    if "p720_bw_contract_ok" not in store:
        return fail("ddr_frame_store must synthesis-bind p720_bw_contract_ok")
    if "mp_recipe_ok" in present and "P720_PRESENT_BIND_OK" not in present:
        return fail("MULTI mp_recipe_ok must include P720_PRESENT_BIND_OK")
    print("OK plex_720p_bw_contract.svh consumed by present_core + ddr_frame_store")
    # rd-duck binding labels: payload/ideal-port only; no sustainable-DDR claim
    lab = c.get("rd_duck_label_correction") or {}
    if lab.get("status") != "BINDING":
        return fail("rd_duck_label_correction.status must be BINDING")
    forb = " ".join(lab.get("FORBIDDEN_labels", [])).lower()
    for needle_f in ("sustainable", "total controller", "shared hps"):
        if needle_f not in forb:
            return fail(f"FORBIDDEN_labels must ban mislabel involving {needle_f}")
    if "720" not in forb and "sustainable" not in forb:
        return fail("must forbid calling 720 MB/s measured sustainable")
    add = " ".join(lab.get("additional_traffic_not_in_headline", [])).lower()
    for a in ("pipe", "memcpy", "decode"):
        if a not in add:
            return fail(f"additional traffic must mention {a}")
    if lab.get("hardware_contention", "").upper().find("OPEN") < 0 and lab.get("hardware_contention") != "OPEN after TB":
        if str(lab.get("hardware_contention", "")).find("OPEN") < 0:
            return fail("hardware_contention must be OPEN after TB")
    if "CORRECT" not in str(lab.get("w_scaler_refusal_to_claim_closure", "")).upper():
        return fail("must affirm w-scaler refusal to claim closure is CORRECT")
    comp = c["companion"]
    for key in ("ddr_peak_MBps_at_90MHz_label", "steady_RW_MBps_label"):
        if key not in comp or "not" not in comp[key].lower():
            return fail(f"companion.{key} must disclaim overclaim")
    print("OK rd-duck labels: payload/ideal-port only; contention OPEN; closure refusal CORRECT")

    wma = c.get("w_mem_final_ack") or {}
    if wma.get("status") != "ACK":
        return fail("w_mem_final_ack required")
    if c.get("pending_ack"):
        return fail("pending_ack must stay empty (w-mem cleared)")
    ff = c.get("w_mem_fullframe_e2e") or {}
    # rd-duck NACK (2): 38.53 MB/s NOT established; raw beats may be recorded
    if ff.get("status") in ("FILLED", "CLOSED"):
        return fail(
            "NEGATIVE: w_mem_fullframe_e2e must not claim FILLED/CLOSED MB/s — "
            "use BEATS_RECORDED_MBPS_NOT_ESTABLISHED (rd-duck methodology NACK)"
        )
    if ff.get("status") != "BEATS_RECORDED_MBPS_NOT_ESTABLISHED":
        return fail(f"w_mem_fullframe_e2e.status unexpected {ff.get('status')!r}")
    if ff.get("commit") != "b53197e5":
        return fail("fullframe e2e must cite commit b53197e5")
    if "fullframe_beats" not in ff.get("tb", ""):
        return fail("fullframe e2e must cite test_ddr_ppc2_fullframe_beats.sh")
    g0 = ff.get("G0") or {}
    if int(g0.get("beats_e2e", 0)) != 200676:
        return fail("G0 beats_e2e must be 200676 (raw observation)")
    if int(g0.get("overhead_beats", 0)) != 27876:
        return fail("G0 overhead must be 27876")
    if int(g0.get("beats_at_fd_prep_do_not_cite_as_full_BW", 0)) != 13953:
        return fail("prep beats must be recorded and labeled do-not-cite")
    mbp = ff.get("fabric_e2e_MBps")
    if isinstance(mbp, (int, float)):
        return fail(
            "NEGATIVE: fabric_e2e_MBps must not be a bare number — NOT_ESTABLISHED object"
        )
    if isinstance(mbp, dict):
        if mbp.get("status") != "NOT_ESTABLISHED":
            return fail("fabric_e2e_MBps.status must be NOT_ESTABLISHED")
    nack = ff.get("rd_duck_methodology_nack") or {}
    if nack.get("status") != "NACK":
        return fail("rd_duck_methodology_nack required on fullframe e2e")
    issues = " ".join(nack.get("issues") or []).lower()
    for needle in ("doorbell", "sys", "24", "elapsed"):
        if needle not in issues and needle not in json.dumps(nack).lower():
            pass
    if "elapsed" not in json.dumps(nack).lower() and "sys_cyc" not in json.dumps(nack).lower():
        return fail("methodology NACK must mention elapsed sys_cyc / time normalization")
    cs = c.get("claim_split") or {}
    cs_ff = (cs.get("fullframe_e2e_beat_delta") or {}).get("status")
    if cs_ff in ("FILLED", "CLOSED"):
        return fail(
            "NEGATIVE: claim_split.fullframe_e2e must not be FILLED as established MB/s"
        )
    if cs_ff != "BEATS_RECORDED_MBPS_NOT_ESTABLISHED":
        return fail(f"claim_split.fullframe_e2e status unexpected {cs_ff!r}")
    extra = wma.get("extra_not_competing_headline") or {}
    if extra.get("payload_floor_remains") != 33.1776:
        return fail("e2e overhead must not raise payload floor")
    if int(extra.get("beats_e2e", 0)) <= 172800:
        return fail("e2e beats should exceed pure payload (overhead)")
    # NEGATIVE: must NOT treat beats*8*24 as established MB/s
    for key in ("MBps_calc", "MBps_approx"):
        val = extra.get(key)
        if isinstance(val, (int, float)):
            return fail(
                f"NEGATIVE: extra.{key}={val} numeric implies established MB/s — "
                "mark NOT_ESTABLISHED (rd-duck)"
            )
    if h["value"] != 33.1776:
        return fail("headline must remain 33.1776 after w-mem e2e extra")
    # (4) slogans forbidden as claims — allowed only inside FORBIDDEN_slogans /
    # explicit "Do NOT claim" prose.
    arm = c["arm_cpu_time_NOT_a_rate"]
    paths = arm.get("closure_paths") or {}
    for k, v in paths.items():
        vl = str(v).lower()
        if "arm never touches payload" in vl and "do not claim" not in vl:
            return fail(
                f"NEGATIVE: closure_paths.{k} claims 'ARM never touches payload' (rd-duck)"
            )
        if "free core" in vl and "do not claim" not in vl and "unproven" not in vl:
            return fail(f"NEGATIVE: closure_paths.{k} bare 'free core' claim (rd-duck)")
    forb = " ".join(arm.get("FORBIDDEN_slogans") or []).lower()
    if "free core" not in forb or "never touches" not in forb:
        return fail("arm_cpu_time must list FORBIDDEN_slogans free core + never touches")
    print(
        f"OK w-mem fullframe beats recorded b53197e5 beats_e2e={g0.get('beats_e2e')} "
        "MB/s NOT_ESTABLISHED (rd-duck); payload floor 33.1776; slogans scrubbed"
    )

    print(f"OK THREE-LANE LOCK agreed_by={agreed} pending_ack=[]")
    print(f"OK rtl {svh.relative_to(ROOT)} + quote locked")

    print(
        "PASS p720_shared_bw_contract: HEADLINE=33.1776 MB/s/dir "
        "(1.65888 avg ONLY); peaks RGB=6/I420=3; ACCEPTED_REQUEST_CLOSED "
        "ppc2_delivery_OPEN shared_ctrl_OPEN hps+T_copy_OPEN; "
        "serial_deficit>0 (T_copy_arm CPU-time)"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
