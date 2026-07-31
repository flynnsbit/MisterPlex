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

    // --- E) YUV-DDR scale policy: default OFF; force=1 maps SkipIdentity→Always ---
    {
        expect(ffmpegScaleModeForDdrYuvPresent(FfmpegScaleMode::SkipIdentity) ==
                   FfmpegScaleMode::SkipIdentity,
               "default force=0 leaves SkipIdentity");
        expect(ffmpegScaleModeForDdrYuvPresent(FfmpegScaleMode::SkipIdentity, false) ==
                   FfmpegScaleMode::SkipIdentity,
               "explicit force=0 leaves SkipIdentity");
        expect(ffmpegScaleModeForDdrYuvPresent(FfmpegScaleMode::SkipIdentity, true) ==
                   FfmpegScaleMode::Always,
               "force=1 maps SkipIdentity→Always");
        expect(ffmpegScaleModeForDdrYuvPresent(FfmpegScaleMode::Always, true) ==
                   FfmpegScaleMode::Always,
               "Always stays Always");
        expect(ffmpegScaleModeForDdrYuvPresent(FfmpegScaleMode::Off, true) == FfmpegScaleMode::Off,
               "Off stays Off (lab)");
    }

    // --- F) force=1 at 624x480 yields scale_pad_crop; force=0 identity-skips ---
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
        // Default product SkipIdentity identity-skips at native 480p.
        r.scale_mode = FfmpegScaleMode::SkipIdentity;
        const auto def = buildFfmpegVideoFilter(r);
        expect(def.identity_skip, "default SkipIdentity skips at 624");
        expect_eq_str(def.reason, "identity_skip_crop_pad_clear", "default reason");

        r.scale_mode = ffmpegScaleModeForDdrYuvPresent(FfmpegScaleMode::SkipIdentity, false);
        const auto off = buildFfmpegVideoFilter(r);
        expect(off.identity_skip, "force=0 still identity-skips");

        r.scale_mode = ffmpegScaleModeForDdrYuvPresent(FfmpegScaleMode::SkipIdentity, true);
        const auto on = buildFfmpegVideoFilter(r);
        expect(on.scale_applied && !on.identity_skip, "force=1 scales at 624");
        expect_eq_str(on.reason, "scale_pad_crop", "force=1 reason");
        expect(on.vf.find("scale=618:480") != std::string::npos, "scale to display");
        expect(on.vf.find("pad=624:480") != std::string::npos, "pad to coded");
        std::printf("GREEN_POLICY force0_skip=1 force1_reason=%s vf=%s\n", on.reason.c_str(),
                    on.vf.c_str());
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
