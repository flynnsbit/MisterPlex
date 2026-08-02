// Host overlay self-check — SAME APIs as misterplexd paintIdle / pause chrome:
//   plex480pDdrFrameGeometry (product bank) OR explicit W×H
//   renderIdleRgb24(IdleMode::Logo)  // IDLE_SCREEN=logo default — do not change product conf
//   PlaybackOverlay::renderRgb24 / setOutputRasterLayout
//
// NOT device verification: no ascal, no DDR, no HDMI. Optional --nn-scale is a
// crude nearest-neighbor stand-in for "bank stretched to mode" and is labelled.
//
// Usage:
//   make "$PWD/build/dump_overlay_png"
//   ./build/dump_overlay_png OUT.png --scenario paused --path bank
//   ./build/dump_overlay_png OUT.png --scenario paused --path bank --nn-scale 1920x1080
//   ./build/dump_overlay_png OUT.png --scenario paused --path output --size 1920x1080
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
    FILE* f = std::fopen(path, "wb");
    if (!f)
        return false;
    const uint8_t sig[8] = {137, 80, 78, 71, 13, 10, 26, 10};
    std::fwrite(sig, 1, 8, f);
    auto be32 = [](uint32_t v, uint8_t o[4]) {
        o[0] = uint8_t((v >> 24) & 0xff);
        o[1] = uint8_t((v >> 16) & 0xff);
        o[2] = uint8_t((v >> 8) & 0xff);
        o[3] = uint8_t(v & 0xff);
    };
    auto chunk = [&](const char* type, const uint8_t* data, size_t n) {
        uint8_t len[4], crcbuf[4];
        be32(uint32_t(n), len);
        std::fwrite(len, 1, 4, f);
        std::fwrite(type, 1, 4, f);
        if (n)
            std::fwrite(data, 1, n, f);
        std::vector<uint8_t> forcrc(4 + n);
        std::memcpy(forcrc.data(), type, 4);
        if (n)
            std::memcpy(forcrc.data() + 4, data, n);
        be32(crc32(0L, forcrc.data(), uInt(forcrc.size())), crcbuf);
        std::fwrite(crcbuf, 1, 4, f);
    };
    uint8_t ihdr[13];
    be32(uint32_t(w), ihdr);
    be32(uint32_t(h), ihdr + 4);
    ihdr[8] = 8;
    ihdr[9] = 2;
    ihdr[10] = ihdr[11] = ihdr[12] = 0;
    chunk("IHDR", ihdr, 13);
    std::vector<uint8_t> raw(size_t(h) * (1 + size_t(w) * 3));
    for (int y = 0; y < h; ++y) {
        raw[size_t(y) * (1 + size_t(w) * 3)] = 0;
        std::memcpy(raw.data() + size_t(y) * (1 + size_t(w) * 3) + 1,
                    rgb + size_t(y) * size_t(w) * 3, size_t(w) * 3);
    }
    uLongf zlen = compressBound(uLong(raw.size()));
    std::vector<uint8_t> zbuf(zlen);
    if (compress2(zbuf.data(), &zlen, raw.data(), uLong(raw.size()), 9) != Z_OK) {
        std::fclose(f);
        return false;
    }
    chunk("IDAT", zbuf.data(), zlen);
    chunk("IEND", nullptr, 0);
    std::fclose(f);
    return true;
}

static void nnScale(const uint8_t* src, int sw, int sh, uint8_t* dst, int dw, int dh) {
    for (int y = 0; y < dh; ++y) {
        const int sy = std::min(sh - 1, y * sh / dh);
        for (int x = 0; x < dw; ++x) {
            const int sx = std::min(sw - 1, x * sw / dw);
            const size_t si = (size_t(sy) * sw + sx) * 3;
            const size_t di = (size_t(y) * dw + x) * 3;
            dst[di] = src[si];
            dst[di + 1] = src[si + 1];
            dst[di + 2] = src[si + 2];
        }
    }
}

static std::string outputGeomTag() {
    misterplex::MisterVideoMode mode;
    if (const char* p = std::getenv("MISTERPLEX_MISTER_INI")) {
        if (p[0])
            mode = misterplex::loadMisterVideoModeFromIni(p);
    } else {
        mode = misterplex::loadMisterVideoMode();
    }
    if (!mode.ok)
        return " output=DEFAULT_ASSUMED mode=? source=none authoring=BANK";
    const std::string src = mode.source.empty() ? "ini" : mode.source;
    return " output=" + std::to_string(mode.width) + "x" + std::to_string(mode.height) +
           " mode=" + (mode.index >= 0 ? std::to_string(mode.index) : "custom") +
           " source=" + src + " authoring=BANK";
}

enum class Scenario { Idle, Stopped, Paused, PausedLong };

static Scenario parseSc(const char* s) {
    if (!s || !std::strcmp(s, "idle"))
        return Scenario::Idle;
    if (!std::strcmp(s, "stopped"))
        return Scenario::Stopped;
    if (!std::strcmp(s, "paused"))
        return Scenario::Paused;
    if (!std::strcmp(s, "paused_long"))
        return Scenario::PausedLong;
    die("--scenario idle|stopped|paused|paused_long");
    return Scenario::Idle;
}

int main(int argc, char** argv) {
    const char* out = "overlay.png";
    Scenario sc = Scenario::Paused;
    // bank = product plane=0 path (compute metrics). output = plane=1 metrics (NOT shipping).
    bool outputPath = false;
    int aw = 0, ah = 0; // authoring size; 0 → product bank
    int nw = 0, nh = 0; // optional NN scale after author
    // before = force Large12x16-class via output metrics at bank size (pre-hires look)
    bool beforeProxy = false;

    for (int i = 1; i < argc; ++i) {
        if (!std::strcmp(argv[i], "--help")) {
            std::printf(
                "dump_overlay_png OUT.png --scenario idle|stopped|paused|paused_long\n"
                "  [--path bank|output] [--size WxH] [--nn-scale WxH] [--before-12x16]\n"
                "LABELS:\n"
                "  path=bank   product plane=0 (real daemon authoring)\n"
                "  path=output plane=1 metrics (HYPOTHETICAL — chromePlaneHw false)\n"
                "  --nn-scale  SIMULATED stretch only — NOT ascal/device\n"
                "  --before-12x16  bank-size render with output-layout 12x16 (pre-hires proxy)\n");
            return 0;
        }
        auto need = [&](const char* f) -> const char* {
            if (i + 1 >= argc)
                die(f);
            return argv[++i];
        };
        if (!std::strcmp(argv[i], "--scenario"))
            sc = parseSc(need("--scenario"));
        else if (!std::strcmp(argv[i], "--path")) {
            const char* p = need("--path");
            if (!std::strcmp(p, "output"))
                outputPath = true;
            else if (!std::strcmp(p, "bank"))
                outputPath = false;
            else
                die("--path bank|output");
        } else if (!std::strcmp(argv[i], "--size")) {
            if (std::sscanf(need("--size"), "%dx%d", &aw, &ah) != 2 || aw <= 0 || ah <= 0)
                die("--size WxH");
        } else if (!std::strcmp(argv[i], "--nn-scale")) {
            if (std::sscanf(need("--nn-scale"), "%dx%d", &nw, &nh) != 2 || nw <= 0 || nh <= 0)
                die("--nn-scale WxH");
        } else if (!std::strcmp(argv[i], "--before-12x16"))
            beforeProxy = true;
        else if (argv[i][0] != '-')
            out = argv[i];
        else
            die("unknown flag");
    }

    if (aw <= 0 || ah <= 0) {
        const auto g = misterplex::plex480pDdrFrameGeometry();
        aw = g.coded_width.get();
        ah = g.coded_height.get();
    }
    if ((aw & 1) || (ah & 1))
        die("authoring size must be even");

    // --before-12x16: use output-layout metrics at bank size → 12x16@2 (pre-hires class)
    if (beforeProxy)
        outputPath = true;

    std::vector<uint8_t> rgb(size_t(aw) * size_t(ah) * 3u, 0);
    misterplex::renderIdleRgb24(rgb.data(), aw, ah, misterplex::IdleMode::Logo, 0);

    misterplex::PlaybackOverlay ov;
    ov.setOutputRasterLayout(outputPath);
    const char* title = "MISTERPLEX";
    auto st = misterplex::PlaybackOverlayState::Stopped;
    int64_t pos = 0, dur = 0;
    int chrome = 0;
    switch (sc) {
    case Scenario::Idle:
        break;
    case Scenario::Stopped:
        chrome = 1;
        title = "MISTERPLEX";
        st = misterplex::PlaybackOverlayState::Stopped;
        break;
    case Scenario::Paused:
        chrome = 1;
        title = "MISTERPLEX";
        st = misterplex::PlaybackOverlayState::Paused;
        pos = 30016;
        dur = 30016;
        break;
    case Scenario::PausedLong:
        chrome = 1;
        title = "MisterPlex The Long Title That Must Ellipsize";
        st = misterplex::PlaybackOverlayState::Paused;
        pos = 52000;
        dur = 30016;
        break;
    }
    if (chrome) {
        ov.setTitle(title);
        ov.showAt(st, pos, dur, 0);
        if (!ov.renderRgb24(rgb.data(), aw, ah))
            std::fprintf(stderr, "dump_overlay_png: renderRgb24 false\n");
    }

    const auto lm = misterplex::OverlayLayoutMetrics::resolve(aw, ah, outputPath);
    const char* font = lm.fontId == misterplex::OverlayFontId::Hires24x32   ? "24x32"
                       : lm.fontId == misterplex::OverlayFontId::Large12x16 ? "12x16"
                                                                            : "8x13";
    const char* pathLab = beforeProxy ? "BEFORE_PROXY_12x16"
                          : outputPath  ? "OUTPUT_METRICS_NOT_SHIPPING"
                                        : "BANK_PRODUCT_PLANE0";
    std::printf("HOST_RENDER path=%s canvas=%dx%d font=%s cell=%dx%d scale=%d chrome=%d%s\n",
                pathLab, aw, ah, font, lm.textCellW(), lm.textCellH(), lm.bodyScale, chrome,
                outputGeomTag().c_str());
    std::printf("SCOPE: host CPU composite only. NOT device. NOT ascal. NOT DDR. NOT HDMI.\n");
    if (chrome) {
        const auto lay =
            misterplex::PlaybackOverlay::computePanelLayout(aw, ah, outputPath, st, title, pos, dur);
        std::printf("title_fitted='%s' secondLine=%d elapsed='%s' total='%s'\n", lay.titleFitted,
                    int(lay.titleSecondLine), lay.elapsed, lay.total);
    }

    const uint8_t* outRgb = rgb.data();
    int ow = aw, oh = ah;
    std::vector<uint8_t> scaled;
    if (nw > 0 && nh > 0) {
        scaled.assign(size_t(nw) * size_t(nh) * 3u, 0);
        nnScale(rgb.data(), aw, ah, scaled.data(), nw, nh);
        outRgb = scaled.data();
        ow = nw;
        oh = nh;
        std::printf("NN_SCALE %dx%d -> %dx%d LABEL=SIMULATED_STRETCH_NOT_ASCAL_NOT_DEVICE\n", aw,
                    ah, nw, nh);
    }

    if (!writePngRgb8(out, outRgb, ow, oh))
        die("png write failed");
    std::printf("wrote %s (%dx%d)\n", out, ow, oh);
    return 0;
}
