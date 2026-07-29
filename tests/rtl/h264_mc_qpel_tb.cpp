// EXECUTES the serialized MC interpolator RTL and compares its outputs against
// an independent H.264 8.4.2.2.1 / 8.4.2.2.2 golden model.
//
// This is deliberately not a Python model sitting beside the RTL: the engines
// were rewritten from fully-parallel port-array forms into resource-shared
// sequential datapaths, which preserves the algorithm and is precisely the
// class of change that breaks the implementation.  Only running the RTL
// distinguishes the two.
//
// Coverage:
//   luma    all 16 quarter-sample positions, centre (j) included, over random
//           windows plus edge-replicated windows (motion vectors pointing
//           outside the picture)
//   chroma  all 64 eighth-sample positions, same window populations
//
// Build with -DMC_NEGATIVE_TEST to perturb the golden model; the run must then
// FAIL, which is what proves the comparison is live rather than vacuous.

#include "Vh264_mc_qpel_tb_top.h"
#include "verilated.h"

#include <cstdio>
#include <cstdint>
#include <cstdlib>
#include <vector>

static Vh264_mc_qpel_tb_top *dut = nullptr;
static vluint64_t main_time = 0;

static void tick() {
    dut->clk = 0;
    dut->eval();
    main_time++;
    dut->clk = 1;
    dut->eval();
    main_time++;
}

static inline int clip1(int v) { return v < 0 ? 0 : (v > 255 ? 255 : v); }

// ---------------------------------------------------------------- golden ---
// Raw horizontal 6-tap at window row r, output column x, UNROUNDED.
static int b1_raw(const uint8_t *W, int r, int x) {
    return (int)W[r * 21 + x + 0] - 5 * (int)W[r * 21 + x + 1] +
           20 * (int)W[r * 21 + x + 2] + 20 * (int)W[r * 21 + x + 3] -
           5 * (int)W[r * 21 + x + 4] + (int)W[r * 21 + x + 5];
}

// Raw vertical 6-tap at window column c, output row y, UNROUNDED.
static int v1_raw(const uint8_t *W, int y, int c) {
    return (int)W[(y + 0) * 21 + c] - 5 * (int)W[(y + 1) * 21 + c] +
           20 * (int)W[(y + 2) * 21 + c] + 20 * (int)W[(y + 3) * 21 + c] -
           5 * (int)W[(y + 4) * 21 + c] + (int)W[(y + 5) * 21 + c];
}

static void luma_golden(const uint8_t *W, int fx, int fy, uint8_t *out) {
    for (int y = 0; y < 16; y++) {
        for (int x = 0; x < 16; x++) {
            const int G = W[(y + 2) * 21 + (x + 2)];
            const int H = W[(y + 2) * 21 + (x + 3)];
            const int M = W[(y + 3) * 21 + (x + 2)];

            const int b = clip1((b1_raw(W, y + 2, x) + 16) >> 5);
            const int s = clip1((b1_raw(W, y + 3, x) + 16) >> 5);
            const int h = clip1((v1_raw(W, y, x + 2) + 16) >> 5);
            const int m = clip1((v1_raw(W, y, x + 3) + 16) >> 5);

            // The centre sample filters the UNROUNDED intermediates and rounds
            // exactly once.  Rounding b1 first is the classic conformance bug.
            const int j1 = b1_raw(W, y + 0, x) - 5 * b1_raw(W, y + 1, x) +
                           20 * b1_raw(W, y + 2, x) + 20 * b1_raw(W, y + 3, x) -
                           5 * b1_raw(W, y + 4, x) + b1_raw(W, y + 5, x);
            const int j = clip1((j1 + 512) >> 10);

            int p = 0;
            switch (fy * 4 + fx) {
            case 0 * 4 + 0: p = G;                break; // G
            case 0 * 4 + 1: p = (G + b + 1) >> 1; break; // a
            case 0 * 4 + 2: p = b;                break; // b
            case 0 * 4 + 3: p = (H + b + 1) >> 1; break; // c
            case 1 * 4 + 0: p = (G + h + 1) >> 1; break; // d
            case 1 * 4 + 1: p = (b + h + 1) >> 1; break; // e
            case 1 * 4 + 2: p = (b + j + 1) >> 1; break; // f
            case 1 * 4 + 3: p = (b + m + 1) >> 1; break; // g
            case 2 * 4 + 0: p = h;                break; // h
            case 2 * 4 + 1: p = (h + j + 1) >> 1; break; // i
            case 2 * 4 + 2: p = j;                break; // j
            case 2 * 4 + 3: p = (j + m + 1) >> 1; break; // k
            case 3 * 4 + 0: p = (M + h + 1) >> 1; break; // n
            case 3 * 4 + 1: p = (h + s + 1) >> 1; break; // p
            case 3 * 4 + 2: p = (j + s + 1) >> 1; break; // q
            case 3 * 4 + 3: p = (m + s + 1) >> 1; break; // r
            default: p = G; break;
            }
#ifdef MC_NEGATIVE_TEST
            if (x == 5 && y == 7) p = (p + 1) & 0xFF;
#endif
            out[y * 16 + x] = (uint8_t)p;
        }
    }
}

static void chroma_golden(const uint8_t *W, int fx, int fy, uint8_t *out) {
    for (int y = 0; y < 8; y++) {
        for (int x = 0; x < 8; x++) {
            const int A = W[(y + 0) * 9 + (x + 0)];
            const int B = W[(y + 0) * 9 + (x + 1)];
            const int C = W[(y + 1) * 9 + (x + 0)];
            const int D = W[(y + 1) * 9 + (x + 1)];
            int p = ((8 - fx) * (8 - fy) * A + fx * (8 - fy) * B +
                     (8 - fx) * fy * C + fx * fy * D + 32) >> 6;
#ifdef MC_NEGATIVE_TEST
            if (x == 3 && y == 4) p = (p + 1) & 0xFF;
#endif
            out[y * 8 + x] = (uint8_t)p;
        }
    }
}

// ---------------------------------------------------------------- driver ---
static const int TIMEOUT = 20000;

static bool luma_run(const uint8_t *W, int fx, int fy, uint8_t *out) {
    for (int i = 0; i < 441; i++) {
        dut->l_win_wr = 1;
        dut->l_win_addr = i;
        dut->l_win_data = W[i];
        tick();
    }
    dut->l_win_wr = 0;

    dut->l_frac_x = fx;
    dut->l_frac_y = fy;
    dut->l_start = 1;
    tick();
    dut->l_start = 0;

    int guard = 0;
    while (!dut->l_done) {
        tick();
        if (++guard > TIMEOUT) {
            printf("FAIL luma: done never asserted (fx=%d fy=%d)\n", fx, fy);
            return false;
        }
    }
    tick();

    for (int i = 0; i < 256; i++) {
        dut->l_pred_rd_idx = i;
        dut->eval();
        out[i] = dut->l_pred_rd_data;
    }
    return true;
}

static bool chroma_run(const uint8_t *U, const uint8_t *V, int fx, int fy,
                       uint8_t *outu, uint8_t *outv) {
    for (int i = 0; i < 81; i++) {
        dut->c_win_u_wr = 1;
        dut->c_win_v_wr = 1;
        dut->c_win_addr = i;
        dut->c_win_data = U[i];
        tick();
    }
    dut->c_win_u_wr = 0;
    dut->c_win_v_wr = 0;
    // V plane is written separately so the two windows genuinely differ and a
    // U/V crosswire cannot pass.
    for (int i = 0; i < 81; i++) {
        dut->c_win_v_wr = 1;
        dut->c_win_addr = i;
        dut->c_win_data = V[i];
        tick();
    }
    dut->c_win_v_wr = 0;

    dut->c_frac_x = fx;
    dut->c_frac_y = fy;
    dut->c_start = 1;
    tick();
    dut->c_start = 0;

    int guard = 0;
    while (!dut->c_done) {
        tick();
        if (++guard > TIMEOUT) {
            printf("FAIL chroma: done never asserted (fx=%d fy=%d)\n", fx, fy);
            return false;
        }
    }
    tick();

    for (int i = 0; i < 64; i++) {
        dut->c_pred_rd_idx = i;
        dut->eval();
        outu[i] = dut->c_pred_u_rd_data;
        outv[i] = dut->c_pred_v_rd_data;
    }
    return true;
}

// --------------------------------------------------------------- windows ---
static uint32_t rng_state = 0x13579BDFu;
static uint32_t rnd() {
    rng_state ^= rng_state << 13;
    rng_state ^= rng_state >> 17;
    rng_state ^= rng_state << 5;
    return rng_state;
}

// A window as the DPB fetch would have produced it for a motion vector that
// points outside the picture: coordinates are clamped to the picture bounds so
// the border sample replicates.  This is what actually reaches the filter, and
// it is the case where long constant runs meet the 6-tap.
static void make_clamped_window(uint8_t *W, int dim, int ox, int oy, int picw,
                                int pich, const uint8_t *pic, int pstride) {
    for (int r = 0; r < dim; r++) {
        for (int c = 0; c < dim; c++) {
            int sx = ox + c;
            int sy = oy + r;
            if (sx < 0) sx = 0;
            if (sx > picw - 1) sx = picw - 1;
            if (sy < 0) sy = 0;
            if (sy > pich - 1) sy = pich - 1;
            W[r * dim + c] = pic[sy * pstride + sx];
        }
    }
}

int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);
    dut = new Vh264_mc_qpel_tb_top;

    dut->clk = 0;
    dut->reset = 1;
    dut->l_win_wr = 0;
    dut->l_start = 0;
    dut->c_win_u_wr = 0;
    dut->c_win_v_wr = 0;
    dut->c_start = 0;
    dut->l_pred_rd_idx = 0;
    dut->c_pred_rd_idx = 0;
    for (int i = 0; i < 8; i++) tick();
    dut->reset = 0;
    for (int i = 0; i < 4; i++) tick();

    // A small synthetic picture the clamped windows are cut out of.  High
    // contrast so a wrong tap or a wrong clamp changes the result.
    const int PW = 40, PH = 40;
    std::vector<uint8_t> pic(PW * PH);
    for (int y = 0; y < PH; y++)
        for (int x = 0; x < PW; x++)
            pic[y * PW + x] = (uint8_t)((x * 13 + y * 29 + ((x ^ y) << 3)) & 0xFF);

    long luma_checked = 0, luma_bad = 0;
    long chroma_checked = 0, chroma_bad = 0;
    int first_fail_reported = 0;

    uint8_t W[441], got[256], exp[256];

    // ---- luma: random windows, all 16 positions -----------------------
    const int LUMA_RANDOM_WINDOWS = 50;
    for (int w = 0; w < LUMA_RANDOM_WINDOWS; w++) {
        for (int i = 0; i < 441; i++) {
            // Mix saturating extremes in so the clip paths are exercised.
            uint32_t r = rnd();
            W[i] = (w % 5 == 0) ? (uint8_t)((r & 1) ? 255 : 0) : (uint8_t)(r & 0xFF);
        }
        for (int fy = 0; fy < 4; fy++) {
            for (int fx = 0; fx < 4; fx++) {
                if (!luma_run(W, fx, fy, got)) return 1;
                luma_golden(W, fx, fy, exp);
                for (int i = 0; i < 256; i++) {
                    luma_checked++;
                    if (got[i] != exp[i]) {
                        luma_bad++;
                        if (first_fail_reported++ < 8)
                            printf("MISMATCH luma win=%d fx=%d fy=%d idx=%d "
                                   "(x=%d,y=%d) rtl=%u golden=%u\n",
                                   w, fx, fy, i, i % 16, i / 16, got[i], exp[i]);
                    }
                }
            }
        }
    }

    // ---- luma: edge-replicated windows (MV outside the picture) -------
    const int edge_ox[] = {-21, -8, -3, 0, 12, 30, 38, 44};
    const int edge_oy[] = {-21, -8, -3, 0, 12, 30, 38, 44};
    long luma_edge_vectors = 0;
    for (unsigned oi = 0; oi < sizeof(edge_ox) / sizeof(edge_ox[0]); oi++) {
        for (unsigned oj = 0; oj < sizeof(edge_oy) / sizeof(edge_oy[0]); oj++) {
            make_clamped_window(W, 21, edge_ox[oi], edge_oy[oj], PW, PH,
                                pic.data(), PW);
            // Centre (j) and the two positions that consume it diagonally are
            // the ones a clamp bug shows up in first, but run all 16.
            for (int fy = 0; fy < 4; fy++) {
                for (int fx = 0; fx < 4; fx++) {
                    if (!luma_run(W, fx, fy, got)) return 1;
                    luma_golden(W, fx, fy, exp);
                    luma_edge_vectors++;
                    for (int i = 0; i < 256; i++) {
                        luma_checked++;
                        if (got[i] != exp[i]) {
                            luma_bad++;
                            if (first_fail_reported++ < 8)
                                printf("MISMATCH luma-edge ox=%d oy=%d fx=%d "
                                       "fy=%d idx=%d rtl=%u golden=%u\n",
                                       edge_ox[oi], edge_oy[oj], fx, fy, i,
                                       got[i], exp[i]);
                        }
                    }
                }
            }
        }
    }

    // ---- chroma: all 64 positions -------------------------------------
    uint8_t U[81], V[81], gu[64], gv[64], eu[64], ev[64];
    const int CHROMA_RANDOM_WINDOWS = 6;
    long chroma_vectors = 0;
    for (int w = 0; w < CHROMA_RANDOM_WINDOWS; w++) {
        for (int i = 0; i < 81; i++) {
            uint32_t r = rnd();
            U[i] = (w % 3 == 0) ? (uint8_t)((r & 1) ? 255 : 0) : (uint8_t)(r & 0xFF);
            V[i] = (uint8_t)((rnd() >> 3) & 0xFF);
        }
        for (int fy = 0; fy < 8; fy++) {
            for (int fx = 0; fx < 8; fx++) {
                if (!chroma_run(U, V, fx, fy, gu, gv)) return 1;
                chroma_golden(U, fx, fy, eu);
                chroma_golden(V, fx, fy, ev);
                chroma_vectors++;
                for (int i = 0; i < 64; i++) {
                    chroma_checked += 2;
                    if (gu[i] != eu[i]) {
                        chroma_bad++;
                        if (first_fail_reported++ < 8)
                            printf("MISMATCH chroma-U win=%d fx=%d fy=%d idx=%d "
                                   "rtl=%u golden=%u\n", w, fx, fy, i, gu[i], eu[i]);
                    }
                    if (gv[i] != ev[i]) {
                        chroma_bad++;
                        if (first_fail_reported++ < 8)
                            printf("MISMATCH chroma-V win=%d fx=%d fy=%d idx=%d "
                                   "rtl=%u golden=%u\n", w, fx, fy, i, gv[i], ev[i]);
                    }
                }
            }
        }
    }

    // ---- chroma: edge-replicated windows ------------------------------
    for (unsigned oi = 0; oi < sizeof(edge_ox) / sizeof(edge_ox[0]); oi++) {
        make_clamped_window(U, 9, edge_ox[oi], edge_oy[oi], PW, PH, pic.data(), PW);
        make_clamped_window(V, 9, edge_oy[oi], edge_ox[oi], PW, PH, pic.data(), PW);
        for (int fy = 0; fy < 8; fy += 3) {
            for (int fx = 0; fx < 8; fx += 3) {
                if (!chroma_run(U, V, fx, fy, gu, gv)) return 1;
                chroma_golden(U, fx, fy, eu);
                chroma_golden(V, fx, fy, ev);
                chroma_vectors++;
                for (int i = 0; i < 64; i++) {
                    chroma_checked += 2;
                    if (gu[i] != eu[i] || gv[i] != ev[i]) {
                        chroma_bad++;
                        if (first_fail_reported++ < 8)
                            printf("MISMATCH chroma-edge ox=%d fx=%d fy=%d "
                                   "idx=%d rtlU=%u goldU=%u rtlV=%u goldV=%u\n",
                                   edge_ox[oi], fx, fy, i, gu[i], eu[i], gv[i], ev[i]);
                    }
                }
            }
        }
    }

    dut->final();
    delete dut;

    printf("RTL SIM h264_mc_luma_qpel   : %ld sample comparisons, %ld mismatches "
           "(%d luma vectors, %ld of them edge-replicated)\n",
           luma_checked, luma_bad,
           LUMA_RANDOM_WINDOWS * 16 + (int)luma_edge_vectors, luma_edge_vectors);
    printf("RTL SIM h264_mc_chroma_epel : %ld sample comparisons, %ld mismatches "
           "(%ld chroma vectors, all 64 sub-positions covered)\n",
           chroma_checked, chroma_bad, chroma_vectors);

    if (luma_bad || chroma_bad) {
        printf("RTL SIM FAIL\n");
        return 1;
    }
    printf("RTL SIM PASS: serialized MC interpolators match H.264 8.4.2.2.1 / "
           "8.4.2.2.2 bit-exactly, centre (j) and edge-replicated windows "
           "included\n");
    return 0;
}
