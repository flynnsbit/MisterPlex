// RED-before-green contract for OSD_CONTROL auto-detect policy.
// Pins: confstr classification (v3 Idle vs pre-v3), apply gate, SPI status gate,
// mailbox liveness is transport-only, auto settle, inert notice.
// No FPGA required.
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
    CHECK(parseOsdControlMode("auto\r") == OsdControlMode::Auto);
    CHECK(parseOsdControlMode("1\r") == OsdControlMode::ForcedOn);
    CHECK(parseOsdControlMode("maybe") == OsdControlMode::ForcedOff);
    CHECK(std::string(osdControlModeName(OsdControlMode::Auto)) == "auto");
    CHECK(std::string(osdCapabilityName(OsdCapability::V3Idle)) == "v3_idle");
    CHECK(std::string(osdCapabilityName(OsdCapability::PreV3)) == "pre_v3");

    // --- CONF_STR classification (quoted product markers) ---
    // Empty is Unknown (keep probing); never invent generation.
    CHECK(classifyOsdConfStr("") == OsdCapability::Unknown);

    // Product Plex.sv snippet (Idle screen on O[15:14]).
    const std::string v3 =
        "Plex;;O[2],TV Mode,NTSC,PAL;O[4],Content resolution,320x240,640x480;"
        "O[15:14],Idle screen,Plex logo,Black,Screensaver,Last frame;v,7;";
    CHECK(classifyOsdConfStr(v3) == OsdCapability::V3Idle);
    CHECK(v3.find(kOsdIdleScreenConfMarker) != std::string::npos);

    // Pre-v3 CONF_STR replaced by commit 363183d8 (Pattern + Content FPS).
    const std::string pre =
        "Plex;;O[2],TV Mode,NTSC,PAL;O[5:4],Content FPS,24,30,60,12;"
        "O[7:6],Pattern,None,Bars,Bars+Block,Grid;O[8],Audio tone,Off,On;";
    CHECK(classifyOsdConfStr(pre) == OsdCapability::PreV3);
    CHECK(confStrHasPreV3Markers(pre));
    CHECK(!confStrHasPreV3Markers(v3));

    // Readable junk without Idle marker → PreV3 (fail closed), not V3Idle.
    CHECK(classifyOsdConfStr("Plex;;O[2],TV Mode,NTSC,PAL;") == OsdCapability::PreV3);

    // Loose "Idle" without the bit-field marker must NOT enable apply.
    CHECK(classifyOsdConfStr("Plex;;Idle screen somewhere;") == OsdCapability::PreV3);

    // --- apply / poll gates: v3 detected -> enabled; pre-v3 -> disabled ---
    CHECK(osdPollWanted(OsdControlMode::Auto));
    CHECK(osdPollWanted(OsdControlMode::ForcedOn));
    CHECK(!osdPollWanted(OsdControlMode::ForcedOff));

    CHECK(!osdApplyWanted(OsdControlMode::Auto, OsdCapability::Unknown));
    CHECK(!osdApplyWanted(OsdControlMode::Auto, OsdCapability::Absent));
    CHECK(!osdApplyWanted(OsdControlMode::Auto, OsdCapability::PreV3));
    CHECK(osdApplyWanted(OsdControlMode::Auto, OsdCapability::V3Idle));
    CHECK(osdApplyWanted(OsdControlMode::ForcedOn, OsdCapability::Unknown));
    CHECK(osdApplyWanted(OsdControlMode::ForcedOn, OsdCapability::PreV3));
    CHECK(!osdApplyWanted(OsdControlMode::ForcedOff, OsdCapability::V3Idle));

    // PLXS/mailbox liveness alone must NOT flip Auto apply — classify first.
    // (Regression: LiveMailbox was previously enough; that is no longer valid.)
    CHECK(!osdApplyWanted(OsdControlMode::Auto, OsdCapability::Unknown));

    // SPI status: Auto only after V3Idle; ForcedOn always; never PreV3 under Auto.
    CHECK(!osdSpiStatusWanted(OsdControlMode::Auto, OsdCapability::Unknown));
    CHECK(!osdSpiStatusWanted(OsdControlMode::Auto, OsdCapability::PreV3));
    CHECK(!osdSpiStatusWanted(OsdControlMode::Auto, OsdCapability::Absent));
    CHECK(osdSpiStatusWanted(OsdControlMode::Auto, OsdCapability::V3Idle));
    CHECK(osdSpiStatusWanted(OsdControlMode::ForcedOn, OsdCapability::PreV3));
    CHECK(!osdSpiStatusWanted(OsdControlMode::ForcedOff, OsdCapability::V3Idle));

    // Legacy ForcedOn-only SPI name still true for ForcedOn.
    CHECK(!osdSpiFallbackWanted(OsdControlMode::Auto));
    CHECK(osdSpiFallbackWanted(OsdControlMode::ForcedOn));
    CHECK(!osdSpiFallbackWanted(OsdControlMode::ForcedOff));

    // --- mailbox liveness (transport only) ---
    {
        OsdMailboxLiveness lv;
        CHECK(!lv.observe(false, 1, 0.0));
        CHECK(!lv.observe(true, 10, 100.0));
        CHECK(!lv.alive);
        CHECK(lv.observe(true, 11, 200.0));
        CHECK(lv.alive);
        CHECK(lv.observe(true, 11, 500.0));
        CHECK(!lv.observe(true, 11, 3000.0));
        CHECK(!lv.alive);
        CHECK(lv.observe(true, 12, 3100.0));
    }

    // --- auto settle ---
    CHECK(osdAutoSettle(OsdCapability::Unknown, 0.0, 1000.0) == OsdCapability::Unknown);
    CHECK(osdAutoSettle(OsdCapability::Unknown, 0.0, 2500.0) == OsdCapability::Absent);
    CHECK(osdAutoSettle(OsdCapability::V3Idle, 0.0, 99999.0) == OsdCapability::V3Idle);
    CHECK(osdAutoSettle(OsdCapability::PreV3, 0.0, 99999.0) == OsdCapability::PreV3);
    CHECK(osdAutoSettle(OsdCapability::Absent, 0.0, 0.0) == OsdCapability::Absent);

    // --- inert notice ---
    CHECK(std::strlen(osdInertUserNotice()) > 0);
    CHECK(std::strlen(osdInertUserNotice()) < 32);
    CHECK(std::strchr(osdInertUserNotice(), '\n') == nullptr);

    {
        PlaybackOverlay ov;
        const int w = 160, h = 90;
        std::vector<uint8_t> rgb(static_cast<size_t>(w) * h * 3, 0x20);
        ov.flashNoticeAt(osdInertUserNotice(), 1000);
        CHECK(ov.visibleAt(1000));
        CHECK(ov.renderRgb24At(rgb.data(), w, h, 1000));
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
