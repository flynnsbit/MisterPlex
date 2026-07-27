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


def test_overflow_detection() -> int:
    """Check which QP/coefficient combinations overflow 18-bit signed range.

    Overflow IS a bug — the RTL truncates (not saturates), which flips the
    sign and corrupts all downstream values. This was a real defect found
    by w-cabac (3b321ca). Any overflow must be a hard failure.
    """
    max_18bit = (1 << 17) - 1  # 131071
    min_18bit = -(1 << 17)     # -131072
    errors = 0

    overflow_cases = []
    for qp in range(52):
        for pos_class, (row, col) in enumerate([(0, 0), (0, 1), (1, 1)]):
            for c in range(1, 257):
                val = spec_dequant_ac(c, qp, row, col)
                if val > max_18bit or val < min_18bit:
                    overflow_cases.append((qp, row, col, c, val))
                    break
            for c in range(-1, -257, -1):
                val = spec_dequant_ac(c, qp, row, col)
                if val > max_18bit or val < min_18bit:
                    overflow_cases.append((qp, row, col, c, val))
                    break

    if overflow_cases:
        info(f"18-bit overflow detected at {len(overflow_cases)} (QP, pos, coeff) boundaries:")
        for qp, row, col, c, val in overflow_cases[:12]:
            info(f"  QP={qp} pos=({row},{col}) coeff={c} → {val} (18-bit range: [{min_18bit}, {max_18bit}])")
        info(f"FAIL: {len(overflow_cases)} overflow cases — RTL truncation corrupts values (sign flip).")
        info("This is the bug fixed by w-cabac in commit 3b321ca (widen to 22-bit).")
        errors = len(overflow_cases)

    return errors


def test_rtl_18bit_truncation_correctness() -> int:
    """Verify that overflow cases produce sign-flipped values (proving the bug).

    This test confirms that 18-bit truncation at the RTL boundary actually
    corrupts the output — the truncated value has wrong sign or magnitude
    compared to the mathematically correct dequant result.
    """
    errors = 0
    max_18bit = (1 << 17) - 1
    min_18bit = -(1 << 17)

    sign_flips = 0
    for qp in range(52):
        for row in range(4):
            for col in range(4):
                for c in [255, -256, 200, -200]:
                    val = spec_dequant_ac(c, qp, row, col)
                    if val > max_18bit or val < min_18bit:
                        truncated = sign_extend_18(val)
                        if (val > 0 and truncated < 0) or (val < 0 and truncated > 0):
                            sign_flips += 1

    if sign_flips > 0:
        info(f"CONFIRMED: {sign_flips} cases where 18-bit truncation flips the sign.")
        info("This is a production-affecting bug at high QP with moderate coefficients.")
    else:
        info("No sign flips detected at tested coefficient values.")
    # This is informational — the hard failure is in test_overflow_detection.
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
    verified.
    """
    # ITU-T H.264 Table 8-15: QPc as a function of qPI
    # For qPI 0–29, QPc = qPI. For qPI 30–51, QPc diverges.
    SPEC_QPC_TABLE = [
        0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19,
        20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 29, 30, 31, 32, 32, 33, 34, 34,
        35, 35, 36, 36, 37, 37, 37, 38, 38, 38, 39, 39, 39, 39,
    ]

    errors = 0
    for qpi in range(52):
        if qpi < len(SPEC_QPC_TABLE):
            expected = SPEC_QPC_TABLE[qpi]
            # Just verify the table is self-consistent
            if expected > qpi:
                print(f"  qPI→QPc TABLE ERROR: qPI={qpi} QPc={expected} > qPI")
                errors += 1
            if expected < 0 or expected > 39:
                print(f"  qPI→QPc TABLE ERROR: qPI={qpi} QPc={expected} out of range")
                errors += 1

    info(f"Chroma QP table: 52 entries verified (RTL NOT YET IMPLEMENTED)")
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
    tb_sv = ROOT / "tests/rtl/h264_dequant_qp_sweep_tb_top.sv"
    rtl_src = ROOT / "fpga/Plex_MiSTer/rtl/h264_iq_idct_4x4.sv"

    if not tb_cpp.exists() or not tb_sv.exists():
        info("SKIP Verilator RTL sweep (testbench files not found)")
        return 0

    build_dir = ROOT / "build/verilator_qp_sweep"
    build_dir.mkdir(parents=True, exist_ok=True)

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

    result = subprocess.run([str(exe)], capture_output=True, text=True, cwd=ROOT)
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

    # 5. Sign-flip confirmation
    print("\n5. Sign-flip analysis (confirms corruption from truncation):")
    e = test_rtl_18bit_truncation_correctness()
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
