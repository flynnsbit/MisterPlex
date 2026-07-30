// Unit tests for the OSD menu word decode and the idle-screen renderer.
//
// These two headers are the contract between Plex.sv's CONF_STR and the daemon.
// If they drift apart the symptom is silent and awful — a menu item labelled
// "-40ms" applies +120ms — so the layout is pinned here rather than trusted.
#include "libmisterplex/idle_screen.hpp"
#include "libmisterplex/osd_menu.hpp"

#include <cstdint>
#include <cstdio>
#include <string>
#include <vector>

static int fails = 0;
#define CHECK(cond)                                                                              \
    do {                                                                                         \
        if (!(cond)) {                                                                           \
            std::fprintf(stderr, "FAIL %s:%d: %s\n", __FILE__, __LINE__, #cond);                 \
            ++fails;                                                                             \
        }                                                                                        \
    } while (0)

int main() {
    using namespace misterplex;

    // --- video delay: 4-bit signed wrap, 20 ms per step, biased to the default ---
    // Power-on status is all zeroes and Main_MiSTer cannot express a non-zero
    // default, so index 0 MUST mean 0 ms.
    CHECK(osdAvOffsetMsFromIndex(0) == kOsdAvOffsetDefaultMs);
    CHECK(osdAvOffsetMsFromIndex(1) == kOsdAvOffsetDefaultMs + 20);
    CHECK(osdAvOffsetMsFromIndex(7) == kOsdAvOffsetDefaultMs + 140);
    CHECK(osdAvOffsetMsFromIndex(8) == kOsdAvOffsetDefaultMs - 160);
    CHECK(osdAvOffsetMsFromIndex(15) == kOsdAvOffsetDefaultMs - 20);
    // The knob must stay monotonic across the wrap seam: index 15 is exactly one
    // step below index 0, so left/right on the OSD never jumps.
    CHECK(osdAvOffsetMsFromIndex(15) + kOsdAvOffsetStepMs == osdAvOffsetMsFromIndex(0));
    // Every index maps to a distinct, in-range value.
    for (unsigned i = 0; i < 16; ++i) {
        const int ms = osdAvOffsetMsFromIndex(i);
        CHECK(ms >= kOsdAvOffsetDefaultMs - 160 && ms <= kOsdAvOffsetDefaultMs + 140);
        CHECK(ms % kOsdAvOffsetStepMs == 0);
    }

    // --- word decode: bit positions must match CONF_STR exactly ---
    {
        const OsdSettings d = decodeOsdWord(0x0000);
        CHECK(d.avOffsetMs == kOsdAvOffsetDefaultMs);
        CHECK(d.audioClockTrimEnabled);
        CHECK(d.resyncEnabled);
        CHECK(d.idleMode == 0);
        CHECK(d.contentResolution.width == 320);
        CHECK(d.contentResolution.height == 240);
        CHECK(std::string(d.contentResolution.label) == "320x240");
    }
    CHECK(decodeOsdWord(1u << 1).resyncEnabled == false);   // O[1] A/V auto resync
    CHECK(!decodeOsdWord(1u << 3).audioClockTrimEnabled); // O[3] Audio clock trim
    const auto osd480 = decodeOsdWord(1u << 4).contentResolution; // O[4] 480p path
    CHECK(osd480.width == kPlex480pCodedWidth);
    CHECK(osd480.height == kPlex480pCodedHeight);
    CHECK(std::string(osd480.label) == "624x480");
    CHECK(osd480.weakBitrateKbps == kPlex480pWeakBitrateKbps);
    CHECK(decodeOsdWord(0xFu << 6).avOffsetMs == kOsdAvOffsetDefaultMs - 20); // O[9:6] idx 15
    CHECK(decodeOsdWord(8u << 6).avOffsetMs == kOsdAvOffsetDefaultMs - 160); // O[9:6] idx 8
    CHECK(decodeOsdWord(3u << 14).idleMode == 3);           // O[15:14] Idle screen
    // Core-owned bits must not leak into user settings.
    for (int bit : {0, 2, 5, 10, 11, 12, 13}) {
        const OsdSettings d = decodeOsdWord(static_cast<uint16_t>(1u << bit));
        CHECK(d.avOffsetMs == kOsdAvOffsetDefaultMs);
        CHECK(d.resyncEnabled);
        CHECK(d.audioClockTrimEnabled);
        CHECK(d.idleMode == 0);
        CHECK(d.contentResolution.width == 320);
    }
    CHECK(contentResolutionFromSize(320, 240).width == 320);
    const auto fallback480 =
        contentResolutionFromCodedSize(kPlex480pCodedWidth, kPlex480pCodedHeight);
    CHECK(fallback480.width == osd480.width);
    CHECK(fallback480.height == osd480.height);
    CHECK(std::string(fallback480.label) == osd480.label);
    CHECK(fallback480.weakBitrateKbps == osd480.weakBitrateKbps);
    CHECK(weakBitrateKbpsForCodedSize(kPlex480pCodedWidth, kPlex480pCodedHeight) ==
          osd480.weakBitrateKbps);
    CHECK(contentResolutionFromSize(640, 480).width == kPlex480pCodedWidth);
    CHECK(contentResolutionFromSize(640, 480).weakBitrateKbps == kPlex480pWeakBitrateKbps);
    CHECK(weakBitrateKbpsForCodedSize(480, 360) == kPlex360pWeakBitrateKbps);

    // --- change detection ignores core traffic ---
    // [10]/[11] flush pulses and [12]/[13] DDR kick/bank toggle constantly during
    // playback; reacting to them would re-log and re-apply settings every frame.
    for (int bit : {0, 2, 5, 10, 11, 12, 13})
        CHECK(!osdChanged(0, static_cast<uint16_t>(1u << bit)));
    for (int bit : {1, 3, 4, 6, 7, 8, 9, 14, 15})
        CHECK(osdChanged(0, static_cast<uint16_t>(1u << bit)));

    // First OSD word = Main's persisted F12 Idle Screen (Plex_v7.CFG). Apply it
    // so menu idle survives daemon restart. Later: idle bits only on change.
    CHECK(shouldApplyOsdIdle(false, 0x0000, 0x4000));  // startup apply Black
    CHECK(!shouldApplyOsdIdle(true, 0x4000, 0x4000));  // unchanged
    CHECK(!shouldApplyOsdIdle(true, 0x4000, 0x4040));  // video-delay-only change
    CHECK(shouldApplyOsdIdle(true, 0x0000, 0x4000));   // live Logo -> Black
    CHECK(shouldApplyOsdIdle(true, 0x4000, 0x8000));   // live Black -> Screensaver
    CHECK(kOsdIdleMask == 0xC000);

    // --- idle mode bits match CONF_STR order ---
    CHECK(idleModeFromBits(0) == IdleMode::Logo);
    CHECK(idleModeFromBits(1) == IdleMode::Black);
    CHECK(idleModeFromBits(2) == IdleMode::Screensaver);
    CHECK(idleModeFromBits(3) == IdleMode::LastFrame);

    // --- applyOsd decision path (planOsdIdleApply — same as media_player) ---
    // NOT a private render lambda: this is the setIdleMode + paintIdle guard.
    {
        // Startup first word → Black while idle: must set mode and paint.
        auto boot = planOsdIdleApply(/*applyIdle=*/true, IdleMode::Logo, /*bits=*/1,
                                     /*playing=*/false, /*havePrior=*/false);
        CHECK(boot.touchMode && boot.mode == IdleMode::Black);
        CHECK(boot.idleChanged && boot.paint);
        CHECK(boot.paintMode == IdleMode::Black);

        // Unchanged idle bits: no paint.
        auto same = planOsdIdleApply(true, IdleMode::Black, 1, false, false);
        CHECK(same.touchMode && !same.idleChanged && !same.paint);

        // Playing: mode may change but must not paint over video.
        auto live = planOsdIdleApply(true, IdleMode::Logo, 2, /*playing=*/true, false);
        CHECK(live.touchMode && live.mode == IdleMode::Screensaver);
        CHECK(live.idleChanged && !live.paint);

        // LastFrame at boot (no prior frame): MUST paint fallback (not leave logo).
        auto lfBoot = planOsdIdleApply(true, IdleMode::Logo, /*bits=*/3, false,
                                       /*havePrior=*/false);
        CHECK(lfBoot.touchMode && lfBoot.mode == IdleMode::LastFrame);
        CHECK(lfBoot.idleChanged && lfBoot.paint);
        CHECK(lfBoot.paintMode == kLastFrameNoPriorFallback);
        CHECK(lfBoot.paintMode == IdleMode::Black);

        // LastFrame with a real latched frame: leave DDR alone (no paint).
        auto lfOk = planOsdIdleApply(true, IdleMode::Black, 3, false, /*havePrior=*/true);
        CHECK(lfOk.mode == IdleMode::LastFrame && lfOk.idleChanged && !lfOk.paint);
        CHECK(lfOk.paintMode == IdleMode::LastFrame);

        // applyIdle=false (shouldApplyOsdIdle said no): no touch.
        auto skip = planOsdIdleApply(false, IdleMode::Logo, 1, false, false);
        CHECK(!skip.touchMode && !skip.paint);

        // Idle thread: LastFrame without prior still repaints fallback; with prior skips.
        CHECK(idleThreadShouldRepaint(IdleMode::LastFrame, false, false));
        CHECK(!idleThreadShouldRepaint(IdleMode::LastFrame, false, true));
        CHECK(!idleThreadShouldRepaint(IdleMode::Logo, true, false));
        CHECK(idleThreadShouldRepaint(IdleMode::Screensaver, false, false));
    }

    // --- Renderer checksums (buffer fill only — not the applyOsd paint gate) ---
    // Proves modes are distinguishable and screensaver moves; does not prove
    // MediaPlayer issued paintIdle. That is planOsdIdleApply above.
    auto fnv1a = [](const uint8_t* p, size_t n) -> uint64_t {
        uint64_t h = 14695981039346656037ull;
        for (size_t i = 0; i < n; ++i) {
            h ^= p[i];
            h *= 1099511628211ull;
        }
        return h;
    };
    {
        const int yw = 320, yh = 240;
        // Drive paint the way paintIdle does after planOsdIdleApply:
        // decodeOsdWord → effectiveIdlePaintMode → renderIdleYuv420p
        auto paintFromOsdWord = [&](uint16_t word, int phase, bool havePrior,
                                    std::vector<uint8_t>& yuv) -> bool {
            const OsdSettings s = decodeOsdWord(word);
            const IdleMode req = idleModeFromBits(static_cast<unsigned>(s.idleMode));
            const IdleMode paint = effectiveIdlePaintMode(req, havePrior);
            if (req == IdleMode::LastFrame && havePrior)
                return false; // genuine last-frame: paintIdle returns without render
            return renderIdleYuv420p(yuv.data(), yw, yh, paint, phase);
        };
        const size_t ysz = static_cast<size_t>(yw) * yh * 3 / 2;
        std::vector<uint8_t> yLogo(ysz), yBlack(ysz), ySs0(ysz), ySs1(ysz);
        std::vector<uint8_t> yLastNoPrior(ysz, 0x5A), yLastPrior(ysz, 0x5A);
        // OSD idle bits sit at [15:14]: 0=Logo 1=Black 2=Screensaver 3=LastFrame
        CHECK(paintFromOsdWord(static_cast<uint16_t>(0u << 14), 0, false, yLogo));
        CHECK(paintFromOsdWord(static_cast<uint16_t>(1u << 14), 0, false, yBlack));
        CHECK(paintFromOsdWord(static_cast<uint16_t>(2u << 14), 0, false, ySs0));
        CHECK(paintFromOsdWord(static_cast<uint16_t>(2u << 14), 100, false, ySs1));
        // LastFrame + no prior → paints Black fallback (not a silent no-op).
        CHECK(paintFromOsdWord(static_cast<uint16_t>(3u << 14), 0, false, yLastNoPrior));
        // LastFrame + prior → no paint (sentinel preserved).
        CHECK(!paintFromOsdWord(static_cast<uint16_t>(3u << 14), 0, true, yLastPrior));
        const uint64_t cLogo = fnv1a(yLogo.data(), yLogo.size());
        const uint64_t cBlack = fnv1a(yBlack.data(), yBlack.size());
        const uint64_t cSs0 = fnv1a(ySs0.data(), ySs0.size());
        const uint64_t cSs1 = fnv1a(ySs1.data(), ySs1.size());
        const uint64_t cLfFb = fnv1a(yLastNoPrior.data(), yLastNoPrior.size());
        const uint64_t cLfPrior = fnv1a(yLastPrior.data(), yLastPrior.size());
        std::printf("idle_osd_checksum logo=0x%016llx black=0x%016llx ss0=0x%016llx "
                    "ss1=0x%016llx lastframe_fallback=0x%016llx lastframe_prior_sentinel=0x%016llx\n",
                    static_cast<unsigned long long>(cLogo),
                    static_cast<unsigned long long>(cBlack),
                    static_cast<unsigned long long>(cSs0),
                    static_cast<unsigned long long>(cSs1),
                    static_cast<unsigned long long>(cLfFb),
                    static_cast<unsigned long long>(cLfPrior));
        CHECK(cLogo != cBlack);
        CHECK(cLogo != cSs0);
        CHECK(cBlack != cSs0);
        CHECK(cSs0 != cSs1); // screensaver advances
        // No-prior LastFrame fallback is video black — not the frozen logo.
        CHECK(cLfFb == cBlack);
        CHECK(cLfFb != cLogo);
        // Prior LastFrame left the sentinel untouched.
        for (uint8_t v : yLastPrior)
            CHECK(v == 0x5A);
        CHECK(cLfPrior != cBlack && cLfPrior != cLogo);
        const size_t yBytes = static_cast<size_t>(yw) * yh;
        const size_t cBytes = yBytes / 4;
        for (size_t i = 0; i < yBytes; ++i)
            CHECK(yBlack[i] == 16);
        for (size_t i = 0; i < cBytes; ++i) {
            CHECK(yBlack[yBytes + i] == 128);
            CHECK(yBlack[yBytes + cBytes + i] == 128);
        }
        size_t logoNonBlack = 0;
        for (size_t i = 0; i < yBytes; ++i)
            if (yLogo[i] != 16)
                ++logoNonBlack;
        CHECK(logoNonBlack > 0);
    }

    // effectiveIdlePaintMode is explicit (not "we did not paint").
    CHECK(effectiveIdlePaintMode(IdleMode::LastFrame, false) == IdleMode::Black);
    CHECK(effectiveIdlePaintMode(IdleMode::LastFrame, true) == IdleMode::LastFrame);
    CHECK(effectiveIdlePaintMode(IdleMode::Logo, false) == IdleMode::Logo);

    // --- screensaver drift stays on screen and reverses ---
    const int span = 40;
    for (int p = -5000; p < 5000; ++p) {
        const int d = idleDrift(p, span);
        CHECK(d >= 0 && d <= span);
    }
    CHECK(idleDrift(0, span) == 0);
    CHECK(idleDrift(kIdlePhasePeriod / 2, span) == span);
    CHECK(idleDrift(kIdlePhasePeriod, span) == 0);
    CHECK(idleDrift(0, 0) == 0);

    // --- renderer ---
    const int w = 320, h = 240;
    std::vector<uint8_t> buf(static_cast<size_t>(w) * h * 3);

    // Black is exactly black: this is the burn-in-safe mode, no stray pixels.
    std::fill(buf.begin(), buf.end(), 0xAB);
    renderIdleRgb24(buf.data(), w, h, IdleMode::Black, 0);
    for (uint8_t v : buf)
        CHECK(v == 0);

    // Renderer LastFrame token is still a no-op; callers must pass
    // effectiveIdlePaintMode(...) so no-prior becomes Black before render.
    std::fill(buf.begin(), buf.end(), 0xAB);
    renderIdleRgb24(buf.data(), w, h, IdleMode::LastFrame, 0);
    for (uint8_t v : buf)
        CHECK(v == 0xAB);
    std::fill(buf.begin(), buf.end(), 0xAB);
    renderIdleRgb24(buf.data(), w, h,
                    effectiveIdlePaintMode(IdleMode::LastFrame, /*havePrior=*/false), 0);
    for (uint8_t v : buf)
        CHECK(v == 0); // Black fallback

    // Logo paints the background everywhere and the mark somewhere.
    std::fill(buf.begin(), buf.end(), 0xAB);
    renderIdleRgb24(buf.data(), w, h, IdleMode::Logo, 0);
    size_t fg = 0, bg = 0, other = 0;
    for (size_t i = 0; i + 2 < buf.size(); i += 3) {
        if (buf[i] == kIdleFgR && buf[i + 1] == kIdleFgG && buf[i + 2] == kIdleFgB)
            ++fg;
        else if (buf[i] == kIdleBgR && buf[i + 1] == kIdleBgG && buf[i + 2] == kIdleBgB)
            ++bg;
        else
            ++other;
    }
    CHECK(other == 0);
    CHECK(fg > 0);
    CHECK(bg > fg);

    // The screensaver must never render into the overscan margin, at any phase.
    for (int p = 0; p < kIdlePhasePeriod; p += 7) {
        std::fill(buf.begin(), buf.end(), 0);
        renderIdleRgb24(buf.data(), w, h, IdleMode::Screensaver, p);
        for (int y = 0; y < h; ++y) {
            for (int x = 0; x < w; ++x) {
                const size_t i = (static_cast<size_t>(y) * w + x) * 3;
                const bool isFg =
                    buf[i] == kIdleFgR && buf[i + 1] == kIdleFgG && buf[i + 2] == kIdleFgB;
                if (!isFg)
                    continue;
                CHECK(x >= kIdleMargin && x < w - kIdleMargin);
                CHECK(y >= kIdleMargin && y < h - kIdleMargin);
            }
        }
    }

    // DDR idle is I420/YUV420p now. Black must be exact video black, while
    // logo/screensaver must preserve the renderer rather than degenerating to
    // a black-only frame.
    std::vector<uint8_t> yuv(static_cast<size_t>(w) * h * 3 / 2);
    CHECK(renderIdleYuv420p(yuv.data(), w, h, IdleMode::Black, 0));
    const size_t yBytes = static_cast<size_t>(w) * h;
    const size_t cBytes = yBytes / 4;
    for (size_t i = 0; i < yBytes; ++i)
        CHECK(yuv[i] == 16);
    for (size_t i = 0; i < cBytes; ++i) {
        CHECK(yuv[yBytes + i] == 128);
        CHECK(yuv[yBytes + cBytes + i] == 128);
    }

    std::vector<uint8_t> yuv2(yuv.size());
    CHECK(renderIdleYuv420p(yuv.data(), w, h, IdleMode::Screensaver, 0));
    CHECK(renderIdleYuv420p(yuv2.data(), w, h, IdleMode::Screensaver, kIdlePhasePeriod / 4));
    size_t nonBlackLuma = 0;
    size_t changed = 0;
    for (size_t i = 0; i < yBytes; ++i) {
        if (yuv[i] != 16)
            ++nonBlackLuma;
        if (yuv[i] != yuv2[i])
            ++changed;
    }
    CHECK(nonBlackLuma > yBytes / 2);
    CHECK(changed > 0);

    // A valid YUV doorbell carrying valid all-black pixels is still a regression:
    // the frame store cannot distinguish that from a deliberate black screen.
    // Grade the actual I420 pixels so logo/screensaver content cannot disappear
    // behind a formally valid payload again.
    constexpr uint8_t kBgY = 45, kBgU = 130, kBgV = 126;
    constexpr uint8_t kFgY = 157, kFgU = 53, kFgV = 169;
    auto sampleIsFg = [](int x, int y, const IdleRenderState& state) {
        uint8_t r = 0, g = 0, b = 0;
        idlePixelRgb(x, y, state, r, g, b);
        return r == kIdleFgR && g == kIdleFgG && b == kIdleFgB;
    };
    auto findSolid2x2 = [&](IdleMode mode, int phase, bool wantFg, int& outX, int& outY) {
        const IdleRenderState state = idleRenderState(w, h, mode, phase);
        for (int y = 0; y + 1 < h; y += 2) {
            for (int x = 0; x + 1 < w; x += 2) {
                bool solid = true;
                for (int dy = 0; dy < 2; ++dy)
                    for (int dx = 0; dx < 2; ++dx)
                        solid = solid && (sampleIsFg(x + dx, y + dy, state) == wantFg);
                if (solid) {
                    outX = x;
                    outY = y;
                    return true;
                }
            }
        }
        return false;
    };
    auto expectI420Sample = [&](const std::vector<uint8_t>& frame, int x, int y, uint8_t yy,
                                uint8_t uu, uint8_t vv) {
        const size_t yi = static_cast<size_t>(y) * w + x;
        const size_t ci = static_cast<size_t>(y / 2) * (w / 2) + (x / 2);
        CHECK(frame[yi] == yy);
        CHECK(frame[yBytes + ci] == uu);
        CHECK(frame[yBytes + cBytes + ci] == vv);
    };

    int fgX0 = 0, fgY0 = 0, bgX0 = 0, bgY0 = 0, fgX1 = 0, fgY1 = 0;
    CHECK(findSolid2x2(IdleMode::Screensaver, 0, true, fgX0, fgY0));
    CHECK(findSolid2x2(IdleMode::Screensaver, 0, false, bgX0, bgY0));
    CHECK(findSolid2x2(IdleMode::Screensaver, kIdlePhasePeriod / 4, true, fgX1, fgY1));
    expectI420Sample(yuv, fgX0, fgY0, kFgY, kFgU, kFgV);
    expectI420Sample(yuv, bgX0, bgY0, kBgY, kBgU, kBgV);
    expectI420Sample(yuv2, fgX1, fgY1, kFgY, kFgU, kFgV);
    CHECK(fgX0 != fgX1 || fgY0 != fgY1);

    if (fails) {
        std::fprintf(stderr, "test_osd_menu: %d failure(s)\n", fails);
        return 1;
    }
    std::printf("test_osd_menu: OK\n");
    return 0;
}
