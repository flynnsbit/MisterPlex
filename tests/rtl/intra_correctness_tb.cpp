// Vector evidence for area-refactored intra + iq_idct_seq + I16 DC Hadamard.
// Independent ITU-ish host models; sequential RTL allowed hundreds of cycles.
#include "Vintra_correctness_tb_top.h"
#include "verilated.h"

#include <array>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <iostream>
#include <vector>

static int g_fail = 0;
static void tick(Vintra_correctness_tb_top& t) {
    t.clk = 0; t.eval();
    t.clk = 1; t.eval();
}

static int clip1(int v) {
    if (v < 0) return 0;
    if (v > 255) return 255;
    return v;
}

// Spec I16 plane 8.3.3.4 with above[i]=a0+i, left[i]=l0+i
static void spec_i16_plane(uint8_t a0, uint8_t l0, uint8_t tl, uint8_t out[256]) {
    uint8_t above[16], left[16];
    for (int i = 0; i < 16; ++i) {
        above[i] = static_cast<uint8_t>(a0 + i);
        left[i] = static_cast<uint8_t>(l0 + i);
    }
    int H = 0, V = 0;
    for (int xp = 0; xp < 8; ++xp) {
        int pos = above[8 + xp];
        int neg = (xp == 7) ? (int)tl : (int)above[6 - xp];
        H += (xp + 1) * (pos - neg);
    }
    for (int yp = 0; yp < 8; ++yp) {
        int pos = left[8 + yp];
        int neg = (yp == 7) ? (int)tl : (int)left[6 - yp];
        V += (yp + 1) * (pos - neg);
    }
    int a = 16 * ((int)above[15] + (int)left[15]);
    int b = (5 * H + 32) >> 6;
    int c = (5 * V + 32) >> 6;
    for (int y = 0; y < 16; ++y)
        for (int x = 0; x < 16; ++x)
            out[y * 16 + x] = (uint8_t)clip1((a + b * (x - 7) + c * (y - 7) + 16) >> 5);
}

// Chroma DC quadrant 8.3.4.1 with above[i]=a0+i, left[i]=l0+i
static void spec_chroma_dc(uint8_t a0, uint8_t l0, bool ha, bool hl,
                           uint8_t& tl, uint8_t& tr, uint8_t& bl, uint8_t& br) {
    int sa0 = 0, sa1 = 0, sl0 = 0, sl1 = 0;
    for (int i = 0; i < 4; ++i) {
        sa0 += a0 + i; sa1 += a0 + 4 + i;
        sl0 += l0 + i; sl1 += l0 + 4 + i;
    }
    if (ha && hl) {
        tl = (uint8_t)((sa0 + sl0 + 4) >> 3);
        tr = (uint8_t)((sa1 + 2) >> 2);
        bl = (uint8_t)((sl1 + 2) >> 2);
        br = (uint8_t)((sa1 + sl1 + 4) >> 3);
    } else if (ha) {
        tl = (uint8_t)((sa0 + 2) >> 2);
        tr = (uint8_t)((sa1 + 2) >> 2);
        bl = tl; br = tr;
    } else if (hl) {
        tl = (uint8_t)((sl0 + 2) >> 2);
        bl = (uint8_t)((sl1 + 2) >> 2);
        tr = tl; br = bl;
    } else {
        tl = tr = bl = br = 128;
    }
}

// Luma DC Hadamard + scale (match h264_transform_dc.sv / 8.5.10)
static int32_t sat29(int64_t v) {
    if (v > 268435455) return 268435455;
    if (v < -268435456) return -268435456;
    return (int32_t)v;
}

static void host_luma_dc_hadamard(const int16_t coeff_zz[16], int qp, int32_t dc[16]) {
    // zigzag scan_of_raster
    static const int scan[16] = {
        0,1,5,6, 2,4,7,12, 3,8,11,13, 9,10,14,15
    };
    int32_t c[16];
    for (int r = 0; r < 16; ++r) c[r] = coeff_zz[scan[r]];

    int32_t g[16];
    for (int row = 0; row < 4; ++row) {
        int i = row * 4;
        g[i+0] = c[i+0]+c[i+1]+c[i+2]+c[i+3];
        g[i+1] = c[i+0]+c[i+1]-c[i+2]-c[i+3];
        g[i+2] = c[i+0]-c[i+1]-c[i+2]+c[i+3];
        g[i+3] = c[i+0]-c[i+1]+c[i+2]-c[i+3];
    }
    int32_t f[16];
    for (int col = 0; col < 4; ++col) {
        f[0*4+col] = g[0*4+col]+g[1*4+col]+g[2*4+col]+g[3*4+col];
        f[1*4+col] = g[0*4+col]+g[1*4+col]-g[2*4+col]-g[3*4+col];
        f[2*4+col] = g[0*4+col]-g[1*4+col]-g[2*4+col]+g[3*4+col];
        f[3*4+col] = g[0*4+col]-g[1*4+col]+g[2*4+col]-g[3*4+col];
    }
    static const int na_tab[6] = {10,11,13,14,16,18};
    int na = na_tab[qp % 6];
    int qdiv = qp / 6;
    for (int i = 0; i < 16; ++i) {
        int64_t mul = (int64_t)f[i] * na;
        int64_t prod = mul << qdiv;
        int64_t rnd = (prod + 2) >> 2;
        dc[i] = sat29(rnd);
    }
}

// Minimal IDCT residual path matching iq_idct_seq / dequant+idct for DC-only block
static void host_iq_idct_dc_only(int16_t c0, int qp, int32_t& r0) {
    // LevelScale for (0,0): na = norm_adjust(qmod,0) which is first column of table
    // From RTL: m=0 for (0,0) → case {qmod,0}: 10,11,13,14,16,18
    static const int na0[6] = {10,11,13,14,16,18};
    int na = na0[qp % 6];
    int qdiv = qp / 6;
    // d = ((c*na << qdiv) + 2) >> 2   (folded x16 and >>6)
    int64_t mul = (int64_t)c0 * na;
    int64_t d0 = (mul << qdiv);
    d0 = (d0 + 2) >> 2;
    // IDCT of DC-only: all residual = (d0 + 32) >> 6 after butterflies that preserve DC*4*4?
    // Full 4x4 IDCT: residual[i] = (f + 32) >> 6 where for DC-only f = d0 for all after H*d*H^T
    // Actually H.264 IDCT: for matrix with only d00, output all samples = (d00 + 32) >> 6
    r0 = (int32_t)((d0 + 32) >> 6);
}

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    Vintra_correctness_tb_top top{};

    top.reset = 1;
    for (int i = 0; i < 4; ++i) tick(top);
    top.reset = 0;
    tick(top);

    // ---- I16 Plane PARALLEL_OUT=1 ----
    {
        uint8_t ref[256];
        spec_i16_plane(20, 30, 25, ref);
        top.i16_mode = 3;
        top.i16_above_flat = 20;
        top.i16_left_flat = 30;
        top.i16_top_left = 25;
        top.i16_has_above = 1;
        top.i16_has_left = 1;
        top.i16_start = 1; tick(top); top.i16_start = 0;
        int cyc = 0;
        while (!top.i16_valid && cyc < 400) { tick(top); ++cyc; }
        if (!top.i16_valid) {
            std::cerr << "FAIL I16 plane PARALLEL_OUT=1: no valid in " << cyc << " cyc\n";
            ++g_fail;
        } else if (top.i16_pred0 != ref[0] || top.i16_pred255 != ref[255]) {
            std::cerr << "FAIL I16 plane P1: pred0 got " << (int)top.i16_pred0
                      << " exp " << (int)ref[0]
                      << " pred255 got " << (int)top.i16_pred255
                      << " exp " << (int)ref[255] << " cyc=" << cyc << "\n";
            ++g_fail;
        } else {
            std::cout << "OK I16 plane PARALLEL_OUT=1 bit-exact corners cyc=" << cyc << "\n";
        }
    }

    // ---- I16 Plane PARALLEL_OUT=0 + rd_data ----
    {
        uint8_t ref[256];
        spec_i16_plane(20, 30, 25, ref);
        top.i16s_mode = 3;
        top.i16s_above_flat = 20;
        top.i16s_left_flat = 30;
        top.i16s_top_left = 25;
        top.i16s_has_above = 1;
        top.i16s_has_left = 1;
        top.i16s_rd_addr = 0;
        top.i16s_start = 1; tick(top); top.i16s_start = 0;
        int cyc = 0;
        while (!top.i16s_valid && cyc < 400) { tick(top); ++cyc; }
        if (!top.i16s_valid) {
            std::cerr << "FAIL I16 PARALLEL_OUT=0: no valid\n";
            ++g_fail;
        } else {
            // 1-cycle sync read
            top.i16s_rd_addr = 0; tick(top);
            uint8_t d0 = top.i16s_rd_data;
            top.i16s_rd_addr = 255; tick(top);
            uint8_t d255 = top.i16s_rd_data;
            if (d0 != ref[0] || d255 != ref[255]) {
                std::cerr << "FAIL I16 P0 rd: d0=" << (int)d0 << " exp " << (int)ref[0]
                          << " d255=" << (int)d255 << " exp " << (int)ref[255] << "\n";
                ++g_fail;
            } else {
                std::cout << "OK I16 PARALLEL_OUT=0 rd_data corners live cyc=" << cyc << "\n";
            }
        }
    }

    // ---- Chroma DC distinct quadrants ----
    {
        uint8_t tl, tr, bl, br;
        spec_chroma_dc(10, 50, true, true, tl, tr, bl, br);
        top.ch_mode = 0;
        top.ch_above_flat = 10;
        top.ch_left_flat = 50;
        top.ch_top_left = 0;
        top.ch_has_above = 1;
        top.ch_has_left = 1;
        top.ch_start = 1; tick(top); top.ch_start = 0;
        int cyc = 0;
        while (!top.ch_valid && cyc < 200) { tick(top); ++cyc; }
        if (!top.ch_valid) {
            std::cerr << "FAIL chroma DC: no valid\n";
            ++g_fail;
        } else if (top.ch_pred0 != tl || top.ch_pred36 != br) {
            std::cerr << "FAIL chroma DC quadrants: pred0=" << (int)top.ch_pred0
                      << " exp tl=" << (int)tl
                      << " pred36=" << (int)top.ch_pred36
                      << " exp br=" << (int)br
                      << " (tr=" << (int)tr << " bl=" << (int)bl << ")\n";
            ++g_fail;
        } else if (tl == br && tr == bl && tl == tr) {
            std::cerr << "FAIL chroma DC: collapsed to single average (luma-like)\n";
            ++g_fail;
        } else {
            std::cout << "OK chroma DC per-quadrant distinct tl=" << (int)tl
                      << " br=" << (int)br << " cyc=" << cyc << "\n";
        }
    }

    // ---- I4 vertical: top-right replicate vs distinct ----
    {
        // With AR = top[3] replicate: above4=above3
        top.i4_mode = 0; // vertical
        top.i4_has_above = 1;
        top.i4_has_left = 1;
        top.i4_above0 = 10;
        top.i4_above3 = 40;
        top.i4_above4 = 40; // replicate
        top.i4_above7 = 40;
        top.i4_left0 = 100;
        tick(top);
        uint8_t p0_rep = top.i4_pred0;
        uint8_t p3_rep = top.i4_pred3;
        // Distinct AR (would be wrong if AR unavailable but used)
        top.i4_above4 = 200;
        top.i4_above7 = 220;
        tick(top);
        uint8_t p0_ar = top.i4_pred0;
        uint8_t p3_ar = top.i4_pred3;
        // Vertical only uses above[0..3]; pred should match replicate path
        if (p0_rep != 10 || p3_rep != 40) {
            std::cerr << "FAIL I4 vertical base: p0=" << (int)p0_rep << " p3=" << (int)p3_rep << "\n";
            ++g_fail;
        } else if (p0_ar != p0_rep || p3_ar != p3_rep) {
            // vertical shouldn't depend on AR — good if equal
            std::cerr << "FAIL I4 vertical leaked AR into pred\n";
            ++g_fail;
        } else {
            std::cout << "OK I4 vertical ignores AR; mode-avail path live used_mode="
                      << (int)top.i4_used_mode << "\n";
        }
        // DDL mode 3: pred[15] taps above[6]/7] (AR). pred[0] does not.
        top.i4_mode = 3;
        top.i4_has_above = 1;
        top.i4_above4 = 40; top.i4_above7 = 40; tick(top);
        uint8_t ddl_rep = top.i4_pred15;
        top.i4_above4 = 200; top.i4_above7 = 220; tick(top);
        uint8_t ddl_ar = top.i4_pred15;
        if (ddl_rep == ddl_ar) {
            std::cerr << "FAIL I4 DDL: AR replicate did not change pred15 (both "
                      << (int)ddl_rep << ")\n";
            ++g_fail;
        } else {
            std::cout << "OK I4 DDL top-right sensitive (rep=" << (int)ddl_rep
                      << " ar=" << (int)ddl_ar << ") — decode_top substitutes top[3]\n";
        }
        // Unavailable above → mode falls back to DC
        top.i4_mode = 0;
        top.i4_has_above = 0;
        tick(top);
        if (top.i4_used_mode != 2) {
            std::cerr << "FAIL I4 avail: mode0 without above used_mode="
                      << (int)top.i4_used_mode << " exp 2\n";
            ++g_fail;
        } else {
            std::cout << "OK I4 neighbour availability fallback to DC\n";
        }
    }

    // ---- I16 DC Hadamard ----
    {
        int16_t coeff[16] = {};
        coeff[0] = 100;
        coeff[1] = -20;
        int32_t host_dc[16];
        host_luma_dc_hadamard(coeff, 26, host_dc);
        top.hm_c0 = 100;
        top.hm_c1 = -20;
        top.hm_qp = 26;
        tick(top);
        if ((int32_t)top.hm_dc0 != host_dc[0] || (int32_t)top.hm_dc1 != host_dc[1]) {
            std::cerr << "FAIL Hadamard: rtl dc0=" << (int32_t)top.hm_dc0
                      << " host " << host_dc[0]
                      << " rtl dc1=" << (int32_t)top.hm_dc1
                      << " host " << host_dc[1] << "\n";
            ++g_fail;
        } else if (host_dc[0] == 0 && host_dc[1] == 0) {
            std::cerr << "FAIL Hadamard: trivial zero output\n";
            ++g_fail;
        } else {
            std::cout << "OK I16 DC Hadamard bit-exact host dc0=" << host_dc[0]
                      << " dc1=" << host_dc[1] << "\n";
        }
    }

    // ---- iq_idct_seq DC-only ----
    {
        int32_t host_r0 = 0;
        host_iq_idct_dc_only(50, 26, host_r0);
        top.iq_c0 = 50;
        top.iq_c1 = 0;
        top.iq_qp = 26;
        top.iq_skip_dc = 0;
        top.iq_dc_override = 0;
        top.iq_dc_value = 0;
        top.iq_start = 1; tick(top); top.iq_start = 0;
        int cyc = 0;
        while (!top.iq_done && cyc < 40) { tick(top); ++cyc; }
        if (!top.iq_done) {
            std::cerr << "FAIL iq_idct_seq: no done\n";
            ++g_fail;
        } else if ((int32_t)top.iq_r0 != host_r0) {
            std::cerr << "FAIL iq_idct_seq r0=" << (int32_t)top.iq_r0
                      << " host " << host_r0 << " cyc=" << cyc << "\n";
            ++g_fail;
        } else {
            std::cout << "OK iq_idct_seq DC-only residual r0=" << host_r0
                      << " cyc=" << cyc << "\n";
        }
        // skip_dc + override: AC coeffs must be 0 (coeff[0] is AC slot 0 under skip_dc)
        top.iq_skip_dc = 1;
        top.iq_dc_override = 1;
        top.iq_dc_value = 1000;
        top.iq_c0 = 0;
        top.iq_c1 = 0;
        top.iq_start = 1; tick(top); top.iq_start = 0;
        cyc = 0;
        while (!top.iq_done && cyc < 40) { tick(top); ++cyc; }
        int32_t exp_ov = (1000 + 32) >> 6;
        if (!top.iq_done || (int32_t)top.iq_r0 != exp_ov) {
            std::cerr << "FAIL iq_idct_seq dc_override: r0=" << (int32_t)top.iq_r0
                      << " exp " << exp_ov << "\n";
            ++g_fail;
        } else {
            std::cout << "OK iq_idct_seq skip_dc+override r0=" << exp_ov << "\n";
        }
    }

    if (g_fail) {
        std::cerr << "INTRA_CORRECTNESS FAIL count=" << g_fail << "\n";
        return 1;
    }
    std::cout << "INTRA_CORRECTNESS PASS\n";
    return 0;
}
