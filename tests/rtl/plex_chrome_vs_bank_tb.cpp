// plex_chrome double-buffer bank TB (rd-duck holes).
//
// Cases (VS_BANK_CASE=):
//   product   — VS coincidence + live immutable during normal list_we
//   fault     — PLEX_CHROME_FAULT_VS_BANK: coincidence hole signature
//   invert    — PLEX_CHROME_FAULT_INVERT_STAGING: normal list_we overwrites LIVE
//
// Bank map oracle (must hold for product):
//   chrome_at LIVE  : live_bank ? list_b : list_a
//   list_we STAGING : if (wr_to_a) list_a else list_b
//   normal wr_to_a  : live_bank   (live_bank=0 → write B; A stays live)
//   swap_now wr_to_a: ~live_bank

#include "Vplex_chrome_vs_bank_tb.h"
#include "verilated.h"

#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

static vluint64_t main_time = 0;
double sc_time_stamp() { return static_cast<double>(main_time); }

static int g_fails = 0;
static void fail(const char* m) {
    std::fprintf(stderr, "FAIL %s\n", m);
    ++g_fails;
}
static void pass(const char* m) { std::fprintf(stderr, "PASS %s\n", m); }

static void tick(Vplex_chrome_vs_bank_tb* t) {
    t->clk = 0;
    t->eval();
    main_time++;
    t->clk = 1;
    t->eval();
    main_time++;
}

static uint64_t packRectPal(uint16_t x, uint16_t y, uint8_t w, uint8_t h, uint8_t pal) {
    uint64_t v = 3ull | (uint64_t(x) << 8) | (uint64_t(y) << 24);
    v |= (uint64_t(w) << 40) | (uint64_t(h) << 48) | (uint64_t(pal) << 56);
    return v;
}

static constexpr uint32_t AMBER = 0xFFB220u;
static constexpr uint32_t WHITE = 0xEBEEF4u; // pal 3

static uint32_t videoAt(int x, int y) {
    return (uint32_t((x * 3 + 17) & 0xFF) << 16) | (uint32_t((y * 5 + 3) & 0xFF) << 8) |
           uint32_t((x ^ y ^ 0x5A) & 0xFF);
}

static void captureFrame(Vplex_chrome_vs_bank_tb* t, int W, int H, std::vector<uint32_t>& fb) {
    fb.assign(static_cast<size_t>(W) * H, 0xDEADBEu);
    t->de_in = 0;
    // Re-arm beam counters via VS edge. Safe only when cfg_seq == latched_seq
    // (no pending promote). Callers must not leave a pending cfg across capture
    // when they need stable live content.
    t->vs_in = 0;
    tick(t);
    t->vs_in = 1;
    tick(t);
    tick(t);
    for (int y = 0; y < H; ++y) {
        t->de_in = 0;
        tick(t);
        t->de_in = 1;
        int pend_x = -1;
        for (int x = 0; x < W; ++x) {
            t->din = videoAt(x, y);
            tick(t);
            if (t->de_out && pend_x >= 0 && pend_x < W)
                fb[static_cast<size_t>(y) * W + pend_x] =
                    static_cast<uint32_t>(t->dout) & 0xFFFFFFu;
            pend_x = x;
        }
        t->de_in = 0;
        tick(t);
        if (t->de_out && pend_x >= 0 && pend_x < W)
            fb[static_cast<size_t>(y) * W + pend_x] =
                static_cast<uint32_t>(t->dout) & 0xFFFFFFu;
    }
}

static bool pxIs(const std::vector<uint32_t>& fb, int W, int x, int y, uint32_t c) {
    return fb[static_cast<size_t>(y) * W + x] == c;
}

static void writeListBeat(Vplex_chrome_vs_bank_tb* t, uint8_t addr, uint64_t data, bool with_vs_rise) {
    if (with_vs_rise) {
        t->vs_in = 0;
        tick(t);
        t->vs_in = 1;
        t->list_we = 1;
        t->list_waddr = addr;
        t->list_wdata = data;
        tick(t);
        t->list_we = 0;
    } else {
        t->list_we = 1;
        t->list_waddr = addr;
        t->list_wdata = data;
        tick(t);
        t->list_we = 0;
        tick(t);
    }
}

static void reset_dut(Vplex_chrome_vs_bank_tb* t, int W, int H) {
    t->clk = 0;
    t->reset = 1;
    t->HDMI_WIDTH = W;
    t->HDMI_HEIGHT = H;
    t->din = 0;
    t->hs_in = 0;
    t->vs_in = 0;
    t->de_in = 0;
    t->cfg_enable = 0;
    t->cfg_seq = 0;
    t->cfg_cmd_count = 0;
    t->list_we = 0;
    t->list_waddr = 0;
    t->list_wdata = 0;
    for (int i = 0; i < 4; ++i)
        tick(t);
    t->reset = 0;
    for (int i = 0; i < 4; ++i)
        tick(t);
}

static bool promoteAmberA(Vplex_chrome_vs_bank_tb* t, int W, int H, std::vector<uint32_t>& fb) {
    const uint64_t cmdA = packRectPal(10, 10, 8, 8, 2);
    writeListBeat(t, 0, cmdA, false);
    t->cfg_enable = 1;
    t->cfg_cmd_count = 1;
    t->cfg_seq = 1;
    tick(t);
    tick(t);
    t->vs_in = 0;
    tick(t);
    t->vs_in = 1;
    tick(t);
    tick(t);
    captureFrame(t, W, H, fb);
    return pxIs(fb, W, 12, 12, AMBER);
}

static void run_live_hold_oracle(Vplex_chrome_vs_bank_tb* t, int W, int H, bool expect_corrupt) {
    std::fprintf(stderr, "EXECUTED live_hold\n");
    std::vector<uint32_t> fb;
    const uint64_t cmdA = packRectPal(10, 10, 8, 8, 2);
    const uint64_t cmdWhite = packRectPal(10, 10, 8, 8, 3);
    const uint64_t cmdElse = packRectPal(80, 10, 8, 8, 3);

    if (expect_corrupt) {
        // Invert selector: after one VS promote live_bank=1, normal wr_to_a=~1=0
        // writes list_b which is LIVE. Seed amber then overwrite with white on
        // the same "staging" path — LIVE must change (red twin).
        t->cfg_enable = 1;
        t->cfg_cmd_count = 1;
        t->cfg_seq = 1;
        tick(t);
        t->vs_in = 0;
        tick(t);
        t->vs_in = 1;
        tick(t);
        tick(t);
        writeListBeat(t, 0, cmdA, false);
        captureFrame(t, W, H, fb);
        const bool amber0 = pxIs(fb, W, 12, 12, AMBER);
        std::fprintf(stderr, "invert seed amber=%d px=%06x\n", amber0 ? 1 : 0,
                     fb[static_cast<size_t>(12) * W + 12] & 0xFFFFFFu);
        bool saw_white_live = false;
        for (int beat = 0; beat < 4; ++beat) {
            writeListBeat(t, static_cast<uint8_t>(beat), beat == 0 ? cmdWhite : cmdElse, false);
            captureFrame(t, W, H, fb);
            const bool amber = pxIs(fb, W, 12, 12, AMBER);
            const bool white = pxIs(fb, W, 12, 12, WHITE);
            std::fprintf(stderr, "live_hold beat=%d amber=%d white=%d px=%06x\n", beat, amber ? 1 : 0,
                         white ? 1 : 0, fb[static_cast<size_t>(12) * W + 12] & 0xFFFFFFu);
            if (white)
                saw_white_live = true;
        }
        if (amber0 && saw_white_live)
            pass("live_hold_invert");
        else
            fail("live_hold_invert: LIVE unchanged — invert fault not visible");
        return;
    }

    if (!promoteAmberA(t, W, H, fb)) {
        fail("live_hold: A not live after promote");
        return;
    }

    bool live_ok_all = true;
    bool saw_white_live = false;
    for (int beat = 0; beat < 6; ++beat) {
        writeListBeat(t, static_cast<uint8_t>(beat), beat == 0 ? cmdWhite : cmdElse, false);
        captureFrame(t, W, H, fb);
        const bool amber = pxIs(fb, W, 12, 12, AMBER);
        const bool white = pxIs(fb, W, 12, 12, WHITE);
        std::fprintf(stderr, "live_hold beat=%d amber=%d white=%d px=%06x\n", beat, amber ? 1 : 0,
                     white ? 1 : 0, fb[static_cast<size_t>(12) * W + 12] & 0xFFFFFFu);
        if (!amber)
            live_ok_all = false;
        if (white)
            saw_white_live = true;
    }

    if (!live_ok_all || saw_white_live)
        fail("live_hold: LIVE HUD changed during list_we (staging wrote live bank)");
    else
        pass("live_hold");
}

static void run_vs_coincidence(Vplex_chrome_vs_bank_tb* t, int W, int H, bool fault) {
    std::fprintf(stderr, "EXECUTED %s\n", fault ? "vs_bank_fault" : "vs_bank_product");
    std::vector<uint32_t> fb;
    if (!promoteAmberA(t, W, H, fb)) {
        fail("A not live after first promote");
        return;
    }
    if (pxIs(fb, W, 42, 12, AMBER))
        fail("B leaked into live before B commit");

    const uint64_t cmdA2 = packRectPal(10, 50, 8, 8, 2);
    const uint64_t cmdB0 = packRectPal(40, 10, 8, 8, 2);
    const uint64_t cmdB1 = packRectPal(40, 30, 8, 8, 2);

    writeListBeat(t, 0, cmdA2, false);
    t->cfg_cmd_count = 1;
    t->cfg_seq = 2;
    tick(t);

    writeListBeat(t, 0, cmdB0, true);
    writeListBeat(t, 1, cmdB1, false);
    t->cfg_cmd_count = 2;
    t->cfg_seq = 3;
    tick(t);
    tick(t);

    captureFrame(t, W, H, fb);
    const bool a_live = pxIs(fb, W, 12, 12, AMBER);
    const bool a2_live = pxIs(fb, W, 12, 52, AMBER);
    const bool b0_live = pxIs(fb, W, 42, 12, AMBER);
    const bool b1_live = pxIs(fb, W, 42, 32, AMBER);
    std::fprintf(stderr, "post-coin a=%d a2=%d b0=%d b1=%d\n", a_live, a2_live, b0_live, b1_live);

    if (fault) {
        t->vs_in = 0;
        tick(t);
        t->vs_in = 1;
        tick(t);
        captureFrame(t, W, H, fb);
        const bool b0p = pxIs(fb, W, 42, 12, AMBER);
        const bool b1p = pxIs(fb, W, 42, 32, AMBER);
        std::fprintf(stderr, "fault after final VS b0=%d b1=%d\n", b0p, b1p);
        if ((b0p && !b1p) || (!b0p && b1p) || (b0_live && !b1_live) || (!b0p && !b1p))
            pass("vs_bank_fault");
        else
            fail("vs_bank_fault: hole not observed");
    } else {
        if (b0_live && !b1_live)
            fail("product: live shows B cmd0 without cmd1 after coincidence");
        if (b1_live && !b0_live)
            fail("product: live shows B cmd1 without cmd0 after coincidence");
        t->vs_in = 0;
        tick(t);
        t->vs_in = 1;
        tick(t);
        tick(t);
        captureFrame(t, W, H, fb);
        const bool b0p = pxIs(fb, W, 42, 12, AMBER);
        const bool b1p = pxIs(fb, W, 42, 32, AMBER);
        std::fprintf(stderr, "product after final VS b0=%d b1=%d\n", b0p, b1p);
        if (!b0p || !b1p)
            fail("product: full B not live after final VS");
        if (g_fails == 0)
            pass("vs_bank_product");
    }
}

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    const char* mode = std::getenv("VS_BANK_CASE");
    if (!mode)
        mode = "product";
    const std::string m(mode);

    auto* t = new Vplex_chrome_vs_bank_tb;
    const int W = 160;
    const int H = 90;
    reset_dut(t, W, H);

    if (m == "invert") {
        run_live_hold_oracle(t, W, H, true);
    } else if (m == "fault") {
        run_vs_coincidence(t, W, H, true);
    } else {
        run_live_hold_oracle(t, W, H, false);
        reset_dut(t, W, H);
        run_vs_coincidence(t, W, H, false);
    }

    delete t;
    if (g_fails) {
        std::fprintf(stderr, "plex_chrome_vs_bank_tb: %d FAIL(s)\n", g_fails);
        return 1;
    }
    std::fprintf(stderr, "plex_chrome_vs_bank_tb: PASS\n");
    return 0;
}
