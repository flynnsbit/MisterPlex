#include "libmisterplex/display_raster.hpp"
#include "libmisterplex/osd_menu.hpp"

#include <cstdio>
#include <cstring>
#include <string>
#include <unistd.h>

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

    CHECK(!displayRasterApplyOnOsdChange());
    CHECK(contentResApplyOnOsdChange());
    CHECK(displayRasterApplyOnStartup());

    CHECK(std::strcmp(videoModeCmdForDisplayLabel("240p"), kVideoModeCmd240p) == 0);
    CHECK(std::strcmp(videoModeCmdForDisplayLabel("480p"), kVideoModeCmd480p) == 0);
    CHECK(std::strcmp(videoModeCmdForDisplayLabel("720p"), kVideoModeCmd720p) == 0);
    CHECK(videoModeCmdForDisplayLabel("Follow") == nullptr);
    CHECK(videoModeCmdForDisplayLabel(nullptr) == nullptr);

    CHECK(videoModePixelKhz(kVideoModeCmd240p) == 25175);
    CHECK(videoModePixelKhz(kVideoModeCmd480p) == 40000);
    CHECK(videoModePixelKhz(kVideoModeCmd720p) == 74250);
    CHECK(videoModePixelKhz(kVideoModeCmd240p) >= kVgaMinPixelKhz);
    CHECK(videoModePixelKhz(kVideoModeCmd480p) >= kVgaMinPixelKhz);
    CHECK(videoModePixelKhz(kVideoModeCmd720p) >= kVgaMinPixelKhz);

    CHECK(videoModeCmdIsSafe(kVideoModeCmd240p));
    CHECK(videoModeCmdIsSafe(kVideoModeCmd480p));
    CHECK(videoModeCmdIsSafe(kVideoModeCmd720p));
    CHECK(!videoModeCmdIsSafe("video_mode 0"));
    CHECK(!videoModeCmdIsSafe("load_core x"));
    CHECK(!videoModeCmdIsSafe(nullptr));

    CHECK(std::string(resolutionFromLabel("240p").label) == "240p");
    CHECK(resolutionFromLabel("240p").width == 320);
    CHECK(resolutionFromLabel("480p").width == 640);
    CHECK(resolutionFromLabel("720p").width == 1280);

    char tmpl[] = "/tmp/misterplex-cmd-XXXXXX";
    const int fd = ::mkstemp(tmpl);
    CHECK(fd >= 0);
    if (fd >= 0)
        ::close(fd);
    CHECK(writeMisterCmdLine(tmpl, kVideoModeCmd240p) == 1);
    CHECK(writeMisterCmdLine(tmpl, "load_core x") == 0);

    if (fails) {
        std::fprintf(stderr, "test_display_raster: %d FAILURES\n", fails);
        return 1;
    }
    std::printf("test_display_raster: OK\n");
    return 0;
}
