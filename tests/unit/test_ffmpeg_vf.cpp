// Unit tests for host/libmisterplex/ffmpeg_vf.hpp — scale policy + sws_flags.
#include "libmisterplex/ffmpeg_vf.hpp"
#include "libmisterplex/yuv420p_chroma_health.hpp"

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

    // --- shipping Always @ 624x480: FOAR into CODED bank (not display 618) ---
    // Parent 2026-08-02: scale=618:480:FOAR was the user-visible row destroyer.
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
        expect(p.scale_applied, "480p always scales when source unknown");
        expect_eq(p.vf,
                  "scale=624:480:force_original_aspect_ratio=decrease,pad=624:480:(ow-iw)/"
                  "2:(oh-ih)/2",
                  "480p FOAR into coded bank not display 618");
        expect_eq(p.reason, "scale_pad_center_coded", "reason coded FOAR");
        expect(p.vf.find("scale=618:480") == std::string::npos, "must not FOAR into 618");
    }

    // --- product silicon: 320 delivery FOAR into coded 624 then center pad ---
    {
        FfmpegVfRequest r;
        r.coded_w = 624;
        r.coded_h = 480;
        r.display_w = 618;
        r.display_h = 480;
        r.crop_left = 0;
        r.crop_top = 0;
        r.scale_mode = FfmpegScaleMode::SkipIdentity;
        r.source_w = 320;
        r.source_h = 240;
        const auto p = buildFfmpegVideoFilter(r);
        expect(p.scale_applied && !p.identity_skip, "320→624 must scale (not identity)");
        expect_eq(p.vf,
                  "scale=624:480:force_original_aspect_ratio=decrease,pad=624:480:(ow-iw)/"
                  "2:(oh-ih)/2",
                  "320 into silicon coded bank FOAR string");
        expect(p.vf.find("scale=618:480") == std::string::npos, "320 path no 618 FOAR");
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

    // --- SkipIdentity when VERIFIED source == coded (even with crop geometry) ---
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
        r.delivery_geometry_verified = true;
        const auto p = buildFfmpegVideoFilter(r);
        expect(!p.scale_applied, "identity skip no scale");
        expect(p.identity_skip, "identity_skip flag");
        expect(p.vf.empty(), "vf empty without fps");
        expect_eq(p.reason, "identity_skip_crop_pad_clear", "crop clear reason");
    }

    // --- RED class: numeric match WITHOUT verification must NOT identity-skip ---
    // Exact coded + crop → crop_pad_no_v_scale (not swscale decrease into 618).
    {
        FfmpegVfRequest r;
        r.coded_w = 624;
        r.coded_h = 480;
        r.display_w = 618;
        r.display_h = 480;
        r.crop_left = 0;
        r.scale_mode = FfmpegScaleMode::SkipIdentity;
        r.source_w = 624;
        r.source_h = 480;
        r.delivery_geometry_verified = false; // PMS transcode_request class
        const auto p = buildFfmpegVideoFilter(r);
        expect(!p.identity_skip, "unverified 624 must not identity_skip");
        expect(!p.scale_applied, "unverified exact coded uses crop not swscale");
        expect_eq(p.reason, "crop_pad_no_v_scale_unverified_delivery", "unverified reason");
        expect(vfPreservesBankHeightSource(p.vf), "unverified exact still preserves height");
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

    // --- Product FORCE_SCALE=1 (Always): every real title geometry pins OUTPUT
    // to coded 624x480 I420 (449280 B). Aspect via decrease + pad (letter/pillar),
    // never stretch. PMS upperBound is a ceiling — source may be any of these.
    {
        const int coded_w = 624, coded_h = 480;
        const int disp_w = 618, disp_h = 480;
        const size_t codedBytes = yuv420pFrameBytesWH(coded_w, coded_h);
        expect(codedBytes == 449280u, "product coded I420 is 449280");

        struct Case {
            int sw, sh;
            const char* name;
        };
        // Parent residual list + exact bank + short 480p delivery + odd dims.
        const Case cases[] = {
            {624, 480, "exact_bank"},
            {624, 352, "scope_2.35"},
            {624, 350, "measured_short_480p"}, // parent device: request 624x480 → 624x350
            {640, 480, "640x480"},             // WIDTH > bank, H exact
            {720, 480, "720x480"},             // WIDTH > bank, H exact
            {704, 396, "704x396"},
            {720, 576, "720x576"},
            {1440, 1080, "1440x1080"},
            {1920, 1080, "1920x1080"},
            {320, 240, "320x240"},
            {426, 240, "426x240"}, // parent device: PMS square-pixel-ish 16:9 tier
            {625, 481, "odd_dims"}, // scale accepts; I420 coded out is still even
            {618, 480, "display_exact"},
        };
        for (const auto& c : cases) {
            FfmpegVfRequest r;
            r.coded_w = coded_w;
            r.coded_h = coded_h;
            r.display_w = disp_w;
            r.display_h = disp_h;
            r.crop_left = 0;
            r.crop_top = 0;
            r.scale_mode =
                ffmpegScaleModeForDdrYuvPresent(FfmpegScaleMode::SkipIdentity, true);
            r.source_w = c.sw;
            r.source_h = c.sh;
            r.delivery_geometry_verified = false;
            const auto p = buildFfmpegVideoFilter(r);
            expect(r.scale_mode == FfmpegScaleMode::Always, "force→Always");
            const bool exactBank = (c.sw == coded_w && c.sh == coded_h);
            // Non-exact bank-height wide deliveries (WIDTH mismatch, H==480):
            // crop+pad hfit, no V resample. Exact unverified: crop+pad pin.
            // Verified exact identity is covered outside this loop.
            const bool bankHeightWideNonExact =
                !exactBank && (c.sh == coded_h && c.sw >= disp_w);
            if (exactBank) {
                // Unverified exact under Always: crop+pad pin, NOT identity_skip.
                expect(!p.scale_applied && !p.identity_skip,
                       (std::string("FORCE_SCALE exact crop-pad pin for ") + c.name).c_str());
                expect(p.vf.find("scale=") == std::string::npos,
                       (std::string("exact no scale= for ") + c.name).c_str());
                expect(p.vf.find("force_original_aspect_ratio") == std::string::npos,
                       (std::string("exact no FOAR for ") + c.name).c_str());
                expect(p.vf.find("crop=618:480") != std::string::npos,
                       (std::string("exact crops display for ") + c.name).c_str());
                expect(p.vf.find("pad=624:480") != std::string::npos,
                       (std::string("exact pads coded for ") + c.name).c_str());
                expect(vfPreservesBankHeightSource(p.vf),
                       (std::string("exact preserves height for ") + c.name).c_str());
                expect_eq(p.reason, "force_exact_crop_pad_unverified", "exact bank reason");
            } else if (bankHeightWideNonExact) {
                expect(!p.scale_applied && !p.identity_skip,
                       (std::string("FORCE_SCALE bank-h crop-pad for ") + c.name).c_str());
                expect(vfPreservesBankHeightSource(p.vf),
                       (std::string("bank-h preserves height for ") + c.name).c_str());
                expect(p.vf.find("crop=618:480") != std::string::npos,
                       (std::string("bank-h crops display for ") + c.name).c_str());
                expect(p.vf.find("pad=624:480") != std::string::npos,
                       (std::string("bank-h pads coded for ") + c.name).c_str());
                expect_eq(p.reason, "crop_pad_no_v_scale_hfit", "bank-h hfit reason");
            } else {
                expect(p.scale_applied && !p.identity_skip,
                       (std::string("FORCE_SCALE pins scale for ") + c.name).c_str());
                expect(p.vf.find("force_original_aspect_ratio=decrease") != std::string::npos,
                       (std::string("aspect preserved (decrease) for ") + c.name).c_str());
                expect(p.vf.find("pad=624:480") != std::string::npos,
                       (std::string("pad to coded bank for ") + c.name).c_str());
                expect(p.vf.find("scale=624:480") != std::string::npos,
                       (std::string("scale into coded box for ") + c.name).c_str());
                expect(p.vf.find("scale=618:480") == std::string::npos,
                       (std::string("no FOAR into display 618 for ") + c.name).c_str());
            }
            expect(yuv420pFrameBytesWH(coded_w, coded_h) == codedBytes,
                   "output byte contract is coded bank");
            // Mid-stream source change cannot identity-skip under force: mode is Always.
            r.source_w = 1920;
            r.source_h = 1080;
            r.delivery_geometry_verified = true;
            const auto mid = buildFfmpegVideoFilter(r);
            expect(mid.scale_applied && !mid.identity_skip,
                   (std::string("mid-stream still scales under force for ") + c.name)
                       .c_str());
            if (exactBank) {
                r.scale_mode =
                    ffmpegScaleModeForDdrYuvPresent(FfmpegScaleMode::SkipIdentity, false);
                r.source_w = coded_w;
                r.source_h = coded_h;
                r.delivery_geometry_verified = true;
                const auto skip = buildFfmpegVideoFilter(r);
                expect(skip.identity_skip && !skip.scale_applied,
                       "RED: force=0+verified exact may identity_skip");
                // Always + verified exact → true identity (lab path).
                r.scale_mode = FfmpegScaleMode::Always;
                const auto id = buildFfmpegVideoFilter(r);
                expect(id.identity_skip && !id.scale_applied,
                       "Always+verified exact is true identity");
                expect_eq(id.reason, "force_exact_identity_crop_clear",
                          "Always+verified identity reason");
            }
        }
        // Odd measured dims: I420 byte helper returns 0 (not a valid plane size).
        expect(yuv420pFrameBytesWH(625, 481) == 0u, "odd dims have no I420 packed size");
        std::printf("GREEN_FORCE_SCALE_GEOM cases=%zu coded_bytes=%zu\n",
                    sizeof(cases) / sizeof(cases[0]), codedBytes);
    }

    // --- B5 phase model: mismatched OUTPUT desyncs; matched does not ---
    {
        const size_t R = 449280u;
        expect(rawPipeDesynced(R, R, 500) == false, "matched output never desyncs");
        expect(rawPipeDesynced(yuv420pFrameBytesWH(624, 350), R, 2),
               "624x350 output desyncs vs 624x480 reader");
        expect(rawPipeDesynced(yuv420pFrameBytesWH(640, 480), R, 1),
               "640x480 output desyncs");
        expect(rawPipeByteAligned(R * 100, R), "aligned total");
        expect(!rawPipeByteAligned(R * 100 + 1, R), "misaligned total");
    }

    // --- FORCE_SCALE=1 output pin: no delivered INPUT size can change OUTPUT bytes ---
    {
        const size_t R = yuv420pFrameBytesWH(624, 480);
        expect(R == 449280u, "reader contract");
        FfmpegVfRequest r;
        r.coded_w = 624;
        r.coded_h = 480;
        r.display_w = 618;
        r.display_h = 480;
        r.scale_mode = ffmpegScaleModeForDdrYuvPresent(FfmpegScaleMode::SkipIdentity, true);
        r.source_w = 1920;
        r.source_h = 1080;
        r.delivery_geometry_verified = true;
        const auto p = buildFfmpegVideoFilter(r);
        expect(!p.identity_skip && p.scale_applied, "force blocks identity_skip always");
        expect(p.vf.find("pad=624:480") != std::string::npos, "output pad is coded bank");
        expect(!rawPipeDesynced(R, R, 10000), "pinned output never phase-walks");
        expect(!pipeDesyncRisk(yuv420pFrameBytesWH(1920, 1080), R, p.identity_skip),
               "input mismatch + force(scale) is NOT pipe risk");
        expect(pipeDesyncRisk(yuv420pFrameBytesWH(1920, 1080), R, true),
               "same input mismatch + identity_skip IS pipe risk (RED twin)");
        std::printf("GREEN_OUTPUT_PIN force_scale output_bytes=%zu == reader\n", R);
    }

    // --- B4: only measured qualifies ---
    {
        expect(!deliveryGeometryVerifiedFromBasis("library_media"),
               "library_media is claim not measurement");
        expect(!deliveryGeometryVerifiedFromBasis("transcode_request"),
               "transcode_request not verified");
        expect(deliveryGeometryVerifiedFromBasis("measured"), "measured qualifies");
    }

    // --- NO_V_RESAMPLE gate (rd-review / w-geom): src_h == bank_h ⇒ no vertical resample ---
    // Arithmetic of the defect, RED mutation of the legacy string, GREEN product path.
    {
        // 1) Arithmetic: decrease into display 618x480 shrinks 624x480 → height 475.
        const int out_h = scaleDecreaseOutHeight(624, 480, 618, 480);
        expect(out_h == 475, "624x480 into 618x480 decrease out_h==475");
        expect(scaleDecreaseResamplesHeight(624, 480, 618, 480),
               "decrease into display resamples height");
        expect(!scaleDecreaseResamplesHeight(320, 240, 618, 480) ||
                   scaleDecreaseOutHeight(320, 240, 618, 480) != 240,
               "320x240 upscale path still changes height (expected)");
        // 320x240 → out_h = 240*618/320 = 463 (width-limited), not 240.
        expect(scaleDecreaseOutHeight(320, 240, 618, 480) == 463, "320x240→463 under decrease");

        // 2) RED mutation: legacy buildScalePadCropped string fails the preserve predicate.
        const std::string legacy = buildScalePadCropped(618, 480, 624, 480, 0, 0, "fast_bilinear");
        expect(legacy.find("scale=618:480") != std::string::npos, "mutation has scale=618:480");
        expect(legacy.find("force_original_aspect_ratio=decrease") != std::string::npos,
               "mutation has decrease");
        expect(!vfPreservesBankHeightSource(legacy),
               "RED: legacy decrease-into-display fails vfPreservesBankHeightSource");

        // 3) GREEN product hot path: Always + unverified exact → crop+pad pin (no FOAR).
        FfmpegVfRequest r;
        r.coded_w = 624;
        r.coded_h = 480;
        r.display_w = 618;
        r.display_h = 480;
        r.crop_left = 0;
        r.crop_top = 0;
        r.scale_mode = FfmpegScaleMode::Always;
        r.source_w = 624;
        r.source_h = 480;
        r.sws_flags = "fast_bilinear";
        r.delivery_geometry_verified = false;
        const auto p = buildFfmpegVideoFilter(r);
        expect(vfPreservesBankHeightSource(p.vf),
               "GREEN: exact coded source vf preserves bank height");
        expect(!p.scale_applied && !p.identity_skip, "GREEN: crop-pad pin not identity_skip");
        expect_eq(p.reason, "force_exact_crop_pad_unverified", "GREEN reason");
        expect(p.vf.find("scale=") == std::string::npos, "GREEN no scale=");
        expect(p.vf.find("force_original_aspect_ratio") == std::string::npos, "GREEN no FOAR");
        expect_eq(p.vf,
                  "crop=618:480:0:0,pad=624:480:0+(618-iw)/2:0+(480-ih)/2:color=black",
                  "GREEN crop-pad string");

        // 3b) Verified exact under Always: true identity (lab / measured-before-plan).
        r.delivery_geometry_verified = true;
        const auto pv = buildFfmpegVideoFilter(r);
        expect(pv.identity_skip && !pv.scale_applied, "GREEN verified exact identity");
        expect_eq(pv.reason, "force_exact_identity_crop_clear", "GREEN verified reason");
        expect(pv.vf.empty() || pv.vf.rfind("fps=", 0) == 0, "GREEN verified empty/fps");
        r.delivery_geometry_verified = false;

        // 4) 240p tier still upscales via decrease into CODED (not display 618).
        r.source_w = 320;
        r.source_h = 240;
        const auto p240 = buildFfmpegVideoFilter(r);
        expect(p240.scale_applied && !p240.identity_skip, "240p still scales");
        expect(p240.vf.find("scale=624:480") != std::string::npos, "240p scale into coded");
        expect(p240.vf.find("scale=618:480") == std::string::npos, "240p must not FOAR 618");
        expect(p240.vf.find("force_original_aspect_ratio=decrease") != std::string::npos,
               "240p keeps decrease");
        expect(!vfPreservesBankHeightSource(p240.vf),
               "240p vf is not a bank-height preserve path (upscale)");

        // 5) delivery height==480, width>coded (640): still no V resample (hfit crop).
        r.source_w = 640;
        r.source_h = 480;
        const auto p640 = buildFfmpegVideoFilter(r);
        expect(vfPreservesBankHeightSource(p640.vf), "640x480 preserves bank height");
        expect(!p640.scale_applied, "640x480 crop not scale");
        expect_eq(p640.reason, "crop_pad_no_v_scale_hfit", "640 hfit reason");
        expect(p640.vf.find("(iw-618)/2") != std::string::npos, "640 center-crop expr");

        // 6) Gate contract: delivery_h == bank_h ⇒ preserve (parent wording).
        expect(scaleDecreaseResamplesHeight(624, 480, 618, 480), "decrease would V-resample");
        expect(!scaleDecreaseResamplesHeight(624, 480, 624, 480), "coded box would not");

        std::printf("GREEN_NO_V_RESAMPLE out_h_624=475 legacy_red=1 product_crop_pad=1 "
                    "verified_identity=1 p240_upscale=1 p640_hfit=1\n");
    }

    // --- WIDTH mismatch gate (parent: 624x350 only proved vertical pin) ---
    // 640x480 and 720x480 into coded 624x480: must center-crop to display 618
    // then pad to 624 — no FOAR, no swscale. I420 plane sizes stay even.
    {
        const int coded_w = 624, coded_h = 480, disp_w = 618, disp_h = 480;
        struct WCase {
            int sw, sh;
            const char* name;
            const char* crop_x_needle; // substring unique to center vs left crop
        };
        const WCase wcases[] = {
            {640, 480, "w640", "(iw-618)/2"},
            {720, 480, "w720", "(iw-618)/2"},
        };
        for (const auto& c : wcases) {
            FfmpegVfRequest r;
            r.coded_w = coded_w;
            r.coded_h = coded_h;
            r.display_w = disp_w;
            r.display_h = disp_h;
            r.crop_left = 0;
            r.crop_top = 0;
            r.scale_mode = FfmpegScaleMode::Always;
            r.source_w = c.sw;
            r.source_h = c.sh;
            r.delivery_geometry_verified = false;
            const auto p = buildFfmpegVideoFilter(r);
            expect(!p.scale_applied && !p.identity_skip,
                   (std::string("WIDTH ") + c.name + " crop-pad not scale/skip").c_str());
            expect(p.vf.find("force_original_aspect_ratio") == std::string::npos,
                   (std::string("WIDTH ") + c.name + " no FOAR").c_str());
            expect(p.vf.find("scale=") == std::string::npos,
                   (std::string("WIDTH ") + c.name + " no scale=").c_str());
            expect(p.vf.find("crop=618:480:") != std::string::npos,
                   (std::string("WIDTH ") + c.name + " crops display").c_str());
            expect(p.vf.find(c.crop_x_needle) != std::string::npos,
                   (std::string("WIDTH ") + c.name + " center-crop expr").c_str());
            expect(p.vf.find("pad=624:480") != std::string::npos,
                   (std::string("WIDTH ") + c.name + " pads coded bank").c_str());
            expect_eq(p.reason, "crop_pad_no_v_scale_hfit",
                      (std::string("WIDTH ") + c.name + " reason").c_str());
            // Output byte contract is always coded bank (reader size).
            expect(yuv420pFrameBytesWH(coded_w, coded_h) == 449280u, "WIDTH bank bytes");
            // Chroma plane dims for coded bank stay even (I420).
            expect((coded_w % 2) == 0 && (coded_h % 2) == 0, "WIDTH coded even");
            expect((disp_w % 2) == 0 && (disp_h % 2) == 0, "WIDTH display even");
        }
        // Vertical-only mismatch (parent measured 624x350): MUST scale (not crop).
        FfmpegVfRequest rv;
        rv.coded_w = coded_w;
        rv.coded_h = coded_h;
        rv.display_w = disp_w;
        rv.display_h = disp_h;
        rv.scale_mode = FfmpegScaleMode::Always;
        rv.source_w = 624;
        rv.source_h = 350;
        const auto pv = buildFfmpegVideoFilter(rv);
        expect(pv.scale_applied && !pv.identity_skip, "V-mismatch 624x350 scales");
        expect(pv.vf.find("scale=624:480") != std::string::npos, "V-mismatch FOAR into coded");
        expect(pv.vf.find("scale=618:480") == std::string::npos, "V-mismatch no 618 FOAR");
        // 426x240 (parent measured PMS tier): must scale.
        rv.source_w = 426;
        rv.source_h = 240;
        const auto p426 = buildFfmpegVideoFilter(rv);
        expect(p426.scale_applied && !p426.identity_skip, "426x240 scales under force");
        expect(p426.vf.find("pad=624:480") != std::string::npos, "426x240 pads coded");
        expect(p426.vf.find("scale=618:480") == std::string::npos, "426 no 618 FOAR");
        // Parent FOAR loss arithmetic: 16:9 into 618 vs 624.
        expect(predictFoarDecreaseHeight(624, 350, 618, 480) > 0, "foar pred");
        expect(scaleDecreaseOutHeight(624, 480, 618, 480) == 475, "4:3 into 618 → 475");
        expect(scaleDecreaseOutHeight(624, 480, 624, 480) == 480, "4:3 into 624 → 480 keep");
        // 16:9 square-pixel into coded: ~350 rows (letterbox class).
        expect(scaleDecreaseOutHeight(1920, 1080, 624, 480) == 351 ||
                   scaleDecreaseOutHeight(1920, 1080, 624, 480) == 350,
               "16:9 1080p into 624 → ~350");
        std::printf("GREEN_WIDTH_MISMATCH w640=hfit w720=hfit v350=scale d426=scale "
                    "foar_coded_not_618=1\n");
    }

    // --- Loss2 half-res (parent A/B: request=397 → measured=312x240) ---
    // Compound ledger must separate PMS half-res from FOAR letterbox.
    {
        const int bank_w = 624, bank_h = 480;
        const double v312 = deliveredVerticalDetailFrac(240, bank_h);
        const double a312 = deliveredAreaFrac(312, 240, bank_w, bank_h);
        expect(v312 > 0.49 && v312 < 0.51, "312 delivery v_frac≈0.5");
        expect(a312 > 0.24 && a312 < 0.26, "312 delivery area_frac≈0.25");
        // FOAR 312x240 into coded 624 fills bank (same 1.3 AR) — filter_v≈1
        const int pic_h = scaleDecreaseOutHeight(312, 240, bank_w, bank_h);
        const int pic_w = scaleDecreaseOutWidth(312, 240, bank_w, bank_h);
        expect(pic_h == 480 && pic_w == 624, "312 FOAR fills bank picture");
        const double fv = foarVerticalDetailFrac(312, 240, bank_w, bank_h, bank_h);
        const double cmp = compoundVerticalDetailFrac(v312, fv);
        expect(cmp > 0.49 && cmp < 0.51, "compound still 0.5 when FOAR fills");
        // Full bank delivery + FOAR into 618 16:9 letterbox
        const double v624 = deliveredVerticalDetailFrac(480, bank_h);
        const double fv618 = foarVerticalDetailFrac(624, 480, 618, 480, bank_h);
        // 4:3 624x480 into 618 → 475/480 not 350; use 1920x1080 for 16:9
        const double fv16 = foarVerticalDetailFrac(1920, 1080, 624, 480, bank_h);
        expect(v624 > 0.99, "full delivery v_frac=1");
        expect(fv16 > 0.72 && fv16 < 0.74, "16:9 FOAR into 624 ~0.73");
        expect(compoundVerticalDetailFrac(v624, fv16) > 0.72 &&
                   compoundVerticalDetailFrac(v624, fv16) < 0.74,
               "compound tracks FOAR letterbox alone");
        std::printf("GREEN_LOSS2_COMPOUND v312=%.3f a312=%.3f cmp312=%.3f fv16=%.3f\n", v312,
                    a312, cmp, fv16);
        (void)fv618;
    }

    if (g_fails) {
        std::fprintf(stderr, "test_ffmpeg_vf: %d failure(s)\n", g_fails);
        return 1;
    }
    std::printf("PASS test_ffmpeg_vf\n");
    return 0;
}
