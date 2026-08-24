// analogRasterApplyOnStart: ANALOG_RASTER=480p31 → O[15:14]==2, pulse status[0],
// only when Main argv contains Plex_SDfamily. No mid-play. No 15 kHz video_mode.
// 127 / 9324 still rewrite to LAN PMS. PLXA ioctl index 4 is 9 bytes, 9th toggle.
// RED twins: SWAP_BITS, LIVE_APPLY, MID_PLAY, VIDEO_MODE, IGNORE_ARGV.
#include "libmisterplex/analog_raster.hpp"
#include "libmisterplex/source_aspect.hpp"
#include "plex_resolve.hpp"

#include <cstdio>
#include <cstring>
#include <string>

static int fails = 0;
#define CHECK(cond)                                                                              \
    do {                                                                                         \
        if (!(cond)) {                                                                           \
            std::fprintf(stderr, "FAIL %s:%d: %s\n", __FILE__, __LINE__, #cond);                 \
            ++fails;                                                                             \
        }                                                                                        \
    } while (0)

#define CHECK_EQ(got, want)                                                                      \
    do {                                                                                         \
        const std::string _got = (got);                                                          \
        const std::string _want = (want);                                                        \
        if (_got != _want) {                                                                     \
            std::fprintf(stderr, "FAIL %s:%d:\n  got  [%s]\n  want [%s]\n",                      \
                         __FILE__, __LINE__, _got.c_str(), _want.c_str());                       \
            ++fails;                                                                             \
        }                                                                                        \
    } while (0)

int main() {
    using namespace misterplex;
    const std::string lan = "http://192.168.2.1:32400";
    const char* sdfamArgv = "/media/fat/MiSTer /media/fat/_Utility/Plex_SDfamily.rbf";

    CHECK(analogRasterApplyOnStart() == true);
    CHECK(analogRasterApplyOnOsdChange() == false);
    CHECK(analogRasterPulseResetOnStart() == true);
    CHECK(analogRasterPokesVideoMode() == false);
    CHECK(analogRasterVideoModeCmd() == nullptr);

    CHECK(analogRasterArgvLooksLikeSdFamily(sdfamArgv));
    CHECK(analogRasterArgvLooksLikeSdFamily("Plex_SDfamily.rbf"));
    CHECK(!analogRasterArgvLooksLikeSdFamily("Plex_480p.rbf"));
    CHECK(!analogRasterArgvLooksLikeSdFamily("Plex_240p15.rbf"));
    CHECK(!analogRasterArgvLooksLikeSdFamily("Plex_720p24.rbf"));
    CHECK(!analogRasterArgvLooksLikeSdFamily(""));
    CHECK(!analogRasterArgvLooksLikeSdFamily(nullptr));

    CHECK(analogRasterShouldApplyOnStart(sdfamArgv, false) == true);
    CHECK(analogRasterShouldApplyOnStart("Plex_SDfamily.rbf", false) == true);
    CHECK(analogRasterShouldApplyOnStart("Plex_SDfamily.rbf", true) == false);
    CHECK(analogRasterShouldApplyOnStart("Plex_480p.rbf", false) == false);
    CHECK(analogRasterShouldApplyOnStart("Plex_720p24.rbf", false) == false);
    CHECK(analogRasterShouldApplyOnStart("", false) == false);

    CHECK(analogRasterMenuBitsFromConf("480p31") == 2);
    CHECK(analogRasterMenuBitsFromConf("240p15") == 1);
    CHECK(analogRasterMenuBitsFromConf("480i") == 3);
    CHECK(analogRasterMenuBitsFromConf("follow") == 0);
    CHECK(analogRasterMenuBitsFromConf("") == 0);
    CHECK(analogRasterMenuBitsFromConf(nullptr) == 0);
    CHECK(analogRasterMenuBitsFromConf(" 480p31 ") == 2);

    const uint16_t w480 = analogRasterEncodeOsdWord(0x0000, analogRasterMenuBitsFromConf("480p31"));
    CHECK(analogRasterOsdBits1514(w480) == 2);
    CHECK(((w480 >> 14) & 3u) == 2u);
    CHECK((w480 & (1u << 15)) != 0);
    CHECK((w480 & (1u << 14)) == 0);

    const AnalogRasterStartPlan p480 = analogRasterStartPlan("480p31");
    CHECK(p480.bits15_14 == 2);
    CHECK(p480.pulseReset == true);
    CHECK(p480.applyLive == false);
    CHECK(p480.pokeVideoMode == false);
    CHECK(p480.videoModeCmd == nullptr);
    CHECK(p480.nPairs == 3);
    CHECK(p480.pairs[0] == 14 && p480.pairs[1] == 0);
    CHECK(p480.pairs[2] == 15 && p480.pairs[3] == 1);
    CHECK(p480.pairs[4] == 0 && p480.pairs[5] == 1);
    CHECK_EQ(p480.setStatusCli, "--bit 14 0 --bit 15 1 --pulse 0");
    CHECK(std::strstr(p480.setStatusCli, "video_mode") == nullptr);

    const AnalogRasterStartPlan p240 = analogRasterStartPlan("240p15");
    CHECK(p240.bits15_14 == 1);
    CHECK(p240.pairs[1] == 1 && p240.pairs[3] == 0);
    CHECK(p240.applyLive == false);
    CHECK(p240.pokeVideoMode == false);
    CHECK_EQ(p240.setStatusCli, "--bit 14 1 --bit 15 0 --pulse 0");

    const AnalogRasterStartPlan pi = analogRasterStartPlan("480i");
    CHECK(pi.bits15_14 == 3);
    CHECK(pi.pairs[1] == 1 && pi.pairs[3] == 1);
    CHECK_EQ(pi.setStatusCli, "--bit 14 1 --bit 15 1 --pulse 0");

    const AnalogRasterStartPlan pf = analogRasterStartPlan("follow");
    CHECK(pf.bits15_14 == 0);
    CHECK(pf.pairs[1] == 0 && pf.pairs[3] == 0);
    CHECK(pf.pulseReset == true);
    CHECK(pf.applyLive == false);
    CHECK(pf.pokeVideoMode == false);

    // 127 / localhost:9324 still rewrite (Web 0:00 landmine). Analog land does
    // not reopen the 720p proxy on SD-family.
    CHECK_EQ(buildPlexBase("http", "127.0.0.1", "32400", lan), lan);
    CHECK_EQ(buildPlexBase("http", "127.0.0.1", "9324", lan), lan);
    CHECK_EQ(buildPlexBase("https", "192-168-2-1.abc.plex.direct", "32400", lan), lan);
    CHECK_EQ(buildPlexBase("http", "169.254.1.20", "32400", lan), lan);
    CHECK(isUnreachableHost("127.0.0.1"));
    CHECK(!isUnreachableHost("192.168.2.1"));

    // Host ioctl: PLXA 9-byte, index 4, 9th-byte token toggle (FPGA falling-edge).
    CHECK(kSourceAspectIoctlIndex == 4);
    CHECK(kSourceAspectPacketMagic == 0x41584C50u);
    const auto pkt1 = encodeSourceAspectPacket({4, 3, true}, 1);
    CHECK(pkt1.size() == 9);
    CHECK(pkt1[0] == 'P' && pkt1[1] == 'L' && pkt1[2] == 'X' && pkt1[3] == 'A');
    CHECK(pkt1[8] == 1);
    const auto pkt2 = encodeSourceAspectPacket({4, 3, true}, 2);
    CHECK(pkt2.size() == 9);
    CHECK(pkt2[8] == 2);
    CHECK(pkt1[8] != pkt2[8]);

    if (fails) {
        std::fprintf(stderr, "test_analog_raster_apply: %d failure(s)\n", fails);
        return 1;
    }
    std::printf("test_analog_raster_apply: OK 480p31 bits15:14=2 pulse_reset live=0 "
                "sdfam_argv no_midplay no_video_mode set_status='--bit 14 0 --bit 15 1 --pulse 0'\n");
    return 0;
}
