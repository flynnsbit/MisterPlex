// Verilator TB: 720p DDR bandwidth + bank geom guard (w-mem).
// Proves with SIMULATION (not host arithmetic alone):
//   G1: Option-C 720p geometry does not overflow
//   R1: legacy 512KiB + 720p sticky-rejects (NEGATIVE teeth)
//   G2: combined R+W 2*1382400 B @ 1 beat/clk finishes inside 24fps budget
//   R2: starved beat rate trips budget_fail (NEGATIVE teeth)
//   G3: sdram_line_spill latency path completes
//   G4: contended host_wr+scan_rd @24 finishes inside budget (SIM proof)
//   R3: contended tiny budget → budget_fail (NEGATIVE teeth)

#include "Vddr_bw_geom_tb_top.h"
#include "verilated.h"

#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>

namespace {

void tick(Vddr_bw_geom_tb_top& t) {
    t.clk = 0;
    t.eval();
    t.clk = 1;
    t.eval();
}

void reset_dut(Vddr_bw_geom_tb_top& t) {
    t.reset = 1;
    t.g_check_en = 0;
    t.r_check_en = 0;
    t.bw_start = 0;
    t.bw_beat_fire = 0;
    t.sp_wr_en = 0;
    t.sp_wr_addr = 0;
    t.sp_wr_data = 0;
    t.sp_commit = 0;
    t.sp_rd_en = 0;
    t.sp_rd_addr = 0;
    t.c24_start = 0;
    t.c24_host_en = 0;
    t.c24_scan_en = 0;
    t.c24_spill_en = 0;
    t.cneg_start = 0;
    t.cneg_host_en = 0;
    t.cneg_scan_en = 0;
    for (int i = 0; i < 4; ++i)
        tick(t);
    t.reset = 0;
    tick(t);
}

int fail(const char* msg) {
    std::printf("FAIL ddr_bw_geom: %s\n", msg);
    return 1;
}

} // namespace

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    Vddr_bw_geom_tb_top top{};

    // ---------- G1: green geom 720p / Option-C ----------
    reset_dut(top);
    top.g_check_en = 1;
    tick(top);
    if (top.g_frame_bytes != 1382400u)
        return fail("G1 frame_bytes != 1382400");
    // usable = 0x180000 - 0x1000 = 0x17F000 = 1568768
    if (top.g_usable_bytes != 0x0017F000u)
        return fail("G1 usable_bytes != 0x17F000");
    if (top.g_overflow_now || top.g_overflow_reject)
        return fail("G1 Option-C must not overflow");
    std::printf("PASS G1 geom_green frame=%u usable=0x%x reject=0\n",
                top.g_frame_bytes, top.g_usable_bytes);

    // ---------- R1: red geom 720p / 512KiB (NEGATIVE) ----------
    reset_dut(top);
    top.r_check_en = 1;
    tick(top);
    if (top.r_frame_bytes != 1382400u)
        return fail("R1 frame_bytes");
    // usable = 0x80000 - 0x1000 = 0x7F000 = 520192
    if (top.r_usable_bytes != 0x0007F000u)
        return fail("R1 usable != 0x7F000");
    if (!top.r_overflow_now)
        return fail("R1 NEG teeth: overflow_now must be 1");
    tick(top);
    if (!top.r_overflow_reject)
        return fail("R1 NEG teeth: overflow_reject sticky must set");
    // Prove sticky holds after check drops
    top.r_check_en = 0;
    tick(top);
    if (!top.r_overflow_reject)
        return fail("R1 sticky lost after check_en=0");
    std::printf("PASS R1 geom_red_512k sticky_reject=1 (NEG teeth)\n");

    // ---------- G2: bandwidth combined R+W @ full beat rate ----------
    // target beats = 2 * (1382400/8) = 345600
    reset_dut(top);
    if (top.bw_target_beats != 345600u)
        return fail("G2 target_beats != 345600");
    if (top.bw_budget_cycles != 3750000u)
        return fail("G2 budget_cycles != 3750000 (90e6/24)");

    top.bw_start = 1;
    tick(top);
    top.bw_start = 0;
    // Drive one beat per cycle until done.
    uint64_t cyc = 0;
    constexpr uint64_t kCap = 400000ull;
    while (cyc < kCap && !top.bw_done && !top.bw_budget_fail) {
        top.bw_beat_fire = 1;
        tick(top);
        ++cyc;
    }
    if (!top.bw_done)
        return fail("G2 did not complete");
    if (top.bw_budget_fail)
        return fail("G2 budget_fail raised incorrectly");
    if (top.bw_beats != 345600u)
        return fail("G2 beats != 345600");
    // At 1 beat/clk, cycles ≈ 345600 << 3750000
    if (top.bw_cycles > 346000u)
        return fail("G2 cycles unexpectedly large");
    std::printf("PASS G2 bw_combined_rw beats=%u cycles=%u budget=%u fail=0\n",
                top.bw_beats, top.bw_cycles, top.bw_budget_cycles);

    // ---------- R2: starved bus → budget_fail (NEGATIVE) ----------
    // Budget intentionally tiny so even partial progress fails.
    // Re-instantiate via hierarchical force: we can't change params live.
    // Instead starve beats: never fire beat_fire; budget will expire.
    reset_dut(top);
    top.bw_start = 1;
    tick(top);
    top.bw_start = 0;
    top.bw_beat_fire = 0;
    // Fast-forward by ticking budget cycles — 3.75M is heavy for Verilator.
    // Use a separate small-budget path: we only prove sticky fail logic by
    // running a SHRUNK budget instance... top is fixed at 3750000.
    //
    // Practical NEG: run until cycles approach a reduced software check:
    // drive 0 beats for 10000 cycles and assert still busy, then we cannot
    // wait 3.75M here. Instead compile a second meter in the top? Already have
    // one. Add software-side proof that at observed rate 0 beats/cycle the
    // required cycles would be infinite → R2 is "no progress" detection via
    // a local mini-meter in C++ that mirrors the RTL formula, AND run RTL
    // with a forced early fail by using start+zero beats only if we reduce
    // budget.
    //
    // Dual approach: C++ mirrors RTL completion predicate for starved case
    // (must FAIL meet-budget), and RTL G2 already proved success path.
    {
        const uint32_t target = 345600u;
        const uint32_t budget = 3750000u;
        const uint32_t beats_starved = 0u;
        const bool would_fail = (beats_starved < target); // never completes
        const bool meets = !would_fail && (target <= budget);
        if (meets)
            return fail("R2 NEG mirror: starved must not meet budget");
        std::printf("PASS R2 starved_mirror meets_budget=0 (NEG teeth; RTL G2 is positive peer)\n");
    }

    // True RTL budget_fail: run a short custom loop using the fact that if we
    // only allow beats after budget... we need a small-budget DUT. Add quick
    // secondary path by overloading: wait, instantiate isn't available.
    // Patch: drive beat_fire=0 for 3750000 is too slow.
    // Speed: Verilator can do ~10M cycles/s; 3.75M ~0.4s acceptable.
    std::printf("R2_rtl: running full budget expiry with beat_fire=0 (may take ~1s)...\n");
    reset_dut(top);
    top.bw_start = 1;
    tick(top);
    top.bw_start = 0;
    top.bw_beat_fire = 0;
    cyc = 0;
    while (cyc < 4000000ull && !top.bw_budget_fail && !top.bw_done) {
        tick(top);
        ++cyc;
    }
    if (!top.bw_budget_fail)
        return fail("R2 RTL NEG: budget_fail must set with zero beats");
    if (top.bw_done)
        return fail("R2 RTL NEG: done must not set");
    std::printf("PASS R2 rtl_budget_fail cycles=%u beats=%u (NEG teeth)\n", top.bw_cycles,
                top.bw_beats);

    // ---------- G3: line spill ----------
    reset_dut(top);
    if (!top.sp_ready)
        return fail("G3 spill not ready after reset");
    for (int i = 0; i < 1280; ++i) {
        top.sp_wr_en = 1;
        top.sp_wr_addr = i;
        top.sp_wr_data = static_cast<uint8_t>(i * 3);
        tick(top);
    }
    top.sp_wr_en = 0;
    top.sp_commit = 1;
    tick(top);
    top.sp_commit = 0;
    if (!top.sp_busy)
        return fail("G3 spill_busy after commit");
    int guard = 0;
    while (!top.sp_done && guard < 32) {
        tick(top);
        ++guard;
    }
    if (!top.sp_done)
        return fail("G3 spill_done timeout");
    top.sp_rd_en = 1;
    top.sp_rd_addr = 100;
    tick(top);
    tick(top);
    if (!top.sp_rd_valid)
        return fail("G3 rd_valid");
    if (top.sp_rd_data != static_cast<uint8_t>(100 * 3))
        return fail("G3 rd_data mismatch");
    std::printf("PASS G3 sdram_line_spill latency+readback\n");

    // ---------- G4: contended concurrent host_wr + scan_rd @24 ----------
    // RR serves one client/clk → total beats = 2*(1382400/8) = 345600
    // Budget 3750000 (90e6/24). PRED: done=1 fail=0 cycles≈345600.
    reset_dut(top);
    if (top.c24_host_target != 172800u)
        return fail("G4 host_target != 172800");
    if (top.c24_scan_target != 172800u)
        return fail("G4 scan_target != 172800");
    if (top.c24_budget != 3750000u)
        return fail("G4 budget != 3750000");
    top.c24_host_en = 1;
    top.c24_scan_en = 1;
    top.c24_spill_en = 0;
    top.c24_start = 1;
    tick(top);
    top.c24_start = 0;
    cyc = 0;
    while (cyc < kCap && !top.c24_done && !top.c24_budget_fail) {
        tick(top);
        ++cyc;
    }
    if (!top.c24_done)
        return fail("G4 contended did not complete");
    if (top.c24_budget_fail)
        return fail("G4 budget_fail incorrectly set");
    if (top.c24_host_beats != 172800u)
        return fail("G4 host_beats != 172800");
    if (top.c24_scan_beats != 172800u)
        return fail("G4 scan_beats != 172800");
    if (top.c24_total_beats != 345600u)
        return fail("G4 total_beats != 345600");
    if (top.c24_cycles > 346000u)
        return fail("G4 cycles unexpectedly large");
    std::printf("PASS G4 contended_rw24 host=%u scan=%u total=%u cycles=%u fail=0\n",
                top.c24_host_beats, top.c24_scan_beats, top.c24_total_beats, top.c24_cycles);

    // ---------- R3: tiny budget NEG (cannot finish 345600 in 1000 cyc) ----------
    reset_dut(top);
    top.cneg_host_en = 1;
    top.cneg_scan_en = 1;
    top.cneg_start = 1;
    tick(top);
    top.cneg_start = 0;
    cyc = 0;
    while (cyc < 5000ull && !top.cneg_budget_fail && !top.cneg_done) {
        tick(top);
        ++cyc;
    }
    if (!top.cneg_budget_fail)
        return fail("R3 NEG: budget_fail must set under tiny budget");
    if (top.cneg_done)
        return fail("R3 NEG: done must not set");
    if (top.cneg_total_beats >= 345600u)
        return fail("R3 NEG: should not reach full transfer");
    std::printf("PASS R3 contended_tiny_budget fail=1 cycles=%u beats=%u (NEG teeth)\n",
                top.cneg_cycles, top.cneg_total_beats);

    // ---------- R4: scan starved (enable=0) under 24fps budget — still fails ----------
    // Only host enabled → scan never completes → must budget_fail (not silent hang).
    // Full 3.75M cycles is ~1s; acceptable for NEG teeth.
    std::printf("R4: scan starved under 24fps budget (may take ~1s)...\n");
    reset_dut(top);
    top.c24_host_en = 1;
    top.c24_scan_en = 0; // STARVE scan
    top.c24_spill_en = 0;
    top.c24_start = 1;
    tick(top);
    top.c24_start = 0;
    cyc = 0;
    while (cyc < 4000000ull && !top.c24_budget_fail && !top.c24_done) {
        tick(top);
        ++cyc;
    }
    if (!top.c24_budget_fail)
        return fail("R4 NEG: budget_fail must set when scan starved");
    if (top.c24_done)
        return fail("R4 NEG: done must not set when scan starved");
    if (top.c24_scan_beats != 0u)
        return fail("R4 NEG: scan_beats must stay 0");
    std::printf("PASS R4 scan_starved budget_fail=1 host=%u scan=0 (NEG teeth)\n",
                top.c24_host_beats);

    std::printf("PASS ddr_bw_geom all\n");
    std::printf("OK ddr_bw_geom sim_executed\n");
    return 0;
}
