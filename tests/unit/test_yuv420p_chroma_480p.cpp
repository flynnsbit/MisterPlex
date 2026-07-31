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

    // --- E) YUV-DDR scale policy: SkipIdentity must become Always ---
    {
        expect(ffmpegScaleModeForDdrYuvPresent(FfmpegScaleMode::SkipIdentity) ==
                   FfmpegScaleMode::Always,
               "YUV DDR forces Always over SkipIdentity");
        expect(ffmpegScaleModeForDdrYuvPresent(FfmpegScaleMode::Always) ==
                   FfmpegScaleMode::Always,
               "Always stays Always");
        expect(ffmpegScaleModeForDdrYuvPresent(FfmpegScaleMode::Off) == FfmpegScaleMode::Off,
               "Off stays Off (lab)");
    }

    // --- F) Policy applied to 624x480 crop geometry yields scale_pad_crop ---
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
        // Conf default product SkipIdentity would identity-skip (unsafe on silicon).
        r.scale_mode = FfmpegScaleMode::SkipIdentity;
        const auto unsafe = buildFfmpegVideoFilter(r);
        expect(unsafe.identity_skip, "baseline conf SkipIdentity still skips (unsafe alone)");
        expect_eq_str(unsafe.reason, "identity_skip_crop_pad_clear", "unsafe reason");

        // YUV DDR wrapper forces Always → scale_pad_crop (matches 240p colour path).
        r.scale_mode = ffmpegScaleModeForDdrYuvPresent(FfmpegScaleMode::SkipIdentity);
        const auto safe = buildFfmpegVideoFilter(r);
        expect(safe.scale_applied && !safe.identity_skip, "DDR policy scales at 624");
        expect_eq_str(safe.reason, "scale_pad_crop", "DDR policy reason");
        expect(safe.vf.find("scale=618:480") != std::string::npos, "scale to display");
        expect(safe.vf.find("pad=624:480") != std::string::npos, "pad to coded");
        std::printf("GREEN_POLICY arm_rescale=1 reason=%s vf=%s\n", safe.reason.c_str(),
                    safe.vf.c_str());
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

    if (g_fails) {
        std::fprintf(stderr, "test_yuv420p_chroma_480p: %d failure(s)\n", g_fails);
        return 1;
    }
    std::printf("PASS test_yuv420p_chroma_480p\n");
    return 0;
}
