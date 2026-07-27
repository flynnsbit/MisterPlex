// Cross-validation: compare w-rel's h264_luma_qpel_sample and
// h264_chroma_epel_sample against our C++ reference model.
// If both agree, the golden oracle is independently confirmed.
#include "Vh264_mc_crossval_tb.h"
#include "verilated.h"
#include "h264_mc_ref_model.h"

#include <cstdint>
#include <cstdio>
#include <random>

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    Vh264_mc_crossval_tb top;

    std::mt19937 rng(99);
    std::uniform_int_distribution<int> pix(0, 255);

    int luma_pass = 0, luma_fail = 0;
    int chroma_pass = 0, chroma_fail = 0;

    // --- Luma cross-validation: all 16 positions × 200 random windows ---
    const int pic_w = 9, pic_h = 9, stride = 9;
    for (int trial = 0; trial < 200; trial++) {
        // Random 9×9 reference window
        uint8_t win[81];
        for (int i = 0; i < 81; i++) win[i] = static_cast<uint8_t>(pix(rng));

        for (int fy = 0; fy < 4; fy++) {
            for (int fx = 0; fx < 4; fx++) {
                // Feed to w-rel's SV module
                for (int i = 0; i < 81; i++)
                    top.luma_ref[i] = win[i];
                top.luma_frac_x = fx;
                top.luma_frac_y = fy;
                top.clk = 0; top.eval();
                top.clk = 1; top.eval();

                uint8_t sv_result = top.luma_sample;

                // Compute from our C++ reference model
                // The SV module's center is at (4,4) in the 9×9 window.
                // Our reference model takes a full frame and integer coords.
                // So int_x=4, int_y=4 in a 9×9 "picture" = the center sample.
                uint8_t cpp_result = mc_ref::luma_interp(
                    win, stride, 4, 4, fx, fy, pic_w, pic_h);

                if (sv_result != cpp_result) {
                    fprintf(stderr,
                        "FAIL crossval luma trial=%d frac=(%d,%d) "
                        "sv=%d cpp=%d\n",
                        trial, fx, fy, sv_result, cpp_result);
                    luma_fail++;
                } else {
                    luma_pass++;
                }
            }
        }
    }

    // --- Chroma cross-validation: all 64 positions × 200 random quads ---
    for (int trial = 0; trial < 200; trial++) {
        uint8_t p00 = pix(rng), p10 = pix(rng), p01 = pix(rng), p11 = pix(rng);

        for (int fdy = 0; fdy < 8; fdy++) {
            for (int fdx = 0; fdx < 8; fdx++) {
                top.chroma_p00 = p00;
                top.chroma_p10 = p10;
                top.chroma_p01 = p01;
                top.chroma_p11 = p11;
                top.chroma_frac_x = fdx;
                top.chroma_frac_y = fdy;
                top.clk = 0; top.eval();
                top.clk = 1; top.eval();

                uint8_t sv_result = top.chroma_sample;

                // Our C++ model: build a tiny 2×2 frame
                uint8_t frame[4] = {p00, p10, p01, p11};
                uint8_t cpp_result = mc_ref::chroma_interp(
                    frame, 2, 0, 0, fdx, fdy, 2, 2);

                if (sv_result != cpp_result) {
                    fprintf(stderr,
                        "FAIL crossval chroma trial=%d frac=(%d,%d) "
                        "sv=%d cpp=%d\n",
                        trial, fdx, fdy, sv_result, cpp_result);
                    chroma_fail++;
                } else {
                    chroma_pass++;
                }
            }
        }
    }

    int total_fail = luma_fail + chroma_fail;
    if (total_fail > 0) {
        fprintf(stderr, "FAIL crossval: luma %d/%d chroma %d/%d\n",
                luma_fail, luma_pass + luma_fail,
                chroma_fail, chroma_pass + chroma_fail);
        return 1;
    }

    printf("OK crossval: C++ ref model matches w-rel SV modules — "
           "luma=%d chroma=%d total=%d\n",
           luma_pass, chroma_pass, luma_pass + chroma_pass);
    return 0;
}
