// Connected loader → shallow CDC → host_if.
// Proves fill-last-slot / near-full does not drop any beat (rd-duck on 96e4a50d).
#include "Vplex_chrome_plxc_connected_tb.h"
#include "verilated.h"

#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <vector>

static vluint64_t main_time = 0;
double sc_time_stamp() { return static_cast<double>(main_time); }

static const int SYS_HALF = 25;
static const int HDMI_HALF = 7;

struct Beat {
    uint8_t addr;
    uint64_t data;
};

static void eval_clks(Vplex_chrome_plxc_connected_tb* t, int freeze_rd) {
    int ns = static_cast<int>(main_time % 50);
    int nh = static_cast<int>(main_time % 14);
    t->clk_sys = (ns < SYS_HALF) ? 1 : 0;
    t->clk_hdmi = freeze_rd ? 0 : ((nh < HDMI_HALF) ? 1 : 0);
    t->freeze_rd = freeze_rd ? 1 : 0;
    t->eval();
}

static void run_sys(Vplex_chrome_plxc_connected_tb* t, int sys_cycles, int freeze_rd,
                    std::vector<Beat>* out) {
    int prev_h = t->clk_hdmi;
    for (int c = 0; c < sys_cycles * 50; ++c) {
        main_time++;
        eval_clks(t, freeze_rd);
        if (!freeze_rd && !prev_h && t->clk_hdmi && t->rd_we) {
            out->push_back({static_cast<uint8_t>(t->rd_addr),
                            static_cast<uint64_t>(t->rd_data)});
        }
        prev_h = t->clk_hdmi;
    }
}

static void mem_wr(Vplex_chrome_plxc_connected_tb* t, uint32_t byte_off, uint64_t data) {
    // Align to sys rising
    while (t->clk_sys) {
        main_time++;
        eval_clks(t, t->freeze_rd);
    }
    while (!t->clk_sys) {
        main_time++;
        eval_clks(t, t->freeze_rd);
    }
    t->mem_we_host = 1;
    t->mem_addr_host = byte_off >> 3;
    t->mem_wdata_host = data;
    // hold one sys period
    for (int i = 0; i < 50; ++i) {
        main_time++;
        eval_clks(t, t->freeze_rd);
    }
    t->mem_we_host = 0;
    for (int i = 0; i < 50; ++i) {
        main_time++;
        eval_clks(t, t->freeze_rd);
    }
}

static uint64_t pack_ctrl(bool en, unsigned count, uint16_t seq) {
    uint64_t w = 0x504C5843ull;
    if (en)
        w |= 1ull << 32;
    w |= (uint64_t)(count & 0x3FFF) << 34;
    w |= (uint64_t)seq << 48;
    return w;
}

static uint64_t glyph(char c, int x, int y) {
    return 2ull | ((uint64_t)x << 8) | ((uint64_t)y << 24) | ((uint64_t)(uint8_t)c << 40);
}

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    int fails = 0;
    auto fail = [&](const char* m) {
        std::fprintf(stderr, "FAIL %s\n", m);
        ++fails;
    };

    auto* t = new Vplex_chrome_plxc_connected_tb;
    t->reset = 1;
    t->clk_sys = 0;
    t->clk_hdmi = 0;
    t->freeze_rd = 0;
    t->mem_we_host = 0;
    t->mem_addr_host = 0;
    t->mem_wdata_host = 0;

    std::vector<Beat> out;
    run_sys(t, 10, 0, &out);
    t->reset = 0;
    run_sys(t, 10, 0, &out);
    out.clear();

    // 12 list + ctrl > DEPTH=8 — must hit full with freeze, then conserve all.
    constexpr int N = 12;
    std::vector<Beat> expect;
    expect.reserve(N + 1);
    for (int i = 0; i < N; ++i) {
        const uint64_t d = glyph(static_cast<char>('A' + (i % 26)), i, i + 1);
        expect.push_back({static_cast<uint8_t>(i), d});
        mem_wr(t, 0x140 + static_cast<uint32_t>(i) * 8, d);
    }
    const uint64_t ctrl = pack_ctrl(true, N, 42);
    expect.push_back({0xFF, ctrl});
    // invalidate then commit ctrl last
    mem_wr(t, 0x130, 0);
    mem_wr(t, 0x130, ctrl);

    std::fprintf(stderr, "=== CONNECTED loader→FIFO near-full freeze→resume ===\n");
    std::fprintf(stderr, "EXECUTED connected_near_full\n");

    // Freeze rd while loader pushes into DEPTH=8
    out.clear();
    int saw_full = 0;
    int we_while_full = 0;
    for (int i = 0; i < 2000; ++i) {
        run_sys(t, 1, /*freeze*/ 1, &out);
        if (t->cdc_full)
            saw_full = 1;
        if (t->cdc_full && t->host_we_sys)
            ++we_while_full;
        if (t->last_seq == 42 && !t->busy)
            break;
    }
    std::fprintf(stderr,
                 "freeze: saw_full=%d we_while_full=%d last_seq=%u loads=%u busy=%d out=%zu\n",
                 saw_full, we_while_full, (unsigned)t->last_seq, (unsigned)t->cnt_loads,
                 (int)t->busy, out.size());

    // Under freeze, cannot finish all 13 into depth 8 without stall — last_seq must
    // not commit early if ctrl not yet accepted.
    if (!saw_full)
        fail("connected: never saw cdc_full under freeze (DEPTH=8, N=12)");
    // out should be empty while frozen
    if (!out.empty())
        fail("connected: rd beats while freeze_rd");

    // Resume hdmi — drain + finish
    for (int i = 0; i < 4000; ++i) {
        run_sys(t, 1, /*freeze*/ 0, &out);
        if (t->last_seq == 42 && !t->busy && t->cdc_empty)
            break;
    }
    // Extra drain
    run_sys(t, 80, 0, &out);

    std::fprintf(stderr,
                 "resume: last_seq=%u loads=%u out=%zu cfg_en=%d cfg_cnt=%d cfg_seq=%d\n",
                 (unsigned)t->last_seq, (unsigned)t->cnt_loads, out.size(),
                 (int)t->cfg_enable, (int)t->cfg_count, (int)t->cfg_seq);

    if (t->last_seq != 42)
        fail("connected: last_seq want 42 after resume");
    if (out.size() != expect.size()) {
        std::fprintf(stderr, "connected out=%zu want=%zu\n", out.size(), expect.size());
        fail("connected: beat count conservation");
    }
    for (size_t i = 0; i < expect.size() && i < out.size(); ++i) {
        if (out[i].addr != expect[i].addr || out[i].data != expect[i].data) {
            std::fprintf(stderr,
                         "connected mismatch i=%zu got a=%u d=%llx want a=%u d=%llx\n", i,
                         (unsigned)out[i].addr, (unsigned long long)out[i].data,
                         (unsigned)expect[i].addr, (unsigned long long)expect[i].data);
            fail("connected: addr/data conservation (boundary/ctrl included)");
            break;
        }
    }
    if (!out.empty() && out.back().addr != 0xFF)
        fail("connected: ctrl must be last");
    if (!out.empty() && out.back().data != ctrl)
        fail("connected: ctrl payload");
    // Boundary beats: first, last list, ctrl
    if (out.size() >= 2) {
        if (out[0].addr != 0)
            fail("connected: first list addr0");
        if (out[static_cast<size_t>(N - 1)].addr != static_cast<uint8_t>(N - 1))
            fail("connected: last list addr");
    }
    if (t->cfg_count != N)
        fail("connected: host_if cfg_count");
    if (t->cfg_seq != 42)
        fail("connected: host_if cfg_seq");
    if (!t->cfg_enable)
        fail("connected: host_if cfg_enable");

    if (fails == 0)
        std::fprintf(stderr, "PASS connected_near_full\n");

    // Second xact while previously drained — no residual loss
    std::fprintf(stderr, "EXECUTED connected_second_xact\n");
    out.clear();
    constexpr int N2 = 5;
    std::vector<Beat> exp2;
    for (int i = 0; i < N2; ++i) {
        const uint64_t d = glyph('Z', 100 + i, 50);
        exp2.push_back({static_cast<uint8_t>(i), d});
        mem_wr(t, 0x140 + static_cast<uint32_t>(i) * 8, d);
    }
    const uint64_t ctrl2 = pack_ctrl(true, N2, 43);
    exp2.push_back({0xFF, ctrl2});
    mem_wr(t, 0x130, 0);
    mem_wr(t, 0x130, ctrl2);
    for (int i = 0; i < 2000; ++i) {
        run_sys(t, 1, 0, &out);
        if (t->last_seq == 43 && !t->busy)
            break;
    }
    run_sys(t, 40, 0, &out);
    if (out.size() != exp2.size())
        fail("connected second xact count");
    for (size_t i = 0; i < exp2.size() && i < out.size(); ++i) {
        if (out[i].addr != exp2[i].addr || out[i].data != exp2[i].data) {
            fail("connected second xact data");
            break;
        }
    }
    if (fails == 0)
        std::fprintf(stderr, "PASS connected_second_xact\n");

    delete t;
    if (fails) {
        std::fprintf(stderr, "plex_chrome_plxc_connected_tb: %d FAIL(s)\n", fails);
        return 1;
    }
    std::fprintf(stderr, "plex_chrome_plxc_connected_tb: PASS\n");
    return 0;
}
