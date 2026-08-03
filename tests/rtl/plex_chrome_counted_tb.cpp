// Counted plex_chrome HUD — product host_if write path → pixels on 1280×720.
// Counterpart to w-scaler counted-DE: prove emitted pixels, not just layout math.
//
// Cases (COUNTED_CASE=):
//   green       — 38-cmd core HUD via list_we; locate panel/track/fill; passthrough exact
//   wrong_off   — cmds written past MAX_CMDS; chrome must NOT paint (red twin expects fail if paint)
//   hit_bleed   — FAULT_HIT_BLEED build: +1px bleed outside rect must be chrome (red twin)
//   trunc79     — 79 cmds into MAX_CMDS=48; cmd[50] marker absent; first 48 visible; no wrap
//
// Markers: EXECUTED <case>, PASS/FAIL lines. Soft-skip is not a pass.

#include "Vplex_chrome_counted_tb.h"
#include "verilated.h"

#include <algorithm>
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

static void tick(Vplex_chrome_counted_tb* t) {
    t->clk = 0;
    t->eval();
    main_time++;
    t->clk = 1;
    t->eval();
    main_time++;
}

static uint64_t packGlyph(uint16_t x, uint16_t y, char c) {
    return 2ull | (uint64_t(x) << 8) | (uint64_t(y) << 24) | (uint64_t(uint8_t(c)) << 40);
}
static uint64_t packRect(uint16_t x, uint16_t y, uint16_t w, uint16_t h) {
    uint64_t v = 1ull | (uint64_t(x) << 8) | (uint64_t(y) << 24);
    v |= (uint64_t(w & 0xFFF) << 40) | (uint64_t(h & 0xFFF) << 52);
    return v;
}
static uint64_t packRectPal(uint16_t x, uint16_t y, uint8_t w, uint8_t h, uint8_t pal) {
    uint64_t v = 3ull | (uint64_t(x) << 8) | (uint64_t(y) << 24);
    v |= (uint64_t(w) << 40) | (uint64_t(h) << 48) | (uint64_t(pal) << 56);
    return v;
}
static uint64_t packPlxc(bool en, unsigned count, uint16_t seq) {
    uint64_t w = 0x504C5843ull;
    if (en)
        w |= 1ull << 32;
    w |= (uint64_t(count) & 0x3FFFull) << 34;
    w |= uint64_t(seq) << 48;
    return w;
}

// Returns whether host_if asserted list_we on this beat (product path accept).
static bool hostWrite(Vplex_chrome_counted_tb* t, uint8_t addr, uint64_t data) {
    t->host_we = 1;
    t->host_addr = addr;
    t->host_wdata = data;
    tick(t);
    const bool list_fire = t->list_we_mon != 0;
    t->host_we = 0;
    tick(t); // chrome consumes list_we/wdata on this cycle
    return list_fire;
}

static uint32_t videoAt(int x, int y) {
    // Distinct per-pixel underlay so pass-through equality is strong.
    return (uint32_t((x * 3 + 17) & 0xFF) << 16) | (uint32_t((y * 5 + 3) & 0xFF) << 8) |
           uint32_t((x ^ y ^ 0x5A) & 0xFF);
}

// Capture full frame using idle720-proven 1-cycle dout alignment.
// Present din(x,y) on DE; dout for that pixel appears on the next de_out beat
// (including the blanking tick after each line for the last pixel).
static void captureFrame(Vplex_chrome_counted_tb* t, int W, int H, std::vector<uint32_t>& fb) {
    fb.assign(static_cast<size_t>(W) * H, 0xDEADBEu);
    t->de_in = 0;
    t->vs_in = 0;
    tick(t);
    t->vs_in = 1;
    tick(t);
    tick(t);

    for (int y = 0; y < H; ++y) {
        t->de_in = 0;
        tick(t);
        t->de_in = 1;
        // Pipeline: first active tick has de_out still low; store starts at x=0
        // after second tick. Keep a 1-pixel delay buffer of coords.
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
    // Sanity: no DEADBEE left in a few corners
    int dead = 0;
    for (int i = 0; i < W * H; i += 137)
        if (fb[static_cast<size_t>(i)] == 0xDEADBEu)
            dead++;
    std::fprintf(stderr, "capture dead_slots~%d (step 137)\n", dead);
}

// Build core STOPPED HUD matching host buildPlaybackHud (1280×720, scale=3).
// Returns commands; fills geometry outs for assertions.
struct HudGeom {
    int px, py, pw, ph;
    int barX, barY, barW, barH, fillW;
    int labelY, textX;
};
static std::vector<uint64_t> buildCoreHud38(HudGeom& g) {
    const int outW = 1280, outH = 720;
    const int scale = 3;
    const int margin = std::max(8, outW / 32);
    const int ph = std::min(72 * scale / 2, std::max(54, outH / 4));
    const int px = margin;
    const int py = outH - ph - margin;
    const int pw = outW - margin * 2;
    g = {px, py, pw, ph, 0, 0, 0, 0, 0, 0, 0};
    g.labelY = py + 10;
    g.textX = px + 16;
    g.barX = px + 16;
    g.barY = py + ph - 18;
    g.barW = pw - 32;
    g.barH = 6;
    // position 125000 / duration 600000 → fill fraction
    g.fillW = static_cast<int>((static_cast<long long>(g.barW) * 125000) / 600000);

    std::vector<uint64_t> cmds;
    cmds.push_back(packRect(uint16_t(px), uint16_t(py), uint16_t(pw), uint16_t(ph)));
    const char* st = "STOPPED";
    int x = g.textX;
    for (const char* p = st; *p; ++p) {
        cmds.push_back(packGlyph(uint16_t(x), uint16_t(g.labelY), *p));
        x += 9 * scale;
    }
    const char* title = "BIG BUCK BUNNY TITLE"; // 19
    int tx = g.textX + int(std::strlen(st)) * 9 * scale + 16;
    for (const char* p = title; *p; ++p) {
        cmds.push_back(packGlyph(uint16_t(tx), uint16_t(g.labelY), *p));
        tx += 9 * scale;
    }
    // times: 2:05 and 10:00
    const char* el = "2:05";
    const char* tot = "10:00";
    const int timeY = py + 34;
    x = px + 16;
    for (const char* p = el; *p; ++p) {
        cmds.push_back(packGlyph(uint16_t(x), uint16_t(timeY), *p));
        x += 9 * scale;
    }
    const int totalW = int(std::strlen(tot)) * 9 * scale;
    x = px + pw - 16 - totalW;
    for (const char* p = tot; *p; ++p) {
        cmds.push_back(packGlyph(uint16_t(x), uint16_t(timeY), *p));
        x += 9 * scale;
    }
    cmds.push_back(packRect(uint16_t(g.barX), uint16_t(g.barY), uint16_t(g.barW), uint16_t(g.barH)));
    if (g.fillW > 0) {
        int fx = g.barX;
        int remain = g.fillW;
        while (remain > 0) {
            const int chunk = std::min(255, remain);
            cmds.push_back(packRectPal(uint16_t(fx), uint16_t(g.barY), uint8_t(chunk),
                                       uint8_t(g.barH), /*Amber*/ 2));
            fx += chunk;
            remain -= chunk;
        }
    }
    return cmds;
}

static void loadList(Vplex_chrome_counted_tb* t, const std::vector<uint64_t>& cmds, uint16_t seq,
                     bool enable, int addr_base = 0) {
    // Product order: list words first, then PLXC ctrl (seq edge).
    int wrote = 0;
    for (size_t i = 0; i < cmds.size(); ++i) {
        const int addr = addr_base + static_cast<int>(i);
        if (addr < 0 || addr > 255)
            continue;
        if (hostWrite(t, uint8_t(addr), cmds[i]))
            wrote++;
    }
    hostWrite(t, 0xFF, packPlxc(enable, static_cast<unsigned>(cmds.size()), seq));
    // Latch on vs rising
    t->vs_in = 0;
    tick(t);
    t->vs_in = 1;
    for (int i = 0; i < 4; ++i)
        tick(t);
    std::fprintf(stderr, "LOAD list_we_pulses=%d cmds=%zu cfg_en=%d cfg_cnt=%u seq=%u base=%d\n",
                 wrote, cmds.size(), int(t->cfg_enable_mon), unsigned(t->cfg_count_mon), seq,
                 addr_base);
}

static bool isPanel(uint32_t p) {
    return (p & 0xFFFFFFu) == 0x141428u;
}
// Fabric pal_rgb(2) = FF_B2_20 (host Pal::Amber). E5_A0_0D is pal6 / idle chevron.
static bool isAmber(uint32_t p) {
    const uint32_t c = p & 0xFFFFFFu;
    return c == 0xFFB220u || c == 0xE5A00Du;
}
static bool isWhite(uint32_t p) {
    return (p & 0xFFFFFFu) == 0xFFFFFFu;
}

static int run_green() {
    std::fprintf(stderr, "EXECUTED green\n");
    auto* t = new Vplex_chrome_counted_tb;
    t->reset = 1;
    t->HDMI_WIDTH = 1280;
    t->HDMI_HEIGHT = 720;
    t->has_frame = 1;
    t->host_we = 0;
    t->din = 0;
    t->hs_in = 1;
    t->vs_in = 1;
    t->de_in = 0;
    for (int i = 0; i < 4; ++i)
        tick(t);
    t->reset = 0;
    for (int i = 0; i < 8; ++i)
        tick(t);

    HudGeom g{};
    auto cmds = buildCoreHud38(g);
    std::fprintf(stderr, "HUD cmds=%zu geom panel=(%d,%d)%dx%d bar=(%d,%d)%dx%d fillW=%d\n",
                 cmds.size(), g.px, g.py, g.pw, g.ph, g.barX, g.barY, g.barW, g.barH, g.fillW);
    if (cmds.size() < 30 || cmds.size() > 48)
        fail("core hud size not in 30..48");

    loadList(t, cmds, /*seq*/ 1, true, /*base*/ 0);

    std::vector<uint32_t> fb;
    captureFrame(t, 1280, 720, fb);

    // --- Panel interior sample ---
    const int psx = g.px + g.pw / 2;
    const int psy = g.py + 8; // top of panel (below edge); may be under glyphs — use lower empty
    const int psy2 = g.py + g.ph / 2; // mid panel
    const uint32_t panel_px = fb[static_cast<size_t>(psy2) * 1280 + psx];
    std::fprintf(stderr, "panel mid (%d,%d)=%06x\n", psx, psy2, panel_px);
    if (!isPanel(panel_px))
        fail("panel color missing at mid");

    // --- Track (dark rect) and amber fill ---
    // Track right end past fill should be panel color 14_14_28 (op1 rect)
    const int track_x = g.barX + g.fillW + 20;
    const int track_y = g.barY + g.barH / 2;
    const uint32_t track_px = fb[static_cast<size_t>(track_y) * 1280 + track_x];
    const int fill_x = g.barX + std::max(1, g.fillW / 2);
    const uint32_t fill_px = fb[static_cast<size_t>(track_y) * 1280 + fill_x];
    std::fprintf(stderr, "track (%d,%d)=%06x fill (%d,%d)=%06x\n", track_x, track_y, track_px,
                 fill_x, track_y, fill_px);
    if (!isPanel(track_px))
        fail("progress track not panel-dark");
    if (!isAmber(fill_px))
        fail("progress fill not amber");

    // --- Glyph ink: sample STOPPED region for any white ---
    int white = 0;
    for (int yy = g.labelY; yy < g.labelY + 8 * 3; ++yy)
        for (int xx = g.textX; xx < g.textX + 7 * 9 * 3; ++xx)
            if (isWhite(fb[static_cast<size_t>(yy) * 1280 + xx]))
                white++;
    std::fprintf(stderr, "STOPPED glyph white_px=%d\n", white);
    if (white < 20)
        fail("STOPPED glyphs missing white ink");

    // --- Pass-through byte-exact outside HUD band ---
    // HUD occupies roughly y in [py, py+ph). Sample grid above and sides.
    int pt_ok = 0, pt_bad = 0;
    for (int y = 40; y < g.py - 4; y += 40) {
        for (int x = 40; x < 1240; x += 40) {
            const uint32_t got = fb[static_cast<size_t>(y) * 1280 + x];
            const uint32_t want = videoAt(x, y);
            if (got == want)
                pt_ok++;
            else {
                pt_bad++;
                if (pt_bad < 5)
                    std::fprintf(stderr, "passthru miss (%d,%d) got=%06x want=%06x\n", x, y, got,
                                 want);
            }
        }
    }
    // also below panel if any
    for (int y = g.py + g.ph + 4; y < 716; y += 20) {
        for (int x = 40; x < 1240; x += 80) {
            const uint32_t got = fb[static_cast<size_t>(y) * 1280 + x];
            if (got == videoAt(x, y))
                pt_ok++;
            else
                pt_bad++;
        }
    }
    std::fprintf(stderr, "passthrough ok=%d bad=%d\n", pt_ok, pt_bad);
    if (pt_bad != 0)
        fail("video not byte-exact outside HUD");
    if (pt_ok < 50)
        fail("passthrough sample too small");

    // Count panel-ish pixels in band (lower bound)
    int panel_n = 0, amber_n = 0, white_n = 0;
    for (int y = g.py; y < g.py + g.ph; ++y) {
        for (int x = g.px; x < g.px + g.pw; x += 2) {
            const uint32_t p = fb[static_cast<size_t>(y) * 1280 + x];
            if (isPanel(p))
                panel_n++;
            else if (isAmber(p))
                amber_n++;
            else if (isWhite(p))
                white_n++;
        }
    }
    std::fprintf(stderr, "COUNTED panel=%d amber=%d white=%d (2x subsample)\n", panel_n, amber_n,
                 white_n);
    if (panel_n < 1000)
        fail("panel pixel count too low");
    if (amber_n < 10)
        fail("amber fill count too low");
    if (white_n < 10)
        fail("white glyph count too low");

    delete t;
    if (g_fails == 0)
        std::fprintf(stderr, "PASS counted-green\n");
    return g_fails ? 1 : 0;
}

// Red twin: write list at base=80 (beyond MAX_CMDS=48) so list_we never accepts.
// Expect NO panel paint — if panel appears, host layout checks would still pass but fabric silent.
static int run_wrong_off() {
    std::fprintf(stderr, "EXECUTED wrong_off\n");
    auto* t = new Vplex_chrome_counted_tb;
    t->reset = 1;
    t->HDMI_WIDTH = 1280;
    t->HDMI_HEIGHT = 720;
    t->has_frame = 1;
    t->host_we = 0;
    t->din = 0;
    t->hs_in = 1;
    t->vs_in = 1;
    t->de_in = 0;
    for (int i = 0; i < 4; ++i)
        tick(t);
    t->reset = 0;
    for (int i = 0; i < 8; ++i)
        tick(t);

    HudGeom g{};
    auto cmds = buildCoreHud38(g);
    // Wrong mailbox-style offset: host_addr starts at 80 ≥ MAX_CMDS → no list_we
    loadList(t, cmds, 2, true, /*base*/ 80);
    if (t->cfg_enable_mon != 1)
        fail("cfg should still enable (ctrl @0xFF works)");

    std::vector<uint32_t> fb;
    captureFrame(t, 1280, 720, fb);
    const int psx = g.px + g.pw / 2;
    const int psy2 = g.py + g.ph / 2;
    const uint32_t panel_px = fb[static_cast<size_t>(psy2) * 1280 + psx];
    std::fprintf(stderr, "wrong_off panel mid=%06x (want video passthrough)\n", panel_px);
    // Must be video, not panel
    if (isPanel(panel_px))
        fail("wrong_off painted panel — list should have been invisible");
    if (panel_px != videoAt(psx, psy2))
        fail("wrong_off mid not pure passthrough");

    // If this case is used as red twin that MUST fail when bleed/wrong path paints:
    // Success of wrong_off is that paint is ABSENT.
    delete t;
    if (g_fails == 0)
        std::fprintf(stderr, "PASS counted-wrong_off\n");
    return g_fails ? 1 : 0;
}

// Red twin under FAULT_HIT_BLEED=1: pixel just outside rect right edge must be chrome.
// Green product would pass-through there.
static int run_hit_bleed() {
    std::fprintf(stderr, "EXECUTED hit_bleed\n");
    auto* t = new Vplex_chrome_counted_tb;
    t->reset = 1;
    t->HDMI_WIDTH = 1280;
    t->HDMI_HEIGHT = 720;
    t->has_frame = 1;
    t->host_we = 0;
    t->din = 0;
    t->hs_in = 1;
    t->vs_in = 1;
    t->de_in = 0;
    for (int i = 0; i < 4; ++i)
        tick(t);
    t->reset = 0;
    for (int i = 0; i < 8; ++i)
        tick(t);

    // Single small rect at (100,100) 40x20
    std::vector<uint64_t> cmds;
    cmds.push_back(packRect(100, 100, 40, 20));
    loadList(t, cmds, 3, true, 0);

    std::vector<uint32_t> fb;
    captureFrame(t, 1280, 720, fb);
    // Inside should be panel
    if (!isPanel(fb[100 * 1280 + 100]))
        fail("hit_bleed inside missing");
    // Just outside right edge x=140 is product pass-through; FAULT bleeds to x=140
    const uint32_t edge = fb[110 * 1280 + 140];
    const uint32_t out2 = fb[110 * 1280 + 141];
    std::fprintf(stderr, "hit_bleed x140=%06x x141=%06x\n", edge, out2);
    if (!isPanel(edge))
        fail("FAULT_HIT_BLEED did not expand right edge (red twin not engaged?)");
    // x=141 should still be video even with +1 bleed
    if (isPanel(out2))
        fail("bleed expanded more than +1");
    if (out2 != videoAt(141, 110))
        fail("beyond bleed not passthrough");

    delete t;
    if (g_fails == 0)
        std::fprintf(stderr, "PASS counted-hit_bleed\n");
    return g_fails ? 1 : 0;
}

// Feed 79 cmds to MAX_CMDS=48: marker only in slot 50 must not appear; slot 0 panel must.
static int run_trunc79() {
    std::fprintf(stderr, "EXECUTED trunc79\n");
    auto* t = new Vplex_chrome_counted_tb;
    t->reset = 1;
    t->HDMI_WIDTH = 1280;
    t->HDMI_HEIGHT = 720;
    t->has_frame = 1;
    t->host_we = 0;
    t->din = 0;
    t->hs_in = 1;
    t->vs_in = 1;
    t->de_in = 0;
    for (int i = 0; i < 4; ++i)
        tick(t);
    t->reset = 0;
    for (int i = 0; i < 8; ++i)
        tick(t);

    std::vector<uint64_t> cmds;
    // cmd0: large panel
    cmds.push_back(packRect(40, 572, 1200, 108));
    // cmds 1..47: tiny dummy glyphs off to the side (still within list)
    for (int i = 1; i < 48; ++i)
        cmds.push_back(packGlyph(uint16_t(10 + (i % 8) * 10), uint16_t(10 + (i / 8) * 10), 'A'));
    // cmds 48..78: should be DROPPED by host_if (addr>=48) — include huge white-ish marker rect
    // Use distinctive amber rect at (200,200) only in dropped region
    for (int i = 48; i < 79; ++i) {
        if (i == 50)
            cmds.push_back(packRectPal(200, 200, 80, 80, /*Amber*/ 2));
        else
            cmds.push_back(packGlyph(300, 300, 'Z'));
    }
    if (cmds.size() != 79)
        fail("trunc79 setup size");

    // Write all 79 at base 0 — host_if ignores addr>=48 for list_we
    int pulses = 0;
    for (size_t i = 0; i < cmds.size(); ++i) {
        if (hostWrite(t, uint8_t(i & 0xFF), cmds[i]))
            pulses++;
    }
    hostWrite(t, 0xFF, packPlxc(true, 79, 9)); // count field 79 → clamp to 48
    t->vs_in = 0;
    tick(t);
    t->vs_in = 1;
    for (int i = 0; i < 4; ++i)
        tick(t);
    std::fprintf(stderr, "trunc79 list_we_pulses=%d cfg_cnt=%u (want pulses=48 cnt<=48)\n", pulses,
                 unsigned(t->cfg_count_mon));
    if (pulses != 48)
        fail("trunc79 list_we accepted != 48");
    if (t->cfg_count_mon > 48)
        fail("trunc79 cfg_count not clamped");

    std::vector<uint32_t> fb;
    captureFrame(t, 1280, 720, fb);
    // Panel from cmd0 present
    if (!isPanel(fb[620 * 1280 + 640]))
        fail("trunc79 panel from cmd0 missing");
    // Marker amber at (200,200) from cmd50 must NOT appear
    int amber_zone = 0;
    for (int y = 200; y < 280; ++y)
        for (int x = 200; x < 280; ++x)
            if (isAmber(fb[static_cast<size_t>(y) * 1280 + x]))
                amber_zone++;
    std::fprintf(stderr, "trunc79 amber_at_cmd50_zone=%d (want 0)\n", amber_zone);
    if (amber_zone != 0)
        fail("trunc79 wrapped/accepted cmd50 marker — corruption");
    // Pass-through at marker centre
    if (fb[240 * 1280 + 240] != videoAt(240, 240))
        fail("trunc79 marker zone not passthrough");

    delete t;
    if (g_fails == 0)
        std::fprintf(stderr, "PASS counted-trunc79\n");
    return g_fails ? 1 : 0;
}

// Product green must NOT show bleed at rect edge (negative of hit_bleed).
static int run_no_bleed_product() {
    std::fprintf(stderr, "EXECUTED no_bleed_product\n");
    auto* t = new Vplex_chrome_counted_tb;
    t->reset = 1;
    t->HDMI_WIDTH = 1280;
    t->HDMI_HEIGHT = 720;
    t->has_frame = 1;
    t->host_we = 0;
    t->din = 0;
    t->hs_in = 1;
    t->vs_in = 1;
    t->de_in = 0;
    for (int i = 0; i < 4; ++i)
        tick(t);
    t->reset = 0;
    for (int i = 0; i < 8; ++i)
        tick(t);

    std::vector<uint64_t> cmds;
    cmds.push_back(packRect(100, 100, 40, 20));
    loadList(t, cmds, 4, true, 0);
    std::vector<uint32_t> fb;
    captureFrame(t, 1280, 720, fb);
    const uint32_t edge = fb[110 * 1280 + 140]; // first pixel outside
    std::fprintf(stderr, "no_bleed x140=%06x want video\n", edge);
    if (isPanel(edge))
        fail("product bleeds past rect edge");
    if (edge != videoAt(140, 110))
        fail("product edge not passthrough");
    delete t;
    if (g_fails == 0)
        std::fprintf(stderr, "PASS counted-no_bleed_product\n");
    return g_fails ? 1 : 0;
}

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    const char* which = std::getenv("COUNTED_CASE");
    std::string cse = which ? which : "green";
    int rc = 2;
    if (cse == "green")
        rc = run_green();
    else if (cse == "wrong_off")
        rc = run_wrong_off();
    else if (cse == "hit_bleed")
        rc = run_hit_bleed();
    else if (cse == "trunc79")
        rc = run_trunc79();
    else if (cse == "no_bleed")
        rc = run_no_bleed_product();
    else {
        std::fprintf(stderr, "USAGE COUNTED_CASE=green|wrong_off|hit_bleed|trunc79|no_bleed\n");
        return 2;
    }
    if (rc == 0)
        std::fprintf(stderr, "plex_chrome_counted_tb: PASS (%s)\n", cse.c_str());
    else
        std::fprintf(stderr, "plex_chrome_counted_tb: FAIL (%s) fails=%d\n", cse.c_str(), g_fails);
    return rc;
}
