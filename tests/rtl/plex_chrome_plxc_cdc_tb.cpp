// Multi-clock PLXC CDC hierarchy: 20 MHz sys → 74.25 MHz hdmi.
// Green: consecutive loader-style burst of 2 list + ctrl → all 3 on hdmi + host_if.
// Green: full MAX_CMDS=112 list + ctrl-last (113 beats) conservation — no drop.
// Green: stopped-rd fill-to-full then resume (DEPTH=8) — all body+ctrl conserved
//        when wr only advances on !wr_full (loader host_ready). DROP twin ignores full.
// Red: edge-detect twin sees only 1 beat (EXECUTED fail path).
#include "Vplex_chrome_plxc_cdc_tb.h"
#include "verilated.h"

#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <vector>

static vluint64_t main_time = 0;
double sc_time_stamp() { return static_cast<double>(main_time); }

// 20 MHz period 50ns; 74.25 MHz period ≈ 13.468 ns → use 50 and 14 time units
static const int SYS_HALF = 25;
static const int HDMI_HALF = 7;

struct Beat {
    uint8_t addr;
    uint64_t data;
};

static void eval_both(Vplex_chrome_plxc_cdc_tb* t) {
    t->eval();
    main_time++;
}

// Advance to next edge opportunity; simple independent clocks
static void run_for(Vplex_chrome_plxc_cdc_tb* t, int sys_cycles,
                    std::vector<Beat>* prod, std::vector<Beat>* fault,
                    int* list_we_n, std::vector<Beat>* list_beats) {
    // run until sys advanced sys_cycles (each sys cycle = 2*SYS_HALF ticks of sys clk)
    int sys_edges = 0;
    int sys_phase = 0;
    int hdmi_phase = 0;
    const int target = sys_cycles * 2; // rising+falling counted via half-phases
    // Use time-based: one sys period = 50 units, hdmi = 14 units
    vluint64_t end = main_time + static_cast<vluint64_t>(sys_cycles) * 50;
    int prev_sys = t->clk_sys;
    int prev_hdmi = t->clk_hdmi;
    while (main_time < end) {
        int ns = static_cast<int>(main_time % 50);
        int nh = static_cast<int>(main_time % 14);
        t->clk_sys = (ns < 25) ? 1 : 0;
        t->clk_hdmi = (nh < 7) ? 1 : 0;
        eval_both(t);
        // sample on hdmi rising
        if (!prev_hdmi && t->clk_hdmi) {
            if (t->prod_host_we) {
                prod->push_back({static_cast<uint8_t>(t->prod_host_addr),
                                 static_cast<uint64_t>(t->prod_host_data)});
            }
            if (t->fault_host_we) {
                fault->push_back({static_cast<uint8_t>(t->fault_host_addr),
                                  static_cast<uint64_t>(t->fault_host_data)});
            }
            if (t->prod_list_we) {
                (*list_we_n)++;
                list_beats->push_back({static_cast<uint8_t>(t->prod_list_waddr),
                                       static_cast<uint64_t>(t->prod_list_wdata)});
            }
        }
        prev_sys = t->clk_sys;
        prev_hdmi = t->clk_hdmi;
    }
}

// Drive sys_we on sys rising edges for consecutive beats (loader style)
static void push_burst(Vplex_chrome_plxc_cdc_tb* t, const std::vector<Beat>& beats,
                       std::vector<Beat>* prod, std::vector<Beat>* fault,
                       int* list_we_n, std::vector<Beat>* list_beats) {
    // Align to sys rising
    while (!(t->clk_sys == 0)) {
        // advance 1 time unit
        int ns = static_cast<int>((main_time + 1) % 50);
        int nh = static_cast<int>((main_time + 1) % 14);
        main_time++;
        t->clk_sys = (ns < 25) ? 1 : 0;
        t->clk_hdmi = (nh < 7) ? 1 : 0;
        t->eval();
    }
    size_t bi = 0;
    int holding = 0;
    int prev_hdmi = t->clk_hdmi;
    int prev_sys = t->clk_sys;
    // For each beat: drive during one full sys high period
    while (bi < beats.size() || holding) {
        int ns = static_cast<int>((main_time + 1) % 50);
        int nh = static_cast<int>((main_time + 1) % 14);
        main_time++;
        int next_sys = (ns < 25) ? 1 : 0;
        int next_hdmi = (nh < 7) ? 1 : 0;
        // before rising sys, set we/addr/data for this beat
        if (!prev_sys && next_sys) {
            if (bi < beats.size()) {
                t->sys_we = 1;
                t->sys_addr = beats[bi].addr;
                t->sys_data = beats[bi].data;
                bi++;
                holding = 1;
            } else {
                t->sys_we = 0;
                holding = 0;
            }
        }
        t->clk_sys = next_sys;
        t->clk_hdmi = next_hdmi;
        t->eval();
        if (!prev_hdmi && next_hdmi) {
            if (t->prod_host_we)
                prod->push_back({static_cast<uint8_t>(t->prod_host_addr),
                                 static_cast<uint64_t>(t->prod_host_data)});
            if (t->fault_host_we)
                fault->push_back({static_cast<uint8_t>(t->fault_host_addr),
                                  static_cast<uint64_t>(t->fault_host_data)});
            if (t->prod_list_we) {
                (*list_we_n)++;
                list_beats->push_back({static_cast<uint8_t>(t->prod_list_waddr),
                                       static_cast<uint64_t>(t->prod_list_wdata)});
            }
        }
        prev_sys = next_sys;
        prev_hdmi = next_hdmi;
        if (bi >= beats.size() && !next_sys)
            holding = 0;
    }
    t->sys_we = 0;
}

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    int fails = 0;
    auto fail = [&](const char* m) {
        std::fprintf(stderr, "FAIL %s\n", m);
        ++fails;
    };

    auto* t = new Vplex_chrome_plxc_cdc_tb;
    t->reset = 1;
    t->clk_sys = 0;
    t->clk_hdmi = 0;
    t->sys_we = 0;
    t->sys_addr = 0;
    t->sys_data = 0;
    t->sh_we = 0;
    t->sh_addr = 0;
    t->sh_data = 0;

    std::vector<Beat> prod, fault, list_beats;
    int list_we_n = 0;

    // reset for ~20 sys cycles
    run_for(t, 20, &prod, &fault, &list_we_n, &list_beats);
    t->reset = 0;
    run_for(t, 10, &prod, &fault, &list_we_n, &list_beats);
    prod.clear();
    fault.clear();
    list_beats.clear();
    list_we_n = 0;

    // Loader-style burst: 2 list words + ctrl, consecutive sys we=1 (no low gap)
    const uint64_t g0 = (uint64_t)0x23 << 40 | (uint64_t)64 << 24 | (uint64_t)64 << 8 | 2ull;
    const uint64_t g1 = (uint64_t)0x41 << 40 | (uint64_t)80 << 24 | (uint64_t)64 << 8 | 2ull;
    const uint64_t ctrl = 0x504C5843ull | (1ull << 32) | (2ull << 34) | (7ull << 48);
    std::vector<Beat> burst = {
        {0x00, g0},
        {0x01, g1},
        {0xFF, ctrl},
    };

    std::fprintf(stderr, "=== GREEN product FIFO CDC burst (2 list + ctrl) ===\n");
    std::fprintf(stderr, "EXECUTED product_burst\n");
    push_burst(t, burst, &prod, &fault, &list_we_n, &list_beats);
    // drain
    run_for(t, 40, &prod, &fault, &list_we_n, &list_beats);

    std::fprintf(stderr, "prod_beats=%zu fault_beats=%zu list_we=%d cfg_en=%d cfg_cnt=%d cfg_seq=%d\n",
                 prod.size(), fault.size(), list_we_n, (int)t->prod_cfg_enable,
                 (int)t->prod_cfg_count, (int)t->prod_cfg_seq);

    if (prod.size() != 3)
        fail("product must deliver exactly 3 beats");
    if (prod.size() >= 1 && !(prod[0].addr == 0x00 && prod[0].data == g0))
        fail("prod beat0 list0");
    if (prod.size() >= 2 && !(prod[1].addr == 0x01 && prod[1].data == g1))
        fail("prod beat1 list1");
    if (prod.size() >= 3 && !(prod[2].addr == 0xFF && prod[2].data == ctrl))
        fail("prod beat2 ctrl");
    if (list_we_n != 2)
        fail("host_if list_we count want 2");
    if (!t->prod_cfg_enable)
        fail("host_if cfg_enable");
    if (t->prod_cfg_count != 2)
        fail("host_if cfg_count");
    if (t->prod_cfg_seq != 7)
        fail("host_if cfg_seq");
    if (fails == 0)
        std::fprintf(stderr, "PASS product_burst\n");

    // RED: edge fault must NOT deliver 3
    std::fprintf(stderr, "=== RED edge-detect twin (expect collapse) ===\n");
    std::fprintf(stderr, "EXECUTED edge_fault_burst\n");
    if (fault.size() >= 3)
        fail("edge twin must NOT deliver all 3 beats (would mean red is green)");
    if (fault.size() != 1)
        fail("edge twin want exactly 1 beat (rising-edge collapse)");
    else
        std::fprintf(stderr, "edge_fault_beats=%zu (collapsed) OK\n", fault.size());
    if (fails == 0)
        std::fprintf(stderr, "PASS edge_fault_collapse\n");

    // Single-beat still works (no regression)
    prod.clear();
    fault.clear();
    list_beats.clear();
    list_we_n = 0;
    std::fprintf(stderr, "=== single beat passthrough ===\n");
    std::fprintf(stderr, "EXECUTED single_beat\n");
    push_burst(t, {{0x00, g0}}, &prod, &fault, &list_we_n, &list_beats);
    run_for(t, 20, &prod, &fault, &list_we_n, &list_beats);
    if (prod.size() != 1 || prod[0].data != g0)
        fail("single beat");
    if (fails == 0)
        std::fprintf(stderr, "PASS single_beat\n");

    // Full-list conservation: 112 list beats + ctrl LAST (loader MAX_CMDS path).
    // Observations that fail under drop/reorder:
    //   prod_beats != 113, any list missing, ctrl not last, host_if count/seq wrong.
    prod.clear();
    fault.clear();
    list_beats.clear();
    list_we_n = 0;
    std::fprintf(stderr, "=== FULL list conservation (112 + ctrl-last) ===\n");
    std::fprintf(stderr, "EXECUTED full_list_conservation\n");
    {
        constexpr int N = 112;
        std::vector<Beat> full;
        full.reserve(static_cast<size_t>(N) + 1);
        for (int i = 0; i < N; ++i) {
            // Unique payload per slot: op=1 box, x=i, y=i&0xff, pal in high
            const uint64_t d = 1ull | (static_cast<uint64_t>(i & 0xFFFF) << 8) |
                               (static_cast<uint64_t>(i & 0xFF) << 24) |
                               (static_cast<uint64_t>(0xA500u + i) << 40);
            full.push_back({static_cast<uint8_t>(i), d});
        }
        const uint64_t ctrl_full =
            0x504C5843ull | (1ull << 32) | (static_cast<uint64_t>(N) << 34) | (99ull << 48);
        full.push_back({0xFF, ctrl_full});

        push_burst(t, full, &prod, &fault, &list_we_n, &list_beats);
        run_for(t, 400, &prod, &fault, &list_we_n, &list_beats);

        std::fprintf(stderr,
                     "full_list prod_beats=%zu list_we=%d cfg_en=%d cfg_cnt=%d cfg_seq=%d\n",
                     prod.size(), list_we_n, (int)t->prod_cfg_enable, (int)t->prod_cfg_count,
                     (int)t->prod_cfg_seq);

        if (prod.size() != static_cast<size_t>(N) + 1)
            fail("full_list: must deliver exactly 113 beats (112 list + ctrl)");
        bool order_ok = true;
        for (int i = 0; i < N; ++i) {
            if (prod.size() <= static_cast<size_t>(i)) {
                order_ok = false;
                break;
            }
            if (prod[static_cast<size_t>(i)].addr != static_cast<uint8_t>(i) ||
                prod[static_cast<size_t>(i)].data != full[static_cast<size_t>(i)].data) {
                std::fprintf(stderr, "full_list mismatch i=%d addr=%u data=%llx want_addr=%d\n", i,
                             (unsigned)prod[static_cast<size_t>(i)].addr,
                             (unsigned long long)prod[static_cast<size_t>(i)].data, i);
                order_ok = false;
                break;
            }
        }
        if (!order_ok)
            fail("full_list: list beat addr/data conservation");
        if (prod.size() == static_cast<size_t>(N) + 1) {
            if (prod[static_cast<size_t>(N)].addr != 0xFF)
                fail("full_list: ctrl must be LAST beat (addr=0xFF)");
            if (prod[static_cast<size_t>(N)].data != ctrl_full)
                fail("full_list: ctrl payload");
        }
        // Ctrl must not appear before the end
        for (size_t i = 0; i < prod.size() && i < static_cast<size_t>(N); ++i) {
            if (prod[i].addr == 0xFF) {
                fail("full_list: ctrl appeared before all list beats");
                break;
            }
        }
        if (list_we_n != N)
            fail("full_list: host_if list_we count want 112");
        if (!t->prod_cfg_enable)
            fail("full_list: cfg_enable");
        if (t->prod_cfg_count != N)
            fail("full_list: cfg_count want 112");
        if (t->prod_cfg_seq != 99)
            fail("full_list: cfg_seq want 99");
        if (fails == 0)
            std::fprintf(stderr, "PASS full_list_conservation\n");
    }

    // --- stopped rd clock: fill shallow FIFO, stall on full, resume, conserve ---
    // Observations that FAIL under silent drop (no host_ready):
    //   sh_out.size() != N, any payload mismatch, ctrl not last, last beat lost.
    std::fprintf(stderr, "=== STOPPED-rd fill-to-full then resume (DEPTH=8) ===\n");
    std::fprintf(stderr, "EXECUTED stopped_rd_fill_resume\n");
    {
        constexpr int N_LIST = 12; // > DEPTH=8 so full is hit with rd frozen
        std::vector<Beat> xact;
        xact.reserve(static_cast<size_t>(N_LIST) + 1);
        for (int i = 0; i < N_LIST; ++i) {
            const uint64_t d = 0xBEEFull << 48 | (uint64_t)(0x1000 + i) << 16 | (uint64_t)i;
            xact.push_back({static_cast<uint8_t>(i), d});
        }
        const uint64_t ctrl_sh =
            0x504C5843ull | (1ull << 32) | (static_cast<uint64_t>(N_LIST) << 34) | (55ull << 48);
        xact.push_back({0xFF, ctrl_sh});

        std::vector<Beat> sh_out;
        // Freeze hdmi: only toggle sys. Sample sh_host_we never fires while frozen.
        auto step_sys_only = [&](int sys_cycles, bool sample_rd) {
            for (int c = 0; c < sys_cycles; ++c) {
                // low
                for (int h = 0; h < SYS_HALF; ++h) {
                    main_time++;
                    t->clk_sys = 0;
                    if (!sample_rd)
                        t->clk_hdmi = 0;
                    else {
                        int nh = static_cast<int>(main_time % 14);
                        t->clk_hdmi = (nh < 7) ? 1 : 0;
                    }
                    t->eval();
                }
                // high — sample wr_full after eval on rising
                for (int h = 0; h < SYS_HALF; ++h) {
                    main_time++;
                    t->clk_sys = 1;
                    int prev_h = t->clk_hdmi;
                    if (!sample_rd)
                        t->clk_hdmi = 0;
                    else {
                        int nh = static_cast<int>(main_time % 14);
                        t->clk_hdmi = (nh < 7) ? 1 : 0;
                    }
                    t->eval();
                    if (sample_rd && !prev_h && t->clk_hdmi && t->sh_host_we) {
                        sh_out.push_back({static_cast<uint8_t>(t->sh_host_addr),
                                          static_cast<uint64_t>(t->sh_host_data)});
                    }
                }
            }
        };

        // Align and freeze rd
        t->clk_hdmi = 0;
        t->sh_we = 0;
        step_sys_only(4, false);

        size_t bi = 0;
        int saw_full = 0;
        int stalled_while_full = 0;
        // Ready-aware push (loader host_ready = !wr_full): hold beat until accepted.
        int guard = 0;
        while (bi < xact.size() && guard < 5000) {
            ++guard;
            // Drive only on sys rising; we=1 only when !full
            // half low
            for (int h = 0; h < SYS_HALF; ++h) {
                main_time++;
                t->clk_sys = 0;
                t->clk_hdmi = 0;
                t->eval();
            }
            const int full_now = t->sh_wr_full ? 1 : 0;
            if (full_now)
                saw_full = 1;
            if (full_now) {
                t->sh_we = 0; // stall — do not drop
                ++stalled_while_full;
            } else if (bi < xact.size()) {
                t->sh_we = 1;
                t->sh_addr = xact[bi].addr;
                t->sh_data = xact[bi].data;
            } else {
                t->sh_we = 0;
            }
            for (int h = 0; h < SYS_HALF; ++h) {
                main_time++;
                t->clk_sys = 1;
                t->clk_hdmi = 0;
                t->eval();
            }
            // Accepted this sys cycle if we asserted and not full at drive time
            if (t->sh_we && !full_now)
                ++bi;
            t->sh_we = 0;
        }
        if (bi != xact.size()) {
            // With rd frozen and DEPTH=8, ready-aware push cannot finish all 13
            // until resume — that is expected. bi should be <= 8-ish.
            std::fprintf(stderr,
                         "stopped_rd: after freeze push bi=%zu saw_full=%d stall_cyc=%d "
                         "(expect bi<=8 and saw_full)\n",
                         bi, saw_full, stalled_while_full);
            if (!saw_full)
                fail("stopped_rd: never saw wr_full with rd frozen");
            if (stalled_while_full < 1)
                fail("stopped_rd: never stalled on full");
            if (bi >= xact.size())
                fail("stopped_rd: completed all beats while rd frozen (impossible if full works)");
        }

        // Resume hdmi + continue ready-aware push of remainder
        guard = 0;
        while ((bi < xact.size() || !t->sh_rd_empty) && guard < 8000) {
            ++guard;
            int prev_h = t->clk_hdmi;
            int ns = static_cast<int>((main_time + 1) % 50);
            int nh = static_cast<int>((main_time + 1) % 14);
            main_time++;
            int next_sys = (ns < 25) ? 1 : 0;
            int next_hdmi = (nh < 7) ? 1 : 0;
            if (!t->clk_sys && next_sys) {
                const int full_now = t->sh_wr_full ? 1 : 0;
                if (!full_now && bi < xact.size()) {
                    t->sh_we = 1;
                    t->sh_addr = xact[bi].addr;
                    t->sh_data = xact[bi].data;
                    ++bi;
                } else {
                    t->sh_we = 0;
                }
            }
            t->clk_sys = next_sys;
            t->clk_hdmi = next_hdmi;
            t->eval();
            if (!prev_h && next_hdmi && t->sh_host_we) {
                sh_out.push_back({static_cast<uint8_t>(t->sh_host_addr),
                                  static_cast<uint64_t>(t->sh_host_data)});
            }
            if (next_sys == 0)
                t->sh_we = 0;
        }
        // Drain remainder
        step_sys_only(80, true);

        std::fprintf(stderr,
                     "stopped_rd: bi=%zu sh_out=%zu saw_full=%d stall_cyc=%d\n", bi,
                     sh_out.size(), saw_full, stalled_while_full);

        if (bi != xact.size())
            fail("stopped_rd: did not accept all beats after resume");
        if (sh_out.size() != xact.size())
            fail("stopped_rd: output beat count != input (conservation)");
        bool ok = sh_out.size() == xact.size();
        for (size_t i = 0; ok && i < xact.size(); ++i) {
            if (sh_out[i].addr != xact[i].addr || sh_out[i].data != xact[i].data)
                ok = false;
        }
        if (!ok)
            fail("stopped_rd: body/ctrl payload conservation");
        if (!sh_out.empty() && sh_out.back().addr != 0xFF)
            fail("stopped_rd: newest ctrl must be last");
        if (!sh_out.empty() && sh_out.back().data != ctrl_sh)
            fail("stopped_rd: newest ctrl payload");
        if (fails == 0)
            std::fprintf(stderr, "PASS stopped_rd_fill_resume\n");

        // DROP twin: ignore full while rd frozen — must LOSE beats (proves gate bites).
        std::fprintf(stderr, "EXECUTED stopped_rd_drop_twin\n");
        // reset shallow via full reset pulse
        t->reset = 1;
        t->sh_we = 0;
        step_sys_only(5, false);
        t->reset = 0;
        step_sys_only(5, false);
        sh_out.clear();
        // Blind push all beats with rd frozen (no ready check) — product silent-loss class
        bi = 0;
        while (bi < xact.size()) {
            for (int h = 0; h < SYS_HALF; ++h) {
                main_time++;
                t->clk_sys = 0;
                t->clk_hdmi = 0;
                t->eval();
            }
            t->sh_we = 1;
            t->sh_addr = xact[bi].addr;
            t->sh_data = xact[bi].data;
            for (int h = 0; h < SYS_HALF; ++h) {
                main_time++;
                t->clk_sys = 1;
                t->clk_hdmi = 0;
                t->eval();
            }
            ++bi;
            t->sh_we = 0;
        }
        // resume drain
        step_sys_only(100, true);
        std::fprintf(stderr, "drop_twin sh_out=%zu (want < %zu)\n", sh_out.size(), xact.size());
        if (sh_out.size() >= xact.size())
            fail("drop_twin: expected silent loss when ignoring wr_full");
        else
            std::fprintf(stderr, "PASS stopped_rd_drop_twin (loss visible)\n");
    }

    if (fails) {
        std::fprintf(stderr, "plex_chrome_plxc_cdc_tb: %d FAIL(s)\n", fails);
        delete t;
        return 1;
    }
    std::fprintf(stderr, "plex_chrome_plxc_cdc_tb: PASS\n");
    delete t;
    return 0;
}
