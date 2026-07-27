// H.264 MC interpolation Verilator testbench — v2 (2-wide output)
// Self-checking: compares RTL output against the independent C++ reference model.
// Coverage: all 16 luma sub-positions, chroma eighth-pel grid, edge clamping,
//           extreme sample values, randomised reference data.
// Reports cycles/MB as a first-class metric against the 250-cycle budget.
#include "Vh264_mc_interp_tb.h"
#include "verilated.h"
#include "h264_mc_ref_model.h"

#include <algorithm>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <iostream>
#include <random>
#include <vector>

static int g_fail_count = 0;
static int g_pass_count = 0;

static void fail(const char* msg) {
    std::cerr << "FAIL h264_mc_interp RTL: " << msg << "\n";
    ++g_fail_count;
}

static void tick(Vh264_mc_interp_tb& top) {
    top.clk = 0;
    top.eval();
    top.clk = 1;
    top.eval();
}

static void reset(Vh264_mc_interp_tb& top) {
    top.rst_n = 0;
    top.cmd_valid = 0;
    top.ref_valid = 0;
    top.pred_ready = 0;
    top.cmd_ref_x = 0;
    top.cmd_ref_y = 0;
    for (int i = 0; i < 3; i++) tick(top);
    top.rst_n = 1;
    tick(top);
}

static uint64_t pack_bytes(const uint8_t* data, int count) {
    uint64_t word = 0;
    for (int i = 0; i < count; i++)
        word |= static_cast<uint64_t>(data[i]) << (56 - 8 * i);
    return word;
}

// Run one MC block through the RTL, collecting 2-wide output.
// ref_x, ref_y: absolute position for cache (use unique values to avoid
// unintended cache hits across test cases).
static int run_mc_block(Vh264_mc_interp_tb& top,
                        bool is_chroma,
                        int frac_x, int frac_y,
                        int chroma_dx, int chroma_dy,
                        int blk_w, int blk_h,
                        const std::vector<uint8_t>& ref_window,
                        std::vector<uint8_t>& out_samples,
                        int ref_x = 0, int ref_y = 0,
                        bool skip_zero = false) {
    out_samples.clear();

    // Issue command
    top.cmd_valid     = 1;
    top.cmd_is_chroma = is_chroma ? 1 : 0;
    top.cmd_frac_x    = frac_x;
    top.cmd_frac_y    = frac_y;
    top.cmd_chroma_dx = chroma_dx;
    top.cmd_chroma_dy = chroma_dy;
    top.cmd_blk_w     = blk_w;
    top.cmd_blk_h     = blk_h;
    top.cmd_skip_zero = skip_zero ? 1 : 0;
    top.cmd_ref_x     = static_cast<int16_t>(ref_x);
    top.cmd_ref_y     = static_cast<int16_t>(ref_y);
    top.ref_valid     = 0;
    top.pred_ready    = 1;

    int timeout = 100;
    while (!top.cmd_ready && timeout-- > 0) tick(top);
    if (timeout <= 0) { fail("cmd_ready timeout"); return -1; }
    tick(top);
    top.cmd_valid = 0;

    // Stream reference data AND collect output simultaneously (pipelined)
    size_t ref_idx = 0;
    top.ref_valid = 0;
    int total_samples = blk_w * blk_h;
    timeout = total_samples + static_cast<int>(ref_window.size()) + 200;

    while (static_cast<int>(out_samples.size()) < total_samples && timeout-- > 0) {
        // Feed reference data
        if (ref_idx < ref_window.size() && top.ref_ready) {
            int remaining = static_cast<int>(ref_window.size() - ref_idx);
            int count = std::min(remaining, 8);
            top.ref_data = pack_bytes(&ref_window[ref_idx], count);
            top.ref_byte_count = count;
            top.ref_valid = 1;
            ref_idx += count;
        } else {
            top.ref_valid = 0;
        }

        tick(top);

        // Collect output (2-wide)
        if (top.pred_valid && top.pred_ready) {
            out_samples.push_back(top.pred_sample0_out);
            if (top.pred_pair && static_cast<int>(out_samples.size()) < total_samples)
                out_samples.push_back(top.pred_sample1_out);
        }
    }
    if (static_cast<int>(out_samples.size()) != total_samples) {
        char buf[128];
        snprintf(buf, sizeof(buf), "incomplete output: got %zu want %d",
                 out_samples.size(), total_samples);
        fail(buf);
        return -1;
    }

    tick(top); tick(top);
    return static_cast<int>(top.cycle_count);
}

static std::vector<uint8_t> build_luma_ref_window(
    const uint8_t* ref, int ref_stride,
    int int_x, int int_y, int blk_w, int blk_h,
    int pic_w, int pic_h) {
    int win_w = blk_w + 5, win_h = blk_h + 5;
    std::vector<uint8_t> win(win_w * win_h);
    for (int r = 0; r < win_h; r++)
        for (int c = 0; c < win_w; c++)
            win[r * win_w + c] = mc_ref::fetch_ref(ref, ref_stride,
                                                    int_x - 2 + c, int_y - 2 + r,
                                                    pic_w, pic_h);
    return win;
}

static std::vector<uint8_t> build_chroma_ref_window(
    const uint8_t* ref, int ref_stride,
    int int_x, int int_y, int blk_w, int blk_h,
    int pic_w, int pic_h) {
    int win_w = blk_w + 1, win_h = blk_h + 1;
    std::vector<uint8_t> win(win_w * win_h);
    for (int r = 0; r < win_h; r++)
        for (int c = 0; c < win_w; c++)
            win[r * win_w + c] = mc_ref::fetch_ref(ref, ref_stride,
                                                    int_x + c, int_y + r,
                                                    pic_w, pic_h);
    return win;
}

// Use unique ref_x/y per test case to prevent cache hits across unrelated tests.
static int g_ref_coord_counter = 1000;

static void test_luma_all_positions(Vh264_mc_interp_tb& top,
                                    const uint8_t* ref, int ref_stride,
                                    int blk_x, int blk_y,
                                    int blk_w, int blk_h,
                                    int pic_w, int pic_h,
                                    int& total_luma, int& total_cycles) {
    for (int fy = 0; fy < 4; fy++) {
        for (int fx = 0; fx < 4; fx++) {
            std::vector<uint8_t> expected(blk_w * blk_h);
            int mv_x = fx, mv_y = fy;
            mc_ref::luma_mc_block(ref, ref_stride, blk_x, blk_y, mv_x, mv_y,
                                  blk_w, blk_h, pic_w, pic_h,
                                  expected.data(), blk_w);

            int int_x = blk_x + (mv_x >> 2);
            int int_y = blk_y + (mv_y >> 2);
            auto ref_win = build_luma_ref_window(ref, ref_stride, int_x, int_y,
                                                  blk_w, blk_h, pic_w, pic_h);

            std::vector<uint8_t> got;
            int rx = g_ref_coord_counter++;
            int ry = g_ref_coord_counter++;
            int cycles = run_mc_block(top, false, fx, fy, 0, 0,
                                      blk_w, blk_h, ref_win, got, rx, ry);

            bool match = (got.size() == expected.size());
            if (match) {
                for (size_t i = 0; i < got.size(); i++) {
                    if (got[i] != expected[i]) {
                        match = false;
                        char buf[256];
                        snprintf(buf, sizeof(buf),
                                 "luma mismatch frac=(%d,%d) blk=%dx%d pos=%d "
                                 "got=%d want=%d",
                                 fx, fy, blk_w, blk_h,
                                 static_cast<int>(i), got[i], expected[i]);
                        fail(buf);
                        break;
                    }
                }
            } else {
                char buf[128];
                snprintf(buf, sizeof(buf),
                         "luma size mismatch frac=(%d,%d) got=%zu want=%d",
                         fx, fy, got.size(), blk_w * blk_h);
                fail(buf);
            }
            if (match) ++g_pass_count;
            ++total_luma;
            if (cycles > 0) total_cycles += cycles;
        }
    }
}

static void test_chroma_grid(Vh264_mc_interp_tb& top,
                             const uint8_t* ref, int ref_stride,
                             int blk_x, int blk_y,
                             int blk_w, int blk_h,
                             int pic_w, int pic_h,
                             int& total_chroma, int& total_cycles) {
    for (int dy = 0; dy < 8; dy++) {
        for (int dx = 0; dx < 8; dx++) {
            std::vector<uint8_t> expected(blk_w * blk_h);
            mc_ref::chroma_mc_block(ref, ref_stride, blk_x, blk_y, dx, dy,
                                    blk_w, blk_h, pic_w, pic_h,
                                    expected.data(), blk_w);

            int int_x = blk_x + (dx >> 3);
            int int_y = blk_y + (dy >> 3);
            auto ref_win = build_chroma_ref_window(ref, ref_stride, int_x, int_y,
                                                    blk_w, blk_h, pic_w, pic_h);

            std::vector<uint8_t> got;
            int rx = g_ref_coord_counter++;
            int ry = g_ref_coord_counter++;
            int cycles = run_mc_block(top, true, 0, 0, dx, dy,
                                      blk_w, blk_h, ref_win, got, rx, ry);

            bool match = (got.size() == expected.size());
            if (match) {
                for (size_t i = 0; i < got.size(); i++) {
                    if (got[i] != expected[i]) {
                        match = false;
                        char buf[256];
                        snprintf(buf, sizeof(buf),
                                 "chroma mismatch frac=(%d,%d) blk=%dx%d pos=%d "
                                 "got=%d want=%d",
                                 dx, dy, blk_w, blk_h,
                                 static_cast<int>(i), got[i], expected[i]);
                        fail(buf);
                        break;
                    }
                }
            } else {
                char buf[128];
                snprintf(buf, sizeof(buf),
                         "chroma size mismatch frac=(%d,%d) got=%zu want=%d",
                         dx, dy, got.size(), blk_w * blk_h);
                fail(buf);
            }
            if (match) ++g_pass_count;
            ++total_chroma;
            if (cycles > 0) total_cycles += cycles;
        }
    }
}

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    Vh264_mc_interp_tb top;
    reset(top);

    std::mt19937 rng(42);
    std::uniform_int_distribution<int> pixel_dist(0, 255);

    int total_luma = 0, total_chroma = 0, total_cycles = 0;
    int edge_luma = 0, edge_chroma = 0, extreme_luma = 0;

    // -----------------------------------------------------------------------
    // Test 1: All 16 luma sub-positions, multiple block sizes
    // -----------------------------------------------------------------------
    const int pic_w = 32, pic_h = 32, ref_stride = pic_w;
    std::vector<uint8_t> ref_frame(pic_w * pic_h);
    for (auto& p : ref_frame) p = static_cast<uint8_t>(pixel_dist(rng));

    struct BlkSpec { int x, y, w, h; };
    BlkSpec luma_blocks[] = {
        {8, 8, 16, 16}, {0, 0, 16, 16}, {8, 8, 8, 8}, {4, 4, 4, 4},
        {0, 0, 8, 8}, {8, 4, 8, 16}, {4, 8, 16, 8}, {0, 0, 4, 8}, {4, 0, 8, 4},
    };
    for (const auto& blk : luma_blocks)
        test_luma_all_positions(top, ref_frame.data(), ref_stride,
                                blk.x, blk.y, blk.w, blk.h, pic_w, pic_h,
                                total_luma, total_cycles);

    // -----------------------------------------------------------------------
    // Test 2: Edge clamping — MVs pointing outside the picture
    // -----------------------------------------------------------------------
    {
        int mv_tests[][2] = {
            {-12, 0}, {0, -12}, {56, 0}, {80, 0}, {0, 80}, {-20, -20}, {80, 80},
        };
        for (const auto& mv : mv_tests) {
            for (int fy = 0; fy < 4; fy++) {
                for (int fx = 0; fx < 4; fx++) {
                    int full_mv_x = mv[0] + fx, full_mv_y = mv[1] + fy;
                    int blk_w = 4, blk_h = 4, blk_x = 8, blk_y = 8;

                    std::vector<uint8_t> expected(blk_w * blk_h);
                    mc_ref::luma_mc_block(ref_frame.data(), ref_stride,
                                          blk_x, blk_y, full_mv_x, full_mv_y,
                                          blk_w, blk_h, pic_w, pic_h,
                                          expected.data(), blk_w);

                    int int_x = blk_x + (full_mv_x >> 2);
                    int int_y = blk_y + (full_mv_y >> 2);
                    auto ref_win = build_luma_ref_window(ref_frame.data(), ref_stride,
                                                          int_x, int_y, blk_w, blk_h,
                                                          pic_w, pic_h);

                    int frac_x_v = full_mv_x & 3, frac_y_v = full_mv_y & 3;
                    std::vector<uint8_t> got;
                    int rx = g_ref_coord_counter++, ry = g_ref_coord_counter++;
                    run_mc_block(top, false, frac_x_v, frac_y_v, 0, 0,
                                 blk_w, blk_h, ref_win, got, rx, ry);

                    bool match = (got.size() == expected.size());
                    if (match)
                        for (size_t i = 0; i < got.size(); i++)
                            if (got[i] != expected[i]) {
                                match = false;
                                char buf[256];
                                snprintf(buf, sizeof(buf),
                                         "edge luma mismatch mv=(%d,%d) pos=%d got=%d want=%d",
                                         full_mv_x, full_mv_y,
                                         static_cast<int>(i), got[i], expected[i]);
                                fail(buf);
                                break;
                            }
                    if (match) ++g_pass_count;
                    ++edge_luma;
                }
            }
        }
    }

    // -----------------------------------------------------------------------
    // Test 3: Extreme sample values (0, 255, checkerboard)
    // -----------------------------------------------------------------------
    {
        std::vector<uint8_t> zero_frame(pic_w * pic_h, 0);
        test_luma_all_positions(top, zero_frame.data(), ref_stride,
                                4, 4, 8, 8, pic_w, pic_h, extreme_luma, total_cycles);

        std::vector<uint8_t> max_frame(pic_w * pic_h, 255);
        test_luma_all_positions(top, max_frame.data(), ref_stride,
                                4, 4, 8, 8, pic_w, pic_h, extreme_luma, total_cycles);

        std::vector<uint8_t> checker_frame(pic_w * pic_h);
        for (int y = 0; y < pic_h; y++)
            for (int x = 0; x < pic_w; x++)
                checker_frame[y * pic_w + x] = ((x + y) & 1) ? 255 : 0;
        test_luma_all_positions(top, checker_frame.data(), ref_stride,
                                4, 4, 8, 8, pic_w, pic_h, extreme_luma, total_cycles);
    }

    // -----------------------------------------------------------------------
    // Test 4: Chroma eighth-pel — all 64 fractional positions
    // -----------------------------------------------------------------------
    {
        int cpw = 16, cph = 16, cs = cpw;
        std::vector<uint8_t> chroma_frame(cpw * cph);
        for (auto& p : chroma_frame) p = static_cast<uint8_t>(pixel_dist(rng));

        BlkSpec chroma_blocks[] = {{2,2,8,8}, {0,0,8,8}, {2,2,4,4}, {0,0,4,4}};
        for (const auto& blk : chroma_blocks)
            test_chroma_grid(top, chroma_frame.data(), cs,
                             blk.x, blk.y, blk.w, blk.h, cpw, cph,
                             total_chroma, total_cycles);

        int chroma_mv_tests[][2] = {{-4,0},{0,-4},{60,0},{0,60},{-8,-8},{60,60}};
        for (const auto& mv : chroma_mv_tests) {
            for (int dy = 0; dy < 8; dy++) {
                for (int dx = 0; dx < 8; dx++) {
                    int full_dx = mv[0]+dx, full_dy = mv[1]+dy;
                    int bw=4, bh=4, bx=4, by=4;
                    std::vector<uint8_t> expected(bw*bh);
                    mc_ref::chroma_mc_block(chroma_frame.data(), cs,
                                            bx, by, full_dx, full_dy,
                                            bw, bh, cpw, cph, expected.data(), bw);
                    int ix = bx + (full_dx >> 3), iy = by + (full_dy >> 3);
                    auto ref_win = build_chroma_ref_window(chroma_frame.data(), cs,
                                                            ix, iy, bw, bh, cpw, cph);
                    int fdx = full_dx & 7, fdy = full_dy & 7;
                    std::vector<uint8_t> got;
                    int rx = g_ref_coord_counter++, ry = g_ref_coord_counter++;
                    run_mc_block(top, true, 0, 0, fdx, fdy, bw, bh, ref_win, got, rx, ry);
                    bool match = (got.size() == expected.size());
                    if (match)
                        for (size_t i = 0; i < got.size(); i++)
                            if (got[i] != expected[i]) {
                                match = false;
                                char buf[256];
                                snprintf(buf, sizeof(buf),
                                         "edge chroma mismatch frac=(%d,%d) pos=%d got=%d want=%d",
                                         fdx, fdy, static_cast<int>(i), got[i], expected[i]);
                                fail(buf);
                                break;
                            }
                    if (match) ++g_pass_count;
                    ++edge_chroma;
                }
            }
        }
    }

    // -----------------------------------------------------------------------
    // Test 5: j-position regression + cycle measurement
    // -----------------------------------------------------------------------
    int j_tests = 0;
    {
        std::vector<uint8_t> ramp_frame(pic_w * pic_h);
        for (int y = 0; y < pic_h; y++)
            for (int x = 0; x < pic_w; x++)
                ramp_frame[y * pic_w + x] = static_cast<uint8_t>((x*13+y*7) & 0xFF);

        for (int by = 2; by < pic_h-10; by += 4) {
            for (int bx = 2; bx < pic_w-10; bx += 4) {
                std::vector<uint8_t> expected(16);
                mc_ref::luma_mc_block(ramp_frame.data(), ref_stride,
                                      bx, by, 2, 2, 4, 4, pic_w, pic_h,
                                      expected.data(), 4);
                auto ref_win = build_luma_ref_window(ramp_frame.data(), ref_stride,
                                                      bx, by, 4, 4, pic_w, pic_h);
                std::vector<uint8_t> got;
                int rx = g_ref_coord_counter++, ry = g_ref_coord_counter++;
                run_mc_block(top, false, 2, 2, 0, 0, 4, 4, ref_win, got, rx, ry);
                for (size_t i = 0; i < got.size() && i < expected.size(); i++)
                    if (got[i] != expected[i]) {
                        char buf[256];
                        snprintf(buf, sizeof(buf),
                                 "j-position regression blk=(%d,%d) pos=%d got=%d want=%d",
                                 bx, by, static_cast<int>(i), got[i], expected[i]);
                        fail(buf);
                        break;
                    }
                ++j_tests;
            }
        }
    }

    // -----------------------------------------------------------------------
    // Test 6: Cycle budget measurement — full MB at worst-case j position
    // -----------------------------------------------------------------------
    int budget_cycles = 0;
    {
        // Luma 16×16 at j position (worst case: frac 2,2)
        std::vector<uint8_t> budget_frame(pic_w * pic_h);
        for (auto& p : budget_frame) p = static_cast<uint8_t>(pixel_dist(rng));
        auto luma_win = build_luma_ref_window(budget_frame.data(), ref_stride,
                                               8, 8, 16, 16, pic_w, pic_h);
        std::vector<uint8_t> luma_got;
        int rx = g_ref_coord_counter++, ry = g_ref_coord_counter++;
        int luma_cyc = run_mc_block(top, false, 2, 2, 0, 0,
                                     16, 16, luma_win, luma_got, rx, ry);

        // Chroma 8×8 × 2 (worst-case fractional)
        int cpw = 16, cph = 16;
        std::vector<uint8_t> chroma_frame(cpw * cph);
        for (auto& p : chroma_frame) p = static_cast<uint8_t>(pixel_dist(rng));
        auto cb_win = build_chroma_ref_window(chroma_frame.data(), cpw, 4, 4,
                                               8, 8, cpw, cph);
        auto cr_win = build_chroma_ref_window(chroma_frame.data(), cpw, 4, 4,
                                               8, 8, cpw, cph);
        std::vector<uint8_t> cb_got, cr_got;
        rx = g_ref_coord_counter++; ry = g_ref_coord_counter++;
        int cb_cyc = run_mc_block(top, true, 0, 0, 3, 5, 8, 8, cb_win, cb_got, rx, ry);
        rx = g_ref_coord_counter++; ry = g_ref_coord_counter++;
        int cr_cyc = run_mc_block(top, true, 0, 0, 5, 3, 8, 8, cr_win, cr_got, rx, ry);

        budget_cycles = luma_cyc + cb_cyc + cr_cyc;
        std::cout << "  CYCLE BUDGET: luma_16x16_j=" << luma_cyc
                  << " cb_8x8=" << cb_cyc << " cr_8x8=" << cr_cyc
                  << " total=" << budget_cycles
                  << " budget=250 " << (budget_cycles <= 250 ? "OK" : "OVER") << "\n";
    }

    // -----------------------------------------------------------------------
    // Test 6b: P_Skip fast path — integer-pel direct copy, no FIR
    // Reference window is blk_w×blk_h (no +5 border).
    // -----------------------------------------------------------------------
    int skip_tests = 0, skip_cycles = 0;
    {
        // Build a blk_w×blk_h reference window (no border)
        for (const auto& blk : luma_blocks) {
            int bw = blk.w, bh = blk.h, bx = blk.x, by = blk.y;
            std::vector<uint8_t> skip_win(bw * bh);
            for (int r = 0; r < bh; r++)
                for (int c = 0; c < bw; c++)
                    skip_win[r * bw + c] = mc_ref::fetch_ref(
                        ref_frame.data(), ref_stride, bx + c, by + r, pic_w, pic_h);

            // Expected: direct copy of the reference window
            std::vector<uint8_t> expected = skip_win;

            std::vector<uint8_t> got;
            int rx = g_ref_coord_counter++, ry = g_ref_coord_counter++;
            int cyc = run_mc_block(top, false, 0, 0, 0, 0,
                                    bw, bh, skip_win, got, rx, ry, true);

            bool match = (got.size() == expected.size());
            if (match) {
                for (size_t i = 0; i < got.size(); i++) {
                    if (got[i] != expected[i]) {
                        match = false;
                        char buf[256];
                        snprintf(buf, sizeof(buf),
                                 "skip_zero mismatch blk=%dx%d pos=%d got=%d want=%d",
                                 bw, bh, static_cast<int>(i), got[i], expected[i]);
                        fail(buf);
                        break;
                    }
                }
            } else {
                char buf[128];
                snprintf(buf, sizeof(buf),
                         "skip_zero size mismatch blk=%dx%d got=%zu want=%d",
                         bw, bh, got.size(), bw * bh);
                fail(buf);
            }
            if (match) ++g_pass_count;
            ++skip_tests;
            if (cyc > 0 && bw == 16 && bh == 16) skip_cycles = cyc;
        }
        std::cout << "  P_SKIP: tests=" << skip_tests
                  << " 16x16_cycles=" << skip_cycles << "\n";
    }

    // -----------------------------------------------------------------------
    // Test 7: Cache hit — re-issuing same window should skip loading
    // -----------------------------------------------------------------------
    int cache_cycles = 0;
    {
        auto luma_win = build_luma_ref_window(ref_frame.data(), ref_stride,
                                               8, 8, 16, 16, pic_w, pic_h);
        std::vector<uint8_t> got1, got2;
        // First call: full load
        int cyc1 = run_mc_block(top, false, 2, 2, 0, 0, 16, 16, luma_win, got1,
                                 -500, -500);
        // Second call: same ref_x/ref_y → cache hit, should be faster
        int cyc2 = run_mc_block(top, false, 1, 1, 0, 0, 16, 16, luma_win, got2,
                                 -500, -500);
        cache_cycles = cyc1 - cyc2;
        std::cout << "  CACHE: first=" << cyc1 << " cached=" << cyc2
                  << " saved=" << cache_cycles << " cycles\n";
    }

    std::cout << "  j-position regression tests: " << j_tests << "\n";

    // -----------------------------------------------------------------------
    // Summary
    // -----------------------------------------------------------------------
    int total_tests = total_luma + total_chroma + edge_luma + edge_chroma
                    + extreme_luma + skip_tests;
    if (g_fail_count > 0) {
        std::cerr << "FAIL h264_mc_interp RTL: " << g_fail_count
                  << " failures out of " << total_tests << " tests\n";
        return 1;
    }

    std::cout << "OK real RTL sim: h264_mc_interp product RTL "
              << "luma_qpel=" << total_luma
              << " chroma_epel=" << total_chroma
              << " edge_luma=" << edge_luma
              << " edge_chroma=" << edge_chroma
              << " extreme_luma=" << extreme_luma
              << " skip_zero=" << skip_tests
              << " total=" << total_tests
              << " pass=" << g_pass_count
              << " cycles_per_mb=" << budget_cycles
              << " skip_16x16_cyc=" << skip_cycles
              << "\n";
    return 0;
}
