#include "Vdecode_stub_fetch_mv_tb.h"
#include "verilated.h"

#include <cstdint>
#include <iostream>
#include <string>

namespace {

class Sim {
public:
    Vdecode_stub_fetch_mv_tb top{};
    uint64_t cycles = 0;

    void tick() {
        top.clk = 0;
        top.eval();
        top.clk = 1;
        top.eval();
        top.clk = 0;
        top.eval();
        ++cycles;
    }

    void reset() {
        top.reset = 1;
        top.idr_pulse = 0;
        top.p_pulse = 0;
        top.is_p_slice = 0;
        top.residual_valid = 0;
        top.slice_valid = 0;
        top.has_mb_type = 0;
        top.first_mb_p_skip = 0;
        top.first_mb_part_mode = 0;
        top.first_mb_mvd_x = 0;
        top.first_mb_mvd_y = 0;
        for (int i = 0; i < 8; ++i) tick();
        top.reset = 0;
        for (int i = 0; i < 4; ++i) tick();
    }

    bool waitIdle(int maxCycles) {
        for (int i = 0; i < maxCycles; ++i) {
            if (!top.busy) return true;
            tick();
        }
        return !top.busy;
    }

    bool waitFrames(uint16_t want, int maxCycles) {
        for (int i = 0; i < maxCycles; ++i) {
            if (top.frames_out >= want && !top.busy) return true;
            tick();
        }
        return top.frames_out >= want && !top.busy;
    }
};

bool fail(const std::string& msg) {
    std::cerr << "FAIL decode_stub fetch_mv: " << msg << "\n";
    return false;
}

} // namespace

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);

    // PRE-REGISTER: nonzero mvd_x=16 qpel on MB0 (no neighbours → MVP=0)
    // must produce fetch_mv=(16,0) and luma_origin_x = 0 + (16>>2) = 4.
    // FAULT_FORCE_ZERO_FETCH_MV must keep origin_x=0 and fail the origin check.
    constexpr int16_t kMvdX = 16;
    constexpr int16_t kMvdY = 0;
    constexpr int16_t kWantMvX = 16;
    constexpr int16_t kWantOriginX = 4; // 16 qpel → 4 full-pel

    Sim sim;
    sim.reset();

    // --- IDR: fill DPB reference with synthetic pattern ---
    sim.top.is_p_slice = 0;
    sim.top.idr_pulse = 1;
    sim.top.slice_valid = 1;
    sim.top.has_mb_type = 1;
    sim.top.first_mb_part_mode = 7;
    sim.tick();
    sim.top.idr_pulse = 0;
    // residual_valid ends PH_WAIT so DPB fill can start
    sim.top.residual_valid = 1;
    sim.tick();
    sim.top.residual_valid = 0;
    // 4x4 MBs * ~386 beats + paint 64*64 < 50k cycles
    if (!sim.waitFrames(1, 50000)) {
        return fail("IDR did not complete (frames_out<1)") ? 0 : 1;
    }

    // Hold P-slice cues before/during VCL so p_fetch_candidate is seen.
    sim.top.is_p_slice = 1;
    sim.top.slice_valid = 1;
    sim.top.has_mb_type = 1;
    sim.top.first_mb_p_skip = 0;
    sim.top.first_mb_part_mode = 0; // P_L0_16x16
    sim.top.first_mb_mvd_x = kMvdX;
    sim.top.first_mb_mvd_y = kMvdY;
    for (int i = 0; i < 4; ++i) sim.tick();

    sim.top.p_pulse = 1;
    sim.tick();
    sim.top.p_pulse = 0;
    sim.top.residual_valid = 1;
    sim.tick();
    sim.top.residual_valid = 0;

    // Wait until first P fetch publishes product MV (or frame completes).
    bool saw_mv = false;
    int16_t got_mv_x = 0, got_mv_y = 0;
    int16_t got_ox = 0, got_oy = 0;
    for (int i = 0; i < 200000; ++i) {
        sim.tick();
        if (sim.top.product_fetch_mv_x != 0 || sim.top.product_fetch_mv_y != 0 ||
            sim.top.frames_out >= 2) {
            got_mv_x = static_cast<int16_t>(sim.top.product_fetch_mv_x);
            got_mv_y = static_cast<int16_t>(sim.top.product_fetch_mv_y);
            got_ox = static_cast<int16_t>(sim.top.product_luma_origin_x);
            got_oy = static_cast<int16_t>(sim.top.product_luma_origin_y);
            saw_mv = true;
            if (sim.top.frames_out >= 2 && !sim.top.busy) break;
        }
    }
    if (!saw_mv && !sim.waitFrames(2, 1)) {
        return fail("P frame did not publish product_fetch_mv / complete") ? 0 : 1;
    }
    // Drain to idle so origin sticky from last fetch is stable.
    (void)sim.waitIdle(200000);
    got_mv_x = static_cast<int16_t>(sim.top.product_fetch_mv_x);
    got_mv_y = static_cast<int16_t>(sim.top.product_fetch_mv_y);
    got_ox = static_cast<int16_t>(sim.top.product_luma_origin_x);
    got_oy = static_cast<int16_t>(sim.top.product_luma_origin_y);

    if (got_mv_x != kWantMvX || got_mv_y != kMvdY) {
        std::cerr << "FAIL decode_stub fetch_mv: product_fetch_mv got=("
                  << got_mv_x << "," << got_mv_y << ") want=(" << kWantMvX << ","
                  << kMvdY << ")\n";
        return 1;
    }
    if (got_ox != kWantOriginX || got_oy != 0) {
        std::cerr << "FAIL decode_stub fetch_mv: luma_origin got=(" << got_ox
                  << "," << got_oy << ") want=(" << kWantOriginX << ",0)\n";
        return 1;
    }
    if (!sim.top.recon_valid) {
        return fail("recon_valid not set after P fetch") ? 0 : 1;
    }

    std::cout << "OK decode_stub fetch_mv: mv=(" << got_mv_x << "," << got_mv_y
              << ") luma_origin=(" << got_ox << "," << got_oy
              << ") cycles=" << sim.cycles << "\n";
    return 0;
}
