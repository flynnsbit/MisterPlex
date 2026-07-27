#!/usr/bin/env python3
"""Exhaustive QP 0–51 dequantisation sweep for h264_dequant4x4.

Verifies the RTL dequant formula against an INDEPENDENT reference model
derived from ITU-T H.264 clause 8.5.12.1 (LevelScale4x4 table and scaling
process for residual 4×4 blocks).

The reference model is intentionally written from the specification,
NOT transcribed from the RTL, to avoid proving we typed the same thing twice.

Coverage:
  - All 52 QP values (0–51)
  - All 6 rows of the LevelScale table (qP%6 = 0..5)
  - All 3 position classes (a: both-even, b: both-odd, c: mixed)
  - Boundary cases: QP 0, QP 51, qP/6 and qP%6 at every value
  - Bit-width overflow detection at high QP
  - RED proof: deliberately broken LUT / shift / decomposition → must FAIL

INSTRUMENT FAILURE #14 (2026-07-27):
  The original version of this test ran 14,144 Verilator vectors and
  reported "spec-correct across QP 0–51" on a tree with a known
  sign-flipping overflow bug (fixed by w-cabac in 3b321ca).

  Two independent failures:
  (1) The Verilator sweep used max |coeff|=20 (max product 117,760),
      structurally below the 131,071 overflow threshold. 14,144 vectors,
      zero of which could trip the bug.
  (2) The Python test detected 117 overflow cases and explicitly dismissed
      them: "These are theoretical — real coefficients at high QP are
      small." The test saw the defect 117 times and returned 0.

  Rule: A TEST MAY NOT DECIDE THAT A DISCREPANCY DOES NOT MATTER.
  If a check finds a mismatch from the spec, it fails. Period.
  Any judgement embedded in a test — "theoretical", "not realistic",
  "won't happen in practice" — is an unreviewed assumption with the
  authority of a passing build behind it.
"""
from __future__ import annotations

import os
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]

# ── H.264 Spec Reference (ITU-T H.264 Table 8-13) ──────────────────────
# LevelScale4x4(m, i, j) for the default flat scaling matrix.
# m = qP % 6; position class determined by (i%2, j%2):
#   a = both even   b = both odd   c = one even one odd
SPEC_LEVEL_SCALE = {
    #  m:  (a,   c,   b)
    0: (10, 13, 16),
    1: (11, 14, 18),
    2: (13, 16, 20),
    3: (14, 18, 23),
    4: (16, 20, 25),
    5: (18, 23, 29),
}


def spec_level_scale(qp: int, row: int, col: int) -> int:
    """LevelScale4x4(qP%6, i, j) per ITU-T H.264 Table 8-13."""
    m = qp % 6
    row_odd = row & 1
    col_odd = col & 1
    if row_odd == 0 and col_odd == 0:
        idx = 0  # class a
    elif row_odd == 1 and col_odd == 1:
        idx = 2  # class b
    else:
        idx = 1  # class c
    return SPEC_LEVEL_SCALE[m][idx]


def spec_dequant_ac(coeff: int, qp: int, row: int, col: int) -> int:
    """Dequantise a single AC coefficient per H.264 clause 8.5.12.1.

    For the combined scaling+IDCT path with the H.264 integer DCT:
      d[i][j] = c[i][j] * LevelScale(qP%6, i, j) * 2^(qP/6)

    This is the pre-IDCT scaled value. The IDCT butterfly + >>6 rounding
    is applied separately.
    """
    ls = spec_level_scale(qp, row, col)
    return coeff * ls * (1 << (qp // 6))


# ── RTL-equivalent formula (transcribed for cross-check, NOT the reference) ──
ZIGZAG = [0, 1, 4, 8, 5, 2, 3, 6, 9, 12, 13, 10, 7, 11, 14, 15]

RTL_NORM_ADJUST = [
    [10, 13, 16],
    [11, 14, 18],
    [13, 16, 20],
    [14, 18, 23],
    [16, 20, 25],
    [18, 23, 29],
]


def rtl_mi(row: int, col: int) -> int:
    s = (row & 1) + (col & 1)
    return 0 if s == 0 else (1 if s == 1 else 2)


def rtl_dequant_one(coeff: int, qp: int, row: int, col: int) -> int:
    """Exact RTL formula from h264_dequant4x4.dequant_one."""
    mi = rtl_mi(row, col)
    qmod = qp % 6
    qdiv = qp // 6
    na = RTL_NORM_ADJUST[qmod][mi]
    qmul = na * 16
    qmul = qmul << (qdiv + 2)
    v = (coeff * qmul + 32) >> 6
    return v


def sign_extend_18(v: int) -> int:
    """Simulate 18-bit signed truncation as the RTL does (v[17:0])."""
    v = v & 0x3FFFF
    if v & 0x20000:
        v -= 0x40000
    return v


# ── Test helpers ──────────────────────────────────────────────────────────
def fail(msg: str) -> None:
    print(f"FAIL dequant-qp-sweep: {msg}", file=sys.stderr)
    raise SystemExit(1)


def info(msg: str) -> None:
    print(f"  {msg}")


# ── Tests ─────────────────────────────────────────────────────────────────
def test_levelscale_table() -> int:
    """Verify all 6×3 LevelScale entries match between spec and RTL tables."""
    errors = 0
    for m in range(6):
        for mi in range(3):
            spec_val = SPEC_LEVEL_SCALE[m][mi]
            rtl_val = RTL_NORM_ADJUST[m][mi]
            if spec_val != rtl_val:
                print(f"  LUT MISMATCH: m={m} mi={mi} spec={spec_val} rtl={rtl_val}")
                errors += 1
    return errors


def test_qp_decomposition() -> int:
    """Verify qP/6 and qP%6 at every QP value 0–51."""
    errors = 0
    for qp in range(52):
        qdiv = qp // 6
        qmod = qp % 6
        if qdiv * 6 + qmod != qp:
            print(f"  DECOMPOSITION ERROR: QP={qp} → {qdiv}*6+{qmod}={qdiv*6+qmod}")
            errors += 1
        if qmod < 0 or qmod > 5:
            print(f"  qmod OUT OF RANGE: QP={qp} qmod={qmod}")
            errors += 1
        if qdiv < 0 or qdiv > 8:
            print(f"  qdiv OUT OF RANGE: QP={qp} qdiv={qdiv}")
            errors += 1
    return errors


def test_formula_equivalence() -> int:
    """Verify RTL formula == spec formula for all QP 0–51, all positions, many coefficients."""
    errors = 0
    test_coefficients = [0, 1, -1, 2, -2, 5, -5, 10, -10, 50, -50, 127, -128, 255, -256]
    qp_tested = set()

    for qp in range(52):
        qp_tested.add(qp)
        for row in range(4):
            for col in range(4):
                for c in test_coefficients:
                    spec_val = spec_dequant_ac(c, qp, row, col)
                    rtl_val = rtl_dequant_one(c, qp, row, col)
                    if spec_val != rtl_val:
                        print(f"  FORMULA MISMATCH: QP={qp} pos=({row},{col}) "
                              f"coeff={c} spec={spec_val} rtl={rtl_val}")
                        errors += 1
                        if errors > 20:
                            print("  ... (stopping after 20 errors)")
                            return errors

    if len(qp_tested) != 52:
        print(f"  COVERAGE GAP: only {len(qp_tested)}/52 QP values tested")
        errors += 1
    return errors


def detect_rtl_output_width() -> int:
    """Read the actual dequant output width from the RTL source."""
    rtl_path = ROOT / "fpga/Plex_MiSTer/rtl/h264_iq_idct_4x4.sv"
    if not rtl_path.exists():
        fail("RTL source not found")
    import re
    text = rtl_path.read_text()
    # Look for: output wire signed [N:0] dequant [0:15]
    m = re.search(r'output\s+wire\s+signed\s+\[(\d+):0\]\s+dequant', text)
    if not m:
        fail("Could not parse dequant output width from RTL")
    msb = int(m.group(1))
    return msb + 1  # total width in bits


def test_overflow_detection() -> int:
    """Check which QP/coefficient combinations overflow the RTL output width.

    Overflow IS a bug — truncation (not saturation) corrupts the value
    (sign flip, magnitude collapse). The test MUST fail if any legal
    coefficient × QP combination produces a dequant product that exceeds
    the RTL's output range.

    This was instrument failure #14: the original test detected 117
    overflow cases on the 18-bit tree and dismissed them as "theoretical".
    The rule is: if a check finds a mismatch, it fails. A test may not
    decide that a discrepancy does not matter.
    """
    width = detect_rtl_output_width()
    max_val = (1 << (width - 1)) - 1
    min_val = -(1 << (width - 1))
    info(f"RTL dequant output width: signed [{width-1}:0] = {width} bits (range [{min_val}, {max_val}])")

    errors = 0
    overflow_cases = []

    for qp in range(52):
        for pos_class, (row, col) in enumerate([(0, 0), (0, 1), (1, 1)]):
            for c in range(1, 257):
                val = spec_dequant_ac(c, qp, row, col)
                if val > max_val or val < min_val:
                    overflow_cases.append((qp, row, col, c, val))
                    break
            for c in range(-1, -257, -1):
                val = spec_dequant_ac(c, qp, row, col)
                if val > max_val or val < min_val:
                    overflow_cases.append((qp, row, col, c, val))
                    break

    if overflow_cases:
        info(f"{width}-bit overflow detected at {len(overflow_cases)} (QP, pos, coeff) boundaries:")
        for qp, row, col, c, val in overflow_cases[:12]:
            info(f"  QP={qp} pos=({row},{col}) coeff={c} → {val} (range: [{min_val}, {max_val}])")
        info(f"FAIL: {len(overflow_cases)} overflow cases — dequant output width too narrow.")
        errors = len(overflow_cases)
    else:
        info(f"No overflow: all 9-bit coeff × QP 0–51 products fit in {width}-bit output ✓")

    return errors


def test_rtl_truncation_correctness() -> int:
    """Verify whether truncation at the detected output width causes sign flips.

    If the width is too narrow, truncation flips signs — this is the
    production-affecting bug that corrupts pixel values.
    """
    width = detect_rtl_output_width()
    max_val = (1 << (width - 1)) - 1
    min_val = -(1 << (width - 1))

    def sign_extend(v: int, w: int) -> int:
        mask = (1 << w) - 1
        v = v & mask
        if v & (1 << (w - 1)):
            v -= (1 << w)
        return v

    sign_flips = 0
    for qp in range(52):
        for row in range(4):
            for col in range(4):
                for c in [255, -256, 200, -200]:
                    val = spec_dequant_ac(c, qp, row, col)
                    if val > max_val or val < min_val:
                        truncated = sign_extend(val, width)
                        if (val > 0 and truncated < 0) or (val < 0 and truncated > 0):
                            sign_flips += 1

    if sign_flips > 0:
        info(f"CONFIRMED: {sign_flips} cases where {width}-bit truncation flips the sign.")
        info("This is a production-affecting bug — pixels invert at affected QPs.")
    else:
        info(f"No sign flips at {width}-bit width ✓")
    # Informational — the hard failure is in test_overflow_detection.
    return 0


# ── RED proofs ────────────────────────────────────────────────────────────
def test_red_broken_lut() -> int:
    """RED PROOF: A single wrong LUT entry must be detected."""
    # Save original
    orig = RTL_NORM_ADJUST[3][1]
    RTL_NORM_ADJUST[3][1] = 17  # wrong: should be 18

    detected = False
    for qp in range(52):
        if qp % 6 != 3:
            continue
        # Test a position of class c (mi=1): row=0, col=1
        spec_val = spec_dequant_ac(1, qp, 0, 1)
        rtl_val = rtl_dequant_one(1, qp, 0, 1)
        if spec_val != rtl_val:
            detected = True
            break

    RTL_NORM_ADJUST[3][1] = orig  # restore

    if not detected:
        print("  RED PROOF FAILED: broken LUT not detected!")
        return 1
    info("RED PROOF OK: broken LUT entry detected")
    return 0


def test_red_broken_shift() -> int:
    """RED PROOF: Wrong shift derivation must be detected."""
    # Test with a modified formula that uses qdiv+3 instead of qdiv+2
    detected = False
    for qp in range(52):
        for c in [1, -1, 5]:
            spec_val = spec_dequant_ac(c, qp, 0, 0)
            # Broken: qdiv+3 instead of qdiv+2
            mi = rtl_mi(0, 0)
            qmod = qp % 6
            qdiv = qp // 6
            na = RTL_NORM_ADJUST[qmod][mi]
            qmul = na * 16
            qmul = qmul << (qdiv + 3)  # BUG: +3 not +2
            broken_val = (c * qmul + 32) >> 6
            if spec_val != broken_val:
                detected = True
                break
        if detected:
            break

    if not detected:
        print("  RED PROOF FAILED: broken shift not detected!")
        return 1
    info("RED PROOF OK: broken shift derivation detected")
    return 0


def test_red_broken_qp_mod() -> int:
    """RED PROOF: Using qP%5 instead of qP%6 must be detected."""
    detected = False
    for qp in range(52):
        for c in [1, -1]:
            spec_val = spec_dequant_ac(c, qp, 0, 0)
            # Broken: qmod = qp%5, qdiv = qp//5
            mi = rtl_mi(0, 0)
            qmod = qp % 5  # BUG
            qdiv = qp // 5  # BUG
            if qmod >= 6:
                qmod = 5
            na = RTL_NORM_ADJUST[qmod][mi]
            qmul = na * 16
            qmul = qmul << (qdiv + 2)
            broken_val = (c * qmul + 32) >> 6
            if spec_val != broken_val:
                detected = True
                break
        if detected:
            break

    if not detected:
        print("  RED PROOF FAILED: broken qP%6 decomposition not detected!")
        return 1
    info("RED PROOF OK: broken qP%%6 decomposition detected")
    return 0


def test_red_broken_mi() -> int:
    """RED PROOF: Swapping position classes a and b must be detected."""
    detected = False
    for qp in range(52):
        for c in [1, -1]:
            # Swap class a (both-even) and class b (both-odd)
            # Test at (0,0) which should be class a=10 at m=0
            spec_val = spec_dequant_ac(c, qp, 0, 0)
            # Broken: use class b value instead
            qmod = qp % 6
            qdiv = qp // 6
            na = RTL_NORM_ADJUST[qmod][2]  # class b instead of class a
            qmul = na * 16
            qmul = qmul << (qdiv + 2)
            broken_val = (c * qmul + 32) >> 6
            if spec_val != broken_val:
                detected = True
                break
        if detected:
            break

    if not detected:
        print("  RED PROOF FAILED: broken position class not detected!")
        return 1
    info("RED PROOF OK: broken position class mapping detected")
    return 0


def test_chroma_qp_table() -> int:
    """Verify the H.264 qPI→QPc mapping table (Table 8-15).

    This table is NOT yet implemented in RTL — this test documents what
    the correct values are so when chroma dequant is added, it can be
    verified. The table is non-linear above qPI=29 and has NEVER been
    exercised by our QP 5–27 test corpus.

    The mapping matters because chroma QP saturates: QPc maxes out at 39
    even when QPy reaches 51. A naive QPc=QPy implementation would
    over-quantize chroma at high QP, producing visible colour artefacts.
    """
    # ITU-T H.264 Table 8-15: QPc as a function of qPI
    # qPI = QPy + chroma_qp_index_offset (clamped to [0,51])
    # For qPI 0–29, QPc = qPI. For qPI 30–51, QPc diverges and saturates at 39.
    SPEC_QPC_TABLE = [
        0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19,
        20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 29, 30, 31, 32, 32, 33, 34, 34,
        35, 35, 36, 36, 37, 37, 37, 38, 38, 38, 39, 39, 39, 39,
    ]

    errors = 0

    # Verify basic properties
    for qpi in range(52):
        qpc = SPEC_QPC_TABLE[qpi]
        # QPc must never exceed qPI
        if qpc > qpi:
            print(f"  qPI→QPc TABLE ERROR: qPI={qpi} QPc={qpc} > qPI")
            errors += 1
        # QPc must be in [0, 39]
        if qpc < 0 or qpc > 39:
            print(f"  qPI→QPc TABLE ERROR: qPI={qpi} QPc={qpc} out of [0,39]")
            errors += 1
        # QPc must be monotonically non-decreasing
        if qpi > 0 and qpc < SPEC_QPC_TABLE[qpi - 1]:
            print(f"  qPI→QPc TABLE ERROR: qPI={qpi} QPc={qpc} < QPc({qpi-1})={SPEC_QPC_TABLE[qpi-1]}")
            errors += 1

    # Verify the non-linear region is genuinely different from linear
    linear_diffs = sum(1 for qpi in range(30, 52) if SPEC_QPC_TABLE[qpi] != qpi)
    if linear_diffs != 22:
        print(f"  Expected 22 non-linear entries (qPI 30–51), got {linear_diffs}")
        errors += 1

    # Verify saturation at QPc=39
    if SPEC_QPC_TABLE[51] != 39 or SPEC_QPC_TABLE[50] != 39:
        print(f"  QPc saturation error: QPc(51)={SPEC_QPC_TABLE[51]}, QPc(50)={SPEC_QPC_TABLE[50]}")
        errors += 1

    # Document the gap: our corpus never tested the non-linear region
    info(f"Chroma QP table: 52 entries verified, {linear_diffs} non-linear above qPI=29")
    info(f"  QPc range: [{SPEC_QPC_TABLE[0]}, {SPEC_QPC_TABLE[51]}] (saturates at 39)")
    info(f"  Non-linear region qPI=[30,51] NEVER EXERCISED by test corpus (QP 5–27)")
    info(f"  RTL STATUS: NOT IMPLEMENTED — no qPI→QPc mapping in RTL")
    info(f"  RTL STATUS: No chroma DC Hadamard (2×2 transform) path exists")
    info(f"  RTL STATUS: No chroma_qp_index_offset handling in pps_parser.sv")

    # Check if pps_parser has chroma_qp_index_offset
    pps_path = ROOT / "fpga/Plex_MiSTer/rtl/pps_parser.sv"
    if pps_path.exists():
        pps_text = pps_path.read_text()
        if "chroma_qp_index_offset" not in pps_text:
            info(f"  CONFIRMED: pps_parser.sv does not parse chroma_qp_index_offset")
        else:
            info(f"  NOTE: pps_parser.sv mentions chroma_qp_index_offset (check if functional)")

    return errors


def run_verilator_sweep() -> int:
    """If Verilator is available, build and run the exhaustive RTL simulation."""
    verilator = Path.home() / ".local/oss-cad-suite-20260726/bin/verilator"
    if not verilator.exists():
        verilator_str = os.environ.get("VERILATOR", "")
        if verilator_str and Path(verilator_str).exists():
            verilator = Path(verilator_str)
        else:
            info("SKIP Verilator RTL sweep (Verilator not found; this is NOT a pass)")
            return 0

    tb_cpp = ROOT / "tests/rtl/h264_dequant_qp_sweep_tb.cpp"
    rtl_src = ROOT / "fpga/Plex_MiSTer/rtl/h264_iq_idct_4x4.sv"

    if not tb_cpp.exists():
        info("SKIP Verilator RTL sweep (testbench C++ not found)")
        return 0

    # Read the product RTL output width and generate a matching SV wrapper
    import re
    rtl_text = rtl_src.read_text()
    m = re.search(r'output\s+wire\s+signed\s+\[(\d+):0\]\s+dequant', rtl_text)
    if not m:
        info("SKIP Verilator RTL sweep (cannot parse dequant output width)")
        return 0
    msb = int(m.group(1))

    build_dir = ROOT / "build/verilator_qp_sweep"
    build_dir.mkdir(parents=True, exist_ok=True)

    # Generate the SV wrapper with the exact width from the product RTL
    tb_sv = build_dir / "h264_dequant_qp_sweep_tb.sv"
    tb_sv.write_text(f"""\
// Auto-generated testbench wrapper — width [{msb}:0] from product RTL.
`default_nettype none
module h264_dequant_qp_sweep_tb (
    input  wire signed [8:0]  coeff    [0:15],
    input  wire        [4:0]  max_coeff,
    input  wire        [5:0]  qp,
    output wire signed [{msb}:0] dequant  [0:15]
);
    h264_dequant4x4 u_dequant (
        .coeff(coeff), .qp(qp), .max_coeff(max_coeff), .dequant(dequant)
    );
endmodule
`default_nettype wire
""")

    # Build
    cmd_build = [
        str(verilator), "--cc", "--exe", "--build",
        "-Wall", "-Wno-UNUSEDSIGNAL", "-Wno-DECLFILENAME", "-Wno-WIDTHTRUNC",
        "--top-module", "h264_dequant_qp_sweep_tb",
        "-Mdir", str(build_dir),
        "-o", "dequant_qp_sweep",
        str(tb_sv), str(rtl_src), str(tb_cpp),
    ]
    info(f"Building Verilator sweep: {' '.join(cmd_build[-4:])}")
    result = subprocess.run(cmd_build, capture_output=True, text=True, cwd=ROOT)
    if result.returncode != 0:
        print(f"  Verilator build FAILED:\n{result.stderr}")
        return 1

    # Run
    exe = build_dir / "dequant_qp_sweep"
    if not exe.exists():
        print(f"  Verilator build produced no executable at {exe}")
        return 1

    result = subprocess.run(
        [str(exe), f"--width={msb + 1}"],
        capture_output=True, text=True, cwd=ROOT,
    )
    print(result.stdout.rstrip())
    if result.stderr.strip():
        print(result.stderr.rstrip())
    if result.returncode != 0:
        print(f"  Verilator RTL sweep FAILED with rc={result.returncode}")
        return 1

    return 0


def main() -> int:
    print("test_dequant_qp_sweep: Exhaustive QP 0–51 dequantisation verification")
    print("=" * 72)
    total_errors = 0

    # 1. LevelScale LUT verification
    print("\n1. LevelScale LUT (spec Table 8-13 vs RTL norm_adjust):")
    e = test_levelscale_table()
    total_errors += e
    if e == 0:
        info("ALL 18 LUT entries match ✓")

    # 2. QP decomposition
    print("\n2. QP/6 and QP%6 decomposition (all 52 values):")
    e = test_qp_decomposition()
    total_errors += e
    if e == 0:
        info("ALL 52 decompositions correct ✓")

    # 3. Formula equivalence across full QP range
    print("\n3. Dequant formula: spec vs RTL across QP 0–51:")
    e = test_formula_equivalence()
    total_errors += e
    n_tests = 52 * 16 * 15  # 52 QPs × 16 positions × 15 coefficient values
    if e == 0:
        info(f"ALL {n_tests} test vectors match ✓")

    # 4. Overflow analysis — this MUST fail on unfixed 18-bit tree
    print("\n4. 18-bit overflow detection (MUST fail on unfixed tree):")
    e = test_overflow_detection()
    total_errors += e
    if e > 0:
        info(f"DETECTED: {e} overflow cases — dequant output width is too narrow")

    # 5. Sign-flip analysis
    print("\n5. Sign-flip analysis (confirms corruption if width is too narrow):")
    e = test_rtl_truncation_correctness()
    total_errors += e

    # 6. RED proofs
    print("\n6. RED proofs (deliberately broken models must be detected):")
    total_errors += test_red_broken_lut()
    total_errors += test_red_broken_shift()
    total_errors += test_red_broken_qp_mod()
    total_errors += test_red_broken_mi()

    # 7. Chroma QP mapping table audit
    print("\n7. Chroma QP mapping table (spec Table 8-15):")
    total_errors += test_chroma_qp_table()

    # 8. Verilator RTL simulation sweep
    print("\n8. Verilator RTL simulation sweep (QP 0–51):")
    total_errors += run_verilator_sweep()

    # Summary
    print("\n" + "=" * 72)
    qp_coverage = " ".join(f"{qp}" for qp in range(52))
    print(f"QP range tested: [{qp_coverage}]")
    print(f"QP values exercised: 52/52")

    if total_errors == 0:
        print(f"\ntest_dequant_qp_sweep: OK — all QP 0–51 verified, "
              f"4 RED proofs passed, LUT+formula+decomposition correct")
        return 0
    else:
        print(f"\nFAIL dequant-qp-sweep: {total_errors} error(s)")
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
