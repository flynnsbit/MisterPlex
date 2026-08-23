// L8 red twin: HDMI LCD path must refuse ascal 15 kHz (kVideoModeCmd240p 6500).
#include "libmisterplex/display_raster.hpp"

#include <cstdio>
#include <cstring>

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

    CHECK(videoModePixelKhz(kVideoModeCmd240p) == 6500);
    CHECK(videoModeIsCrt15k(kVideoModeCmd240p));
    CHECK(videoModeIsCrt15k(kVideoModeCmd480i));
    CHECK(!videoModeIsCrt15k(kVideoModeCmd480p));
    CHECK(!videoModeIsCrt15k(kVideoModeCmd240pLcd));
    CHECK(videoModePixelKhz(kVideoModeCmd240p) < kVgaMinPixelKhz);
    CHECK(videoModePixelKhz(kVideoModeCmd480i) < kVgaMinPixelKhz);
    CHECK(videoModePixelKhz(kVideoModeCmd240pLcd) >= kVgaMinPixelKhz);
    CHECK(videoModePixelKhz(kVideoModeCmd480p) >= kVgaMinPixelKhz);

    CHECK(!videoModeCmdIsHdmiLcdSafe(kVideoModeCmd240p));
    CHECK(!videoModeCmdIsHdmiLcdSafe(kVideoModeCmd480i));
    CHECK(videoModeCmdIsHdmiLcdSafe(kVideoModeCmd480p));
    CHECK(videoModeCmdIsHdmiLcdSafe(kVideoModeCmd240pLcd));
    CHECK(videoModeCmdIsHdmiLcdSafe(kVideoModeCmd720p));
    CHECK(!videoModeCmdIsHdmiLcdSafe(nullptr));

    const char* follow240 = videoModeCmdForDisplayLabel("240p");
    CHECK(follow240 != nullptr);
    CHECK(videoModePixelKhz(follow240) == 6500);
    CHECK(!videoModeCmdIsHdmiLcdSafe(follow240));

    if (fails) {
        std::fprintf(stderr, "test_hdmi_lcd_refuse_15k: %d failure(s)\n", fails);
        return 1;
    }
    std::printf("test_hdmi_lcd_refuse_15k: OK\n");
    return 0;
}
