// B6 by construction: under DDR_YUV_FORCE_SCALE (Always), every representative
// delivery geometry must pin ffmpeg OUTPUT to coded-bank I420 bytes and must
// never identity_skip on an unverified claim. Reader always consumes coded size.
#include "libmisterplex/ffmpeg_vf.hpp"
#include "libmisterplex/yuv420p_chroma_health.hpp"

#include <cstdio>
#include <string>

static int g_fails = 0;
static void expect(bool c, const char* m) {
    if (!c) {
        std::fprintf(stderr, "FAIL: %s\n", m);
        ++g_fails;
    }
}

int main() {
    using namespace misterplex;
    const int cw = 624, ch = 480, dw = 618, dh = 480;
    const size_t reader = yuv420pFrameBytesWH(cw, ch);
    expect(reader == 449280u, "coded bank 449280");

    struct Case {
        int w, h;
        const char* name;
        bool expect_scale; // true => scale_applied; false => crop/pad path ok
    };
    // Parent residual set + WIDTH class + measured PMS tiers.
    // exact_bank unverified → FOAR coded (crop_pad dies on fleet 624x350).
    // bank-height WIDE (640/720) still crop/hfit (no V resample).
    const Case cases[] = {
        {624, 480, "exact_bank", true},
        {624, 352, "624x352", true},
        {624, 350, "624x350", true},
        {640, 480, "640x480", false},
        {720, 480, "720x480", false},
        {720, 404, "720x404", true},
        {1440, 1080, "1440x1080", true},
        {426, 240, "426x240", true},
        {320, 240, "320x240", true},
        {1920, 1080, "1920x1080", true},
    };

    for (const auto& c : cases) {
        FfmpegVfRequest r;
        r.coded_w = cw;
        r.coded_h = ch;
        r.display_w = dw;
        r.display_h = dh;
        r.crop_left = 0;
        r.crop_top = 0;
        r.scale_mode =
            ffmpegScaleModeForDdrYuvPresent(FfmpegScaleMode::SkipIdentity, true);
        r.source_w = c.w;
        r.source_h = c.h;
        r.delivery_geometry_verified = false; // product play-time
        const auto p = buildFfmpegVideoFilter(r);
        const size_t prod = yuv420pFrameBytesWH(c.w, c.h);
        const std::string tag = c.name;

        expect(r.scale_mode == FfmpegScaleMode::Always,
               (tag + " force→Always").c_str());
        // Structural safety: never identity_skip on unverified delivery.
        expect(!p.identity_skip, (tag + " must not identity_skip unverified").c_str());
        // OUTPUT pin: pad=624:480 present OR crop_pad path (also pads coded).
        expect(p.vf.find("pad=624:480") != std::string::npos,
               (tag + " pads coded bank").c_str());
        // Reader vs producer risk only if identity_skip (should be false).
        expect(!pipeDesyncRisk(prod, reader, p.identity_skip),
               (tag + " pipeDesyncRisk must be 0 under force").c_str());
        if (c.expect_scale) {
            expect(p.scale_applied, (tag + " scales").c_str());
            expect(p.vf.find("force_original_aspect_ratio=decrease") != std::string::npos,
                   (tag + " FOAR decrease for non-bank-h").c_str());
        } else {
            expect(!p.scale_applied, (tag + " crop/pad no swscale").c_str());
            expect(p.vf.find("force_original_aspect_ratio") == std::string::npos,
                   (tag + " no FOAR on bank-h path").c_str());
        }
        // By construction: filter OUTPUT geometry is coded bank → 449280 B/frame.
        // (ffmpeg-out host gate measures this; here we pin the plan.)
        std::printf("SAFE %s in=%dx%d prod=%zu reason=%s scale=%d skip=%d\n", c.name, c.w,
                    c.h, prod, p.reason.c_str(), (int)p.scale_applied, (int)p.identity_skip);
    }

    // Verified exact may identity_skip — only safe because prod==reader.
    {
        FfmpegVfRequest r;
        r.coded_w = cw;
        r.coded_h = ch;
        r.display_w = dw;
        r.display_h = dh;
        r.scale_mode = FfmpegScaleMode::Always;
        r.source_w = 624;
        r.source_h = 480;
        r.delivery_geometry_verified = true;
        const auto p = buildFfmpegVideoFilter(r);
        expect(p.identity_skip, "verified exact identity");
        expect(!pipeDesyncRisk(reader, reader, true), "verified match no risk");
    }

    // RED twin class: force OFF + unverified exact must NOT be silent identity
    // under SkipIdentity without verify (crop_pad or scale — not skip).
    {
        FfmpegVfRequest r;
        r.coded_w = cw;
        r.coded_h = ch;
        r.display_w = dw;
        r.display_h = dh;
        r.scale_mode =
            ffmpegScaleModeForDdrYuvPresent(FfmpegScaleMode::SkipIdentity, false);
        r.source_w = 640;
        r.source_h = 480;
        r.delivery_geometry_verified = false;
        const auto p = buildFfmpegVideoFilter(r);
        expect(!p.identity_skip, "force0 640 never identity");
        expect(p.vf.find("pad=624:480") != std::string::npos, "force0 640 still pads");
    }

    if (g_fails) {
        std::fprintf(stderr, "test_force_scale_construction: %d failure(s)\n", g_fails);
        return 1;
    }
    std::printf("PASS test_force_scale_construction cases=%zu reader=%zu\n",
                sizeof(cases) / sizeof(cases[0]), reader);
    return 0;
}
