// Real RTL sim for serialized MC interpolators (h264_mc_luma_qpel / chroma_epel).
// Golden model is written from ITU-T H.264 8.4.2.2.1 / 8.4.2.2.2 — NOT from RTL.
//
// Coverage:
//   - All 16 luma quarter-pel sub-positions (G..r) on multiple windows
//   - Centre j: full-precision intermediates, single (j1+512)>>10 (RED: double-round differs)
//   - Chroma 1/8-pel over all 8x8 frac pairs on several windows
//   - Edge-replicated 21x21 / 9x9 windows (what clamp+fetch must deliver)

#include "Vh264_mc_qpel_tb_top.h"
#include "verilated.h"

#include <array>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <random>
#include <string>
#include <vector>

static int g_fails = 0;
static int g_checks = 0;

#define CHECK(cond)                                                                                \
    do {                                                                                           \
        ++g_checks;                                                                                \
        if (!(cond)) {                                                                             \
            std::fprintf(stderr, "FAIL %s:%d: %s\n", __FILE__, __LINE__, #cond);                  \
            ++g_fails;                                                                             \
        }                                                                                          \
    } while (0)

static void tick(Vh264_mc_qpel_tb_top& dut) {
    dut.clk = 0;
    dut.eval();
    dut.clk = 1;
    dut.eval();
}

static int clip1(int v) {
    if (v < 0)
        return 0;
    if (v > 255)
        return 255;
    return v;
}

static int avg2(int a, int b) { return (a + b + 1) >> 1; }

// 6-tap (1,-5,20,20,-5,1) — shift/add form matches the standard filter weights.
static int tap6(int a0, int a1, int a2, int a3, int a4, int a5) {
    return a0 - 5 * a1 + 20 * a2 + 20 * a3 - 5 * a4 + a5;
}

// Spec luma qpel over a pre-clamped 21x21 window (origin at integer sample (-2,-2)).
static void spec_luma_qpel(const uint8_t win[21 * 21], int fx, int fy, uint8_t out[16 * 16]) {
    auto W = [&](int r, int c) -> int { return static_cast<int>(win[r * 21 + c]); };

    // Unrounded horizontal plane b1[row 0..20][col 0..15]
    int b1[21][16];
    for (int r = 0; r < 21; ++r)
        for (int x = 0; x < 16; ++x)
            b1[r][x] = tap6(W(r, x), W(r, x + 1), W(r, x + 2), W(r, x + 3), W(r, x + 4), W(r, x + 5));

    auto round5 = [](int v) { return clip1((v + 16) >> 5); };
    auto round10 = [](int v) { return clip1((v + 512) >> 10); };

    // Half samples used by the 16 positions
    int b[16][16];  // horizontal half at integer row y+2
    int s[16][16];  // horizontal half at integer row y+3
    int h[16][16];  // vertical half over integer column x+2
    int m[16][16];  // vertical half over integer column x+3
    int j[16][16];  // centre: vertical 6-tap over unrounded b1, one round

    for (int y = 0; y < 16; ++y) {
        for (int x = 0; x < 16; ++x) {
            b[y][x] = round5(b1[y + 2][x]);
            s[y][x] = round5(b1[y + 3][x]);
            h[y][x] = round5(tap6(W(y, x + 2), W(y + 1, x + 2), W(y + 2, x + 2), W(y + 3, x + 2),
                                  W(y + 4, x + 2), W(y + 5, x + 2)));
            m[y][x] = round5(tap6(W(y, x + 3), W(y + 1, x + 3), W(y + 2, x + 3), W(y + 3, x + 3),
                                  W(y + 4, x + 3), W(y + 5, x + 3)));
            const int j1 = tap6(b1[y][x], b1[y + 1][x], b1[y + 2][x], b1[y + 3][x], b1[y + 4][x],
                                b1[y + 5][x]);
            j[y][x] = round10(j1);
        }
    }

    for (int y = 0; y < 16; ++y) {
        for (int x = 0; x < 16; ++x) {
            const int G = W(y + 2, x + 2);
            const int H = W(y + 2, x + 3);
            const int M = W(y + 3, x + 2);
            int p = 0;
            switch ((fy << 2) | fx) {
            case 0b0000: p = G; break;                         // G
            case 0b0001: p = avg2(G, b[y][x]); break;          // a
            case 0b0010: p = b[y][x]; break;                   // b
            case 0b0011: p = avg2(b[y][x], H); break;          // c
            case 0b0100: p = avg2(G, h[y][x]); break;          // d
            case 0b0101: p = avg2(b[y][x], h[y][x]); break;    // e
            case 0b0110: p = avg2(b[y][x], j[y][x]); break;    // f
            case 0b0111: p = avg2(b[y][x], m[y][x]); break;    // g
            case 0b1000: p = h[y][x]; break;                   // h
            case 0b1001: p = avg2(h[y][x], j[y][x]); break;    // i
            case 0b1010: p = j[y][x]; break;                   // j
            case 0b1011: p = avg2(j[y][x], m[y][x]); break;    // k
            case 0b1100: p = avg2(M, h[y][x]); break;          // n
            case 0b1101: p = avg2(h[y][x], s[y][x]); break;    // p
            case 0b1110: p = avg2(j[y][x], s[y][x]); break;    // q
            default: p = avg2(m[y][x], s[y][x]); break;        // r
            }
            out[y * 16 + x] = static_cast<uint8_t>(p);
        }
    }
}

// Double-rounded j (classic bug): round b1 to b then vertical 6-tap +16>>5.
static void bad_double_round_j(const uint8_t win[21 * 21], uint8_t out[16 * 16]) {
    auto W = [&](int r, int c) -> int { return static_cast<int>(win[r * 21 + c]); };
    int b_rounded[21][16];
    for (int r = 0; r < 21; ++r)
        for (int x = 0; x < 16; ++x) {
            const int b1 = tap6(W(r, x), W(r, x + 1), W(r, x + 2), W(r, x + 3), W(r, x + 4),
                                W(r, x + 5));
            b_rounded[r][x] = clip1((b1 + 16) >> 5);
        }
    for (int y = 0; y < 16; ++y)
        for (int x = 0; x < 16; ++x) {
            const int j1 = tap6(b_rounded[y][x], b_rounded[y + 1][x], b_rounded[y + 2][x],
                                b_rounded[y + 3][x], b_rounded[y + 4][x], b_rounded[y + 5][x]);
            out[y * 16 + x] = static_cast<uint8_t>(clip1((j1 + 16) >> 5));
        }
}

// Spec chroma 1/8-pel, 9x9 window, 8x8 out. Single +32>>6.
static void spec_chroma_epel(const uint8_t win[9 * 9], int xF, int yF, uint8_t out[8 * 8]) {
    auto W = [&](int r, int c) -> int { return static_cast<int>(win[r * 9 + c]); };
    for (int y = 0; y < 8; ++y) {
        for (int x = 0; x < 8; ++x) {
            const int A = W(y, x);
            const int B = W(y, x + 1);
            const int C = W(y + 1, x);
            const int D = W(y + 1, x + 1);
            const int v = (8 - xF) * (8 - yF) * A + xF * (8 - yF) * B + (8 - xF) * yF * C +
                          xF * yF * D + 32;
            out[y * 8 + x] = static_cast<uint8_t>((v >> 6) & 0xff);
        }
    }
}

// Edge clamp: replicate picture border into a 21x21 / 9x9 fetch window.
static void build_luma_window_clamped(const std::vector<uint8_t>& pic, int pic_w, int pic_h,
                                      int origin_x, int origin_y, uint8_t win[21 * 21]) {
    for (int r = 0; r < 21; ++r) {
        for (int c = 0; c < 21; ++c) {
            int x = origin_x + c;
            int y = origin_y + r;
            if (x < 0)
                x = 0;
            if (y < 0)
                y = 0;
            if (x >= pic_w)
                x = pic_w - 1;
            if (y >= pic_h)
                y = pic_h - 1;
            win[r * 21 + c] = pic[static_cast<size_t>(y * pic_w + x)];
        }
    }
}

static void build_chroma_window_clamped(const std::vector<uint8_t>& pic, int pic_w, int pic_h,
                                        int origin_x, int origin_y, uint8_t win[9 * 9]) {
    for (int r = 0; r < 9; ++r) {
        for (int c = 0; c < 9; ++c) {
            int x = origin_x + c;
            int y = origin_y + r;
            if (x < 0)
                x = 0;
            if (y < 0)
                y = 0;
            if (x >= pic_w)
                x = pic_w - 1;
            if (y >= pic_h)
                y = pic_h - 1;
            win[r * 9 + c] = pic[static_cast<size_t>(y * pic_w + x)];
        }
    }
}

static void reset_dut(Vh264_mc_qpel_tb_top& dut) {
    dut.reset = 1;
    dut.luma_win_wr = 0;
    dut.luma_start = 0;
    dut.luma_pred_rd_idx = 0;
    dut.chroma_win_u_wr = 0;
    dut.chroma_win_v_wr = 0;
    dut.chroma_start = 0;
    dut.chroma_pred_rd_idx = 0;
    for (int i = 0; i < 4; ++i)
        tick(dut);
    dut.reset = 0;
    tick(dut);
}

static void load_luma_win(Vh264_mc_qpel_tb_top& dut, const uint8_t win[21 * 21]) {
    for (int i = 0; i < 441; ++i) {
        dut.luma_win_wr = 1;
        dut.luma_win_addr = static_cast<uint16_t>(i);
        dut.luma_win_data = win[i];
        tick(dut);
    }
    dut.luma_win_wr = 0;
    tick(dut);
}

static void load_chroma_wins(Vh264_mc_qpel_tb_top& dut, const uint8_t wu[9 * 9],
                             const uint8_t wv[9 * 9]) {
    for (int i = 0; i < 81; ++i) {
        dut.chroma_win_addr = static_cast<uint8_t>(i);
        dut.chroma_win_data = wu[i];
        dut.chroma_win_u_wr = 1;
        dut.chroma_win_v_wr = 0;
        tick(dut);
        dut.chroma_win_data = wv[i];
        dut.chroma_win_u_wr = 0;
        dut.chroma_win_v_wr = 1;
        tick(dut);
    }
    dut.chroma_win_u_wr = 0;
    dut.chroma_win_v_wr = 0;
    tick(dut);
}

static bool run_luma(Vh264_mc_qpel_tb_top& dut, int fx, int fy, uint8_t out[16 * 16]) {
    dut.luma_frac_x = static_cast<uint8_t>(fx & 3);
    dut.luma_frac_y = static_cast<uint8_t>(fy & 3);
    dut.luma_start = 1;
    tick(dut);
    dut.luma_start = 0;
    int guard = 0;
    while (!dut.luma_done) {
        tick(dut);
        if (++guard > 100000) {
            std::fprintf(stderr, "TIMEOUT luma fx=%d fy=%d\n", fx, fy);
            return false;
        }
    }
    // done is 1-cycle; samples are stable after done
    tick(dut);
    for (int i = 0; i < 256; ++i) {
        dut.luma_pred_rd_idx = static_cast<uint8_t>(i);
        dut.eval(); // async read
        out[i] = static_cast<uint8_t>(dut.luma_pred_rd_data);
    }
    return true;
}

static bool run_chroma(Vh264_mc_qpel_tb_top& dut, int fx, int fy, uint8_t ou[8 * 8],
                       uint8_t ov[8 * 8]) {
    dut.chroma_frac_x = static_cast<uint8_t>(fx & 7);
    dut.chroma_frac_y = static_cast<uint8_t>(fy & 7);
    dut.chroma_start = 1;
    tick(dut);
    dut.chroma_start = 0;
    int guard = 0;
    while (!dut.chroma_done) {
        tick(dut);
        if (++guard > 100000) {
            std::fprintf(stderr, "TIMEOUT chroma fx=%d fy=%d\n", fx, fy);
            return false;
        }
    }
    tick(dut);
    for (int i = 0; i < 64; ++i) {
        dut.chroma_pred_rd_idx = static_cast<uint8_t>(i);
        dut.eval();
        ou[i] = static_cast<uint8_t>(dut.chroma_pred_u_rd_data);
        ov[i] = static_cast<uint8_t>(dut.chroma_pred_v_rd_data);
    }
    return true;
}

static int count_diff(const uint8_t* a, const uint8_t* b, int n) {
    int d = 0;
    for (int i = 0; i < n; ++i)
        if (a[i] != b[i])
            ++d;
    return d;
}

static void fill_pattern(uint8_t* dst, int n, int seed) {
    std::mt19937 rng(static_cast<uint32_t>(seed));
    std::uniform_int_distribution<int> dist(0, 255);
    for (int i = 0; i < n; ++i)
        dst[i] = static_cast<uint8_t>(dist(rng));
}

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    Vh264_mc_qpel_tb_top dut;
    reset_dut(dut);

    std::fprintf(stderr, "MC RTL SIM: h264_mc_luma_qpel + h264_mc_chroma_epel\n");

    // ---- Luma: several windows x all 16 sub-positions ----
    struct LumaCase {
        const char* name;
        uint8_t win[21 * 21];
    };
    std::vector<LumaCase> luma_cases(4);
    luma_cases[0].name = "random0";
    fill_pattern(luma_cases[0].win, 441, 1);
    luma_cases[1].name = "ramp";
    for (int i = 0; i < 441; ++i)
        luma_cases[1].win[i] = static_cast<uint8_t>((i * 3) & 255);
    luma_cases[2].name = "extreme";
    for (int i = 0; i < 441; ++i)
        luma_cases[2].win[i] = (i & 1) ? 255 : 0;
    // Edge-clamped fetch from a small picture with MV pointing outside.
    luma_cases[3].name = "edge_clamp";
    {
        const int pw = 24, ph = 20;
        std::vector<uint8_t> pic(static_cast<size_t>(pw * ph));
        for (int y = 0; y < ph; ++y)
            for (int x = 0; x < pw; ++x)
                pic[static_cast<size_t>(y * pw + x)] =
                    static_cast<uint8_t>((x * 7 + y * 13) & 255);
        // origin for integer sample (0,0) is window (-2,-2); push further out.
        build_luma_window_clamped(pic, pw, ph, /*origin_x=*/-6, /*origin_y=*/-5, luma_cases[3].win);
    }

    int luma_vectors = 0;
    int luma_mismatch_samples = 0;
    for (const auto& lc : luma_cases) {
        load_luma_win(dut, lc.win);
        for (int fy = 0; fy < 4; ++fy) {
            for (int fx = 0; fx < 4; ++fx) {
                uint8_t gold[256], got[256];
                spec_luma_qpel(lc.win, fx, fy, gold);
                CHECK(run_luma(dut, fx, fy, got));
                const int d = count_diff(gold, got, 256);
                if (d != 0) {
                    std::fprintf(stderr, "LUMA MISMATCH case=%s fx=%d fy=%d diffs=%d\n", lc.name,
                                 fx, fy, d);
                    // print first few
                    int shown = 0;
                    for (int i = 0; i < 256 && shown < 4; ++i) {
                        if (gold[i] != got[i]) {
                            std::fprintf(stderr, "  [%d] gold=%u got=%u\n", i, gold[i], got[i]);
                            ++shown;
                        }
                    }
                    luma_mismatch_samples += d;
                    ++g_fails;
                }
                ++luma_vectors;
                ++g_checks;
            }
        }
    }
    std::fprintf(stderr, "LUMA: %d vectors (4 windows x 16 fracs), sample_mismatches=%d\n",
                 luma_vectors, luma_mismatch_samples);

    // ---- j double-round RED proof on random0 window ----
    {
        uint8_t gold_j[256], bad_j[256], got_j[256];
        spec_luma_qpel(luma_cases[0].win, /*fx=*/2, /*fy=*/2, gold_j);
        bad_double_round_j(luma_cases[0].win, bad_j);
        const int disc = count_diff(gold_j, bad_j, 256);
        CHECK(disc > 0); // golden must discriminate double-round
        load_luma_win(dut, luma_cases[0].win);
        CHECK(run_luma(dut, 2, 2, got_j));
        CHECK(count_diff(got_j, gold_j, 256) == 0);
        CHECK(count_diff(got_j, bad_j, 256) == disc); // matches single-round, not double
        std::fprintf(stderr, "J RED: double-round differs in %d/256 samples; RTL matches single-round\n",
                     disc);
    }

    // ---- Chroma ----
    struct ChromaCase {
        const char* name;
        uint8_t u[81];
        uint8_t v[81];
    };
    std::vector<ChromaCase> chroma_cases(3);
    chroma_cases[0].name = "random";
    fill_pattern(chroma_cases[0].u, 81, 11);
    fill_pattern(chroma_cases[0].v, 81, 12);
    chroma_cases[1].name = "extreme";
    for (int i = 0; i < 81; ++i) {
        chroma_cases[1].u[i] = (i & 1) ? 255 : 0;
        chroma_cases[1].v[i] = (i & 2) ? 255 : 0;
    }
    chroma_cases[2].name = "edge_clamp";
    {
        const int pw = 12, ph = 10;
        std::vector<uint8_t> pic(static_cast<size_t>(pw * ph));
        for (int i = 0; i < pw * ph; ++i)
            pic[static_cast<size_t>(i)] = static_cast<uint8_t>((i * 9) & 255);
        build_chroma_window_clamped(pic, pw, ph, -3, -2, chroma_cases[2].u);
        build_chroma_window_clamped(pic, pw, ph, -1, -4, chroma_cases[2].v);
    }

    int chroma_vectors = 0;
    int chroma_mismatch_samples = 0;
    for (const auto& cc : chroma_cases) {
        load_chroma_wins(dut, cc.u, cc.v);
        for (int fy = 0; fy < 8; ++fy) {
            for (int fx = 0; fx < 8; ++fx) {
                uint8_t gu[64], gv[64], ou[64], ov[64];
                spec_chroma_epel(cc.u, fx, fy, gu);
                spec_chroma_epel(cc.v, fx, fy, gv);
                CHECK(run_chroma(dut, fx, fy, ou, ov));
                const int du = count_diff(gu, ou, 64);
                const int dv = count_diff(gv, ov, 64);
                if (du || dv) {
                    std::fprintf(stderr, "CHROMA MISMATCH case=%s fx=%d fy=%d du=%d dv=%d\n",
                                 cc.name, fx, fy, du, dv);
                    chroma_mismatch_samples += du + dv;
                    ++g_fails;
                }
                ++chroma_vectors;
                ++g_checks;
            }
        }
    }
    std::fprintf(stderr, "CHROMA: %d vectors (3 windows x 64 fracs), sample_mismatches=%d\n",
                 chroma_vectors, chroma_mismatch_samples);

    if (g_fails) {
        std::fprintf(stderr, "MC RTL SIM FAIL: %d failures in %d checks\n", g_fails, g_checks);
        return 1;
    }
    std::fprintf(stderr,
                 "MC RTL SIM PASS: luma_vectors=%d chroma_vectors=%d checks=%d "
                 "(executed serialized interpolator RTL via Verilator)\n",
                 luma_vectors, chroma_vectors, g_checks);
    return 0;
}
