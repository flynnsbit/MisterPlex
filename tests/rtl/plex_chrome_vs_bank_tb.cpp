// Exact VS / list_we coincidence for plex_chrome double-buffer (rd-duck hole 2).
//
// Setup:
//   A fills staging + pending cfg; before VS, B's first list beat shares the VS edge.
// Product: all of B lands in post-swap staging; live HUD (A) stays intact until B commits.
// FAULT (PLEX_CHROME_FAULT_VS_BANK): B cmd0 hits the bank becoming live.

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

// RECT_PAL: op=3, pal 2 = amber 0xFFB220
static uint64_t packRectPal(uint16_t x, uint16_t y, uint8_t w, uint8_t h, uint8_t pal) {
    uint64_t v = 3ull | (uint64_t(x) << 8) | (uint64_t(y) << 24);
    v |= (uint64_t(w) << 40) | (uint64_t(h) << 48) | (uint64_t(pal) << 56);
    return v;
}

static constexpr uint32_t AMBER = 0xFFB220u;
static constexpr uint32_t WHITE_GLYPH = 0xFFFFFFu;

static uint32_t videoAt(int x, int y) {
    return (uint32_t((x * 3 + 17) & 0xFF) << 16) | (uint32_t((y * 5 + 3) & 0xFF) << 8) |
           uint32_t((x ^ y ^ 0x5A) & 0xFF);
}

static void captureFrame(Vplex_chrome_vs_bank_tb* t, int W, int H, std::vector<uint32_t>& fb) {
    fb.assign(static_cast<size_t>(W) * H, 0xDEADBEu);
    t->de_in = 0;
    // Keep vs high (already latched); do not re-pulse VS here.
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
    // vs_d tracks previous vs_in. For a rise: previous tick had vs=0, this tick vs=1.
    if (with_vs_rise) {
        t->vs_in = 0;
        tick(t);
        t->vs_in = 1;
        t->list_we = 1;
        t->list_waddr = addr;
        t->list_wdata = data;
        tick(t); // coincidence edge
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

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    const char* mode = std::getenv("VS_BANK_CASE");
    if (!mode)
        mode = "product";
    const bool fault = (std::string(mode) == "fault");

    auto* t = new Vplex_chrome_vs_bank_tb;
    const int W = 160;
    const int H = 90; // small canvas for speed

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

    std::fprintf(stderr, "EXECUTED %s\n", fault ? "vs_bank_fault" : "vs_bank_product");

    // --- Phase A: write HUD A (amber rect @10,10) to staging, commit cfg, promote on VS ---
    // A: pal2 amber 8x8 at (10,10)
    const uint64_t cmdA = packRectPal(10, 10, 8, 8, 2);
    // B: pal2 amber 8x8 at (40,10) — distinct location
    const uint64_t cmdB0 = packRectPal(40, 10, 8, 8, 2);
    const uint64_t cmdB1 = packRectPal(40, 30, 8, 8, 2); // second beat of B

    writeListBeat(t, 0, cmdA, false);
    t->cfg_enable = 1;
    t->cfg_cmd_count = 1;
    t->cfg_seq = 1; // ends xact_hold; pending swap
    tick(t);
    tick(t);

    // Promote A alone (no list_we)
    t->vs_in = 0;
    tick(t);
    t->vs_in = 1;
    tick(t);
    tick(t);

    std::vector<uint32_t> fb;
    captureFrame(t, W, H, fb);
    if (!pxIs(fb, W, 12, 12, AMBER))
        fail("A not live after first promote");
    if (pxIs(fb, W, 42, 12, AMBER))
        fail("B leaked into live before B commit");

    // --- Phase B coincidence: A is live. Start B list on SAME edge as a VS that
    // would promote if cfg were pending. First put B pending? Race is:
    //   update A ctrl pending + B first list beat on VS.
    // Re-arm: write a new A' pending, then B cmd0 on VS edge.
    // Simpler path matching rd-duck:
    //   live has A. Write staging with nothing pending. Commit B cfg without list
    //   is wrong. Do:
    //   1) write B cmd0.. without cfg yet while live=A
    //   2) Actually the hole needs pending swap ON the edge of B's first beat.
    // Rebuild: after A live, write C as new staging fully + cfg pending (seq=2),
    // then on VS, B-new overwrites with first beat coincidence.

    // Fresh: A live. Fill staging with "A2" fully and set cfg_seq=2 (pending).
    const uint64_t cmdA2 = packRectPal(10, 50, 8, 8, 2); // A2 marker lower
    writeListBeat(t, 0, cmdA2, false);
    t->cfg_cmd_count = 1;
    t->cfg_seq = 2;
    tick(t);
    // Do NOT VS yet — A still live, A2 pending in staging.

    // Coincidence: VS promote A2 + B's first list beat same edge.
    // B wants 2 cmds; first beat on VS edge, second after.
    writeListBeat(t, 0, cmdB0, true); // VS rise + list_we cmd0
    writeListBeat(t, 1, cmdB1, false);
    // Commit B ctrl (seq=3) after list
    t->cfg_cmd_count = 2;
    t->cfg_seq = 3;
    tick(t);
    tick(t);

    // Capture WITHOUT another VS — see what is live now.
    // Product: swap was either deferred (B xact held) or A2 promoted cleanly;
    // B cmd0 must not corrupt the bank that was becoming live mid-beat.
    captureFrame(t, W, H, fb);

    const bool a_live = pxIs(fb, W, 12, 12, AMBER);
    const bool a2_live = pxIs(fb, W, 12, 52, AMBER);
    const bool b0_live = pxIs(fb, W, 42, 12, AMBER);
    const bool b1_live = pxIs(fb, W, 42, 32, AMBER);

    std::fprintf(stderr, "post-coin a=%d a2=%d b0=%d b1=%d\n", a_live, a2_live, b0_live, b1_live);

    if (fault) {
        // FAULT expects corruption class: B cmd0 visible on live while B incomplete,
        // or split banks (b0 without b1 after promote). Document with PASS if hole seen.
        // After full B commit + later VS, promote B.
        t->vs_in = 0;
        tick(t);
        t->vs_in = 1;
        tick(t);
        captureFrame(t, W, H, fb);
        const bool b0p = pxIs(fb, W, 42, 12, AMBER);
        const bool b1p = pxIs(fb, W, 42, 32, AMBER);
        std::fprintf(stderr, "fault after final VS b0=%d b1=%d\n", b0p, b1p);
        // Hole signature: missing cmd (b0 without b1 or b1 without b0) OR
        // mid-window b0_live while a2 also conflicting. Accept either.
        if ((b0p && !b1p) || (!b0p && b1p) || (b0_live && !b1_live)) {
            pass("vs_bank_fault");
        } else if (!b0p && !b1p) {
            // Staging lost cmd0 entirely — also a hole signature
            pass("vs_bank_fault");
        } else {
            fail("vs_bank_fault: hole not observed (both B cmds present)");
        }
    } else {
        // Product: after coincidence, live should still be coherent (A or A2 full),
        // not a split B. Then final VS promotes full B (both cmds).
        if (b0_live && !b1_live)
            fail("product: live shows B cmd0 without cmd1 after coincidence");
        if (b1_live && !b0_live)
            fail("product: live shows B cmd1 without cmd0 after coincidence");

        // Promote B
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
        // Old A markers should not be required off — B may replace entire list.
        if (g_fails == 0)
            pass("vs_bank_product");
    }

    delete t;
    if (g_fails) {
        std::fprintf(stderr, "plex_chrome_vs_bank_tb: %d FAIL(s)\n", g_fails);
        return 1;
    }
    std::fprintf(stderr, "plex_chrome_vs_bank_tb: PASS\n");
    return 0;
}
