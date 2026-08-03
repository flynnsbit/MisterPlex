// Verilator TB for present_pace_seq — ENABLE on/off, late, early, 24-in-60.
#include "Vpresent_pace_tb.h"
#include "verilated.h"

#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>

static vluint64_t main_time = 0;
double sc_time_stamp() { return static_cast<double>(main_time); }

struct SwapSnap {
    bool on = false;
    bool off = false;
};

static void tick(Vpresent_pace_tb* t) {
    t->clk = 0;
    t->eval();
    main_time++;
    t->clk = 1;
    t->eval();
    main_time++;
}

// Sample do_swap on the vsync edge cycle — output is 1-cycle, cleared next tick.
static SwapSnap vsync(Vpresent_pace_tb* t) {
    t->vsync_pulse = 1;
    tick(t);
    SwapSnap s{t->do_swap_on != 0, t->do_swap_off != 0};
    t->vsync_pulse = 0;
    tick(t);
    return s;
}

static void ring(Vpresent_pace_tb* t, int bank) {
    t->pending_bank = bank & 1;
    t->pending_ready = 1;
    t->swap_req_toggle = !t->swap_req_toggle;
    tick(t);
}

// After DUT reset, host toggle must match swap_req_seen=0 or the next ring
// is a non-edge (toggle already 1 from a prior case).
static void rearm(Vpresent_pace_tb* t) {
    t->reset = 1;
    for (int i = 0; i < 2; ++i)
        tick(t);
    t->reset = 0;
    t->swap_req_toggle = 0;
    t->vsync_pulse = 0;
    for (int i = 0; i < 2; ++i)
        tick(t);
}

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    const char* which = std::getenv("PACE_CASE");
    std::string cse = which ? which : "all";
    int fails = 0;
    auto fail = [&](const char* m) {
        std::fprintf(stderr, "FAIL %s\n", m);
        ++fails;
    };

    auto* t = new Vpresent_pace_tb;
    t->reset = 1;
    t->clk = 0;
    t->vsync_pulse = 0;
    t->swap_req_toggle = 0;
    t->pending_bank = 0;
    t->pending_ready = 1;
    t->content_fps = 24;
    t->display_hz = 60;
    for (int i = 0; i < 4; ++i)
        tick(t);
    t->reset = 0;
    for (int i = 0; i < 4; ++i)
        tick(t);

    if (cse == "all" || cse == "legacy") {
        std::fprintf(stderr, "=== legacy ENABLE=0 ===\n");
        t->enable_sel = 0;
        ring(t, 1);
        SwapSnap s = vsync(t);
        if (!s.off)
            fail("legacy no swap");
        if (t->cnt_presented_off < 1)
            fail("legacy presented");
        if (fails == 0)
            std::fprintf(stderr, "PASS legacy\n");
    }

    if (cse == "all" || cse == "late") {
        std::fprintf(stderr, "=== ENABLE=1 late ===\n");
        rearm(t);
        t->enable_sel = 1;
        t->pending_ready = 0;
        SwapSnap s = vsync(t);
        if (s.on)
            fail("late swapped");
        if (t->cnt_late_on < 1)
            fail("late counter");
        if (fails == 0)
            std::fprintf(stderr, "PASS late\n");
    }

    if (cse == "all" || cse == "early") {
        std::fprintf(stderr, "=== ENABLE=1 early hold ===\n");
        rearm(t);
        t->enable_sel = 1;
        t->pending_ready = 1;
        ring(t, 0);
        SwapSnap s0 = vsync(t); // tick0 advance+swap
        if (!s0.on)
            fail("early first swap");
        ring(t, 1);
        SwapSnap s1 = vsync(t); // tick1 hold
        if (s1.on)
            fail("early second should hold");
        if (t->cnt_early_hold_on < 1)
            fail("early_hold counter");
        if (fails == 0)
            std::fprintf(stderr, "PASS early\n");
    }

    if (cse == "all" || cse == "film") {
        std::fprintf(stderr, "=== ENABLE=1 24-in-60 ===\n");
        rearm(t);
        t->enable_sel = 1;
        t->pending_ready = 1;
        unsigned film_swaps = 0;
        for (int n = 0; n < 60; ++n) {
            bool adv = true;
            if (n > 0) {
                const uint32_t a = (static_cast<uint32_t>(n) * 24u) / 60u;
                const uint32_t b = (static_cast<uint32_t>(n - 1) * 24u) / 60u;
                adv = (a != b);
            }
            if (adv)
                ring(t, n & 1);
            SwapSnap s = vsync(t);
            if (s.on)
                ++film_swaps;
        }
        std::fprintf(stderr, "film presented=%u vsync=%u late=%u early=%u snaps=%u\n",
                     static_cast<unsigned>(t->cnt_presented_on),
                     static_cast<unsigned>(t->cnt_vsync_on),
                     static_cast<unsigned>(t->cnt_late_on),
                     static_cast<unsigned>(t->cnt_early_hold_on), film_swaps);
        if (t->cnt_presented_on != 24)
            fail("film presented != 24");
        if (film_swaps != 24)
            fail("film snap swaps != 24");
        if (t->cnt_vsync_on != 60)
            fail("film vsync != 60");
        if (t->cnt_late_on != 0)
            fail("film late");
        if (fails == 0)
            std::fprintf(stderr, "PASS film\n");
    }

    // do_swap only with vsync: doorbell without vsync must not swap
    if (cse == "all" || cse == "tear") {
        std::fprintf(stderr, "=== no mid-scan swap ===\n");
        rearm(t);
        t->enable_sel = 1;
        t->pending_ready = 1;
        ring(t, 1);
        for (int i = 0; i < 5; ++i) {
            tick(t);
            if (t->do_swap_on)
                fail("swap without vsync");
        }
        if (fails == 0)
            std::fprintf(stderr, "PASS tear-guard\n");
    }

    delete t;
    if (fails) {
        std::fprintf(stderr, "present_pace_tb: %d FAIL(s)\n", fails);
        return 1;
    }
    std::fprintf(stderr, "present_pace_tb: PASS\n");
    return 0;
}
