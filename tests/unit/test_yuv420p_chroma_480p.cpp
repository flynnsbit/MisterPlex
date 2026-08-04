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
    expect(w == 624 && h == 480, "480p helper coded 624x480");
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

        // Default DDR policy force ON → Always → unverified exact CLAIM FOAR-codes
        // (not crop=618:480 — fails on fleet-mode 624x350; not identity_skip).
        r.scale_mode = ffmpegScaleModeForDdrYuvPresent(FfmpegScaleMode::SkipIdentity);
        const auto on = buildFfmpegVideoFilter(r);
        expect(on.scale_applied && !on.identity_skip, "default force scales unverified claim");
        expect_eq_str(on.reason, "force_unverified_claim_scale_pad_coded", "default force reason");
        expect(on.vf.find("scale=624:480") != std::string::npos, "FOAR into coded");
        expect(on.vf.find("scale=618:480") == std::string::npos, "no FOAR 618");
        expect(on.vf.find("crop=618:480") == std::string::npos, "no fixed crop claim");
        expect(on.vf.rfind("fps=24/1,", 0) == 0, "fps then scale-pad");

        // Escape force=0: SkipIdentity but unverified → still must NOT identity-skip.
        r.scale_mode = ffmpegScaleModeForDdrYuvPresent(FfmpegScaleMode::SkipIdentity, false);
        const auto off = buildFfmpegVideoFilter(r);
        expect(off.scale_applied && !off.identity_skip, "escape+unverified still scales");
        expect_eq_str(off.reason, "unverified_claim_scale_pad_coded", "escape guard reason");

        // Escape force=0 + VERIFIED match → may identity-skip (lab/direct-play).
        r.delivery_geometry_verified = true;
        const auto ver = buildFfmpegVideoFilter(r);
        expect(ver.identity_skip && !ver.scale_applied, "escape+verified may skip");
        expect_eq_str(ver.reason, "identity_skip_crop_pad_clear", "verified skip reason");
        // Always + verified exact → true identity.
        r.scale_mode = FfmpegScaleMode::Always;
        const auto avid = buildFfmpegVideoFilter(r);
        expect(avid.identity_skip && !avid.scale_applied, "Always+verified identity");
        expect_eq_str(avid.reason, "force_exact_identity_crop_clear", "Always verified reason");
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

    // --- F1c) DESYNC class model (B1: 640 was WRONG as the N=2 silicon story) ---
    // Capture evidence (cap480a f_020 vs cap480b f_049):
    //   - N=2 TREK24 copies in one raster → S ≈ 449280/2 = 224640 = 624x240 I420 EXACT
    //   - upright FLASH split L/R → horizontal component ⇒ producer width ≠ pure
    //     624 vertical-only stack alone (624x240 sim stacks two complete FLASH)
    //   - 640x480 = 460800 > 449280 cannot place two full frames in one raster
    // True single producer size is NOT uniquely pinned from stills; B2 measures it.
    // Gate keeps the CLASS (any S≠R under fixed reader) + N=2 candidate + risk API.
    {
        const size_t coded = yuv420pCodedFrameBytes(
            makeDdrFrameGeometry(kPlex480pCodedWidth.get(), kPlex480pCodedHeight.get()));
        const size_t s624x240 = yuv420pFrameBytesWH(624, 240); // 224640
        const size_t s320x240 = yuv420pFrameBytesWH(320, 240); // 115200
        const size_t s640x480 = yuv420pFrameBytesWH(640, 480); // 460800
        expect(coded == 449280u, "coded I420 bytes");
        expect(s624x240 == 224640u, "624x240 I420 (N=2 candidate)");
        expect(coded % s624x240 == 0u, "N=2 exact divide");
        expect(coded / s624x240 == 2u, "exactly two 624x240 per coded");
        // B1 discriminator: N copies → S ≈ reader/N (not 640x480).
        expect(producerBytesFromCounterCopies(coded, 2) == 224640u, "N=2 ⇒ 224640");
        expect(producerBytesFromCounterCopies(coded, 2) == s624x240, "N=2 matches 624x240");
        expect(producerBytesFromCounterCopies(coded, 4) == 112320u, "N=4 ⇒ 112320");
        expect(producerBytesFromCounterCopies(coded, 1) == coded, "N=1 ⇒ full bank");
        expect(producerBytesFromCounterCopies(coded, 0) == 0u, "N=0 guard");
        // 640x480 cannot explain N=2 full frames in one reader raster.
        expect(s640x480 > coded, "640x480 larger than reader — not N=2 packing");
        expect(s640x480 != producerBytesFromCounterCopies(coded, 2),
               "640x480 is NOT the N=2 producer size");
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
        // Parent RK6: measured 624x350 S=327600. With scale_mode=always identity_skip=0
        // the scaler bridges to reader 449280 — pipeDesyncRisk is FALSE (requires
        // identity_skip). Do NOT fit R/S=1.371 as a desync model for that session.
        // N=2 TREK24 still requires S=224640 (624x240) from an identity-skip capture.
        const size_t s624x350 = yuv420pFrameBytesWH(624, 350); // 327600
        expect(s624x350 == 327600u, "624x350 I420");
        expect(s624x350 < coded, "350 input smaller than coded bank");
        expect(coded % s624x350 != 0u, "350 does not tile reader exactly");
        expect(producerBytesFromCounterCopies(coded, 2) != s624x350,
               "N=2 discriminator is NOT 624x350");
        expect(!pipeDesyncRisk(s624x350, coded, false),
               "KILL 1.371 desync: identity_skip=0 → risk=0 (scaler bridges)");
        expect(pipeDesyncRisk(s624x350, coded, true), "350 + identity_skip=1: risk fires");
        expect(rawPipeDesynced(s624x350, coded, 1), "350 identity path would desync");
        std::printf("GREEN_DESYNC coded=%zu s624x240=%zu s624x350=%zu s640x480=%zu "
                    "(350 NOT N=2; 1.371 desync N/A when identity_skip=0)\n",
                    coded, s624x240, s624x350, s640x480);
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

    if (g_fails) {
        std::fprintf(stderr, "test_yuv420p_chroma_480p: %d failure(s)\n", g_fails);
        return 1;
    }
    std::printf("PASS test_yuv420p_chroma_480p\n");
    return 0;
}
