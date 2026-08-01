#include "libmisterplex/mister_video_mode.hpp"

#include <cstdio>
#include <cstdlib>
#include <fstream>
#include <string>

static int fails = 0;
#define CHECK(c)                                                                                 \
    do {                                                                                         \
        if (!(c)) {                                                                              \
            std::fprintf(stderr, "FAIL %s:%d %s\n", __FILE__, __LINE__, #c);                    \
            ++fails;                                                                             \
        }                                                                                        \
    } while (0)

int main() {
    using namespace misterplex;

    // Preset 12 = device daily driver (parent-measured).
    {
        const auto m = parseMisterVideoModeValue("12");
        CHECK(m.ok);
        CHECK(m.width == 1920);
        CHECK(m.height == 1440);
        CHECK(m.index == 12);
    }
    {
        const auto m = parseMisterVideoModeValue("8");
        CHECK(m.ok && m.width == 1920 && m.height == 1080);
    }
    {
        const auto m = parseMisterVideoModeValue("5");
        CHECK(m.ok && m.width == 800 && m.height == 600);
    }
    {
        const auto m = parseMisterVideoModeValue("6");
        CHECK(m.ok && m.width == 640 && m.height == 480);
    }
    {
        const auto m = parseMisterVideoModeValue("1920x1440@60");
        CHECK(m.ok && m.width == 1920 && m.height == 1440 && m.refresh == 60);
    }
    {
        const auto m = parseMisterVideoModeValue("1920,1440,60,cvtrb");
        CHECK(m.ok && m.width == 1920 && m.height == 1440);
    }
    {
        const auto m = parseMisterVideoModeValue("999");
        CHECK(!m.ok);
    }

    // Ini [Plex] section wins over [MiSTer]
    {
        const char* path = "build/test_mister_ini_plex.ini";
        std::system("mkdir -p build");
        {
            std::ofstream o(path);
            o << "[MiSTer]\nvideo_mode=8\n\n[Plex]\n"
                 "video_mode=12\nvideo_mode_ntsc=12\nfb_terminal=0\n";
        }
        const auto m = loadMisterVideoModeFromIni(path);
        CHECK(m.ok);
        CHECK(m.width == 1920 && m.height == 1440 && m.index == 12);
        CHECK(m.source == "ini:plex");
    }
    // Parent lab: only [MiSTer] video_mode=8 (was source=none / DEFAULT_ASSUMED)
    {
        const char* path = "build/test_mister_ini_mister_only.ini";
        {
            std::ofstream o(path);
            o << "[MiSTer]\nvideo_mode=8\nvideo_mode_ntsc=8\n";
        }
        const auto m = loadMisterVideoModeFromIni(path);
        CHECK(m.ok);
        CHECK(m.width == 1920 && m.height == 1080 && m.index == 8);
        CHECK(m.source == "ini:mister");
    }
    // Empty → not ok (DEFAULT_ASSUMED path)
    {
        const char* path = "build/test_mister_ini_empty.ini";
        {
            std::ofstream o(path);
            o << "[Plex]\nfb_terminal=0\n";
        }
        const auto m = loadMisterVideoModeFromIni(path);
        CHECK(!m.ok);
    }

    // Output layout §4
    {
        const auto L = computeOutputChromeLayout(1920, 1440);
        CHECK(L.bodyScale == 6);
        CHECK(L.advancePx == 78);
        CHECK(L.useLargeFont);
    }
    {
        const auto L = computeOutputChromeLayout(640, 480);
        CHECK(L.bodyScale == 2);
        CHECK(L.advancePx == 26);
    }
    {
        const auto L = computeOutputChromeLayout(320, 240);
        CHECK(L.bodyScale == 2);
        CHECK(L.advancePx == 18); // 8x13 * 2
        CHECK(!L.useLargeFont);
    }

    if (fails) {
        std::fprintf(stderr, "test_mister_video_mode: %d FAIL\n", fails);
        return 1;
    }
    std::printf("test_mister_video_mode: OK\n");
    return 0;
}
