// H.264 MC interpolation Verilator testbench
// Self-checking: compares RTL output against the independent C++ reference model.
// Coverage: all 16 luma sub-positions, chroma eighth-pel grid, edge clamping,
//           extreme sample values, randomised reference data.
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

// Reset the DUT
static void reset(Vh264_mc_interp_tb& top) {
    top.rst_n = 0;
    top.cmd_valid = 0;
    top.ref_valid = 0;
    top.pred_ready = 0;
    for (int i = 0; i < 3; i++) tick(top);
    top.rst_n = 1;
    tick(top);
}

// Pack bytes into a 64-bit word, MSB first
static uint64_t pack_bytes(const uint8_t* data, int count) {
    uint64_t word = 0;
    for (int i = 0; i < count; i++) {
        word |= static_cast<uint64_t>(data[i]) << (56 - 8 * i);
    }
    return word;
}

// Run one MC block through the RTL and collect output samples.
// Returns the cycle count reported by the DUT.
static int run_mc_block(Vh264_mc_interp_tb& top,
                        bool is_chroma,
                        int frac_x, int frac_y,
                        int chroma_dx, int chroma_dy,
                        int blk_w, int blk_h,
                        const std::vector<uint8_t>& ref_window,
                        std::vector<uint8_t>& out_samples) {
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
    top.ref_valid     = 0;
    top.pred_ready    = 1;

    // Wait for cmd_ready
    int timeout = 100;
    while (!top.cmd_ready && timeout-- > 0) tick(top);
    if (timeout <= 0) { fail("cmd_ready timeout"); return -1; }
    tick(top); // clock in the command
    top.cmd_valid = 0;

    // Stream reference data in 64-bit words
    size_t ref_idx = 0;
    top.ref_valid = 0;
    while (ref_idx < ref_window.size()) {
        if (top.ref_ready) {
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
    }
    top.ref_valid = 0;

    // Collect output samples
    int total_samples = blk_w * blk_h;
    timeout = total_samples + 200;
    while (static_cast<int>(out_samples.size()) < total_samples && timeout-- > 0) {
        tick(top);
        if (top.pred_valid && top.pred_ready) {
            out_samples.push_back(top.pred_sample_out);
        }
    }
    if (static_cast<int>(out_samples.size()) != total_samples) {
        fail("incomplete output from DUT");
        return -1;
    }

    // Let DUT return to idle
    tick(top);
    tick(top);

    return static_cast<int>(top.cycle_count);
}

// Build a reference window for luma: (blk_w+5) × (blk_h+5) samples,
// extracted from a reference frame with edge clamping applied.
static std::vector<uint8_t> build_luma_ref_window(
    const uint8_t* ref, int ref_stride,
    int int_x, int int_y,
    int blk_w, int blk_h,
    int pic_w, int pic_h) {
    int win_w = blk_w + 5;
    int win_h = blk_h + 5;
    std::vector<uint8_t> win(win_w * win_h);
    for (int r = 0; r < win_h; r++) {
        for (int c = 0; c < win_w; c++) {
            int rx = int_x - 2 + c;
            int ry = int_y - 2 + r;
            win[r * win_w + c] = mc_ref::fetch_ref(ref, ref_stride,
                                                    rx, ry, pic_w, pic_h);
        }
    }
    return win;
}

// Build a reference window for chroma: (blk_w+1) × (blk_h+1) samples.
static std::vector<uint8_t> build_chroma_ref_window(
    const uint8_t* ref, int ref_stride,
    int int_x, int int_y,
    int blk_w, int blk_h,
    int pic_w, int pic_h) {
    int win_w = blk_w + 1;
    int win_h = blk_h + 1;
    std::vector<uint8_t> win(win_w * win_h);
    for (int r = 0; r < win_h; r++) {
        for (int c = 0; c < win_w; c++) {
            int rx = int_x + c;
            int ry = int_y + r;
            win[r * win_w + c] = mc_ref::fetch_ref(ref, ref_stride,
                                                    rx, ry, pic_w, pic_h);
        }
    }
    return win;
}

// Test all 16 luma sub-positions with a given reference block.
static void test_luma_all_positions(Vh264_mc_interp_tb& top,
                                    const uint8_t* ref, int ref_stride,
                                    int blk_x, int blk_y,
                                    int blk_w, int blk_h,
                                    int pic_w, int pic_h,
                                    int& total_luma, int& total_cycles) {
    for (int fy = 0; fy < 4; fy++) {
        for (int fx = 0; fx < 4; fx++) {
            // Compute reference model output
            std::vector<uint8_t> expected(blk_w * blk_h);
            // Quarter-pel MV that places us at (blk_x, blk_y) integer + (fx, fy) fraction
            int mv_x = fx;  // fraction only, since blk_x is already the base
            int mv_y = fy;
            mc_ref::luma_mc_block(ref, ref_stride,
                                  blk_x, blk_y, mv_x, mv_y,
                                  blk_w, blk_h, pic_w, pic_h,
                                  expected.data(), blk_w);

            // Build reference window with clamping
            int int_x = blk_x + (mv_x >> 2);
            int int_y = blk_y + (mv_y >> 2);
            auto ref_win = build_luma_ref_window(ref, ref_stride,
                                                  int_x, int_y,
                                                  blk_w, blk_h,
                                                  pic_w, pic_h);

            // Run RTL
            std::vector<uint8_t> got;
            int cycles = run_mc_block(top, false, fx, fy, 0, 0,
                                      blk_w, blk_h, ref_win, got);

            // Compare
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

// Test chroma fractional grid.
static void test_chroma_grid(Vh264_mc_interp_tb& top,
                             const uint8_t* ref, int ref_stride,
                             int blk_x, int blk_y,
                             int blk_w, int blk_h,
                             int pic_w, int pic_h,
                             int& total_chroma, int& total_cycles) {
    for (int dy = 0; dy < 8; dy++) {
        for (int dx = 0; dx < 8; dx++) {
            std::vector<uint8_t> expected(blk_w * blk_h);
            int mv_x = dx;
            int mv_y = dy;
            mc_ref::chroma_mc_block(ref, ref_stride,
                                    blk_x, blk_y, mv_x, mv_y,
                                    blk_w, blk_h, pic_w, pic_h,
                                    expected.data(), blk_w);

            int int_x = blk_x + (mv_x >> 3);
            int int_y = blk_y + (mv_y >> 3);
            auto ref_win = build_chroma_ref_window(ref, ref_stride,
                                                    int_x, int_y,
                                                    blk_w, blk_h,
                                                    pic_w, pic_h);

            std::vector<uint8_t> got;
            int cycles = run_mc_block(top, true, 0, 0, dx, dy,
                                      blk_w, blk_h, ref_win, got);

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

    std::mt19937 rng(42); // deterministic seed
    std::uniform_int_distribution<int> pixel_dist(0, 255);

    int total_luma = 0, total_chroma = 0, total_cycles = 0;
    int edge_luma = 0, edge_chroma = 0;
    int extreme_luma = 0;

    // -----------------------------------------------------------------------
    // Test 1: All 16 luma sub-positions with random reference data
    // Multiple block sizes: 16×16, 8×8, 4×4
    // -----------------------------------------------------------------------
    const int pic_w = 32, pic_h = 32;
    const int ref_stride = pic_w;
    std::vector<uint8_t> ref_frame(pic_w * pic_h);

    // Random reference frame
    for (auto& p : ref_frame) p = static_cast<uint8_t>(pixel_dist(rng));

    // Test with blocks at various positions
    struct BlkSpec { int x, y, w, h; };
    BlkSpec luma_blocks[] = {
        {8, 8, 16, 16},   // interior 16×16
        {0, 0, 16, 16},   // top-left corner
        {8, 8, 8, 8},     // interior 8×8
        {4, 4, 4, 4},     // interior 4×4
        {0, 0, 8, 8},     // corner 8×8
        {8, 4, 8, 16},    // 8×16 partition
        {4, 8, 16, 8},    // 16×8 partition
        {0, 0, 4, 8},     // 4×8 sub-partition
        {4, 0, 8, 4},     // 8×4 sub-partition
    };

    for (const auto& blk : luma_blocks) {
        test_luma_all_positions(top, ref_frame.data(), ref_stride,
                                blk.x, blk.y, blk.w, blk.h,
                                pic_w, pic_h,
                                total_luma, total_cycles);
    }

    // -----------------------------------------------------------------------
    // Test 2: Edge clamping — MVs pointing outside the picture
    // -----------------------------------------------------------------------
    {
        // MV pointing left of picture (negative x)
        int mv_tests[][4] = {
            {-12, 0, 0, 0},   // 3 pixels left of boundary
            {0, -12, 0, 0},   // 3 pixels above boundary
            {0, 0, 0, 0},     // at boundary
            {56, 0, 0, 0},    // right of picture (pic_w=32, blk at x=8, mv=56/4=14 → x=22, ref extends to 24 → within, try larger)
            {80, 0, 0, 0},    // far right
            {0, 80, 0, 0},    // far below
            {-20, -20, 0, 0}, // top-left corner
            {80, 80, 0, 0},   // bottom-right corner
        };
        for (const auto& mv : mv_tests) {
            for (int fy = 0; fy < 4; fy++) {
                for (int fx = 0; fx < 4; fx++) {
                    int full_mv_x = mv[0] + fx;
                    int full_mv_y = mv[1] + fy;
                    int blk_w = 4, blk_h = 4;
                    int blk_x = 8, blk_y = 8;

                    std::vector<uint8_t> expected(blk_w * blk_h);
                    mc_ref::luma_mc_block(ref_frame.data(), ref_stride,
                                          blk_x, blk_y, full_mv_x, full_mv_y,
                                          blk_w, blk_h, pic_w, pic_h,
                                          expected.data(), blk_w);

                    int int_x = blk_x + (full_mv_x >> 2);
                    int int_y = blk_y + (full_mv_y >> 2);
                    auto ref_win = build_luma_ref_window(ref_frame.data(), ref_stride,
                                                          int_x, int_y,
                                                          blk_w, blk_h,
                                                          pic_w, pic_h);

                    int frac_x_val = full_mv_x & 3;
                    int frac_y_val = full_mv_y & 3;
                    std::vector<uint8_t> got;
                    run_mc_block(top, false, frac_x_val, frac_y_val, 0, 0,
                                 blk_w, blk_h, ref_win, got);

                    bool match = (got.size() == expected.size());
                    if (match) {
                        for (size_t i = 0; i < got.size(); i++) {
                            if (got[i] != expected[i]) {
                                match = false;
                                char buf[256];
                                snprintf(buf, sizeof(buf),
                                         "edge luma mismatch mv=(%d,%d) frac=(%d,%d) "
                                         "pos=%d got=%d want=%d",
                                         full_mv_x, full_mv_y, frac_x_val, frac_y_val,
                                         static_cast<int>(i), got[i], expected[i]);
                                fail(buf);
                                break;
                            }
                        }
                    }
                    if (match) ++g_pass_count;
                    ++edge_luma;
                }
            }
        }
    }

    // -----------------------------------------------------------------------
    // Test 3: Extreme sample values (0 and 255) to catch overflow/clipping
    // -----------------------------------------------------------------------
    {
        // All-zero frame
        std::vector<uint8_t> zero_frame(pic_w * pic_h, 0);
        test_luma_all_positions(top, zero_frame.data(), ref_stride,
                                4, 4, 8, 8, pic_w, pic_h,
                                extreme_luma, total_cycles);

        // All-255 frame
        std::vector<uint8_t> max_frame(pic_w * pic_h, 255);
        test_luma_all_positions(top, max_frame.data(), ref_stride,
                                4, 4, 8, 8, pic_w, pic_h,
                                extreme_luma, total_cycles);

        // Alternating 0/255 checkerboard — maximises filter ringing
        std::vector<uint8_t> checker_frame(pic_w * pic_h);
        for (int y = 0; y < pic_h; y++)
            for (int x = 0; x < pic_w; x++)
                checker_frame[y * pic_w + x] = ((x + y) & 1) ? 255 : 0;
        test_luma_all_positions(top, checker_frame.data(), ref_stride,
                                4, 4, 8, 8, pic_w, pic_h,
                                extreme_luma, total_cycles);
    }

    // -----------------------------------------------------------------------
    // Test 4: Chroma eighth-pel — all 64 fractional positions
    // -----------------------------------------------------------------------
    {
        int chroma_pic_w = 16, chroma_pic_h = 16;
        int chroma_stride = chroma_pic_w;
        std::vector<uint8_t> chroma_frame(chroma_pic_w * chroma_pic_h);
        for (auto& p : chroma_frame)
            p = static_cast<uint8_t>(pixel_dist(rng));

        // 8×8 and 4×4 chroma blocks
        BlkSpec chroma_blocks[] = {
            {2, 2, 8, 8},
            {0, 0, 8, 8},
            {2, 2, 4, 4},
            {0, 0, 4, 4},
        };
        for (const auto& blk : chroma_blocks) {
            test_chroma_grid(top, chroma_frame.data(), chroma_stride,
                             blk.x, blk.y, blk.w, blk.h,
                             chroma_pic_w, chroma_pic_h,
                             total_chroma, total_cycles);
        }

        // Edge-clamping chroma tests
        int chroma_mv_tests[][2] = {
            {-4, 0}, {0, -4}, {60, 0}, {0, 60}, {-8, -8}, {60, 60},
        };
        for (const auto& mv : chroma_mv_tests) {
            for (int dy = 0; dy < 8; dy++) {
                for (int dx = 0; dx < 8; dx++) {
                    int full_dx = mv[0] + dx;
                    int full_dy = mv[1] + dy;
                    int blk_w = 4, blk_h = 4;
                    int blk_x = 4, blk_y = 4;

                    std::vector<uint8_t> expected(blk_w * blk_h);
                    mc_ref::chroma_mc_block(chroma_frame.data(), chroma_stride,
                                            blk_x, blk_y, full_dx, full_dy,
                                            blk_w, blk_h,
                                            chroma_pic_w, chroma_pic_h,
                                            expected.data(), blk_w);

                    int int_x = blk_x + (full_dx >> 3);
                    int int_y = blk_y + (full_dy >> 3);
                    auto ref_win = build_chroma_ref_window(
                        chroma_frame.data(), chroma_stride,
                        int_x, int_y, blk_w, blk_h,
                        chroma_pic_w, chroma_pic_h);

                    int frac_dx = full_dx & 7;
                    int frac_dy = full_dy & 7;
                    std::vector<uint8_t> got;
                    run_mc_block(top, true, 0, 0, frac_dx, frac_dy,
                                 blk_w, blk_h, ref_win, got);

                    bool match = (got.size() == expected.size());
                    if (match) {
                        for (size_t i = 0; i < got.size(); i++) {
                            if (got[i] != expected[i]) {
                                match = false;
                                char buf[256];
                                snprintf(buf, sizeof(buf),
                                         "edge chroma mismatch frac=(%d,%d) "
                                         "pos=%d got=%d want=%d",
                                         frac_dx, frac_dy,
                                         static_cast<int>(i), got[i], expected[i]);
                                fail(buf);
                                break;
                            }
                        }
                    }
                    if (match) ++g_pass_count;
                    ++edge_chroma;
                }
            }
        }
    }

    // -----------------------------------------------------------------------
    // Test 5: Specific j-position regression — this is where the classic
    // off-by-one bug lives (intermediate precision, double rounding).
    // Test with carefully constructed data that maximises intermediate values.
    // -----------------------------------------------------------------------
    {
        // Ramp pattern to stress intermediate accumulation
        std::vector<uint8_t> ramp_frame(pic_w * pic_h);
        for (int y = 0; y < pic_h; y++)
            for (int x = 0; x < pic_w; x++)
                ramp_frame[y * pic_w + x] = static_cast<uint8_t>((x * 13 + y * 7) & 0xFF);

        int j_tests = 0;
        // Test j position (frac_x=2, frac_y=2) specifically with multiple blocks
        for (int by = 2; by < pic_h - 10; by += 4) {
            for (int bx = 2; bx < pic_w - 10; bx += 4) {
                std::vector<uint8_t> expected(16);
                mc_ref::luma_mc_block(ramp_frame.data(), ref_stride,
                                      bx, by, 2, 2,  // frac (2,2) = j position
                                      4, 4, pic_w, pic_h,
                                      expected.data(), 4);

                int int_x = bx;
                int int_y = by;
                auto ref_win = build_luma_ref_window(ramp_frame.data(), ref_stride,
                                                      int_x, int_y,
                                                      4, 4, pic_w, pic_h);

                std::vector<uint8_t> got;
                run_mc_block(top, false, 2, 2, 0, 0, 4, 4, ref_win, got);

                for (size_t i = 0; i < got.size() && i < expected.size(); i++) {
                    if (got[i] != expected[i]) {
                        char buf[256];
                        snprintf(buf, sizeof(buf),
                                 "j-position regression blk=(%d,%d) pos=%d "
                                 "got=%d want=%d",
                                 bx, by, static_cast<int>(i), got[i], expected[i]);
                        fail(buf);
                        break;
                    }
                }
                ++j_tests;
            }
        }
        std::cout << "  j-position regression tests: " << j_tests << "\n";
    }

    // -----------------------------------------------------------------------
    // Summary
    // -----------------------------------------------------------------------
    int total_tests = total_luma + total_chroma + edge_luma + edge_chroma + extreme_luma;
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
              << " total=" << total_tests
              << " pass=" << g_pass_count
              << "\n";
    return 0;
}
