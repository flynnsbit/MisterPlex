// Host-only overlay self-check: render PlaybackOverlay (+ optional idle chevron)
// at bank 624x480 to a PNG. No device. Parent reviews layout without grabber.
//
// Usage:
//   make "$PWD/build/dump_overlay_png"
//   ./build/dump_overlay_png out.png
//   ./build/dump_overlay_png out.png --state paused --title 'Big Buck Bunny' \
//       --pos-ms 30016 --dur-ms 30016 --idle
//   echo "true rc=$?"
#include "libmisterplex/playback_overlay.hpp"
#include "libmisterplex/idle_screen.hpp"

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

// Minimal RGB8 PNG writer (IHDR/IDAT/IEND).
static bool writePngRgb8(const char* path, const uint8_t* rgb, int w, int h) {
    if (!path || !rgb || w <= 0 || h <= 0)
        return false;
    FILE* f = std::fopen(path, "wb");
    if (!f)
        return false;
    const uint8_t sig[8] = {137, 80, 78, 71, 13, 10, 26, 10};
    std::fwrite(sig, 1, 8, f);

    auto crc32b = [](const uint8_t* p, size_t n) -> uint32_t {
        return crc32(0L, p, static_cast<uInt>(n));
    };
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
        be32(crc32b(forcrc.data(), forcrc.size()), crcbuf);
        std::fwrite(crcbuf, 1, 4, f);
    };

    uint8_t ihdr[13];
    be32(static_cast<uint32_t>(w), ihdr + 0);
    be32(static_cast<uint32_t>(h), ihdr + 4);
    ihdr[8] = 8;  // bit depth
    ihdr[9] = 2;  // RGB
    ihdr[10] = 0;
    ihdr[11] = 0;
    ihdr[12] = 0;
    chunk("IHDR", ihdr, 13);

    // filter0 + RGB rows, zlib compress
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

static misterplex::PlaybackOverlayState parseState(const char* s) {
    if (!s)
        return misterplex::PlaybackOverlayState::Stopped;
    if (!std::strcmp(s, "paused") || !std::strcmp(s, "PAUSED"))
        return misterplex::PlaybackOverlayState::Paused;
    if (!std::strcmp(s, "playing") || !std::strcmp(s, "PLAYING"))
        return misterplex::PlaybackOverlayState::Playing;
    return misterplex::PlaybackOverlayState::Stopped;
}

int main(int argc, char** argv) {
    const char* out = "overlay_selfcheck.png";
    const char* title = "MISTERPLEX";
    const char* stateS = "stopped";
    int64_t pos = 0, dur = 0;
    int w = 624, h = 480;
    bool idle = false;
    bool longTitle = false;

    for (int i = 1; i < argc; ++i) {
        if (!std::strcmp(argv[i], "--help")) {
            std::printf("dump_overlay_png OUT.png [--idle] [--state stopped|paused|playing]\n"
                        "  [--title STR] [--long-title] [--pos-ms N] [--dur-ms N]\n"
                        "  [--w N] [--h N]\n");
            return 0;
        }
        if (argv[i][0] != '-') {
            out = argv[i];
            continue;
        }
        auto need = [&](const char* flag) -> const char* {
            if (i + 1 >= argc)
                die(flag);
            return argv[++i];
        };
        if (!std::strcmp(argv[i], "--title"))
            title = need("--title");
        else if (!std::strcmp(argv[i], "--state"))
            stateS = need("--state");
        else if (!std::strcmp(argv[i], "--pos-ms"))
            pos = std::atoll(need("--pos-ms"));
        else if (!std::strcmp(argv[i], "--dur-ms"))
            dur = std::atoll(need("--dur-ms"));
        else if (!std::strcmp(argv[i], "--w"))
            w = std::atoi(need("--w"));
        else if (!std::strcmp(argv[i], "--h"))
            h = std::atoi(need("--h"));
        else if (!std::strcmp(argv[i], "--idle"))
            idle = true;
        else if (!std::strcmp(argv[i], "--long-title"))
            longTitle = true;
        else
            die("unknown flag");
    }
    if (longTitle)
        title = "MisterPlex The Long Title That Must Ellipsize";

    if (w <= 0 || h <= 0 || (w & 1) || (h & 1))
        die("w/h must be positive even");

    std::vector<uint8_t> rgb(static_cast<size_t>(w) * static_cast<size_t>(h) * 3u, 0);
    if (idle) {
        misterplex::renderIdleRgb24(rgb.data(), w, h, misterplex::IdleMode::Logo, 0);
    } else {
        // studio-ish dark field
        for (size_t i = 0; i < rgb.size(); i += 3) {
            rgb[i] = 16;
            rgb[i + 1] = 16;
            rgb[i + 2] = 20;
        }
    }

    misterplex::PlaybackOverlay ov;
    ov.setTitle(title);
    ov.showAt(parseState(stateS), pos, dur, /*now*/ 0);
    if (!ov.renderRgb24At(rgb.data(), w, h, 0)) {
        // still write canvas (idle alone)
        std::fprintf(stderr, "dump_overlay_png: renderRgb24At returned false (empty dirty?)\n");
    }

    auto lm = misterplex::PlaybackOverlay::layoutMetrics(w, h);
    auto lay = misterplex::PlaybackOverlay::computePanelLayout(
        w, h, false, parseState(stateS), title, pos, dur);
    const char* font = lm.fontId == misterplex::OverlayFontId::Hires24x32 ? "24x32"
                       : lm.fontId == misterplex::OverlayFontId::Large12x16 ? "12x16"
                                                                           : "8x13";
    std::printf("canvas=%dx%d font=%s cell=%dx%d scale=%d\n", w, h, font, lm.textCellW(),
                lm.textCellH(), lm.bodyScale);
    std::printf("title_fitted='%s' secondLine=%d titleMaxW=%d panel=%dx%d@%d,%d\n",
                lay.titleFitted, (int)lay.titleSecondLine, lay.titleMaxW, lay.panel.w,
                lay.panel.h, lay.panel.x, lay.panel.y);
    std::printf("elapsed='%s' total='%s'\n", lay.elapsed, lay.total);

    if (!writePngRgb8(out, rgb.data(), w, h))
        die("png write failed");
    std::printf("wrote %s\n", out);
    return 0;
}
