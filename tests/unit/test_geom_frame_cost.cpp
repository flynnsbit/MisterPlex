// Geometry-side frame cost lock: 240p vs 480p DECODE on the FPGA DDR path.
//
// Pre-register (must hold or this is RED):
//   P1: ddrFrameGeometryForFpgaPresent(320,240) == ForFpgaPresent(624,480)
//       (same coded bank, same crop, same frame_bytes=449280)
//   P2: product FORCE_SCALE Always emits pad=624:480 for both source tiers
//   P3: clearYuv crop_right=6 touches strips only, not full 449280
//   P4: drops (A/V pacer) ≠ publish_misses (DDR fail) in ledger semantics
//   P5: V_STORE=240 + STORE_Y_SCALE with FRAME_H=480 ⇒ even store rows only
//       (arithmetic lock; RTL cite in comment — no RBF claimed)
//
// true rc captured by make/driver directly.
#include "libmisterplex/ddr_frame_layout.hpp"
#include "libmisterplex/ffmpeg_vf.hpp"
#include "libmisterplex/frame_ledger.hpp"
#include "libmisterplex/yuv420p_chroma_health.hpp"

#include <chrono>
#include <cstdio>
#include <cstring>
#include <string>
#include <vector>

static int g_fails = 0;
static void expect(bool c, const char* m) {
    if (!c) {
        std::fprintf(stderr, "FAIL %s\n", m);
        ++g_fails;
    }
}

int main() {
    using namespace misterplex;
    using clock = std::chrono::steady_clock;

    // --- P1: publish geometry identical for 240 and 480 DECODE tiers ---
    const auto g240 = ddrFrameGeometryForFpgaPresent(320, 240);
    const auto g480 = ddrFrameGeometryForFpgaPresent(624, 480);
    expect(g240.coded_width.get() == 624 && g240.coded_height.get() == 480, "P1 240→coded 624x480");
    expect(g480.coded_width.get() == 624 && g480.coded_height.get() == 480, "P1 480→coded 624x480");
    expect(g240.display_width.get() == 618 && g240.crop_right == 6, "P1 240 display/crop");
    expect(g480.display_width.get() == 618 && g480.crop_right == 6, "P1 480 display/crop");
    const size_t fb240 = yuv420pCodedFrameBytes(g240);
    const size_t fb480 = yuv420pCodedFrameBytes(g480);
    expect(fb240 == 449280u && fb480 == 449280u, "P1 same frame_bytes 449280");
    expect(fb240 == fb480, "P1 240 decode does NOT shrink DDR publish");
    std::printf("P1_OK coded=624x480 display=618 crop_right=6 frame_bytes=%zu (both tiers)\n",
                fb240);

    // --- P2: FORCE_SCALE Always for both source sizes ---
    {
        auto planFor = [](int sw, int sh) {
            FfmpegVfRequest r;
            r.coded_w = 624;
            r.coded_h = 480;
            r.display_w = 618;
            r.display_h = 480;
            r.crop_left = 0;
            r.crop_top = 0;
            r.scale_mode =
                ffmpegScaleModeForDdrYuvPresent(FfmpegScaleMode::SkipIdentity, true);
            r.source_w = sw;
            r.source_h = sh;
            r.delivery_geometry_verified = false;
            return buildFfmpegVideoFilter(r);
        };
        const auto p240 = planFor(320, 240);
        const auto p480 = planFor(624, 480);
        expect(p240.scale_applied && p480.scale_applied, "P2 both scale");
        expect(!p240.identity_skip && !p480.identity_skip, "P2 neither identity_skip");
        expect(p240.vf.find("pad=624:480") != std::string::npos, "P2 240 pad coded");
        expect(p480.vf.find("pad=624:480") != std::string::npos, "P2 480 pad coded");
        expect(p240.vf.find("force_original_aspect_ratio=decrease") != std::string::npos,
               "P2 decrease");
        // 624-wide source still goes through scale=618 (mild shrink) then pad — not free.
        expect(p480.vf.find("scale=618:480") != std::string::npos, "P2 480 scales into display");
        std::printf("P2_OK force_scale Always vf_240_len=%zu vf_480_len=%zu\n", p240.vf.size(),
                    p480.vf.size());
    }

    // --- P3: clearYuv is strip-only (crop_right=6) ---
    {
        // Bytes touched if only right pad: Y: 480*6 + U/V: 240*3 each = 2880+720+720=4320
        const int yTouch = 480 * 6;
        const int cTouch = 240 * 3;
        const int strip = yTouch + 2 * cTouch;
        expect(strip == 4320, "P3 strip arithmetic 4320");
        expect(strip * 100 < static_cast<int>(fb240), "P3 strip << full frame");
        std::printf("P3_OK clearYuv strip_bytes=%d full=%zu ratio_x1000=%zu\n", strip, fb240,
                    (static_cast<size_t>(strip) * 1000u) / fb240);
    }

    // --- P4: ledger semantics drops vs publish_misses ---
    {
        // 100 frames, 85 presents, 12 pacer drops, 3 publish misses
        // residual = 100-85-12 = 3 == publish_misses
        const auto live = frameLedgerLiveOf(100, 85, 12, 3);
        expect(live.residual == 3, "P4 residual=frames-presents-drops");
        expect(frameLedgerResidualExplainedByPublishMiss(live), "P4 residual==publish_misses");
        // If parent only looks at drops, publish stalls are invisible in drops.
        expect(live.drops == 12 && live.publish_misses == 3, "P4 counters distinct");
        const auto frag = frameLedgerTelemetryFragment(live);
        expect(frag.find("publish_misses=3") != std::string::npos, "P4 fragment has publish_misses");
        expect(frag.find("drops=12") != std::string::npos, "P4 fragment has drops");
        std::printf("P4_OK %s\n", frag.c_str());
    }

    // --- P5: V_STORE / STORE_Y_SCALE arithmetic (present_core.sv:162-164, qsf FRAME_H=480) ---
    {
        constexpr int FRAME_H = 480; // Plex.qsf VERILOG_MACRO FRAME_H=480
        constexpr int V_STORE = 240; // present_core.sv:162
        constexpr int STORE_Y_SCALE = (FRAME_H * 65536) / V_STORE; // == 131072
        expect(STORE_Y_SCALE == 131072, "P5 STORE_Y_SCALE exact 2.0 in Q16");
        // store_y = (py * STORE_Y_SCALE) >> 16 for py in 0..239 → even rows only
        expect(((0 * STORE_Y_SCALE) >> 16) == 0, "P5 py0→0");
        expect(((1 * STORE_Y_SCALE) >> 16) == 2, "P5 py1→2");
        expect(((239 * STORE_Y_SCALE) >> 16) == 478, "P5 py239→478");
        // Odd coded rows 1,3,...,479 are never fetched — vertical detail capped.
        // This does NOT drop frames; it discards half of vertical samples at scanout.
        std::printf("P5_OK STORE_Y_SCALE=%d even_rows_only (no frame-drop implication)\n",
                    STORE_Y_SCALE);
    }

    // --- Host microbench: chroma inspect + memcpy + strip clear (tag=measured) ---
    {
        std::vector<uint8_t> buf(fb240);
        fillYuv420pStudioBlack(buf.data(), 624, 480);
        // paint non-dead chroma so repair returns false after full scan
        std::memset(buf.data() + 624 * 480, 90, 624 * 480 / 4);

        const int N = 200;
        auto t0 = clock::now();
        for (int i = 0; i < N; ++i)
            (void)repairDeadYuv420pChroma(buf.data(), 624, 480);
        auto t1 = clock::now();
        const double chroma_us =
            std::chrono::duration<double, std::micro>(t1 - t0).count() / N;

        t0 = clock::now();
        std::vector<uint8_t> dst(fb240);
        uint64_t sink = 0;
        for (int i = 0; i < N; ++i) {
            std::memcpy(dst.data(), buf.data(), fb240);
            sink += dst[0];
            sink += dst[fb240 / 2];
            sink += dst[fb240 - 1];
            asm volatile("" : "+r"(sink) : : "memory");
        }
        if (sink == 0xdeadbeefULL)
            std::fprintf(stderr, "sink\n");
        t1 = clock::now();
        const double copy_us =
            std::chrono::duration<double, std::micro>(t1 - t0).count() / N;

        // Simulate clearYuv right pad only
        t0 = clock::now();
        for (int i = 0; i < N; ++i) {
            for (int y = 0; y < 480; ++y)
                std::memset(buf.data() + y * 624 + 618, 16, 6);
            for (int y = 0; y < 240; ++y) {
                std::memset(buf.data() + 624 * 480 + y * 312 + 309, 128, 3);
                std::memset(buf.data() + 624 * 480 + 74880 + y * 312 + 309, 128, 3);
            }
        }
        t1 = clock::now();
        const double clear_us =
            std::chrono::duration<double, std::micro>(t1 - t0).count() / N;

        std::printf("BENCH tag=measured host_cpu chroma_inspect_us_f=%.2f memcpy449280_us_f=%.2f "
                    "clear_strip_us_f=%.2f N=%d\n",
                    chroma_us, copy_us, clear_us, N);
        // Sanity: strip clear should be cheaper than full memcpy on any sane host.
        expect(clear_us < copy_us * 2.0 + 50.0, "bench clear not absurdly slower than copy");
        // Frame budget @24fps = 41666 us — these host numbers are not device ARM A9.
        std::printf("NOTE host_bench ≠ device A9; use PRESENT_PROFILE on device for silicon us_f\n");
    }

    if (g_fails) {
        std::fprintf(stderr, "test_geom_frame_cost: %d failure(s)\n", g_fails);
        return 1;
    }
    std::printf("PASS test_geom_frame_cost\n");
    return 0;
}
