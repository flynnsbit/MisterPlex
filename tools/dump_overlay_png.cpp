// Host-only overlay self-check using the SAME paint APIs as misterplexd:
//   paintIdle:      plex480pDdrFrameGeometry → renderIdleRgb24 → overlay_.renderRgb24
//   pause overlay:  same geometry → fill dark → overlay_.renderRgb24
//                   (daemon uses renderYuv420p; draw path is shared paint())
// Not a reimplementation of glyphs — includes playback_overlay.hpp + idle_screen.hpp.
//
// Usage:
//   make "$PWD/build/dump_overlay_png"
//   ./build/dump_overlay_png OUT.png --scenario idle|paused|paused_long|stopped
//   echo "true rc=$?"
#include "libmisterplex/ddr_frame_layout.hpp"
#include "libmisterplex/idle_screen.hpp"
#include "libmisterplex/mister_video_mode.hpp"
#include "libmisterplex/playback_overlay.hpp"

#include <cstdint>
#include <cstdlib>
#include <cstdio>
#include <cstring>
#include <string>
#include <vector>
#include <zlib.h>

static void die(const char* m) {
    std::fprintf(stderr, "dump_overlay_png: %s\n", m);
    std::exit(2);
}

static bool writePngRgb8(const char* path, const uint8_t* rgb, int w, int h) {
    if (!path || !rgb || w <= 0 || h <= 0)
        return false;
    FILE* f = std::fopen(path, "wb");
    if (!f)
        return false;
    const uint8_t sig[8] = {137, 80, 78, 71, 13, 10, 26, 10};
    std::fwrite(sig, 1, 8, f);
    auto be32 = [](uint32_t v, uint8_t o[4]) {
        o[0] = static_cast<uint8_t>((v >> 24) & 0xff);
        o[1] = static_cast<uint8_t>((v >> 16) & 0xff);
        o[2] = static_cast<uint8_t>((v >> 8) & 0xff);
        o[3] = static_cast<uint8_t>(v & 0xff);
    };
    auto chunk = [&](const char* type, const uint8_t* data, size_t n) {
        uint8_t len[4], crcbuf[4];
        be32(static_cast<uint32_t>(n), len);
        std::fwrite(len, 1, 4, f);
        std::fwrite(type, 1, 4, f);
        if (n)
            std::fwrite(data, 1, n, f);
        std::vector<uint8_t> forcrc(4 + n);
        std::memcpy(forcrc.data(), type, 4);
        if (n)
            std::memcpy(forcrc.data() + 4, data, n);
        const uint32_t c = crc32(0L, forcrc.data(), static_cast<uInt>(forcrc.size()));
        be32(c, crcbuf);
        std::fwrite(crcbuf, 1, 4, f);
    };
    uint8_t ihdr[13];
    be32(static_cast<uint32_t>(w), ihdr + 0);
    be32(static_cast<uint32_t>(h), ihdr + 4);
    ihdr[8] = 8;
    ihdr[9] = 2;
    ihdr[10] = ihdr[11] = ihdr[12] = 0;
    chunk("IHDR", ihdr, 13);
    std::vector<uint8_t> raw(static_cast<size_t>(h) * (1 + static_cast<size_t>(w) * 3));
    for (int y = 0; y < h; ++y) {
        raw[static_cast<size_t>(y) * (1 + static_cast<size_t>(w) * 3)] = 0;
        std::memcpy(raw.data() + static_cast<size_t>(y) * (1 + static_cast<size_t>(w) * 3) + 1,
                    rgb + static_cast<size_t>(y) * static_cast<size_t>(w) * 3,
                    static_cast<size_t>(w) * 3);
    }
    uLongf zlen = compressBound(static_cast<uLong>(raw.size()));
    std::vector<uint8_t> zbuf(zlen);
    if (compress2(zbuf.data(), &zlen, raw.data(), static_cast<uLong>(raw.size()), 9) != Z_OK) {
        std::fclose(f);
        return false;
    }
    chunk("IDAT", zbuf.data(), zlen);
    chunk("IEND", nullptr, 0);
    std::fclose(f);
    return true;
}

// Mirror media_player.cpp overlayOutputGeomTag provenance labels (not HDMI measure).
static std::string outputGeomTag() {
    misterplex::MisterVideoMode mode;
    if (const char* p = std::getenv("MISTERPLEX_MISTER_INI")) {
        if (p[0])
            mode = misterplex::loadMisterVideoModeFromIni(p);
    } else {
        mode = misterplex::loadMisterVideoMode();
    }
    constexpr const char* kAuth = " authoring=624x480";
    if (!mode.ok)
        return std::string(" output=DEFAULT_ASSUMED mode=? source=none") + kAuth;
    const std::string src = mode.source.empty() ? std::string("ini") : mode.source;
    return std::string(" output=") + std::to_string(mode.width) + "x" +
           std::to_string(mode.height) + " mode=" +
           (mode.index >= 0 ? std::to_string(mode.index) : std::string("custom")) +
           " source=" + src + kAuth;
}

enum class Scenario { Idle, Stopped, Paused, PausedLong };

static Scenario parseScenario(const char* s) {
    if (!s || !std::strcmp(s, "idle"))
        return Scenario::Idle;
    if (!std::strcmp(s, "stopped"))
        return Scenario::Stopped;
    if (!std::strcmp(s, "paused"))
        return Scenario::Paused;
    if (!std::strcmp(s, "paused_long"))
        return Scenario::PausedLong;
    die("scenario must be idle|stopped|paused|paused_long");
    return Scenario::Idle;
}

int main(int argc, char** argv) {
    const char* out = "overlay_selfcheck.png";
    Scenario sc = Scenario::Idle;
    for (int i = 1; i < argc; ++i) {
        if (!std::strcmp(argv[i], "--help")) {
            std::printf("dump_overlay_png OUT.png --scenario idle|stopped|paused|paused_long\n");
            return 0;
        }
        if (!std::strcmp(argv[i], "--scenario")) {
            if (i + 1 >= argc)
                die("--scenario needs arg");
            sc = parseScenario(argv[++i]);
            continue;
        }
        if (argv[i][0] != '-')
            out = argv[i];
        else
            die("unknown flag");
    }

    // Exact daemon geometry source (paintIdle / publishPausedOverlayFrame).
    const auto g = misterplex::plex480pDdrFrameGeometry();
    const int cw = g.coded_width.get();
    const int ch = g.coded_height.get();
    if (cw != 624 || ch != 480)
        die("unexpected plex480pDdrFrameGeometry (expect 624x480)");

    std::vector<uint8_t> rgb(static_cast<size_t>(cw) * static_cast<size_t>(ch) * 3u, 0);

    // IDLE_SCREEN=logo product default → IdleMode::Logo
    misterplex::renderIdleRgb24(rgb.data(), cw, ch, misterplex::IdleMode::Logo, 0);

    misterplex::PlaybackOverlay ov;
    const char* title = "MISTERPLEX";
    misterplex::PlaybackOverlayState st = misterplex::PlaybackOverlayState::Stopped;
    int64_t pos = 0, dur = 0;
    int chrome = 0;
    switch (sc) {
    case Scenario::Idle:
        // logo only — no transport chrome (chrome=0 in idle log when !visible)
        break;
    case Scenario::Stopped:
        st = misterplex::PlaybackOverlayState::Stopped;
        title = "MISTERPLEX";
        chrome = 1;
        break;
    case Scenario::Paused:
        st = misterplex::PlaybackOverlayState::Paused;
        title = "MISTERPLEX";
        pos = 30016;
        dur = 30016;
        chrome = 1;
        break;
    case Scenario::PausedLong:
        st = misterplex::PlaybackOverlayState::Paused;
        title = "MisterPlex The Long Title That Must Ellipsize";
        pos = 52000; // wall overrun — elapsed must clamp to 0:30
        dur = 30016;
        chrome = 1;
        break;
    }

    if (chrome) {
        ov.setTitle(title);
        ov.showAt(st, pos, dur, /*nowMs*/ 0);
        // Same entry as paintIdle composite (daemon pause uses YUV twin of this paint).
        if (!ov.renderRgb24(rgb.data(), cw, ch))
            std::fprintf(stderr, "dump_overlay_png: renderRgb24 false (dirty empty?)\n");
    }

    const auto lm = misterplex::PlaybackOverlay::layoutMetrics(cw, ch);
    const char* font = lm.fontId == misterplex::OverlayFontId::Hires24x32   ? "24x32"
                       : lm.fontId == misterplex::OverlayFontId::Large12x16 ? "12x16"
                                                                            : "8x13";
    // Daemon-shaped log line (authoring bank + output provenance).
    std::printf("media: dump overlay canvas=%dx%d font=%s cell=%dx%d scale=%d chrome=%d%s plane=0\n",
                cw, ch, font, lm.textCellW(), lm.textCellH(), lm.bodyScale, chrome,
                outputGeomTag().c_str());

    if (chrome) {
        const auto lay = misterplex::PlaybackOverlay::computePanelLayout(cw, ch, false, st, title,
                                                                         pos, dur);
        std::printf("title_fitted='%s' secondLine=%d elapsed='%s' total='%s'\n", lay.titleFitted,
                    (int)lay.titleSecondLine, lay.elapsed, lay.total);
    }

    // PREREG tip Hires24x32@2
    if (lm.fontId != misterplex::OverlayFontId::Hires24x32 || lm.bodyScale != 2) {
        std::fprintf(stderr, "dump_overlay_png: unexpected font (want 24x32@2)\n");
        return 1;
    }

    if (!writePngRgb8(out, rgb.data(), cw, ch))
        die("png write failed");
    std::printf("wrote %s\n", out);
    return 0;
}
