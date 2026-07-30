// Unit tests for host/libmisterplex/ffmpeg_vf.hpp — scale policy + sws_flags.
#include "libmisterplex/ffmpeg_vf.hpp"

#include <cstdio>
#include <cstdlib>
#include <string>

static int g_fails = 0;

static void expect(bool cond, const char* msg) {
    if (!cond) {
        std::fprintf(stderr, "FAIL: %s\n", msg);
        ++g_fails;
    }
}

static void expect_eq(const std::string& got, const std::string& want, const char* msg) {
    if (got != want) {
        std::fprintf(stderr, "FAIL: %s\n  got:  %s\n  want: %s\n", msg, got.c_str(),
                     want.c_str());
        ++g_fails;
    }
}

int main() {
    using namespace misterplex;

    // --- parse defaults stay shipping-safe ---
    expect(parseFfmpegScaleMode("") == FfmpegScaleMode::Always, "empty → Always");
    expect(parseFfmpegScaleMode("bogus") == FfmpegScaleMode::Always, "unknown → Always");
    expect(parseFfmpegScaleMode("skip_identity") == FfmpegScaleMode::SkipIdentity,
           "skip_identity");
    expect(parseFfmpegScaleMode("off") == FfmpegScaleMode::Off, "off");
    expect(parseFfmpegScaleMode("auto") == FfmpegScaleMode::SkipIdentity, "auto alias");

    expect(swsFlagsTokenOk(""), "empty flags ok");
    expect(swsFlagsTokenOk("fast_bilinear"), "fast_bilinear ok");
    expect(swsFlagsTokenOk("bilinear+accurate_rnd"), "combo ok");
    expect(!swsFlagsTokenOk("fast;rm -rf"), "shell metachar rejected");
    expect(!swsFlagsTokenOk("flags=evil"), "equals rejected");

    // --- shipping Always @ 320x240 (no crop): historical centre pad, no :flags= ---
    {
        FfmpegVfRequest r;
        r.coded_w = 320;
        r.coded_h = 240;
        r.display_w = 320;
        r.display_h = 240;
        r.scale_mode = FfmpegScaleMode::Always;
        const auto p = buildFfmpegVideoFilter(r);
        expect(p.scale_applied, "always scales");
        expect(!p.identity_skip, "always not identity skip");
        expect_eq(p.vf,
                  "scale=320:240:force_original_aspect_ratio=decrease,pad=320:240:(ow-iw)/"
                  "2:(oh-ih)/2",
                  "240p centre pad historical string");
        expect_eq(p.reason, "scale_pad_center", "reason center");
    }

    // --- shipping Always @ 624x480 crop path ---
    {
        FfmpegVfRequest r;
        r.coded_w = 624;
        r.coded_h = 480;
        r.display_w = 618;
        r.display_h = 480;
        r.crop_left = 3;
        r.crop_top = 0;
        r.scale_mode = FfmpegScaleMode::Always;
        const auto p = buildFfmpegVideoFilter(r);
        expect(p.scale_applied, "480p always scales");
        expect_eq(p.vf,
                  "scale=618:480:force_original_aspect_ratio=decrease,pad=624:480:3:0:color="
                  "black",
                  "480p crop pad historical string");
        expect_eq(p.reason, "scale_pad_crop", "reason crop");
    }

    // --- Always + fps prefix ---
    {
        FfmpegVfRequest r;
        r.coded_w = 320;
        r.coded_h = 240;
        r.display_w = 320;
        r.display_h = 240;
        r.fps_filter = "fps=24000/1001";
        r.scale_mode = FfmpegScaleMode::Always;
        const auto p = buildFfmpegVideoFilter(r);
        expect(p.vf.rfind("fps=24000/1001,scale=", 0) == 0, "fps first then scale");
    }

    // --- Always + fast_bilinear flags (opt-in; not default) ---
    {
        FfmpegVfRequest r;
        r.coded_w = 320;
        r.coded_h = 240;
        r.display_w = 320;
        r.display_h = 240;
        r.scale_mode = FfmpegScaleMode::Always;
        r.sws_flags = "fast_bilinear";
        const auto p = buildFfmpegVideoFilter(r);
        expect_eq(p.vf,
                  "scale=320:240:flags=fast_bilinear:force_original_aspect_ratio=decrease,"
                  "pad=320:240:(ow-iw)/2:(oh-ih)/2",
                  "flags inserted before force_original_aspect_ratio");
        expect_eq(p.reason, "scale_pad_center_flags", "reason flags");
    }

    // --- SkipIdentity when source == coded (even with crop geometry) ---
    {
        FfmpegVfRequest r;
        r.coded_w = 624;
        r.coded_h = 480;
        r.display_w = 618;
        r.display_h = 480;
        r.crop_left = 3;
        r.scale_mode = FfmpegScaleMode::SkipIdentity;
        r.source_w = 624;
        r.source_h = 480;
        const auto p = buildFfmpegVideoFilter(r);
        expect(!p.scale_applied, "identity skip no scale");
        expect(p.identity_skip, "identity_skip flag");
        expect(p.vf.empty(), "vf empty without fps");
        expect_eq(p.reason, "identity_skip_crop_pad_clear", "crop clear reason");
    }

    // --- SkipIdentity unknown source → still scales (safe) ---
    {
        FfmpegVfRequest r;
        r.coded_w = 320;
        r.coded_h = 240;
        r.display_w = 320;
        r.display_h = 240;
        r.scale_mode = FfmpegScaleMode::SkipIdentity;
        // source unset, assume false
        const auto p = buildFfmpegVideoFilter(r);
        expect(p.scale_applied, "unknown source still scales under skip_identity");
        expect(!p.identity_skip, "not skipped");
    }

    // --- SkipIdentity + assume_match without source dims ---
    {
        FfmpegVfRequest r;
        r.coded_w = 320;
        r.coded_h = 240;
        r.display_w = 320;
        r.display_h = 240;
        r.scale_mode = FfmpegScaleMode::SkipIdentity;
        r.assume_source_matches_coded = true;
        const auto p = buildFfmpegVideoFilter(r);
        expect(p.identity_skip && !p.scale_applied, "assume_match skips");
        expect_eq(p.reason, "identity_skip", "assume reason");
    }

    // --- Off never scales ---
    {
        FfmpegVfRequest r;
        r.coded_w = 624;
        r.coded_h = 480;
        r.display_w = 618;
        r.display_h = 480;
        r.scale_mode = FfmpegScaleMode::Off;
        r.fps_filter = "fps=24/1";
        const auto p = buildFfmpegVideoFilter(r);
        expect(!p.scale_applied && !p.identity_skip, "off neither applied nor identity");
        expect_eq(p.vf, "fps=24/1", "off keeps fps only");
        expect_eq(p.reason, "scale_off", "off reason");
    }

    // --- mismatched source under skip_identity still scales ---
    {
        FfmpegVfRequest r;
        r.coded_w = 624;
        r.coded_h = 480;
        r.display_w = 618;
        r.display_h = 480;
        r.crop_left = 3;
        r.scale_mode = FfmpegScaleMode::SkipIdentity;
        r.source_w = 1920;
        r.source_h = 1080;
        const auto p = buildFfmpegVideoFilter(r);
        expect(p.scale_applied && !p.identity_skip, "mismatch scales");
    }

    if (g_fails) {
        std::fprintf(stderr, "test_ffmpeg_vf: %d failure(s)\n", g_fails);
        return 1;
    }
    std::printf("PASS test_ffmpeg_vf\n");
    return 0;
}
