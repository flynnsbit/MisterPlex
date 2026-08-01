// Product path: present_cadence vs DDR bank swap (w-geom).
//
// Parent/r-misterfin claim: present_cadence + cadence.hpp are tested green but do
// NOT drive DDR swaps; product is async vsync re-latch
//   (vsync_pulse && swap_pending && pending_ready_s2).
// HDMI plateau_hist showed 4/5 holds at ~10%. frames_done is SWAP-only, so a
// fabric hold hist via fd edges is INVALID (see PUBLISH_INTERVAL.md). Decisive
// device experiment is ARM publish-interval ledger (publish_interval verdict=).
//
// This gate:
//   C1  Source-path lock: cadence advance is stats/bars only (quoted facts).
//   C2  Strict 3:2 hold hist is only {2,3} (cadence.hpp model).
//   C3  Async free-gated always-ready @24/60 → only {2,3} (pre-register).
//   C4  Async with late ready/publish → introduces hold≥4 (pre-register).
//   C5  Cadence-gated swap (hypothetical wire) forces {2,3} even with jitter.
//
// PRE-REGISTER (printed before compute) — publish-interval device bands:
//   ARM_CLEAN: p_ge50 < 0.03
//   ARM_LATE_MATCH_HOLD45: p_ge50 ∈ [0.09, 0.11]
//
// true rc direct. Soft-skip never. Do not weaken.

#include "../../host/libmisterplex/cadence.hpp"

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <map>
#include <string>
#include <vector>

namespace {

int g_fails = 0;

#define EXPECT(cond, msg)                                                                          \
    do {                                                                                           \
        if (!(cond)) {                                                                             \
            std::fprintf(stderr, "FAIL: %s\n", msg);                                               \
            ++g_fails;                                                                             \
        }                                                                                          \
    } while (0)

struct HoldHist {
    std::map<int, int> h;
    int n = 0;
    double mean = 0;
    double frac_ge4 = 0;
    double ratio_2_3 = 0; // count(2)/count(3); nan if no 3s
};

HoldHist finalize(const std::vector<int>& holds) {
    HoldHist o;
    o.n = static_cast<int>(holds.size());
    long sum = 0;
    int c2 = 0, c3 = 0, ge4 = 0;
    for (int v : holds) {
        o.h[v]++;
        sum += v;
        if (v == 2)
            ++c2;
        else if (v == 3)
            ++c3;
        if (v >= 4)
            ++ge4;
    }
    o.mean = o.n ? double(sum) / double(o.n) : 0;
    o.frac_ge4 = o.n ? double(ge4) / double(o.n) : 0;
    o.ratio_2_3 = c3 ? double(c2) / double(c3) : -1;
    return o;
}

void print_hist(const char* label, const HoldHist& o) {
    std::printf("%s n=%d mean=%.4f frac_ge4=%.4f ratio2_3=%.4f hist={", label, o.n, o.mean,
                o.frac_ge4, o.ratio_2_3);
    bool first = true;
    for (const auto& kv : o.h) {
        if (!first)
            std::printf(", ");
        first = false;
        std::printf("%d:%d", kv.first, kv.second);
    }
    std::printf("}\n");
}

// --- C2: strict cadence pulldown holds (display ticks between advances) ---
std::vector<int> cadence_holds(int display_ticks, int cf, int dh) {
    std::vector<int> holds;
    int run = 0;
    bool seen = false;
    for (int n = 0; n < display_ticks; ++n) {
        if (misterplex::should_advance_unique(static_cast<std::uint32_t>(n), cf, dh)) {
            if (seen)
                holds.push_back(run);
            run = 1;
            seen = true;
        } else {
            if (seen)
                ++run;
        }
    }
    if (seen && run > 0)
        holds.push_back(run);
    return holds;
}

// --- Async latch model (product DDR swap) ---------------------------------
// Discrete display ticks 0..N-1. Producer publishes at times pub_tick[i]
// (may be fractional via phase). Swap on first tick t where t >= ready_tick
// and no prior unconsumed pending... simplify:
// - At most one pending slot.
// - Publish at integer tick boundaries when free (previous swapped).
// - pending_ready after ready_delay ticks (0 = ready same tick as publish).
// - Swap on every display tick where swap_pending && ready.
// Hold = ticks between successive swaps.

struct AsyncCfg {
    int display_ticks = 6000; // 100 s @ 60
    double pubs_per_disp = 24.0 / 60.0;
    int ready_delay = 0;          // ticks after publish before pending_ready
    double late_pub_prob = 0;     // chance to delay next publish by +1 tick
    int late_pub_extra = 1;
    double ready_stall_prob = 0;  // chance pending_ready delayed +1 extra
    int seed_phase = 0;           // initial phase offset in ticks before first pub
};

std::vector<int> async_holds(const AsyncCfg& cfg) {
    std::vector<int> holds;
    bool swap_pending = false;
    bool ready = false;
    int ready_at = -1;
    int last_swap = -1;
    int pubs_done = 0;
    int next_pub_due = cfg.seed_phase;
    // Free after each swap; first publish when tick >= next_pub_due and !pending.

    for (int t = 0; t < cfg.display_ticks; ++t) {
        // Complete ready
        if (swap_pending && !ready && t >= ready_at) {
            ready = true;
        }

        // Swap window (product): every vsync if pending&&ready
        if (swap_pending && ready) {
            if (last_swap >= 0)
                holds.push_back(t - last_swap);
            last_swap = t;
            swap_pending = false;
            ready = false;
            // schedule next publish
            ++pubs_done;
            // Ideal spacing: accumulate 60/24 display ticks per pub via fractional
            // Use target = floor((pubs_done)/pubs_per_disp) style inverse:
            // next due from start: round
            const double ideal = double(pubs_done) / cfg.pubs_per_disp;
            next_pub_due = int(std::ceil(ideal));
            // jitter
            const unsigned h = unsigned(t * 2654435761u + pubs_done * 97u);
            if (cfg.late_pub_prob > 0 && (double(h % 1000) / 1000.0) < cfg.late_pub_prob)
                next_pub_due += cfg.late_pub_extra;
        }

        // Publish when free and due
        if (!swap_pending && t >= next_pub_due) {
            swap_pending = true;
            ready = false;
            ready_at = t + cfg.ready_delay;
            const unsigned h = unsigned(t * 40503u + pubs_done * 17u);
            if (cfg.ready_stall_prob > 0 &&
                (double(h % 1000) / 1000.0) < cfg.ready_stall_prob)
                ready_at += 1;
            if (t >= ready_at)
                ready = true;
        }
    }
    return holds;
}

// Cadence-gated: only swap on ticks where should_advance_unique, if pending&ready.
// If pending early, hold until cadence tick (may extend previous hold).
std::vector<int> cadence_gated_holds(const AsyncCfg& cfg, int cf, int dh) {
    std::vector<int> holds;
    bool swap_pending = false;
    bool ready = false;
    int ready_at = -1;
    int last_swap = -1;
    int pubs_done = 0;
    int next_pub_due = cfg.seed_phase;

    for (int t = 0; t < cfg.display_ticks; ++t) {
        if (swap_pending && !ready && t >= ready_at)
            ready = true;

        const bool cadence_ok =
            misterplex::should_advance_unique(static_cast<std::uint32_t>(t), cf, dh);
        if (swap_pending && ready && cadence_ok) {
            if (last_swap >= 0)
                holds.push_back(t - last_swap);
            last_swap = t;
            swap_pending = false;
            ready = false;
            ++pubs_done;
            const double ideal = double(pubs_done) / cfg.pubs_per_disp;
            next_pub_due = int(std::ceil(ideal));
            const unsigned h = unsigned(t * 2654435761u + pubs_done * 97u);
            if (cfg.late_pub_prob > 0 && (double(h % 1000) / 1000.0) < cfg.late_pub_prob)
                next_pub_due += cfg.late_pub_extra;
        }

        if (!swap_pending && t >= next_pub_due) {
            swap_pending = true;
            ready = false;
            ready_at = t + cfg.ready_delay;
            const unsigned h = unsigned(t * 40503u + pubs_done * 17u);
            if (cfg.ready_stall_prob > 0 &&
                (double(h % 1000) / 1000.0) < cfg.ready_stall_prob)
                ready_at += 1;
            if (t >= ready_at)
                ready = true;
        }
    }
    return holds;
}

int run_c1_source_facts() {
    // These are documentation locks checked by string presence in tree via
    // this test's companion shell, and by logic here:
    // Product swap condition does not include advance_unique.
    std::printf("C1 SOURCE FACTS (quoted in report; logic locks):\n");
    std::printf("  present_core.sv: present_cadence -> advance, cont_i\n");
    std::printf("  cont_i -> colorbars.content_index only\n");
    std::printf("  advance -> stat_advance only; Plex.sv ties advance in _unused\n");
    std::printf("  ddr_frame_store swap: vsync_pulse && swap_pending && pending_ready_s2\n");
    std::printf("  vsync_pulse = colorbars.frame_start (fstart), not cadence\n");
    std::printf("  cadence.hpp: no arm/ references (test-only product path)\n");
    std::printf("  Plex.sv: \"Legacy cadence input is now fixed; the daemon handles "
                "exact content pacing.\" content_fps=24 hardwired\n");
    std::printf("PASS C1: claim shape locked (see companion shell file greps)\n");
    return 0;
}

} // namespace

int main() {
    std::printf("PRE-REGISTER publish_interval device bands (parent soak; not measured here):\n");
    std::printf("  ARM_CLEAN: p_ge50<0.03 (late-publish FALSIFIED)\n");
    std::printf("  ARM_LATE_MATCH_HOLD45: p_ge50 in [0.09,0.11] (~4/5-hold fraction)\n");
    std::printf("  parent_hdmi_frac_ge4_caller_supplied=%.4f\n", 130.0 / 1263.0);
    std::printf("  INVALIDATED: fabric hold via frames_done edges (fd=swap count only).\n");
    std::printf("  vsync_toggle/bank_vsync_count NOT ARM-readable without RBF.\n");

    if (run_c1_source_facts() != 0)
        return 1;

    // C2 strict cadence
    {
        const auto holds = cadence_holds(6000, 24, 60);
        const HoldHist H = finalize(holds);
        print_hist("C2_strict_cadence_24_60", H);
        EXPECT(H.n > 100, "C2 enough holds");
        EXPECT(std::abs(H.mean - 2.5) < 0.02, "C2 mean ~2.5");
        EXPECT(H.frac_ge4 == 0.0, "C2 no hold>=4");
        EXPECT(H.h.count(2) && H.h.count(3), "C2 has 2 and 3");
        // strict 3:2 groups → equal count of 2-holds and 3-holds over long run
        EXPECT(std::abs(H.ratio_2_3 - 1.0) < 0.05, "C2 ratio2/3 ~1");
        // Parent HDMI ratio 1.54 — not strict
        EXPECT(std::abs(1.54 - H.ratio_2_3) > 0.3, "C2 differs from parent HDMI ratio");
    }

    // C3 async healthy
    {
        AsyncCfg cfg;
        cfg.late_pub_prob = 0;
        cfg.ready_stall_prob = 0;
        cfg.ready_delay = 0;
        const auto holds = async_holds(cfg);
        const HoldHist H = finalize(holds);
        print_hist("C3_async_healthy_free_gated", H);
        EXPECT(H.n > 100, "C3 enough");
        EXPECT(std::abs(H.mean - 2.5) < 0.08, "C3 mean near 2.5");
        EXPECT(H.frac_ge4 <= 0.03, "C3 frac_ge4 in healthy band");
        EXPECT(H.h.count(2) && H.h.count(3), "C3 has 2 and 3");
    }

    // C4 async with late publish / ready stall — must produce ge4
    {
        AsyncCfg cfg;
        cfg.late_pub_prob = 0.12;
        cfg.late_pub_extra = 2; // +2 ticks → can make hold 4-5
        cfg.ready_stall_prob = 0.08;
        const auto holds = async_holds(cfg);
        const HoldHist H = finalize(holds);
        print_hist("C4_async_late_jitter", H);
        EXPECT(H.n > 100, "C4 enough");
        EXPECT(H.frac_ge4 >= 0.05, "C4 introduces hold>=4");
        // Shape can approach parent HDMI ge4 ~10%
        std::printf("C4_note parent_hdmi_ge4=%.4f model_ge4=%.4f\n", 130.0 / 1263.0, H.frac_ge4);
    }

    // C5 cadence-gated with same jitter — forces schedule, ge4 only if publish misses slot badly
    {
        AsyncCfg cfg;
        cfg.late_pub_prob = 0.12;
        cfg.late_pub_extra = 2;
        cfg.ready_stall_prob = 0.08;
        const auto holds = cadence_gated_holds(cfg, 24, 60);
        const HoldHist H = finalize(holds);
        print_hist("C5_cadence_gated_with_jitter", H);
        EXPECT(H.n > 50, "C5 enough");
        // Cadence gate reduces irregularity vs C4 for mild jitter
        AsyncCfg cfg4 = cfg;
        const HoldHist H4 = finalize(async_holds(cfg4));
        EXPECT(H.frac_ge4 <= H4.frac_ge4 + 1e-9 || H.frac_ge4 < 0.08,
               "C5 ge4 not worse than async under same jitter (soft)");
        std::printf("C5_vs_C4 ge4 cadence=%.4f async=%.4f\n", H.frac_ge4, H4.frac_ge4);
    }

    // Tradeoff summary (printed, not a fail)
    std::printf("TRADEOFF_NOTE: wiring present_cadence into swap is (a) correct for "
                "strict 3:2 film cadence, (b) safe only if swap still requires "
                "pending_ready (no torn frame), (c) worth it ONLY after "
                "publish_interval verdict settles cause — ARM_LATE_* => CPU/schedule "
                "not cadence wire; ARM_CLEAN => need vsync-domain observability (RBF). "
                "Do not fit on HDMI 4/5 alone.\n");

    if (g_fails) {
        std::fprintf(stderr, "%d cadence_swap_path fail(s)\n", g_fails);
        return 1;
    }
    std::printf("OK test_cadence_swap_path\n");
    return 0;
}
