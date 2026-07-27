// Red-before-green: coefficient width truncation in the dequant pipeline.
//
// Feeds coefficients with |level| > 255 through the product RTL dequant,
// IDCT, and recon and verifies the output matches the spec-correct result.
//
// On the current RTL the [8:0] truncation wraps 300 → −212 (sign flip),
// producing dequant = −3392 instead of +4800.  This test MUST FAIL on the
// un-fixed RTL and PASS after the coefficient path is widened.

#include "Vlevel_width_tb_top.h"
#include "verilated.h"

#include <array>
#include <cstdint>
#include <cstdlib>
#include <iostream>

namespace {

constexpr int NORM_ADJUST[6][3] = {
    {10, 13, 16}, {11, 14, 18}, {13, 16, 20},
    {14, 18, 23}, {16, 20, 25}, {18, 23, 29},
};
constexpr int ZIGZAG[16] = {0,1,4,8,5,2,3,6,9,12,13,10,7,11,14,15};

int dequant_gold(int c, int qp, int scan) {
    int z = ZIGZAG[scan];
    int row = z / 4, col = z % 4;
    int odd = (row & 1) + (col & 1);
    int mi = (odd == 0) ? 0 : ((odd == 1) ? 1 : 2);
    int qmod = qp % 6, qdiv = qp / 6;
    int64_t qmul = static_cast<int64_t>(NORM_ADJUST[qmod][mi]) * 16;
    qmul <<= (qdiv + 2);
    int64_t v = (static_cast<int64_t>(c) * qmul + 32) >> 6;
    return static_cast<int>(v);
}

// H.264 4x4 integer IDCT (butterfly, same as product RTL)
void idct_gold(const std::array<int,16>& dq, std::array<int,16>& out) {
    int tmp[4][4], t2[4][4];
    // Row-major input
    for (int i = 0; i < 4; ++i)
        for (int j = 0; j < 4; ++j)
            tmp[i][j] = dq[i * 4 + j];
    // Horizontal
    for (int i = 0; i < 4; ++i) {
        int e0 = tmp[i][0] + tmp[i][2];
        int e1 = tmp[i][0] - tmp[i][2];
        int e2 = (tmp[i][1] >> 1) - tmp[i][3];
        int e3 = tmp[i][1] + (tmp[i][3] >> 1);
        t2[i][0] = e0 + e3;
        t2[i][1] = e1 + e2;
        t2[i][2] = e1 - e2;
        t2[i][3] = e0 - e3;
    }
    // Vertical
    for (int j = 0; j < 4; ++j) {
        int e0 = t2[0][j] + t2[2][j];
        int e1 = t2[0][j] - t2[2][j];
        int e2 = (t2[1][j] >> 1) - t2[3][j];
        int e3 = t2[1][j] + (t2[3][j] >> 1);
        out[0 * 4 + j] = (e0 + e3 + 32) >> 6;
        out[1 * 4 + j] = (e1 + e2 + 32) >> 6;
        out[2 * 4 + j] = (e1 - e2 + 32) >> 6;
        out[3 * 4 + j] = (e0 - e3 + 32) >> 6;
    }
}

int clip8(int v) { return v < 0 ? 0 : (v > 255 ? 255 : v); }

int failures = 0;

void check(const char* label, int got, int want) {
    if (got != want) {
        std::cerr << "FAIL " << label << ": got " << got << " want " << want << "\n";
        ++failures;
    }
}

int sx18(uint32_t v) {
    v &= 0x3FFFF;
    return (v & 0x20000) ? static_cast<int>(v) - 0x40000 : static_cast<int>(v);
}

} // namespace

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    auto dut = std::make_unique<Vlevel_width_tb_top>();

    // --- Test 1: coeff[0] = 300 at QP=4, rest zero, pred=128 ---
    // 300 in 9-bit signed wraps to −212 → sign flip in dequant.
    constexpr int TEST_COEFF = 300;
    constexpr int TEST_QP = 4;
    constexpr int PRED = 128;

    for (int i = 0; i < 16; ++i) {
        dut->coeff[i] = 0;
        dut->pred[i] = PRED;
    }
    dut->coeff[0] = static_cast<int16_t>(TEST_COEFF);
    dut->qp = TEST_QP;
    dut->max_coeff = 16;
    dut->eval();

    // Golden dequant
    std::array<int,16> gold_dq{};
    for (int i = 0; i < 16; ++i)
        gold_dq[i] = (i == 0) ? dequant_gold(TEST_COEFF, TEST_QP, 0) : 0;

    // Golden IDCT
    std::array<int,16> gold_idct{};
    idct_gold(gold_dq, gold_idct);

    // Golden recon
    std::array<int,16> gold_recon{};
    for (int i = 0; i < 16; ++i)
        gold_recon[i] = clip8(PRED + gold_idct[i]);

    std::cout << "level_width_tb: coeff[0]=" << TEST_COEFF << " QP=" << TEST_QP << "\n";
    std::cout << "  gold dequant[0]=" << gold_dq[0] << "\n";
    std::cout << "  RTL  dequant[0]=" << sx18(dut->dequant[0]) << "\n";

    // Check dequant
    for (int i = 0; i < 16; ++i)
        check("dequant", sx18(dut->dequant[i]), gold_dq[i]);

    // Check recon
    for (int i = 0; i < 16; ++i)
        check("recon", dut->recon[i], gold_recon[i]);

    // --- Test 2: coeff[0] = -652, sign preserved but magnitude wrong ---
    constexpr int TEST_COEFF2 = -652;
    for (int i = 0; i < 16; ++i) {
        dut->coeff[i] = 0;
        dut->pred[i] = PRED;
    }
    dut->coeff[0] = static_cast<int16_t>(TEST_COEFF2);
    dut->qp = TEST_QP;
    dut->max_coeff = 16;
    dut->eval();

    std::array<int,16> gold_dq2{};
    for (int i = 0; i < 16; ++i)
        gold_dq2[i] = (i == 0) ? dequant_gold(TEST_COEFF2, TEST_QP, 0) : 0;

    std::cout << "  coeff[0]=" << TEST_COEFF2 << " gold dequant[0]=" << gold_dq2[0]
              << " RTL=" << sx18(dut->dequant[0]) << "\n";
    for (int i = 0; i < 16; ++i)
        check("dequant2", sx18(dut->dequant[i]), gold_dq2[i]);

    // --- Test 3: boundary: coeff[0] = 256, first value that overflows 9-bit ---
    constexpr int TEST_COEFF3 = 256;
    for (int i = 0; i < 16; ++i) {
        dut->coeff[i] = 0;
        dut->pred[i] = PRED;
    }
    dut->coeff[0] = static_cast<int16_t>(TEST_COEFF3);
    dut->qp = TEST_QP;
    dut->max_coeff = 16;
    dut->eval();

    int gold_256 = dequant_gold(TEST_COEFF3, TEST_QP, 0);
    int rtl_256 = sx18(dut->dequant[0]);
    std::cout << "  coeff[0]=256 gold dequant[0]=" << gold_256 << " RTL=" << rtl_256 << "\n";
    check("boundary_256", rtl_256, gold_256);

    // --- Test 4: coeff[0] = 255, should pass even on current RTL ---
    constexpr int TEST_COEFF4 = 255;
    for (int i = 0; i < 16; ++i) {
        dut->coeff[i] = 0;
        dut->pred[i] = PRED;
    }
    dut->coeff[0] = static_cast<int16_t>(TEST_COEFF4);
    dut->qp = TEST_QP;
    dut->max_coeff = 16;
    dut->eval();

    int gold_255 = dequant_gold(TEST_COEFF4, TEST_QP, 0);
    int rtl_255 = sx18(dut->dequant[0]);
    std::cout << "  coeff[0]=255 gold dequant[0]=" << gold_255 << " RTL=" << rtl_255 << "\n";
    check("safe_255", rtl_255, gold_255);

    if (failures) {
        std::cerr << "level_width_tb: " << failures << " FAILURES (expected on pre-fix RTL)\n";
        return 1;
    }
    std::cout << "level_width_tb: PASS — coefficient width is correct\n";
    return 0;
}
