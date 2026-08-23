// HDMI-LCD scoring must not emit 15 kHz ascal. 480i is CRT-only.
// RED twin: videoModeCmdForDisplayLabel("240p") is kVideoModeCmd240p (6500).
#include "libmisterplex/display_raster.hpp"
#include "libmisterplex/osd_menu.hpp"
#include "libmisterplex/present_bank.hpp"

#include <cstdio>
#include <string>

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

    CHECK(displayRasterApplyOnOsdChange() == false);
    CHECK(displayRasterApplyOnStartup() == true);
    CHECK(kForceDisplayRasterOnPlay == false);
    CHECK(kHdmiLcdMinLineHz == 31000);
    CHECK(kVgaMinPixelKhz == 25175);
    CHECK(videoModePixelKhz(kVideoModeCmd240p) == 6500);
    CHECK(videoModePixelKhz(kVideoModeCmd480i) == 13500);
    CHECK(videoModePixelKhz(kVideoModeCmd240pLcd) == 25175);
    CHECK(videoModePixelKhz(kVideoModeCmd480p) == 40000);
    CHECK(videoModePixelKhz(kVideoModeCmd720p) == 74250);
    CHECK(videoModePixelKhz(kVideoModeCmd720p24) == 30000);

    CHECK(videoModeHtotal(kVideoModeCmd240p) == 416);
    CHECK(videoModeVtotal(kVideoModeCmd240p) == 262);
    CHECK(videoModeLineHz(kVideoModeCmd240p) == 15625);
    CHECK(videoModeHtotal(kVideoModeCmd480i) == 858);
    CHECK(videoModeVtotal(kVideoModeCmd480i) == 262);
    CHECK(videoModeLineHz(kVideoModeCmd480i) == 15734);
    CHECK(videoModeHtotal(kVideoModeCmd240pLcd) == 800);
    CHECK(videoModeVtotal(kVideoModeCmd240pLcd) == 525);
    CHECK(videoModeLineHz(kVideoModeCmd240pLcd) == 31468);
    CHECK(videoModeHtotal(kVideoModeCmd480p) == 1056);
    CHECK(videoModeVtotal(kVideoModeCmd480p) == 628);
    CHECK(videoModeLineHz(kVideoModeCmd480p) == 37878);
    CHECK(videoModeLineHz(kVideoModeCmd720p) == 45000);
    CHECK(videoModeLineHz(kVideoModeCmd720p24) == 18181);

    CHECK(videoModeIsCrt15k(kVideoModeCmd240p));
    CHECK(videoModeIsCrt15k(kVideoModeCmd480i));
    CHECK(!videoModeIsCrt15k(kVideoModeCmd240pLcd));
    CHECK(!videoModeIsCrt15k(kVideoModeCmd480p));
    CHECK(!videoModeIsCrt15k(kVideoModeCmd720p));

    CHECK(videoModeForbiddenOnHdmiLcd(kVideoModeCmd240p));
    CHECK(videoModeForbiddenOnHdmiLcd(kVideoModeCmd480i));
    CHECK(videoModeForbiddenOnHdmiLcd(kVideoModeCmd720p24));
    CHECK(!videoModeForbiddenOnHdmiLcd(kVideoModeCmd240pLcd));
    CHECK(!videoModeForbiddenOnHdmiLcd(kVideoModeCmd480p));
    CHECK(!videoModeForbiddenOnHdmiLcd(kVideoModeCmd720p));
    CHECK(videoModeLineHz(kVideoModeCmd240pLcd) >= kHdmiLcdMinLineHz);
    CHECK(videoModeLineHz(kVideoModeCmd480p) >= kHdmiLcdMinLineHz);
    CHECK(videoModeLineHz(kVideoModeCmd240p) < kHdmiLcdMinLineHz);
    CHECK(videoModeLineHz(kVideoModeCmd480i) < kHdmiLcdMinLineHz);

    // Naive F12 label mapper is CRT analog. Using it as HDMI-LCD scoring is RED.
    CHECK(videoModeCmdForDisplayLabel("240p") == kVideoModeCmd240p);
    CHECK(videoModeCmdForDisplayLabel("480i") == kVideoModeCmd480i);
    CHECK(videoModeCmdForDisplaySel(1u, "480p") == kVideoModeCmd240p);
    CHECK(videoModeCmdForOsdWord(1u << 14) == kVideoModeCmd240p);

    const char* lcd240 = videoModeCmdForScoringPath("240p", DisplaySink::HdmiLcd);
    CHECK(lcd240 == kVideoModeCmd240pLcd);
    CHECK(lcd240 != kVideoModeCmd240p);
    CHECK(!videoModeIsCrt15k(lcd240));
    CHECK(!videoModeForbiddenOnHdmiLcd(lcd240));
    CHECK(videoModePixelKhz(lcd240) >= kVgaMinPixelKhz);
    CHECK(videoModeLineHz(lcd240) >= kHdmiLcdMinLineHz);

    const char* lcd480p = videoModeCmdForScoringPath("480p", DisplaySink::HdmiLcd);
    CHECK(lcd480p == kVideoModeCmd480p);
    CHECK(!videoModeForbiddenOnHdmiLcd(lcd480p));

    const char* lcd480i = videoModeCmdForScoringPath("480i", DisplaySink::HdmiLcd);
    CHECK(lcd480i == nullptr);
    CHECK(lcd480i != kVideoModeCmd480i);

    CHECK(videoModeCmdForScoringPath("240p_lcd", DisplaySink::HdmiLcd) == kVideoModeCmd240pLcd);
    CHECK(videoModeCmdForScoringPath("720p", DisplaySink::HdmiLcd) == kVideoModeCmd720p);
    CHECK(videoModeCmdForScoringPath("720p", DisplaySink::HdmiLcd) != kVideoModeCmd720p24);

    const char* osdLcd240 = videoModeCmdForOsdWordOnSink(1u << 14, DisplaySink::HdmiLcd);
    CHECK(std::string(decodeOsdWord(1u << 14).displayResolution.label) == "240p");
    CHECK(osdLcd240 == kVideoModeCmd240pLcd);
    CHECK(osdLcd240 != kVideoModeCmd240p);
    CHECK(!videoModeForbiddenOnHdmiLcd(osdLcd240));

    CHECK(videoModeCmdForScoringPath("240p", DisplaySink::Crt15k) == kVideoModeCmd240p);
    CHECK(videoModeCmdForScoringPath("480i", DisplaySink::Crt15k) == kVideoModeCmd480i);
    CHECK(videoModeIsCrt15k(videoModeCmdForScoringPath("480i", DisplaySink::Crt15k)));

    const auto clamp720 = clampDisplayToLiveGlass(LiveGlass::True480,
                                                  {1280, 720, "720p", 1500});
    CHECK(std::string(clamp720.label) == "480i");
    CHECK(videoModeCmdForDisplayLabel(clamp720.label) == kVideoModeCmd480i);
    CHECK(videoModeCmdForScoringPath(clamp720.label, DisplaySink::HdmiLcd) == nullptr);

    const auto clamp240 = clampDisplayToLiveGlass(LiveGlass::True480,
                                                  {320, 240, "240p", 1000});
    CHECK(std::string(clamp240.label) == "240p");
    CHECK(videoModeCmdForScoringPath(clamp240.label, DisplaySink::HdmiLcd) !=
          kVideoModeCmd240p);

    if (fails) {
        std::fprintf(stderr, "test_display_raster_policy: %d failures\n", fails);
        return 1;
    }
    std::printf("test_display_raster_policy: OK lcd240p=%s\n", lcd240);
    return 0;
}
