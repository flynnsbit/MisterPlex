// Unit: MiSTer.ini video_mode parse + content overlay canvas (SIZE A vs glass B).
#include "libmisterplex/mister_video_mode.hpp"
#include "libmisterplex/overlay_canvas.hpp"

#include <cstdio>
#include <cstdlib>
#include <fstream>
#include <string>

using namespace misterplex;

static int g_fails = 0;

#define CHECK(cond, msg)                                                         \
    do {                                                                         \
        if (!(cond)) {                                                           \
            std::fprintf(stderr, "FAIL %s:%d: %s\n", __FILE__, __LINE__, msg);   \
            ++g_fails;                                                           \
        }                                                                        \
    } while (0)

static std::string writeTempIni(const std::string& body) {
    const char* dir = std::getenv("TEST_TMPDIR");
    std::string base = dir && dir[0] ? std::string(dir) : std::string("build");
    static int n = 0;
    std::string path = base + "/test_mister_video_mode_" + std::to_string(n++) + ".ini";
    std::ofstream out(path);
    out << body;
    out.close();
    return path;
}

int main() {
    // --- preset table matches lab SoT (crt-lcd-matrix / display-resolution) ---
    {
        int w = 0, h = 0, hz = 0;
        CHECK(misterVideoModePreset(0, &w, &h, &hz), "preset0");
        CHECK(w == 1280 && h == 720 && hz == 60, "mode0=1280x720@60");
        CHECK(misterVideoModePreset(5, &w, &h, &hz), "preset5");
        CHECK(w == 800 && h == 600, "mode5=800x600");
        CHECK(misterVideoModePreset(7, &w, &h, &hz), "preset7");
        CHECK(w == 1280 && h == 720 && hz == 50, "mode7=720p50");
        CHECK(misterVideoModePreset(8, &w, &h, &hz), "preset8");
        CHECK(w == 1920 && h == 1080, "mode8=1080p");
    }

    // NEG: naive wrong table claimed mode0=640x480 — must not hold.
    {
        int w = 0, h = 0, hz = 0;
        misterVideoModePreset(0, &w, &h, &hz);
        CHECK(!(w == 640 && h == 480), "NEG mode0 is not 640x480");
    }

    // Lab: only [MiSTer] video_mode=0 → glass 1280x720, source ini:mister
    {
        const auto path = writeTempIni(
            "[MiSTer]\n"
            "direct_video=0\n"
            "vga_scaler=1\n"
            "video_mode=0\n");
        const auto m = loadMisterVideoModeFromIni(path);
        CHECK(m.ok, "mister section ok");
        CHECK(m.width == 1280 && m.height == 720, "mister mode0 geom");
        CHECK(m.index == 0, "mister index0");
        CHECK(m.source == "ini:mister", "source tag mister");
    }

    // [Plex] overrides [MiSTer]
    {
        const auto path = writeTempIni(
            "[MiSTer]\nvideo_mode=0\n"
            "[Plex]\nvideo_mode=5\n");
        const auto m = loadMisterVideoModeFromIni(path);
        CHECK(m.ok && m.width == 800 && m.height == 600, "plex overrides");
        CHECK(m.source == "ini:plex", "source plex");
    }

    // Missing → DEFAULT_ASSUMED path (ok=false)
    {
        const auto path = writeTempIni("[Something]\nfoo=1\n");
        const auto m = loadMisterVideoModeFromIni(path);
        CHECK(!m.ok, "missing video_mode → not ok");
    }

    // Unreadable path
    {
        const auto m = loadMisterVideoModeFromIni("/no/such/misterplex_ini_path");
        CHECK(!m.ok, "missing file");
    }

    // --- content canvas (SIZE A) ---
    {
        const auto floor = resolveOverlayCanvas(0, 0, 0, 0);
        CHECK(floor.width == 624 && floor.height == 480, "floor480");
        CHECK(std::string(floor.source) == "floor480", "floor src");
    }
    {
        const auto c = resolveOverlayCanvas(0, 0, 1280, 720);
        CHECK(c.width == 1280 && c.height == 720, "couple 1280");
        CHECK(std::string(c.source) == "couple", "couple src");
    }
    {
        const auto c = resolveOverlayCanvas(960, 540, 1280, 720);
        CHECK(c.width == 960 && c.height == 540, "applied wins");
        CHECK(std::string(c.source) == "applied", "applied src");
    }

    // NEG: glass 720p must not force bank canvas without couple/applied
    {
        MisterVideoMode glass;
        glass.ok = true;
        glass.width = 1280;
        glass.height = 720;
        glass.index = 0;
        glass.source = "ini:mister";
        const auto bank = resolveOverlayCanvas(0, 0, 0, 0);
        CHECK(bank.width == 624 && bank.height == 480, "bank stays floor under glass720");
        CHECK(glassMustNotDriveBankCanvas(glass, bank), "glass≠bank policy");
        const auto tag = overlayCanvasLogTag(bank, glass);
        CHECK(tag.find("authoring=624x480") != std::string::npos, "tag authoring bank");
        CHECK(tag.find("output=1280x720") != std::string::npos, "tag glass output");
        CHECK(tag.find("DEFAULT_ASSUMED") == std::string::npos, "not assumed when glass ok");
    }

    // DEFAULT_ASSUMED tag when glass fails
    {
        MisterVideoMode glass;
        const auto bank = resolveOverlayCanvas(0, 0, 0, 0);
        const auto tag = overlayCanvasLogTag(bank, glass);
        CHECK(tag.find("DEFAULT_ASSUMED") != std::string::npos, "assumed tag");
        CHECK(tag.find("mode=?") != std::string::npos, "mode=?");
    }

    // 720 content couple → authoring 1280 (the real product target)
    {
        const auto bank = resolveOverlayCanvas(0, 0, 1280, 720);
        CHECK(overlayBodyScaleForCanvas(bank.height) >= 2, "scale>=2 @720");
        MisterVideoMode glass = parseMisterVideoModeValue("0");
        CHECK(glass.ok && glass.width == 1280, "parse 0");
        const auto tag = overlayCanvasLogTag(bank, glass);
        CHECK(tag.find("authoring=1280x720") != std::string::npos, "authoring content720");
    }

    // NEG odd dims illegal
    CHECK(!overlayCanvasDimsLegal(625, 480), "odd w illegal");
    CHECK(!overlayCanvasDimsLegal(1280, 719), "odd h illegal");

    if (g_fails) {
        std::fprintf(stderr, "%d checks failed\n", g_fails);
        return 1;
    }
    std::puts("test_mister_video_mode OK");
    return 0;
}
