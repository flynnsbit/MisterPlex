// QP 0–51 dequant sweep for h264_dequant4x4 — LUMA AC ONLY, MODULE-LEVEL.
//
// WHAT THIS COMPARES: specDequant(coeff, qp, row, col) vs dut.dequant[pos]
//   specDequant = independent C++ model from ITU-T H.264 clause 8.5.12.1
//   dut.dequant = Verilator simulation of h264_dequant4x4.sv
//
// WHAT THIS DOES NOT COVER:
//   - IDCT, reconstruction, coefficient delivery (parser → dequant pipeline)
//   - Chroma dequant (QPc mapping not in RTL)
//   - Luma DC / chroma DC Hadamard (not in RTL)
//   - End-to-end frame decode
//
// Any spec≠RTL mismatch is a hard failure. No overflow classification.

#include "Vh264_dequant_qp_sweep_tb.h"
#include "verilated.h"

#include <array>
#include <cstdint>
#include <cstdlib>
#include <iostream>
#include <vector>

namespace {

// ── H.264 Spec Reference (ITU-T H.264 Table 8-13) ──────────────────────
// LevelScale4x4(m, i, j) for the default flat scaling matrix.
// Index: [qP%6][position_class]
// Position class: 0=both-even(a), 1=mixed(c), 2=both-odd(b)
constexpr int LEVEL_SCALE[6][3] = {
    {10, 13, 16},
    {11, 14, 18},
    {13, 16, 20},
    {14, 18, 23},
    {16, 20, 25},
    {18, 23, 29},
};

// H.264 4×4 zigzag scan table
constexpr int ZIGZAG[16] = {0, 1, 4, 8, 5, 2, 3, 6, 9, 12, 13, 10, 7, 11, 14, 15};

int positionClass(int row, int col) {
    int s = (row & 1) + (col & 1);
    return s == 0 ? 0 : (s == 1 ? 1 : 2);
}

// Spec-derived dequant: d = c * LevelScale(qP%6, i, j) * 2^(qP/6)
int specDequant(int coeff, int qp, int row, int col) {
    int m = qp % 6;
    int pc = positionClass(row, col);
    int ls = LEVEL_SCALE[m][pc];
    return coeff * ls * (1 << (qp / 6));
}

int signExtend(int v, unsigned int mask, unsigned int sbit) {
    v &= static_cast<int>(mask);
    if (static_cast<unsigned int>(v) & sbit) v -= static_cast<int>(mask + 1);
    return v;
}

} // namespace

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);

    // Accept optional output width argument (default 18 for pre-fix tree)
    int output_width = 18;
    for (int i = 1; i < argc; ++i) {
        if (std::string(argv[i]).rfind("--width=", 0) == 0) {
            output_width = std::atoi(argv[i] + 8);
        }
    }
    const int max_val = (1 << (output_width - 1)) - 1;
    const int min_val = -(1 << (output_width - 1));
    const unsigned int sign_mask = (1u << output_width) - 1u;
    const unsigned int sign_bit = 1u << (output_width - 1);

    std::cout << "RTL output width: signed [" << (output_width - 1)
              << ":0] = " << output_width << " bits (range ["
              << min_val << ", " << max_val << "])\n";

    Vh264_dequant_qp_sweep_tb dut;

    // Test coefficients — must include values large enough to overflow
    // the output width at high QP. The dequant product is c*na*2^(qP/6),
    // where na can be up to 29. At QP 51 (qdiv=8), coeff=18 gives
    // 18*29*256=132,864 which exceeds 18-bit signed range (±131071).
    // Omitting large coefficients would make this sweep blind to width bugs.
    const std::vector<int> test_coeffs = {
        0, 1, -1, 2, -2, 3, -3, 5, -5, 7, -7, 10, -10, 15, -15, 20, -20,
        50, -50, 100, -100, 127, -128, 200, -200, 255, -256
    };

    int total_compared = 0;
    int total_match = 0;
    int total_mismatch = 0;
    std::array<bool, 52> qp_pass{};
    qp_pass.fill(true);

    for (int qp = 0; qp < 52; ++qp) {
        int qp_compared = 0;

        for (int coeff_val : test_coeffs) {
            // Drive all 16 scan positions with the same coefficient
            dut.max_coeff = 16;
            dut.qp = static_cast<uint8_t>(qp);
            for (int i = 0; i < 16; ++i) {
                dut.coeff[i] = static_cast<int16_t>(coeff_val);
            }
            dut.eval();

            // Check each output position
            for (int scan = 0; scan < 16; ++scan) {
                int pos = ZIGZAG[scan];
                int row = pos / 4;
                int col = pos % 4;

                int spec_val = specDequant(coeff_val, qp, row, col);
                int rtl_raw = signExtend(static_cast<int>(dut.dequant[pos]), sign_mask, sign_bit);

                // Any difference between spec and RTL is a failure.
                // We do NOT classify overflows as "expected" or "theoretical".
                if (rtl_raw != spec_val) {
                    std::cerr << "MISMATCH: QP=" << qp
                              << " scan=" << scan << " pos=(" << row << "," << col
                              << ") coeff=" << coeff_val
                              << " spec=" << spec_val
                              << " rtl=" << rtl_raw << "\n";
                    ++total_mismatch;
                    qp_pass[qp] = false;
                } else {
                    ++total_match;
                }
                ++total_compared;
                ++qp_compared;
            }
        }
    }

    // Print QP coverage table
    std::cout << "\nQP coverage table (52/52):\n";
    std::cout << "QP  : ";
    for (int qp = 0; qp < 52; ++qp) {
        if (qp > 0 && qp % 13 == 0) std::cout << "\n      ";
        std::cout << (qp < 10 ? " " : "") << qp << (qp_pass[qp] ? "✓" : "✗") << " ";
    }
    std::cout << "\n\n";

    // Count passed QPs
    int qp_passed = 0;
    for (int qp = 0; qp < 52; ++qp) {
        if (qp_pass[qp]) ++qp_passed;
    }

    std::cout << "Total: compared=" << total_compared
              << " matched=" << total_match
              << " mismatched=" << total_mismatch
              << " qp_passed=" << qp_passed << "/52\n";

    if (total_mismatch > 0) {
        std::cerr << "FAIL dequant-qp-sweep-rtl: " << total_mismatch
                  << " mismatches in RTL simulation\n";
        return 1;
    }

    std::cout << "OK dequant-qp-sweep-rtl: QP 0–51 all " << qp_passed
              << "/52 passed, " << total_compared << " vectors verified against spec\n";
    return 0;
}
