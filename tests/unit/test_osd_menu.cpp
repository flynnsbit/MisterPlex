// Unit tests for the OSD menu word decode and the idle-screen renderer.
//
// These two headers are the contract between Plex.sv's CONF_STR and the daemon.
// If they drift apart the symptom is silent and awful — a menu item labelled
// "-40ms" applies +120ms — so the layout is pinned here rather than trusted.
#include "libmisterplex/idle_screen.hpp"
#include "libmisterplex/osd_menu.hpp"

#include <cstdint>
#include <cstdio>
#include <vector>

static int fails = 0;
#define CHECK(cond)                                                                              \
    do {                                                                                         \
        if (!(cond)) {                                                                           \
            std::fprintf(stderr, "FAIL %s:%d: %s\n", __FILE__, __LINE__, #cond);                 \
            ++fails;                                                                             \
        }                                                                                        \
    } while (0)

int main() {
    using namespace misterplex;

    // --- A/V offset: 4-bit signed, 20 ms per step ---
    // Power-on status is all zeroes and Main_MiSTer cannot express a non-zero
    // default, so index 0 MUST mean 0 ms.
    CHECK(osdAvOffsetMsFromIndex(0) == 0);
    CHECK(osdAvOffsetMsFromIndex(1) == 20);
    CHECK(osdAvOffsetMsFromIndex(7) == 140);
    CHECK(osdAvOffsetMsFromIndex(8) == -160);
    CHECK(osdAvOffsetMsFromIndex(15) == -20);
    // Every index maps to a distinct, in-range value.
    for (unsigned i = 0; i < 16; ++i) {
        const int ms = osdAvOffsetMsFromIndex(i);
        CHECK(ms >= -160 && ms <= 140);
        CHECK(ms % kOsdAvOffsetStepMs == 0);
    }

    // --- word decode: bit positions must match CONF_STR exactly ---
    {
        const OsdSettings d = decodeOsdWord(0x0000);
        CHECK(d.avOffsetMs == 0);
        CHECK(d.audioClockPpm == kOsdAudioClockPpm);
        CHECK(d.resyncEnabled);
        CHECK(d.idleMode == 0);
    }
    CHECK(decodeOsdWord(1u << 1).resyncEnabled == false);   // O[1] A/V auto resync
    CHECK(decodeOsdWord(1u << 3).audioClockPpm == 0);       // O[3] Audio clock trim
    CHECK(decodeOsdWord(0xFu << 6).avOffsetMs == -20);      // O[9:6] index 15
    CHECK(decodeOsdWord(8u << 6).avOffsetMs == -160);       // O[9:6] index 8
    CHECK(decodeOsdWord(3u << 14).idleMode == 3);           // O[15:14] Idle screen
    // Core-owned bits must not leak into user settings.
    for (int bit : {0, 2, 4, 5, 10, 11, 12, 13}) {
        const OsdSettings d = decodeOsdWord(static_cast<uint16_t>(1u << bit));
        CHECK(d.avOffsetMs == 0);
        CHECK(d.resyncEnabled);
        CHECK(d.audioClockPpm == kOsdAudioClockPpm);
        CHECK(d.idleMode == 0);
    }

    // --- change detection ignores core traffic ---
    // [10]/[11] flush pulses and [12]/[13] DDR kick/bank toggle constantly during
    // playback; reacting to them would re-log and re-apply settings every frame.
    for (int bit : {0, 2, 4, 5, 10, 11, 12, 13})
        CHECK(!osdChanged(0, static_cast<uint16_t>(1u << bit)));
    for (int bit : {1, 3, 6, 7, 8, 9, 14, 15})
        CHECK(osdChanged(0, static_cast<uint16_t>(1u << bit)));

    // --- idle mode bits match CONF_STR order ---
    CHECK(idleModeFromBits(0) == IdleMode::Logo);
    CHECK(idleModeFromBits(1) == IdleMode::Black);
    CHECK(idleModeFromBits(2) == IdleMode::Screensaver);
    CHECK(idleModeFromBits(3) == IdleMode::LastFrame);

    // --- screensaver drift stays on screen and reverses ---
    const int span = 40;
    for (int p = -5000; p < 5000; ++p) {
        const int d = idleDrift(p, span);
        CHECK(d >= 0 && d <= span);
    }
    CHECK(idleDrift(0, span) == 0);
    CHECK(idleDrift(kIdlePhasePeriod / 2, span) == span);
    CHECK(idleDrift(kIdlePhasePeriod, span) == 0);
    CHECK(idleDrift(0, 0) == 0);

    // --- renderer ---
    const int w = 320, h = 240;
    std::vector<uint8_t> buf(static_cast<size_t>(w) * h * 3);

    // Black is exactly black: this is the burn-in-safe mode, no stray pixels.
    std::fill(buf.begin(), buf.end(), 0xAB);
    renderIdleRgb24(buf.data(), w, h, IdleMode::Black, 0);
    for (uint8_t v : buf)
        CHECK(v == 0);

    // LastFrame must not touch the buffer — it is the "leave it alone" mode.
    std::fill(buf.begin(), buf.end(), 0xAB);
    renderIdleRgb24(buf.data(), w, h, IdleMode::LastFrame, 0);
    for (uint8_t v : buf)
        CHECK(v == 0xAB);

    // Logo paints the background everywhere and the mark somewhere.
    std::fill(buf.begin(), buf.end(), 0xAB);
    renderIdleRgb24(buf.data(), w, h, IdleMode::Logo, 0);
    size_t fg = 0, bg = 0, other = 0;
    for (size_t i = 0; i + 2 < buf.size(); i += 3) {
        if (buf[i] == kIdleFgR && buf[i + 1] == kIdleFgG && buf[i + 2] == kIdleFgB)
            ++fg;
        else if (buf[i] == kIdleBgR && buf[i + 1] == kIdleBgG && buf[i + 2] == kIdleBgB)
            ++bg;
        else
            ++other;
    }
    CHECK(other == 0);
    CHECK(fg > 0);
    CHECK(bg > fg);

    // The screensaver must never render into the overscan margin, at any phase.
    for (int p = 0; p < kIdlePhasePeriod; p += 7) {
        std::fill(buf.begin(), buf.end(), 0);
        renderIdleRgb24(buf.data(), w, h, IdleMode::Screensaver, p);
        for (int y = 0; y < h; ++y) {
            for (int x = 0; x < w; ++x) {
                const size_t i = (static_cast<size_t>(y) * w + x) * 3;
                const bool isFg =
                    buf[i] == kIdleFgR && buf[i + 1] == kIdleFgG && buf[i + 2] == kIdleFgB;
                if (!isFg)
                    continue;
                CHECK(x >= kIdleMargin && x < w - kIdleMargin);
                CHECK(y >= kIdleMargin && y < h - kIdleMargin);
            }
        }
    }

    if (fails) {
        std::fprintf(stderr, "test_osd_menu: %d failure(s)\n", fails);
        return 1;
    }
    std::printf("test_osd_menu: OK\n");
    return 0;
}
