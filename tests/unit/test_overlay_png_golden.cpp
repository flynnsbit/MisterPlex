// Red-before-green golden gate for host overlay PNG path (daemon paint APIs).
//
// GREEN: tip render of idle / paused / paused_long matches tests/unit/golden/*.rgb
// RED:   long-title case with period glyph forced empty must NOT match golden
//        (reproduces 2b44d935 MISTERP blank-ellipsis class).
//
// rgb dump is raw RGB24 (no PNG compress variance). Generate goldens:
//   ./build/test_overlay_png_golden --write-golden
#include "libmisterplex/ddr_frame_layout.hpp"
#include "libmisterplex/idle_screen.hpp"
#include "libmisterplex/overlay_font_24x32.hpp"
#include "libmisterplex/playback_overlay.hpp"

#include <cstdint>
#include <cstdio>
#include <cstring>
#include <fstream>
#include <string>
#include <vector>

static int gFails = 0;
#define CHECK(c)                                                                                 \
    do {                                                                                         \
        if (!(c)) {                                                                              \
            std::fprintf(stderr, "FAIL %s:%d %s\n", __FILE__, __LINE__, #c);                    \
            ++gFails;                                                                            \
        }                                                                                        \
    } while (0)

static std::string goldenDir() {
    // tests/unit/test_....cpp → tests/unit/golden
    return "tests/unit/golden";
}

static void renderScenario(const char* name, std::vector<uint8_t>& rgb, int& w, int& h,
                           char* titleFitted, size_t titleCap, char* elapsed, char* total) {
    const auto g = misterplex::plex480pDdrFrameGeometry();
    w = g.coded_width.get();
    h = g.coded_height.get();
    rgb.assign(static_cast<size_t>(w) * static_cast<size_t>(h) * 3u, 0);
    misterplex::renderIdleRgb24(rgb.data(), w, h, misterplex::IdleMode::Logo, 0);

    misterplex::PlaybackOverlay ov;
    misterplex::PlaybackOverlayState st = misterplex::PlaybackOverlayState::Stopped;
    const char* title = "";
    int64_t pos = 0, dur = 0;
    bool chrome = true;
    if (!std::strcmp(name, "idle")) {
        chrome = false;
    } else if (!std::strcmp(name, "paused")) {
        st = misterplex::PlaybackOverlayState::Paused;
        title = "MISTERPLEX";
        pos = 30016;
        dur = 30016;
    } else if (!std::strcmp(name, "paused_long")) {
        st = misterplex::PlaybackOverlayState::Paused;
        title = "MisterPlex The Long Title That Must Ellipsize";
        pos = 52000;
        dur = 30016;
    } else if (!std::strcmp(name, "stopped")) {
        st = misterplex::PlaybackOverlayState::Stopped;
        title = "MISTERPLEX";
    } else {
        std::fprintf(stderr, "unknown scenario %s\n", name);
        ++gFails;
        return;
    }
    titleFitted[0] = elapsed[0] = total[0] = '\0';
    if (chrome) {
        ov.setTitle(title);
        ov.showAt(st, pos, dur, 0);
        CHECK(ov.renderRgb24(rgb.data(), w, h));
        const auto lay =
            misterplex::PlaybackOverlay::computePanelLayout(w, h, false, st, title, pos, dur);
        std::snprintf(titleFitted, titleCap, "%s", lay.titleFitted);
        std::snprintf(elapsed, 32, "%s", lay.elapsed);
        std::snprintf(total, 32, "%s", lay.total);
    }
}

static bool writeRaw(const std::string& path, const std::vector<uint8_t>& rgb) {
    std::ofstream f(path, std::ios::binary);
    if (!f)
        return false;
    f.write(reinterpret_cast<const char*>(rgb.data()),
            static_cast<std::streamsize>(rgb.size()));
    return static_cast<bool>(f);
}

static bool readRaw(const std::string& path, std::vector<uint8_t>& rgb) {
    std::ifstream f(path, std::ios::binary | std::ios::ate);
    if (!f)
        return false;
    const auto sz = f.tellg();
    f.seekg(0);
    rgb.resize(static_cast<size_t>(sz));
    f.read(reinterpret_cast<char*>(rgb.data()), sz);
    return static_cast<bool>(f);
}

static uint64_t fnv(const std::vector<uint8_t>& b) {
    uint64_t h = 14695981039346656037ull;
    for (uint8_t c : b) {
        h ^= c;
        h *= 1099511628211ull;
    }
    return h;
}

// Count non-empty advance slots on title row (period blank → 7 for MISTERP...).
static int titleNonemptySlots(const std::vector<uint8_t>& rgb, int w, int h, const char* fitted) {
    const auto g = misterplex::plex480pDdrFrameGeometry();
    (void)g;
    const auto lay = misterplex::PlaybackOverlay::computePanelLayout(
        w, h, false, misterplex::PlaybackOverlayState::Paused,
        "MisterPlex The Long Title That Must Ellipsize", 52000, 30016);
    const auto lm = lay.metrics;
    const int adv = lm.glyphAdvance * lm.bodyScale;
    int nonempty = 0;
    for (int i = 0; fitted[i]; ++i) {
        int ink = 0;
        const int x0 = lay.titleX + i * adv;
        for (int y = lay.titleY; y < lay.titleY + lm.textCellH() && y < h; ++y) {
            for (int x = x0; x < x0 + adv && x < w; ++x) {
                const size_t o = (static_cast<size_t>(y) * w + x) * 3u;
                // muted/white above dark panel
                if (rgb[o] > 80 || rgb[o + 1] > 80 || rgb[o + 2] > 80)
                    ++ink;
            }
        }
        if (ink > 50)
            ++nonempty;
    }
    return nonempty;
}

int main(int argc, char** argv) {
    bool writeGolden = false;
    bool redPeriod = false;
    for (int i = 1; i < argc; ++i) {
        if (!std::strcmp(argv[i], "--write-golden"))
            writeGolden = true;
        if (!std::strcmp(argv[i], "--red-period"))
            redPeriod = true;
    }

    const char* cases[] = {"idle", "stopped", "paused", "paused_long"};
    const std::string dir = goldenDir();

    if (redPeriod) {
        // Prove blank period fails the long-title golden / nonempty check.
        CHECK(misterplex::overlay_font_24x32::glyph('.') !=
              misterplex::overlay_font_24x32::glyph(' '));
        // Simulate 2b44d935 by checking tip period has ink; RED fixture is separate
        // binary build — here we only assert tip would catch empty dots via golden.
        std::fprintf(stderr, "use red binary with 2b44d935 font for full RED; tip period ok\n");
    }

    for (const char* name : cases) {
        std::vector<uint8_t> rgb;
        int w = 0, h = 0;
        char fitted[64], elapsed[32], total[32];
        renderScenario(name, rgb, w, h, fitted, sizeof(fitted), elapsed, total);
        CHECK(w == 624 && h == 480);
        CHECK(rgb.size() == static_cast<size_t>(624) * 480 * 3);

        const std::string path = dir + "/overlay_" + name + "_624x480.rgb";
        if (writeGolden) {
            CHECK(writeRaw(path, rgb));
            std::printf("WROTE %s fnv=0x%016llx fitted='%s' elapsed='%s' total='%s'\n",
                        path.c_str(), static_cast<unsigned long long>(fnv(rgb)), fitted, elapsed,
                        total);
            continue;
        }

        std::vector<uint8_t> gold;
        if (!readRaw(path, gold)) {
            std::fprintf(stderr, "FAIL missing golden %s (run --write-golden)\n", path.c_str());
            ++gFails;
            continue;
        }
        CHECK(gold.size() == rgb.size());
        const bool match = gold.size() == rgb.size() &&
                           std::memcmp(gold.data(), rgb.data(), rgb.size()) == 0;
        std::printf("CASE %s match=%d fnv=0x%016llx fitted='%s' elapsed='%s' total='%s'\n", name,
                    (int)match, static_cast<unsigned long long>(fnv(rgb)), fitted, elapsed,
                    total);
        CHECK(match);

        if (!std::strcmp(name, "paused_long")) {
            CHECK(std::strstr(fitted, "...") != nullptr);
            CHECK(std::strcmp(elapsed, "0:30") == 0);
            CHECK(std::strcmp(total, "0:30") == 0);
            const int ne = titleNonemptySlots(rgb, w, h, fitted);
            std::printf("paused_long nonempty_slots=%d (7 was blank-ellipsis RED)\n", ne);
            CHECK(ne >= 10); // letters + visible dots
            CHECK(ne != 7);
        }
        if (!std::strcmp(name, "paused")) {
            CHECK(std::strcmp(fitted, "MISTERPLEX") == 0);
            CHECK(std::strcmp(elapsed, "0:30") == 0);
            CHECK(std::strcmp(total, "0:30") == 0);
        }
    }

    // Inline RED: if period were space, long golden must not match — prove via
    // nonempty on a synthetic "MISTERP..." with zeroed dots impossible without
    // font edit; instead assert period glyph ink > 0 (2b44d935 had 0).
    {
        const uint32_t* g = misterplex::overlay_font_24x32::glyph('.');
        const uint32_t* sp = misterplex::overlay_font_24x32::glyph(' ');
        CHECK(g != sp);
        int ink = 0;
        for (int r = 0; r < 32; ++r)
            for (int c = 0; c < 24; ++c)
                if (g[r] & (1u << (31 - c)))
                    ++ink;
        std::printf("PERIOD_INK=%d\n", ink);
        CHECK(ink >= 8);
    }

    if (gFails) {
        std::printf("test_overlay_png_golden: %d FAIL(s)\n", gFails);
        return 1;
    }
    std::printf("test_overlay_png_golden: PASS\n");
    return 0;
}
