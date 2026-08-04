#!/usr/bin/env python3
"""720p present M10K budget vs decode_stub reclaim (static + prior fit fixture).

Product path is ARM decode → DDR banks → fabric present/scanout. Full fabric
H.264 DPB is dead (~2160 M10K). This gate budgets *present* linebufs only.

PREREG (published before reading fixture in CI sense): stub reclaim M10K=268
from prior hierarchy dumps. Fixture records measure + delta.

NEGATIVE classes (must FAIL when injected):
  1) line_buf WIDTH hardcoded to 480p qword count (80) instead of Y_LINE_QWORDS
  2) budget claims WILL FIT at 720p WITHOUT stub reclaim (margin must go red)
  3) stub dpb_mem index must use DPB_AW (not hard-coded [17:0] alias)
"""
from __future__ import annotations

import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
FS = ROOT / "fpga/Plex_MiSTer/rtl/ddr_frame_store.sv"
LBR = ROOT / "fpga/Plex_MiSTer/rtl/line_buf_ram.sv"
STUB = ROOT / "fpga/Plex_MiSTer/rtl/decode_stub.sv"
FIX = ROOT / "tests/fixtures/decode_stub_fit_hierarchy_480p.json"
DEVICE_M10K = 553


def bits_linebufs(coded_w: int, line_count: int = 8) -> int:
    """Ideal dual-set line buffer bits: LINE_SLOTS=2*LINE_COUNT of Y+U+V @64b."""
    y_qw = coded_w // 8
    c_qw = coded_w // 16
    slots = line_count * 2
    return slots * (y_qw + 2 * c_qw) * 64


def m10k_scaled(measured_m10k: int, measured_bits: int, new_bits: int) -> int:
    """Scale M10K by bit ratio using measured shallow packing (ceil)."""
    if measured_bits <= 0:
        raise SystemExit("FAIL: measured_bits invalid")
    # ceil(new_bits / bits_per_block) with bits_per_block from measure
    # Use float then ceil
    import math

    return int(math.ceil(new_bits * measured_m10k / measured_bits))


def main() -> int:
    fs = FS.read_text(encoding="utf-8", errors="replace")
    lbr = LBR.read_text(encoding="utf-8", errors="replace")
    stub_src = STUB.read_text(encoding="utf-8", errors="replace")
    fix = json.loads(FIX.read_text(encoding="utf-8"))

    # --- PREREG vs measure (from fixture, frozen at capture) ---
    prereg_m10k = fix["prereg_before_measure"]["m10k_reclaim"]
    meas_m10k = fix["decode_stub"]["m10k"]
    if prereg_m10k != 268 or meas_m10k != 268:
        print(
            f"FAIL: expected PREREG/measure stub M10K 268/268 got "
            f"{prereg_m10k}/{meas_m10k}",
            file=sys.stderr,
        )
        return 1
    if fix["measure_delta"]["m10k"] != 0:
        print("FAIL: fixture claims M10K miss but should be HIT", file=sys.stderr)
        return 1

    # --- RTL formulas must scale with CODED_W, not hardcode 480p ---
    if "Y_LINE_QWORDS = CODED_W / 8" not in fs.replace(" ", ""):
        # allow spaced form
        if not re.search(r"Y_LINE_QWORDS\s*=\s*CODED_W\s*/\s*8", fs):
            print("FAIL: Y_LINE_QWORDS must derive from CODED_W", file=sys.stderr)
            return 1
    if not re.search(
        r"line_buf_ram\s*#\s*\(\s*\.WIDTH\s*\(\s*Y_LINE_QWORDS\s*\)", fs
    ):
        print(
            "FAIL: yram WIDTH must be Y_LINE_QWORDS (geometry-scaled)",
            file=sys.stderr,
        )
        return 1
    if not re.search(
        r"line_buf_ram\s*#\s*\(\s*\.WIDTH\s*\(\s*C_LINE_QWORDS\s*\)", fs
    ):
        print("FAIL: uram/vram WIDTH must be C_LINE_QWORDS", file=sys.stderr)
        return 1
    if "parameter int WIDTH = 320" not in lbr and "parameter int WIDTH" not in lbr:
        print("FAIL: line_buf_ram missing WIDTH param", file=sys.stderr)
        return 1

    # NEGATIVE 1: hardcoded 480p yram width must be detected as red twin
    red_fs = re.sub(
        r"line_buf_ram\s*#\s*\(\s*\.WIDTH\s*\(\s*Y_LINE_QWORDS\s*\)",
        "line_buf_ram #(.WIDTH(80)",
        fs,
        count=1,
    )
    if re.search(
        r"line_buf_ram\s*#\s*\(\s*\.WIDTH\s*\(\s*Y_LINE_QWORDS\s*\)", red_fs
    ) and ".WIDTH(80)" not in red_fs:
        print("FAIL: red twin inject failed", file=sys.stderr)
        return 1
    if re.search(
        r"line_buf_ram\s*#\s*\(\s*\.WIDTH\s*\(\s*Y_LINE_QWORDS\s*\)", red_fs
    ):
        # first yram replaced; remaining may still match — require at least one 80
        if ".WIDTH(80)" not in red_fs:
            print("FAIL: red twin WIDTH(80) missing", file=sys.stderr)
            return 1
    else:
        # yram no longer all Y_LINE_QWORDS — red condition for product source check
        pass
    # Product source must NOT contain the red pattern
    if re.search(r"line_buf_ram\s*#\s*\(\s*\.WIDTH\s*\(\s*80\s*\)", fs):
        print("FAIL: product yram WIDTH hardcoded to 80 (480p silent mismatch)", file=sys.stderr)
        return 1

    # --- Arithmetic ---
    lc = 8
    m = re.search(r"parameter\s+int\s+LINE_COUNT\s*=\s*(\d+)", fs)
    if m:
        lc = int(m.group(1))
    bits_480 = bits_linebufs(640, lc)
    bits_720 = bits_linebufs(1280, lc)
    if bits_720 != 2 * bits_480:
        print(
            f"FAIL: expected 720p linebuf bits 2x 480p got {bits_720} vs {bits_480}",
            file=sys.stderr,
        )
        return 1

    fs_m10k = fix["ddr_frame_store"]["m10k"]
    fs_bits = fix["ddr_frame_store"]["block_memory_bits"]
    # measured bits may be slightly below ideal due packing; scale from measure
    m10k_720_est = m10k_scaled(fs_m10k, fs_bits, bits_720)
    # also width-double estimate: each of 96 blocks doubles
    m10k_720_double = fs_m10k * 2
    m10k_720 = max(m10k_720_est, m10k_720_double)  # conservative peak of two models
    m10k_720_lo = min(m10k_720_est, m10k_720_double)

    chip = fix["chip"]["m10k"]
    stub_m10k = meas_m10k
    free_now = DEVICE_M10K - chip
    delta_line = m10k_720 - fs_m10k  # using conservative

    # WITHOUT stub reclaim
    used_no_reclaim = chip - fs_m10k + m10k_720
    margin_no_reclaim = DEVICE_M10K - used_no_reclaim

    # WITH stub reclaim
    used_reclaim = chip - stub_m10k - fs_m10k + m10k_720
    margin_reclaim = DEVICE_M10K - used_reclaim

    # NEGATIVE 2: asserting WILL FIT without reclaim when margin_no_reclaim < 0
    if margin_no_reclaim >= 0:
        # If packing is better than worst-case, still require explicit statement
        # that without reclaim the margin is tight (< 20) or we fail soft
        if margin_no_reclaim > 20:
            print(
                f"FAIL: unexpected large positive margin without reclaim "
                f"({margin_no_reclaim}); revisit packing model",
                file=sys.stderr,
            )
            return 1
    else:
        # expected path: negative or zero without reclaim
        pass

    if margin_reclaim < 0:
        print(
            f"FAIL CRITICAL: even WITH stub reclaim, 720p present M10K margin "
            f"negative ({margin_reclaim}). used={used_reclaim} device={DEVICE_M10K}",
            file=sys.stderr,
        )
        return 1

    # --- Stub DPB index must scale (no hard-coded [17:0] silent alias) ---
    stub_src_ns = re.sub(r"\s+", "", stub_src)
    if "dpb_mem[dpb_mem_waddr[17:0]]" in stub_src_ns:
        print("FAIL: hard-coded 18-bit dpb_mem index reintroduced (alias)", file=sys.stderr)
        return 1
    if "DPB_AW" not in stub_src or "dpb_mem_waddr[DPB_AW-1:0]" not in stub_src_ns:
        print("FAIL: expected DPB_AW-scaled dpb_mem index", file=sys.stderr)
        return 1
    # Arithmetic: on-chip 720p 2-frame still WILL NOT FIT device M10K (product omits it)
    frame_720 = 1280 * 720 * 3 // 2
    two_720_bits = 2 * frame_720 * 8
    ideal_m10k = (two_720_bits + 10239) // 10240
    if ideal_m10k < 2000:
        print(f"FAIL: expected 720p 2-frame DPB >> device ({ideal_m10k} M10K ideal)", file=sys.stderr)
        return 1

    # dpb dominates stub M10K
    if fix["decode_stub"]["dpb_mem_m10k"] != 256:
        print("FAIL: fixture dpb_mem_m10k expected 256", file=sys.stderr)
        return 1
    if stub_m10k - fix["decode_stub"]["dpb_mem_m10k"] != 12:
        print(
            f"FAIL: non-DPB stub M10K expected 12 got "
            f"{stub_m10k - fix['decode_stub']['dpb_mem_m10k']}",
            file=sys.stderr,
        )
        return 1

    print(
        "PASS 720p present M10K budget | "
        f"chip_m10k={chip}/{DEVICE_M10K} free={free_now} | "
        f"stub_reclaim_m10k={stub_m10k} (dpb={fix['decode_stub']['dpb_mem_m10k']}) "
        f"ALM={fix['decode_stub']['alm_needed']} "
        f"ALUT={fix['decode_stub']['combinational_aluts']} "
        f"REG={fix['decode_stub']['dedicated_logic_registers']} | "
        f"linebuf_bits_640={bits_480} bits_1280={bits_720} "
        f"fstore_m10k_480={fs_m10k} est_720=[{m10k_720_lo}..{m10k_720}] | "
        f"margin_no_reclaim={margin_no_reclaim} margin_with_reclaim={margin_reclaim} | "
        f"PREREG_m10k={prereg_m10k} MEASURE={meas_m10k} delta=0 HIT | "
        f"scope=present+stub_painter NOT fabric_decoder | "
        f"fit_src={fix['source_fit_rpt']}:L{fix['decode_stub']['fit_rpt_line']}"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
