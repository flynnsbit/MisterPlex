// Defect A host gate — 624x480 YUV DDR chroma must not publish as U/V~0.
//
// RED class (pre-fix silicon fingerprint):
//   Y populated, U=V=0 across the chroma region → green cast (BT.601).
// GREEN class (after repair / healthy source):
//   U/V mean near neutral 128 (or real colour chroma), dead_chroma=false.
//
// Also locks the YUV-DDR scale policy: SkipIdentity must be forced to Always
// so the 480p path matches the colour-correct 240p scale_pad_crop path.
//
// true rc captured by the driver script / make rule directly (never through a pipe).

#include "libmisterplex/ddr_frame_layout.hpp"
#include "libmisterplex/ffmpeg_vf.hpp"
#include "libmisterplex/yuv420p_chroma_health.hpp"

#include <cstdio>
#include <cstring>
#include <fstream>
#include <string>
#include <vector>

namespace {

int g_fails = 0;

void expect(bool cond, const char* msg) {
    if (!cond) {
        std::fprintf(stderr, "FAIL %s\n", msg);
        ++g_fails;
    }
}

void expect_eq_str(const std::string& a, const std::string& b, const char* msg) {
    if (a != b) {
        std::fprintf(stderr, "FAIL %s: got '%s' want '%s'\n", msg, a.c_str(), b.c_str());
        ++g_fails;
    }
}

std::vector<uint8_t> makeFrame(int w, int h, uint8_t yv, uint8_t uv, uint8_t vv) {
    const size_t yb = static_cast<size_t>(w) * static_cast<size_t>(h);
    const size_t cb = yb / 4u;
    std::vector<uint8_t> f(yb + 2u * cb);
    std::memset(f.data(), yv, yb);
    std::memset(f.data() + yb, uv, cb);
    std::memset(f.data() + yb + cb, vv, cb);
    return f;
}

} // namespace

int main() {
    using namespace misterplex;

    const int w = kPlex480pCodedWidth.get();
    const int h = kPlex480pCodedHeight.get();
    expect(w == 624 && h == 480, "product coded 624x480");
    const size_t frameBytes = static_cast<size_t>(w) * static_cast<size_t>(h) * 3u / 2u;
    expect(frameBytes == static_cast<size_t>(kPlex480pYuv420pBytes), "frame_bytes 449280");

    // --- A) RED class: Y intact, U=V=0 (parent green-cast fingerprint) ---
    {
        auto dead = makeFrame(w, h, /*Y*/ 128, /*U*/ 0, /*V*/ 0);
        expect(dead.size() == frameBytes, "dead frame size");
        const auto hth = inspectYuv420pChroma(dead.data(), w, h);
        expect(hth.valid, "dead inspect valid");
        expect(hth.dead_chroma, "RED: dead_chroma must detect U=V=0");
        expect(hth.mean_u < 1.0 && hth.mean_v < 1.0, "RED: mean U/V ~0");
        expect(hth.zero_frac_u > 0.99 && hth.zero_frac_v > 0.99, "RED: zero frac");
        std::printf("RED_CLASS dead_chroma=1 mean_u=%.2f mean_v=%.2f zero_u=%.3f zero_v=%.3f\n",
                    hth.mean_u, hth.mean_v, hth.zero_frac_u, hth.zero_frac_v);
    }

    // --- B) GREEN after repair: U=V → 128 (neutral, not green) ---
    {
        auto dead = makeFrame(w, h, /*Y*/ 160, /*U*/ 0, /*V*/ 0);
        // Simulate pre-fix publish buffer (vector zero-init chroma region).
        const bool repaired = repairDeadYuv420pChroma(dead.data(), w, h);
        expect(repaired, "repair applied on dead chroma");
        const auto hth = inspectYuv420pChroma(dead.data(), w, h);
        expect(hth.valid && !hth.dead_chroma, "GREEN: not dead after repair");
        expect(hth.mean_u > 127.0 && hth.mean_u < 129.0, "GREEN: mean U ~128");
        expect(hth.mean_v > 127.0 && hth.mean_v < 129.0, "GREEN: mean V ~128");
        // Y untouched
        expect(dead[0] == 160 && dead[static_cast<size_t>(w) * h - 1] == 160,
               "GREEN: Y plane unchanged");
        std::printf("GREEN_REPAIR dead_chroma=0 mean_u=%.2f mean_v=%.2f\n", hth.mean_u,
                    hth.mean_v);
    }

    // --- C) Healthy red-ish chroma must NOT be "repaired" ---
    {
        // Approximate BT.601 red: Y~81 U~90 V~240
        auto red = makeFrame(w, h, 81, 90, 240);
        const auto before = inspectYuv420pChroma(red.data(), w, h);
        expect(before.valid && !before.dead_chroma, "red not dead");
        expect(!repairDeadYuv420pChroma(red.data(), w, h), "red not repaired");
        const auto after = inspectYuv420pChroma(red.data(), w, h);
        expect(after.mean_u > 89.0 && after.mean_u < 91.0, "red U preserved");
        expect(after.mean_v > 239.0 && after.mean_v < 241.0, "red V preserved");
        std::printf("GREEN_HEALTHY red mean_u=%.2f mean_v=%.2f\n", after.mean_u, after.mean_v);
    }

    // --- D) Residue class 0x04/0x19 (pre-PLXD bank0) still counts as dead ---
    {
        auto res = makeFrame(w, h, 100, 0x04, 0x19);
        const auto hth = inspectYuv420pChroma(res.data(), w, h);
        expect(hth.dead_chroma, "0x04/0x19 residue is dead_chroma");
        expect(repairDeadYuv420pChroma(res.data(), w, h), "residue repaired");
    }

    // --- E) YUV-DDR scale policy: default ON maps SkipIdentity→Always ---
    {
        expect(ffmpegScaleModeForDdrYuvPresent(FfmpegScaleMode::SkipIdentity) ==
                   FfmpegScaleMode::Always,
               "default force=1 maps SkipIdentity→Always");
        expect(ffmpegScaleModeForDdrYuvPresent(FfmpegScaleMode::SkipIdentity, true) ==
                   FfmpegScaleMode::Always,
               "explicit force=1 maps SkipIdentity→Always");
        expect(ffmpegScaleModeForDdrYuvPresent(FfmpegScaleMode::SkipIdentity, false) ==
                   FfmpegScaleMode::SkipIdentity,
               "escape force=0 leaves SkipIdentity");
        expect(ffmpegScaleModeForDdrYuvPresent(FfmpegScaleMode::Always, true) ==
                   FfmpegScaleMode::Always,
               "Always stays Always");
        expect(ffmpegScaleModeForDdrYuvPresent(FfmpegScaleMode::Off, true) == FfmpegScaleMode::Off,
               "Off stays Off (lab)");
    }

    // --- F) default force ON scales; escape force=0 + unverified still scales ---
    {
        FfmpegVfRequest r;
        r.coded_w = w;
        r.coded_h = h;
        r.display_w = kPlex480pDisplayWidth.get();
        r.display_h = h;
        r.crop_left = 0;
        r.crop_top = 0;
        r.fps_filter = "fps=24/1";
        r.source_w = w;
        r.source_h = h;
        r.delivery_geometry_verified = false; // PMS transcode_request

        // Default DDR policy force ON → Always → scale_pad_crop.
        r.scale_mode = ffmpegScaleModeForDdrYuvPresent(FfmpegScaleMode::SkipIdentity);
        const auto on = buildFfmpegVideoFilter(r);
        expect(on.scale_applied && !on.identity_skip, "default force scales at 624");
        expect_eq_str(on.reason, "scale_pad_crop", "default force reason");
        expect(on.vf.find("scale=618:480") != std::string::npos, "scale to display");
        expect(on.vf.find("pad=624:480") != std::string::npos, "pad to coded");

        // Escape force=0: SkipIdentity but unverified → still must NOT skip.
        r.scale_mode = ffmpegScaleModeForDdrYuvPresent(FfmpegScaleMode::SkipIdentity, false);
        const auto off = buildFfmpegVideoFilter(r);
        expect(off.scale_applied && !off.identity_skip, "escape+unverified still scales");
        expect_eq_str(off.reason, "scale_pad_crop_unverified_delivery", "escape guard reason");

        // Escape force=0 + VERIFIED match → may identity-skip (lab/direct-play).
        r.delivery_geometry_verified = true;
        const auto ver = buildFfmpegVideoFilter(r);
        expect(ver.identity_skip && !ver.scale_applied, "escape+verified may skip");
        expect_eq_str(ver.reason, "identity_skip_crop_pad_clear", "verified skip reason");
        std::printf("GREEN_POLICY force_default_reason=%s escape_unverified=%s\n",
                    on.reason.c_str(), off.reason.c_str());
    }

    // --- F1b) delivery basis trust helper (B4: only measured) ---
    {
        expect(!deliveryGeometryVerifiedFromBasis("transcode_request"),
               "PMS request is NOT verified");
        expect(!deliveryGeometryVerifiedFromBasis("unknown"), "unknown not verified");
        expect(!deliveryGeometryVerifiedFromBasis("library_media"),
               "library_media is PMS claim NOT verified");
        expect(deliveryGeometryVerifiedFromBasis("measured"), "measured is verified");
    }

    // --- F1c) DESYNC class model — B1 SIGN ERROR SETTLED from cap480a/f_020.png ---
    // Viewed archive (FORCE_SCALE=0 broken silicon):
    //   - TREK24 n=312 appears TWICE in one HDMI raster → N=2
    //   - S_producer ≈ reader_bytes/N = 449280/2 = 224640 = I420 624x240 EXACT
    //   - "FLASH" split ASH|FL left/right → horizontal wrap component
    //   - full-field magenta (median RGB ≈ 255,0,255) = chroma plane walk
    // REJECTED model: producer = 640x480 I420 = 460800 > 449280
    //   → only 0.975 producer frames/raster — CANNOT place two counters.
    // Alias note: RGB24 624x240 = 449280 = I420 624x480 (same byte count, wrong
    //   layout) would pass total%R==0 yet still paint magenta — phase helpers
    //   that only see byte counts cannot catch format alias; FORCE_SCALE+pix_fmt
    //   pins both size and I420 layout on the product path.
    // True single producer size at break is not unique from one still, but the
    // N=2 discriminator KILLS the 640x480>R hypothesis. B2 measures live.
    {
        const size_t coded = yuv420pCodedFrameBytes(
            makeDdrFrameGeometry(kPlex480pCodedWidth.get(), kPlex480pCodedHeight.get()));
        const size_t s624x240 = yuv420pFrameBytesWH(624, 240); // 224640
        const size_t s320x240 = yuv420pFrameBytesWH(320, 240); // 115200
        const size_t s640x480 = yuv420pFrameBytesWH(640, 480); // 460800
        const size_t rgb624x240 = static_cast<size_t>(624) * 240u * 3u; // 449280 alias
        expect(coded == 449280u, "coded I420 bytes");
        expect(s624x240 == 224640u, "624x240 I420 (N=2 candidate)");
        expect(coded % s624x240 == 0u, "N=2 exact divide");
        expect(coded / s624x240 == 2u, "exactly two 624x240 per coded");
        // B1 sign: larger-than-reader producer cannot pack N=2 copies.
        expect(s640x480 > coded, "640x480 larger than reader — not N=2 packing");
        expect(coded / s640x480 == 0u, "640x480 yields 0 full copies per raster");
        expect(rgb624x240 == coded, "RGB24 624x240 aliases coded I420 byte count");
        expect(rawPipeDesynced(s624x240, coded, 0) == false, "aligned at 0");
        // After 1 reader frame of a smaller producer, phase may return 0 when
        // reader is an integer multiple — still two producer frames per raster.
        expect(rawPipePhaseOffset(s624x240, coded, 1) == 0u, "2x multiple realigns");
        expect(rawPipeDesynced(s320x240, coded, 1), "320x240 desyncs");
        expect(rawPipeDesynced(s640x480, coded, 1), "640x480 desyncs (class)");
        expect(!rawPipeDesynced(coded, coded, 100), "matched sizes stay synced");
        // Risk API: identity_skip + mismatch = risk; scale path = no risk flag.
        expect(pipeDesyncRisk(s640x480, coded, true), "RED risk identity+mismatch");
        expect(pipeDesyncRisk(s624x240, coded, true), "RED risk 624x240 identity");
        expect(!pipeDesyncRisk(s640x480, coded, false), "GREEN no risk when scaling");
        expect(!pipeDesyncRisk(coded, coded, true), "GREEN match+identity");
        expect(rawPipeByteAligned(coded * 10, coded), "GREEN byte align");
        expect(!rawPipeByteAligned(coded * 10 + 100, coded), "RED byte misalign");
        std::printf("GREEN_DESYNC B1_SETTLED N=2→S=%zu 640x480=%zu REJECTED as N=2 "
                    "rgb24_alias=%zu coded=%zu\n",
                    s624x240, s640x480, rgb624x240, coded);
    }

    // --- F1d) ffmpeg geometry line parser (B2) ---
    {
        const auto in = parseFfmpegGeometryLine(
            "  Stream #0:0: Video: h264 (High), yuv420p(progressive), 640x480, 24 fps");
        expect(in.ok && in.w == 640 && in.h == 480, "parse input 640x480");
        const auto in2 = parseFfmpegGeometryLine(
            "  Stream #0:0: Video: h264, yuv420p, 624x480 [SAR 1:1 DAR 13:10]");
        expect(in2.ok && in2.w == 624 && in2.h == 480, "parse 624x480 with SAR");
        const auto out = parseFfmpegGeometryLine(
            "  Stream #0:0: Video: rawvideo (I420 / 0x30323449), yuv420p, 624x480");
        expect(out.ok && out.w == 624 && out.h == 480, "parse rawvideo out");
        const auto bad = parseFfmpegGeometryLine("frame= 123 fps=24 q=-0.0 size= 1024kB");
        expect(!bad.ok, "progress line not geometry");
        std::printf("GREEN_PARSE measured_parser ok\n");
    }

    // --- F2) 240p source vs 624 coded: force flag is a no-op (already scales) ---
    {
        FfmpegVfRequest r;
        r.coded_w = w;
        r.coded_h = h;
        r.display_w = kPlex480pDisplayWidth.get();
        r.display_h = h;
        r.crop_left = 0;
        r.crop_top = 0;
        r.fps_filter = "fps=24/1";
        r.source_w = 320;
        r.source_h = 240;
        r.scale_mode = ffmpegScaleModeForDdrYuvPresent(FfmpegScaleMode::SkipIdentity, false);
        const auto off = buildFfmpegVideoFilter(r);
        r.scale_mode = ffmpegScaleModeForDdrYuvPresent(FfmpegScaleMode::SkipIdentity, true);
        const auto on = buildFfmpegVideoFilter(r);
        expect(off.scale_applied && on.scale_applied, "240p scales with force on or off");
        expect(!off.identity_skip && !on.identity_skip, "240p never identity-skips");
        expect_eq_str(off.reason, on.reason, "240p force flag is no-op on reason");
        expect_eq_str(off.vf, on.vf, "240p force flag is no-op on vf");
        std::printf("GREEN_240P_NOOP reason=%s\n", off.reason.c_str());
    }

    // --- G) clearYuv crop pad must not create dead chroma on a healthy frame ---
    // (media_player clear uses kYuv420BlackU/V=128 on pad only)
    {
        auto red = makeFrame(w, h, 81, 90, 240);
        // Manually black the 6-col right pad like clearYuv would (chroma right=3).
        const size_t yb = static_cast<size_t>(w) * static_cast<size_t>(h);
        const size_t cb = yb / 4u;
        uint8_t* u = red.data() + yb;
        uint8_t* v = red.data() + yb + cb;
        const int cuw = w / 2;
        const int cuh = h / 2;
        for (int y = 0; y < cuh; ++y) {
            std::memset(u + static_cast<size_t>(y) * cuw + (cuw - 3), kYuv420BlackU, 3);
            std::memset(v + static_cast<size_t>(y) * cuw + (cuw - 3), kYuv420BlackV, 3);
        }
        const auto hth = inspectYuv420pChroma(red.data(), w, h);
        expect(!hth.dead_chroma, "pad-only 128 does not mark dead");
        expect(!repairDeadYuv420pChroma(red.data(), w, h), "no repair on padded red");
    }

    // --- H) KILL under-read-from-display: reader uses CODED bytes, not 618 ---
    {
        const auto g = plex480pDdrFrameGeometry();
        const size_t codedBytes = yuv420pCodedFrameBytes(g);
        const size_t displayBytes =
            yuv420pFrameBytes(g.display_width.get(), g.display_height.get());
        const size_t decode240Bytes = yuv420pFrameBytes(320, 240);
        expect(codedBytes == frameBytes, "coded frame bytes == 449280");
        expect(g.display_width.get() == 618, "product display 618");
        expect(displayBytes != codedBytes, "display I420 != coded I420");
        expect(displayBytes == static_cast<size_t>(618 * 480 * 3 / 2), "618*480*3/2");
        expect(decode240Bytes != codedBytes, "320x240 I420 != coded");
        // Reader must NOT use display or 240p size (would leave chroma at init).
        expect(codedBytes > displayBytes, "coded larger than display (6-col pad)");
        std::printf("KILL_UNDERREAD coded=%zu display618=%zu decode240=%zu\n", codedBytes,
                    displayBytes, decode240Bytes);
    }

    // --- I) Studio-black init is NOT dead_chroma (zero-init IS) ---
    {
        std::vector<uint8_t> zero(frameBytes, 0);
        expect(inspectYuv420pChroma(zero.data(), w, h).dead_chroma,
               "zero-init buffer is dead_chroma (green class)");
        std::vector<uint8_t> studio(frameBytes);
        expect(fillYuv420pStudioBlack(studio.data(), w, h), "studio fill ok");
        const auto hth = inspectYuv420pChroma(studio.data(), w, h);
        expect(hth.valid && !hth.dead_chroma, "studio black not dead_chroma");
        expect(hth.mean_u > 127.0 && hth.mean_u < 129.0, "studio U=128");
        expect(hth.mean_v > 127.0 && hth.mean_v < 129.0, "studio V=128");
        std::printf("GREEN_INIT studio mean_u=%.2f mean_v=%.2f (zero was dead)\n", hth.mean_u,
                    hth.mean_v);
    }

    // --- J) Assembly path: healthy pipe I420 survives coded-size buffer + pad ---
    // Simulates: ffmpeg wrote full 449280 with red chroma; reader filled frameBytes;
    // clearYuv pad only; buffer handed to sendDdrFrame must keep U/V expected.
    {
        auto pipe = makeFrame(w, h, 81, 90, 240);
        // Product crop_right=6 → chroma right pad 3 samples @128 (clearYuv class).
        const size_t yb = static_cast<size_t>(w) * static_cast<size_t>(h);
        const size_t cb = yb / 4u;
        uint8_t* u = pipe.data() + yb;
        uint8_t* v = pipe.data() + yb + cb;
        const int cuw = w / 2;
        const int cuh = h / 2;
        for (int y = 0; y < cuh; ++y) {
            std::memset(u + static_cast<size_t>(y) * cuw + (cuw - 3), kYuv420BlackU, 3);
            std::memset(v + static_cast<size_t>(y) * cuw + (cuw - 3), kYuv420BlackV, 3);
        }
        const auto hth = inspectYuv420pChroma(pipe.data(), w, h);
        expect(hth.valid && !hth.dead_chroma, "publish buffer not dead");
        // Content region (not pad) should stay near red chroma.
        expect(hth.mean_u > 85.0 && hth.mean_u < 95.0, "publish U still red-ish");
        expect(hth.mean_v > 230.0 && hth.mean_v < 241.0, "publish V still red-ish");
        std::printf("GREEN_ASSEMBLY publish mean_u=%.2f mean_v=%.2f (pipe chroma kept)\n",
                    hth.mean_u, hth.mean_v);
    }

    // --- K) B5 product wiring: arm/ must call rawPipeDesynced + byte-align assert ---
    // RED history: helpers lived only in unit tests; users got magenta with no log.
    {
        const char* path = "arm/misterplexd/media_player.cpp";
        std::ifstream in(path);
        expect(static_cast<bool>(in), "open media_player.cpp for B5 static");
        std::string src((std::istreambuf_iterator<char>(in)), std::istreambuf_iterator<char>());
        expect(src.find("rawPipeDesynced") != std::string::npos,
               "arm must call rawPipeDesynced (not unit-only)");
        expect(src.find("rawPipePhaseOffset") != std::string::npos,
               "arm must call rawPipePhaseOffset at teardown");
        expect(src.find("rawPipeByteAligned") != std::string::npos,
               "arm must call rawPipeByteAligned (total%frameBytes)");
        expect(src.find("MEASURED_OUTPUT_FINAL") != std::string::npos,
               "arm must emit MEASURED_OUTPUT_FINAL (post-vf measurement)");
        expect(src.find("MEASURED_DELIVERY_FINAL") != std::string::npos,
               "arm must emit MEASURED_DELIVERY_FINAL (pre-vf measurement)");
        expect(src.find("PIPE_PHASE_DESYNC") != std::string::npos,
               "arm must ERROR on phase desync");
        // B4 consume path: measurement must advertise delivery_verified=1 basis=measured
        // (play-time GEOM may still say 0 — that is pre-measure, not a stuck flag).
        expect(src.find("delivery_verified=1 delivery_basis=measured") != std::string::npos,
               "MEASURED_DELIVERY must set delivery_verified=1 basis=measured");
        expect(src.find("deliveryGeometryVerified_.store(true") != std::string::npos,
               "measurement must store deliveryGeometryVerified_=true");
        // B4: library_media must not verify delivery in the helper.
        expect(!deliveryGeometryVerifiedFromBasis("library_media"),
               "B4 library_media never verifies");
        expect(!deliveryGeometryVerifiedFromBasis("transcode_request"),
               "B4 transcode_request never verifies");
        expect(deliveryGeometryVerifiedFromBasis("measured"), "B4 measured verifies");
        std::printf("GREEN_B5_ARM_WIRE rawPipeDesynced+MEASURED_*_FINAL+B4_consume present\n");
    }

    if (g_fails) {
        std::fprintf(stderr, "test_yuv420p_chroma_480p: %d failure(s)\n", g_fails);
        return 1;
    }
    std::printf("PASS test_yuv420p_chroma_480p\n");
    return 0;
}
