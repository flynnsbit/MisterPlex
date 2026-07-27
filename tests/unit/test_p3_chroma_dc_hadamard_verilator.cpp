// Standalone test for h264_chroma_dc_hadamard_inv.
// Spec-derived vectors from H.264 clause 8.5.11.2, verified against
// host/libmisterplex/h264_recon.hpp:481 invChromaDc2x2().
// All arithmetic is independent of RTL — transcribed from the specification.
#include "Vp3_chroma_dc_hadamard_tb.h"
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <iostream>
#include <array>
#include <vector>

// Independent reference: H.264 clause 8.5.11.2 inverse 2x2 Hadamard + dequant.
// Not copied from the RTL — derived from the spec text.
struct HadRef {
    int16_t dc[4]; // raster order (by*2+bx): [0]=(0,0) [1]=(0,1) [2]=(1,0) [3]=(1,1)
};
static HadRef specHadamard(const int16_t coeff[4], int qp) {
    // Butterfly stage 1 (clause 8.5.11.2, equations 8-324..8-327)
    int a = coeff[0] + coeff[1];
    int e = coeff[0] - coeff[1];
    int b = coeff[2] - coeff[3];
    int c = coeff[2] + coeff[3];
    // Butterfly stage 2
    int had[4];
    had[0] = a + c;   // (0,0)
    had[1] = e + b;   // (0,1)
    had[2] = a - c;   // (1,0)
    had[3] = e - b;   // (1,1)
    // Dequant: qmul = (mf0[qp%6] * 16) << (qp/6 + 2)
    static const int mf0[6] = {10, 11, 13, 14, 16, 18};
    int qmul = (mf0[qp % 6] * 16) << (qp / 6 + 2);
    HadRef out;
    for (int i = 0; i < 4; ++i)
        out.dc[i] = static_cast<int16_t>((had[i] * qmul) >> 7);
    return out;
}

struct TestVec {
    const char* name;
    int16_t coeff[4];
    int qp;
};

static int sign18(int v) {
    // Sign-extend 18-bit value
    if (v & (1 << 17)) v |= ~((1 << 18) - 1);
    return v;
}

int main() {
    // Test vectors: each designed to exercise a different aspect
    std::vector<TestVec> vecs = {
        // Basic functionality
        {"all_zero",        {0, 0, 0, 0},       0},
        {"single_dc",       {1, 0, 0, 0},       0},
        {"all_ones",        {1, 1, 1, 1},       0},
        {"all_neg_ones",    {-1,-1,-1,-1},       0},
        {"alternating",     {1,-1, 1,-1},        0},
        {"diagonal",        {1, 0, 0, 1},        0},
        {"anti_diagonal",   {0, 1, 1, 0},        0},

        // Sign patterns
        {"plus_minus",      {10,-10, 10,-10},    10},
        {"minus_plus",      {-10, 10,-10, 10},   10},
        {"mixed_signs",     {5, -3, 7, -2},      15},

        // QP sweep — same coefficients, different QP
        {"qp0",             {3, -2, 1, -1},      0},
        {"qp6",             {3, -2, 1, -1},      6},
        {"qp12",            {3, -2, 1, -1},      12},
        {"qp18",            {3, -2, 1, -1},      18},
        {"qp24",            {3, -2, 1, -1},      24},
        {"qp30",            {3, -2, 1, -1},      30},
        {"qp36",            {3, -2, 1, -1},      36},
        {"qp39",            {3, -2, 1, -1},      39},

        // qp%6 sweep — one value from each mf0 row
        {"qp0_mf10",        {2, 1, -1, -2},      0},
        {"qp1_mf11",        {2, 1, -1, -2},      1},
        {"qp2_mf13",        {2, 1, -1, -2},      2},
        {"qp3_mf14",        {2, 1, -1, -2},      3},
        {"qp4_mf16",        {2, 1, -1, -2},      4},
        {"qp5_mf18",        {2, 1, -1, -2},      5},

        // Boundary values — extreme coefficients
        {"max_pos",         {127, 127, 127, 127}, 0},
        {"max_neg",         {-128,-128,-128,-128}, 0},
        {"max_mixed",       {127,-128, 127,-128}, 0},
        {"clip_stress_lo",  {-128,-128,-128,-128}, 39},
        {"clip_stress_hi",  {127, 127, 127, 127}, 39},

        // Realistic film content (small levels, moderate QP)
        {"film_skin",       {2, -1, 0, 1},       26},
        {"film_sky",        {1, 0, 0, 0},         22},
        {"film_dark",       {-1, 0, 0, 0},        30},
        {"film_edge",       {5, -3, 2, -1},       20},
        {"film_flat",       {0, 0, 0, 0},         26},
    };

    Vp3_chroma_dc_hadamard_tb dut;
    int pass = 0, fail = 0;

    for (const auto& v : vecs) {
        for (int i = 0; i < 4; ++i)
            dut.coeff[i] = v.coeff[i];
        dut.qp = v.qp;
        dut.eval();

        auto ref = specHadamard(v.coeff, v.qp);
        bool ok = true;
        for (int i = 0; i < 4; ++i) {
            int rtl_val = sign18(dut.dc[i]);
            int ref_val = ref.dc[i];
            if (rtl_val != ref_val) {
                std::cerr << "FAIL " << v.name << " dc[" << i << "]"
                          << " rtl=" << rtl_val << " ref=" << ref_val
                          << " (qp=" << v.qp << " coeff={"
                          << v.coeff[0] << "," << v.coeff[1] << ","
                          << v.coeff[2] << "," << v.coeff[3] << "})\n";
                ok = false;
            }
        }
        // Degeneracy defence (#18): non-zero input must produce non-zero output
        bool anyInputNonZero = false, anyOutputNonZero = false;
        for (int i = 0; i < 4; ++i) {
            if (v.coeff[i] != 0) anyInputNonZero = true;
            if (sign18(dut.dc[i]) != 0) anyOutputNonZero = true;
        }
        if (anyInputNonZero && !anyOutputNonZero) {
            std::cerr << "DEGENERACY " << v.name
                      << ": non-zero input produced all-zero output — transform never exercised\n";
            ok = false;
        }
        if (ok) ++pass;
        else ++fail;
    }

    std::cout << "Chroma DC Hadamard: " << pass << " pass, " << fail << " fail"
              << " out of " << vecs.size() << " vectors\n";

    // Count how many non-zero-input vectors produced non-zero output
    int nonZeroInputVecs = 0, nonTrivialVecs = 0;
    for (const auto& v : vecs) {
        bool hasInput = false;
        for (int i = 0; i < 4; ++i) if (v.coeff[i] != 0) hasInput = true;
        if (hasInput) {
            ++nonZeroInputVecs;
            for (int i = 0; i < 4; ++i) dut.coeff[i] = v.coeff[i];
            dut.qp = v.qp;
            dut.eval();
            for (int i = 0; i < 4; ++i) if (sign18(dut.dc[i]) != 0) { ++nonTrivialVecs; break; }
        }
    }
    std::cout << "Degeneracy: " << nonTrivialVecs << "/" << nonZeroInputVecs
              << " non-zero-input vectors produced non-zero output\n";

    if (fail) {
        std::cerr << "CHROMA DC HADAMARD TEST FAILED\n";
        return 1;
    }

    std::cout << "CHROMA DC HADAMARD TEST PASS\n";
    return 0;
}
