// RED-before-green contract for OSD_CONTROL auto-detect policy.
// Pins: parse modes, apply gate, SPI fallback only ForcedOn, mailbox liveness,
// auto settle Absent, inert notice string. No FPGA required.
#include "libmisterplex/osd_control.hpp"
#include "libmisterplex/playback_overlay.hpp"

#include <cstdio>
#include <cstring>
#include <string>
#include <vector>

static int fails = 0;
#define CHECK(c)                                                                                 \
    do {                                                                                         \
        if (!(c)) {                                                                              \
            std::fprintf(stderr, "FAIL %s:%d %s\n", __FILE__, __LINE__, #c);                     \
            ++fails;                                                                             \
        }                                                                                        \
    } while (0)

int main() {
    using namespace misterplex;

    // --- parseOsdControlMode ---
    CHECK(parseOsdControlMode("") == OsdControlMode::Auto);
    CHECK(parseOsdControlMode("auto") == OsdControlMode::Auto);
    CHECK(parseOsdControlMode("1") == OsdControlMode::ForcedOn);
    CHECK(parseOsdControlMode("true") == OsdControlMode::ForcedOn);
    CHECK(parseOsdControlMode("on") == OsdControlMode::ForcedOn);
    CHECK(parseOsdControlMode("0") == OsdControlMode::ForcedOff);
    CHECK(parseOsdControlMode("off") == OsdControlMode::ForcedOff);
    CHECK(parseOsdControlMode("false") == OsdControlMode::ForcedOff);
    // CRLF leftover must not break tokens
    CHECK(parseOsdControlMode("auto\r") == OsdControlMode::Auto);
    CHECK(parseOsdControlMode("1\r") == OsdControlMode::ForcedOn);
    // Unknown → fail closed (never silent enable)
    CHECK(parseOsdControlMode("maybe") == OsdControlMode::ForcedOff);
    CHECK(std::string(osdControlModeName(OsdControlMode::Auto)) == "auto");

    // --- apply / poll / SPI gates ---
    CHECK(osdPollWanted(OsdControlMode::Auto));
    CHECK(osdPollWanted(OsdControlMode::ForcedOn));
    CHECK(!osdPollWanted(OsdControlMode::ForcedOff));

    CHECK(!osdApplyWanted(OsdControlMode::Auto, OsdCapability::Unknown));
    CHECK(!osdApplyWanted(OsdControlMode::Auto, OsdCapability::Absent));
    CHECK(osdApplyWanted(OsdControlMode::Auto, OsdCapability::LiveMailbox));
    CHECK(osdApplyWanted(OsdControlMode::ForcedOn, OsdCapability::Unknown));
    CHECK(osdApplyWanted(OsdControlMode::ForcedOn, OsdCapability::Absent));
    CHECK(!osdApplyWanted(OsdControlMode::ForcedOff, OsdCapability::LiveMailbox));

    // SPI fallback is the pre-v3 footgun — Auto must never request it.
    CHECK(!osdSpiFallbackWanted(OsdControlMode::Auto));
    CHECK(osdSpiFallbackWanted(OsdControlMode::ForcedOn));
    CHECK(!osdSpiFallbackWanted(OsdControlMode::ForcedOff));

    // --- mailbox liveness (first sight stale; seq advance LIVE; freeze dead) ---
    {
        OsdMailboxLiveness lv;
        CHECK(!lv.observe(false, 1, 0.0)); // no magic
        CHECK(!lv.observe(true, 10, 100.0)); // first sight not LIVE
        CHECK(!lv.alive);
        CHECK(lv.observe(true, 11, 200.0)); // seq moved → LIVE
        CHECK(lv.alive);
        CHECK(lv.observe(true, 11, 500.0)); // still alive within stale window
        CHECK(!lv.observe(true, 11, 3000.0)); // frozen >2s → dead
        CHECK(!lv.alive);
        CHECK(lv.observe(true, 12, 3100.0)); // seq moves again → LIVE
    }

    // --- auto settle ---
    CHECK(osdAutoSettle(OsdCapability::Unknown, 0.0, 1000.0) == OsdCapability::Unknown);
    CHECK(osdAutoSettle(OsdCapability::Unknown, 0.0, 2500.0) == OsdCapability::Absent);
    CHECK(osdAutoSettle(OsdCapability::LiveMailbox, 0.0, 99999.0) == OsdCapability::LiveMailbox);
    CHECK(osdAutoSettle(OsdCapability::Absent, 0.0, 0.0) == OsdCapability::Absent);

    // --- inert notice is short ASCII for 5x7 font ---
    CHECK(std::strlen(osdInertUserNotice()) > 0);
    CHECK(std::strlen(osdInertUserNotice()) < 32);
    CHECK(std::strchr(osdInertUserNotice(), '\n') == nullptr);

    // --- overlay flashNotice is HDMI-visible (pixels change) ---
    {
        PlaybackOverlay ov;
        const int w = 160, h = 90;
        std::vector<uint8_t> rgb(static_cast<size_t>(w) * h * 3, 0x20);
        ov.flashNoticeAt(osdInertUserNotice(), 1000);
        CHECK(ov.visibleAt(1000));
        CHECK(ov.renderRgb24At(rgb.data(), w, h, 1000));
        // Banner uses amber/white on black — some pixel must leave flat 0x20.
        bool changed = false;
        for (uint8_t v : rgb) {
            if (v != 0x20) {
                changed = true;
                break;
            }
        }
        CHECK(changed);
        CHECK(!ov.visibleAt(1000 + PlaybackOverlay::kNoticeVisibleMs + 1));
    }

    if (fails) {
        std::fprintf(stderr, "test_osd_control: %d fails\n", fails);
        return 1;
    }
    std::printf("test_osd_control: OK\n");
    return 0;
}
