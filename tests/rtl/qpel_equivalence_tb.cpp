// Drives qpel_equivalence_tb_top: for every fractional position and every
// output position in the 16x16 block, the two independent quarter-pel luma
// implementations in the product tree must produce the identical sample.
#include <array>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <iostream>
#include <random>

#include "Vqpel_equivalence_tb_top.h"
#include "verilated.h"

static long failures = 0;
static long compares = 0;

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    Vqpel_equivalence_tb_top dut;

    // Deterministic stimulus: fixed seed so a failure is always reproducible.
    std::mt19937 rng(0xC0FFEEu);
    std::uniform_int_distribution<int> byte_dist(0, 255);

    struct Pattern {
        const char* name;
        int kind;
    };
    const Pattern patterns[] = {
        {"random", 0},
        {"flat_mid", 1},
        {"extremes", 2},   // 0/255 checkerboard - exercises clip1 on both sides
        {"ramp", 3},
        {"impulse", 4},
    };

    // Report at most a handful of mismatches, but count them all.
    const long report_cap = 20;

    for (const Pattern& pat : patterns) {
        for (int r = 0; r < 25; ++r) {
            for (int c = 0; c < 25; ++c) {
                int v = 0;
                switch (pat.kind) {
                    case 0: v = byte_dist(rng); break;
                    case 1: v = 128; break;
                    case 2: v = ((r + c) & 1) ? 255 : 0; break;
                    case 3: v = (r * 25 + c) % 256; break;
                    case 4: v = (r == 12 && c == 12) ? 255 : 0; break;
                }
                dut.plane[r * 25 + c] = static_cast<uint8_t>(v);
            }
        }

        for (int fy = 0; fy < 4; ++fy) {
            for (int fx = 0; fx < 4; ++fx) {
                dut.frac_x = fx;
                dut.frac_y = fy;
                for (int py = 0; py < 16; ++py) {
                    for (int px = 0; px < 16; ++px) {
                        dut.pos_x = px;
                        dut.pos_y = py;
                        dut.eval();
                        ++compares;
                        if (dut.block_pred != dut.sample_pred) {
                            ++failures;
                            if (failures <= report_cap) {
                                std::cerr << "FAIL qpel mismatch pattern=" << pat.name
                                          << " frac=(" << fx << "," << fy << ")"
                                          << " pos=(" << px << "," << py << ")"
                                          << " block=" << int(dut.block_pred)
                                          << " sample=" << int(dut.sample_pred) << "\n";
                            }
                        }
                    }
                }
            }
        }
    }

    if (failures) {
        std::cerr << "QPEL EQUIVALENCE FAILED mismatches=" << failures
                  << " compares=" << compares << "\n";
        std::cerr << "h264_luma_qpel_block_16x16 (h264_dpb.sv) and "
                     "h264_luma_qpel_sample (h264_inter_pred.sv) do not implement "
                     "the same function.\n";
        return 1;
    }
    std::cout << "QPEL EQUIVALENCE PASS compares=" << compares
              << " patterns=5 frac_positions=16 block_positions=256\n";
    return 0;
}
