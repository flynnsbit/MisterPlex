// measured_delivery field semantics + letterbox arithmetic (480-as-240 RCA).
// measured_delivery = ffmpeg INPUT Stream WxH (pre-vf), NOT post-pad active rows.
#include "libmisterplex/ffmpeg_vf.hpp"
#include "libmisterplex/ddr_frame_layout.hpp"

#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <string>

static int g_fails = 0;
static void expect(bool c, const char* m) {
    if (!c) {
        std::fprintf(stderr, "FAIL: %s\n", m);
        ++g_fails;
    }
}

// Active size after force_original_aspect_ratio=decrease into box tw x th.
static void decreaseInto(int sw, int sh, int tw, int th, int* ow, int* oh) {
    const double s = std::min(static_cast<double>(tw) / sw, static_cast<double>(th) / sh);
    *ow = static_cast<int>(std::lround(sw * s));
    *oh = static_cast<int>(std::lround(sh * s));
    // YUV even
    *ow &= ~1;
    *oh &= ~1;
}

int main() {
    using namespace misterplex;

    // --- parseFfmpegGeometryLine: input vs output classification inputs ---
    {
        const auto in = parseFfmpegGeometryLine(
            "    Stream #0:0: Video: h264 (High), yuv420p(tv, bt709), 624x350 [SAR 1:1 DAR 312:175], 23.98 fps");
        expect(in.ok && in.w == 624 && in.h == 350, "parse input 624x350");
        expect(in.is_video, "input is_video");
        // Not Output section
        expect(!in.is_output, "input not is_output");
    }
    {
        const auto out = parseFfmpegGeometryLine(
            "  Stream #0:0: Video: rawvideo (I420 / 0x30323449), yuv420p, 624x480");
        expect(out.ok && out.w == 624 && out.h == 480, "parse output 624x480");
        // Classification in media_player also keys on "rawvideo" substring.
        expect(std::string("  Stream #0:0: Video: rawvideo").find("rawvideo") != std::string::npos,
               "rawvideo token present for outish");
    }

    // --- product vf string for silicon canvas (crop_left=0) ---
    {
        FfmpegVfRequest r;
        r.coded_w = 624;
        r.coded_h = 480;
        r.display_w = 618;
        r.display_h = 480;
        r.crop_left = 0;
        r.crop_top = 0;
        r.scale_mode = FfmpegScaleMode::Always;
        r.sws_flags = "fast_bilinear";
        r.fps_filter = "fps=24/1";
        r.source_w = 624;
        r.source_h = 350;
        r.delivery_geometry_verified = true;
        const auto p = buildFfmpegVideoFilter(r);
        expect(p.scale_applied, "624x350 into canvas must scale");
        expect(!p.identity_skip, "not identity");
        // Must match product shape parent grepped on device.
        expect(p.vf.find("scale=618:480:flags=fast_bilinear:force_original_aspect_ratio=decrease") !=
                   std::string::npos,
               "vf has decrease into 618x480");
        expect(p.vf.find("pad=624:480") != std::string::npos, "vf pads to coded 624x480");
    }

    // --- arithmetic: parent letterbox claim for 16:9 into 624x480 ---
    {
        // 624-wide true 16:9 height
        const double h16 = 624.0 * 9.0 / 16.0;
        expect(std::fabs(h16 - 351.0) < 0.01, "624-wide 16:9 height is 351");
        expect(std::fabs((624.0 / 350.0) - (16.0 / 9.0)) < 0.01, "624x350 aspect ≈ 16:9");

        int ow = 0, oh = 0;
        decreaseInto(624, 350, 618, 480, &ow, &oh);
        // Width-limited: ~618 x 347
        expect(ow == 618, "decrease into 618x480 is width-limited");
        expect(oh >= 346 && oh <= 348, "active height after decrease ~347");

        // CRITICAL: if source were true 4:3 624x480, decrease into 618x480 is NOT ~350.
        decreaseInto(624, 480, 618, 480, &ow, &oh);
        expect(ow == 618, "4:3 still width-limited to 618");
        expect(oh >= 474 && oh <= 476, "4:3 active height ~475 — NOT 350");
    }

    // --- kill misreading measured_delivery as post-pad active picture ---
    // If INPUT is 624x350, measured_delivery reports 350. That is SOURCE height.
    // Post-vf OUTPUT for force-scale path is coded 624x480 (full bank including bars).
    // Active picture inside that bank is ~618x347 centered — that is NOT a field today
    // unless MEASURED_OUTPUT is 624x480 and one inspects luma non-black span.
    {
        const auto geom = productDdrFrameStoreGeometry();
        expect(geom.coded_width.get() == 624 && geom.coded_height.get() == 480, "coded bank");
        expect(geom.display_width.get() == 618 && geom.display_height.get() == 480, "display");
    }

    // --- compound loss arithmetic (conditional) ---
    // IF source active content occupies ~350 of 480 store rows AND store reader
    // only addresses even rows (legacy FRAME_H<=240 / py*2 class), unique active
    // rows on glass ≈ 175. Parent measured 240-row ceiling on RBF 78eff44e — that
    // is FPGA-side; ARM delivers full 480-line bank after pad.
    {
        const int content_rows = 350;
        const int unique_if_even_only = content_rows / 2;
        expect(unique_if_even_only == 175, "compound 350→175 if even-row only");
        const int unique_if_full_480_even = 480 / 2;
        expect(unique_if_full_480_even == 240, "full bank even-only → 240 unique");
    }

    // --- library_media claim vs measured: main.cpp already documents 624x480 claim
    // with measured 624x350 — delivery_verified stays 0 for library_media basis.
    // Numeric match alone must not identity-skip.
    {
        FfmpegVfRequest r;
        r.coded_w = 624;
        r.coded_h = 480;
        r.display_w = 618;
        r.display_h = 480;
        r.scale_mode = FfmpegScaleMode::SkipIdentity;
        r.source_w = 624;
        r.source_h = 480; // library claim
        r.delivery_geometry_verified = false;
        const auto p = buildFfmpegVideoFilter(r);
        expect(p.scale_applied, "unverified library 624x480 must still scale");
        expect(p.reason.find("unverified") != std::string::npos, "unverified reason");
    }

    if (g_fails) {
        std::fprintf(stderr, "%d failure(s)\n", g_fails);
        return 1;
    }
    std::printf("test_measured_delivery_letterbox: OK\n");
    return 0;
}
