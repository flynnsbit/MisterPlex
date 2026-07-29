// Full-suite REAL RTL simulation for area-refactored intra + iq_idct_seq.
// - I4x4: independent ITU 8.3.1 host golden vs h264_intra4x4_pred RTL (~4600 vec)
// - iq_idct_seq: bit-exact vs parallel h264_dequant4x4_flex+h264_idct4x4 RTL (~3000 blk)
//
// SKIP is NOT PASS. This binary always executes Verilated RTL.
#include "Vintra_full_suite_tb_top.h"
#include "verilated.h"

#include <array>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <iostream>
#include <random>
#include <string>

static int g_fail = 0;
static int g_i4_pass = 0;
static int g_iq_pass = 0;

static void tick(Vintra_full_suite_tb_top& t) {
    t.clk = 0; t.eval();
    t.clk = 1; t.eval();
}

static int clip1(int v) {
    if (v < 0) return 0;
    if (v > 255) return 255;
    return v;
}

// Independent I4x4 predictor (ITU-T H.264 8.3.1), not transcribed from RTL.
static void host_i4(int mode, const uint8_t above[8], const uint8_t left[4],
                    uint8_t tl, bool hasA, bool hasL, int& used, uint8_t pred[16]) {
    int m = mode;
    if (!hasA && (mode == 0 || mode == 3 || mode == 7)) m = 2;
    if (!hasL && (mode == 1 || mode == 8)) m = 2;
    if ((!hasA || !hasL) && (mode == 4 || mode == 5 || mode == 6)) m = 2;
    if (mode > 8) { used = 15; for (int i = 0; i < 16; ++i) pred[i] = 128; return; }
    used = m;

    // q vector matching product layout (bottom-left → top-right)
    uint8_t q[15];
    q[0] = left[3];
    q[1] = left[3]; q[2] = left[2]; q[3] = left[1]; q[4] = left[0];
    q[5] = tl;
    for (int i = 0; i < 8; ++i) q[6 + i] = above[i];
    q[14] = above[7];

    auto a2 = [&](int i) -> uint8_t {
        return (uint8_t)((q[i] + q[i + 1] + 1) >> 1);
    };
    auto a3 = [&](int i) -> uint8_t {
        return (uint8_t)((q[i] + 2 * q[i + 1] + q[i + 2] + 2) >> 2);
    };

    int sumA = above[0] + above[1] + above[2] + above[3];
    int sumL = left[0] + left[1] + left[2] + left[3];
    uint8_t dc;
    if (hasA && hasL) dc = (uint8_t)((sumA + sumL + 4) >> 3);
    else if (hasA || hasL) dc = (uint8_t)(((hasA ? sumA : sumL) + 2) >> 2);
    else dc = 128;

    for (int i = 0; i < 16; ++i) {
        int x = i % 4, y = i / 4;
        int zvr = 2 * x - y;
        int zhd = 2 * y - x;
        int zhu = x + 2 * y;
        uint8_t p = 128;
        switch (m) {
        case 0: p = q[6 + x]; break;
        case 1: p = q[4 - y]; break;
        case 2: p = dc; break;
        case 3: p = a3(6 + x + y); break;
        case 4: p = a3(4 + x - y); break;
        case 5:
            if (zvr < 0) p = a3(5 + zvr);
            else if ((zvr % 2) == 0) p = a2(5 + zvr / 2);
            else p = a3(5 + (zvr - 1) / 2);
            break;
        case 6:
            if (zhd < 0) p = a3(3 - zhd);
            else if ((zhd % 2) == 0) p = a2(4 - zhd / 2);
            else p = a3(4 - (zhd + 1) / 2);
            break;
        case 7:
            if ((y % 2) == 0) p = a2(6 + x + y / 2);
            else p = a3(6 + x + (y - 1) / 2);
            break;
        case 8:
            if (zhu > 5) p = q[1];
            else if (zhu == 5) p = a3(0);
            else if ((zhu % 2) == 0) p = a2(3 - zhu / 2);
            else p = a3(2 - (zhu - 1) / 2);
            break;
        default: p = 128; break;
        }
        pred[i] = p;
    }
}

static void drive_i4(Vintra_full_suite_tb_top& t, int mode,
                     const uint8_t a[8], const uint8_t l[4], uint8_t tl,
                     bool ha, bool hl) {
    t.i4_mode = mode;
    t.i4_a0 = a[0]; t.i4_a1 = a[1]; t.i4_a2 = a[2]; t.i4_a3 = a[3];
    t.i4_a4 = a[4]; t.i4_a5 = a[5]; t.i4_a6 = a[6]; t.i4_a7 = a[7];
    t.i4_l0 = l[0]; t.i4_l1 = l[1]; t.i4_l2 = l[2]; t.i4_l3 = l[3];
    t.i4_tl = tl;
    t.i4_has_above = ha ? 1 : 0;
    t.i4_has_left  = hl ? 1 : 0;
    t.eval(); // combo
}

static void read_i4_pred(const Vintra_full_suite_tb_top& t, uint8_t p[16]) {
    p[0]=t.i4_p0;   p[1]=t.i4_p1;   p[2]=t.i4_p2;   p[3]=t.i4_p3;
    p[4]=t.i4_p4;   p[5]=t.i4_p5;   p[6]=t.i4_p6;   p[7]=t.i4_p7;
    p[8]=t.i4_p8;   p[9]=t.i4_p9;   p[10]=t.i4_p10; p[11]=t.i4_p11;
    p[12]=t.i4_p12; p[13]=t.i4_p13; p[14]=t.i4_p14; p[15]=t.i4_p15;
}

static bool check_i4(Vintra_full_suite_tb_top& t, int mode,
                     const uint8_t a[8], const uint8_t l[4], uint8_t tl,
                     bool ha, bool hl, const char* tag) {
    int used = 0;
    uint8_t exp[16], got[16];
    host_i4(mode, a, l, tl, ha, hl, used, exp);
    drive_i4(t, mode, a, l, tl, ha, hl);
    read_i4_pred(t, got);
    if ((int)t.i4_used_mode != used) {
        std::cerr << "FAIL I4 used_mode " << tag << " mode=" << mode
                  << " got " << (int)t.i4_used_mode << " exp " << used << "\n";
        ++g_fail;
        return false;
    }
    for (int i = 0; i < 16; ++i) {
        if (got[i] != exp[i]) {
            std::cerr << "FAIL I4 " << tag << " mode=" << mode << " px=" << i
                      << " got " << (int)got[i] << " exp " << (int)exp[i]
                      << " ha=" << ha << " hl=" << hl << "\n";
            ++g_fail;
            return false;
        }
    }
    ++g_i4_pass;
    return true;
}

static void set_iq_coeff(Vintra_full_suite_tb_top& t, const int16_t c[16]) {
    t.iq_c0=c[0];   t.iq_c1=c[1];   t.iq_c2=c[2];   t.iq_c3=c[3];
    t.iq_c4=c[4];   t.iq_c5=c[5];   t.iq_c6=c[6];   t.iq_c7=c[7];
    t.iq_c8=c[8];   t.iq_c9=c[9];   t.iq_c10=c[10]; t.iq_c11=c[11];
    t.iq_c12=c[12]; t.iq_c13=c[13]; t.iq_c14=c[14]; t.iq_c15=c[15];
}

static void read_iq(const Vintra_full_suite_tb_top& t, int32_t r[16]) {
    r[0]=(int32_t)t.iq_r0;   r[1]=(int32_t)t.iq_r1;
    r[2]=(int32_t)t.iq_r2;   r[3]=(int32_t)t.iq_r3;
    r[4]=(int32_t)t.iq_r4;   r[5]=(int32_t)t.iq_r5;
    r[6]=(int32_t)t.iq_r6;   r[7]=(int32_t)t.iq_r7;
    r[8]=(int32_t)t.iq_r8;   r[9]=(int32_t)t.iq_r9;
    r[10]=(int32_t)t.iq_r10; r[11]=(int32_t)t.iq_r11;
    r[12]=(int32_t)t.iq_r12; r[13]=(int32_t)t.iq_r13;
    r[14]=(int32_t)t.iq_r14; r[15]=(int32_t)t.iq_r15;
}

static void read_par(const Vintra_full_suite_tb_top& t, int32_t r[16]) {
    r[0]=(int32_t)t.par_r0;   r[1]=(int32_t)t.par_r1;
    r[2]=(int32_t)t.par_r2;   r[3]=(int32_t)t.par_r3;
    r[4]=(int32_t)t.par_r4;   r[5]=(int32_t)t.par_r5;
    r[6]=(int32_t)t.par_r6;   r[7]=(int32_t)t.par_r7;
    r[8]=(int32_t)t.par_r8;   r[9]=(int32_t)t.par_r9;
    r[10]=(int32_t)t.par_r10; r[11]=(int32_t)t.par_r11;
    r[12]=(int32_t)t.par_r12; r[13]=(int32_t)t.par_r13;
    r[14]=(int32_t)t.par_r14; r[15]=(int32_t)t.par_r15;
}

static bool run_iq_block(Vintra_full_suite_tb_top& t, const int16_t c[16],
                         int qp, int maxc, bool skip_dc, bool dc_ov,
                         int32_t dc_val, const char* tag) {
    set_iq_coeff(t, c);
    t.iq_qp = qp;
    t.iq_max_coeff = maxc;
    t.iq_skip_dc = skip_dc ? 1 : 0;
    t.iq_dc_override = dc_ov ? 1 : 0;
    t.iq_dc_value = dc_val;
    // Parallel is combo — sample after eval with same inputs
    t.eval();
    int32_t par[16];
    read_par(t, par);

    t.iq_start = 1; tick(t); t.iq_start = 0;
    int cyc = 0;
    while (!t.iq_done && cyc < 64) { tick(t); ++cyc; }
    if (!t.iq_done) {
        std::cerr << "FAIL iq_idct_seq no done " << tag << "\n";
        ++g_fail;
        return false;
    }
    int32_t seq[16];
    read_iq(t, seq);
    // Re-sample parallel after done (inputs still held)
    t.eval();
    read_par(t, par);
    for (int i = 0; i < 16; ++i) {
        if (seq[i] != par[i]) {
            std::cerr << "FAIL iq_idct_seq vs parallel " << tag
                      << " r" << i << " seq=" << seq[i] << " par=" << par[i]
                      << " qp=" << qp << " skip_dc=" << skip_dc
                      << " dc_ov=" << dc_ov << " cyc=" << cyc << "\n";
            ++g_fail;
            return false;
        }
    }
    ++g_iq_pass;
    return true;
}

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    Vintra_full_suite_tb_top top{};

    top.reset = 1;
    for (int i = 0; i < 4; ++i) tick(top);
    top.reset = 0;
    tick(top);

    // ═══════════════════════════════════════════════════════════════════
    // I4x4 full suite — target ≥4600 vectors
    // ═══════════════════════════════════════════════════════════════════
    std::mt19937 rng(0x14C04A4u);
    std::uniform_int_distribution<int> u8(0, 255);
    std::uniform_int_distribution<int> uMode(0, 8);

    // Structured corner cases
    const uint8_t zeros[8] = {};
    const uint8_t ones[8] = {255,255,255,255,255,255,255,255};
    const uint8_t ramp[8] = {0,32,64,96,128,160,192,224};
    const uint8_t leftZ[4] = {0,0,0,0};
    const uint8_t leftO[4] = {255,255,255,255};
    const uint8_t leftR[4] = {10,40,80,120};

    // Avail × mode × neighbour sets
    const bool avails[][2] = {
        {true,true},{true,false},{false,true},{false,false}
    };
    const uint8_t* above_sets[] = {zeros, ones, ramp};
    const uint8_t* left_sets[]  = {leftZ, leftO, leftR};
    const uint8_t tls[] = {0, 1, 128, 254, 255};

    for (int ai = 0; ai < 3; ++ai)
    for (int li = 0; li < 3; ++li)
    for (uint8_t tl : tls)
    for (auto av : avails)
    for (int mode = 0; mode <= 8; ++mode) {
        uint8_t a[8], l[4];
        std::memcpy(a, above_sets[ai], 8);
        std::memcpy(l, left_sets[li], 4);
        // Explicit top-right replicate case (above[4..7]=above[3])
        uint8_t a_rep[8];
        std::memcpy(a_rep, a, 8);
        a_rep[4] = a_rep[5] = a_rep[6] = a_rep[7] = a[3];
        check_i4(top, mode, a, l, tl, av[0], av[1], "struct");
        check_i4(top, mode, a_rep, l, tl, av[0], av[1], "ar_rep");
    }

    // Random neighbours × modes × avail — fill to ≥4600
    int structured = g_i4_pass;
    while (g_i4_pass < 4600) {
        uint8_t a[8], l[4];
        for (int i = 0; i < 8; ++i) a[i] = (uint8_t)u8(rng);
        for (int i = 0; i < 4; ++i) l[i] = (uint8_t)u8(rng);
        uint8_t tl = (uint8_t)u8(rng);
        bool ha = (rng() & 1) != 0;
        bool hl = (rng() & 1) != 0;
        int mode = uMode(rng);
        // 25% force AR replicate (product decode_top path when AR unavailable)
        if ((rng() % 4) == 0) {
            a[4] = a[5] = a[6] = a[7] = a[3];
        }
        if (!check_i4(top, mode, a, l, tl, ha, hl, "rand")) {
            // keep going but stop flood after a few fails
            if (g_fail >= 8) break;
        }
    }

    std::cout << "I4 RTL vs host golden: pass=" << g_i4_pass
              << " (structured=" << structured << ") fail_so_far=" << g_fail << "\n";

    // ═══════════════════════════════════════════════════════════════════
    // iq_idct_seq vs parallel RTL — 3000 blocks
    // ═══════════════════════════════════════════════════════════════════
    std::uniform_int_distribution<int> uQp(0, 51);
    std::uniform_int_distribution<int> uC(-2047, 2047);
    std::uniform_int_distribution<int> uSparse(0, 15);

    // Structured
    {
        int16_t z[16] = {};
        run_iq_block(top, z, 26, 16, false, false, 0, "zero");
        int16_t dc[16] = {};
        dc[0] = 50;
        run_iq_block(top, dc, 26, 16, false, false, 0, "dc50");
        int16_t ov[16] = {};
        run_iq_block(top, ov, 26, 15, true, true, 1000, "i16_ov");
        int16_t ac[16] = {};
        for (int i = 0; i < 15; ++i) ac[i] = (int16_t)(i + 1);
        run_iq_block(top, ac, 18, 15, true, true, 200, "i16_ac");
        for (int qp = 0; qp <= 51; qp += 3) {
            int16_t c[16] = {};
            c[0] = 100; c[1] = -40; c[5] = 17;
            char tag[32];
            std::snprintf(tag, sizeof(tag), "qp%d", qp);
            run_iq_block(top, c, qp, 16, false, false, 0, tag);
        }
    }

    int structured_iq = g_iq_pass;
    while (g_iq_pass < 3000 && g_fail < 20) {
        int16_t c[16] = {};
        int qp = uQp(rng);
        bool skip = (rng() % 5) == 0; // ~20% I16-style
        bool ov = skip && ((rng() & 1) != 0);
        int maxc = skip ? 15 : 16;
        int32_t dc_val = ov ? (int32_t)(rng() % 8001) - 4000 : 0;
        int nnz = 1 + (int)(rng() % 12);
        for (int k = 0; k < nnz; ++k) {
            int idx = uSparse(rng);
            if (skip && idx == 0 && ov) continue; // DC slot unused in coeff[]
            c[idx] = (int16_t)uC(rng);
        }
        char tag[32];
        std::snprintf(tag, sizeof(tag), "r%d", g_iq_pass);
        run_iq_block(top, c, qp, maxc, skip, ov, dc_val, tag);
    }

    std::cout << "iq_idct_seq vs parallel RTL: pass=" << g_iq_pass
              << " (structured=" << structured_iq << ") fail_so_far=" << g_fail << "\n";

    if (g_fail) {
        std::cerr << "INTRA_FULL_SUITE FAIL i4_pass=" << g_i4_pass
                  << " iq_pass=" << g_iq_pass << " fails=" << g_fail << "\n";
        return 1;
    }
    if (g_i4_pass < 4600 || g_iq_pass < 3000) {
        std::cerr << "INTRA_FULL_SUITE UNDERCOUNT i4=" << g_i4_pass
                  << " iq=" << g_iq_pass << "\n";
        return 2;
    }
    std::cout << "INTRA_FULL_SUITE PASS i4=" << g_i4_pass
              << " iq_idct_seq_vs_parallel=" << g_iq_pass
              << " (REAL RTL SIM, not model-only)\n";
    return 0;
}
