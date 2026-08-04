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

PROOF GAP OPEN: fabric BW is NOT closed. Need full 1280x720 real-reader
end-of-frame beat delta under PPC2 + clk 20:90 + stalls, including
doorbell/mailbox/refill overhead. Prep-only beat counts ≠ closure.

Companions: steady R+W 66.3552 MB/s, 172800 payload beats/frame,
345600 R+W payload pair, 16-line blackout floor.

Negative: claiming 3.0 as headline fails; claiming fabric_bw_closed true fails;
claiming serial e2e closed (deficit<=0) fails. T_copy_arm is CPU TIME not a rate.
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

    if gap.get("status") != "OPEN":
        return fail("proof_gap.status must be OPEN until real-reader beat delta lands")
    if gap.get("fabric_bw_closed") is not False:
        return fail("NEGATIVE: fabric_bw_closed must be false")
    missing = " ".join(gap.get("missing", [])).lower()
    for needle in ("1280", "beat", "20:90", "stall", "doorbell"):
        if needle not in missing:
            return fail(f"proof_gap.missing must mention {needle}")
    print("OK proof_gap OPEN — fabric BW NOT closed")

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
    if "w-scaler" not in agreed or "w-clock" not in agreed:
        return fail(f"agreed_by must include w-clock and w-scaler, got {agreed}")
    if "rd-duck" not in c.get("audit_ack", []):
        return fail("audit_ack must include rd-duck")
    if p.get("clk_ratio_sys_to_ddr") != "20:90":
        return fail("product_config must lock clk_ratio_sys_to_ddr=20:90")
    print(f"OK agreed_by={agreed} audit_ack={c.get('audit_ack')}")

    print(
        "PASS p720_shared_bw_contract: HEADLINE=33.1776 MB/s/dir "
        "(1.65888 avg ONLY); peaks RGB=6/I420=3; proof_gap=OPEN; "
        "serial_deficit>0 (T_copy_arm CPU-time)"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
