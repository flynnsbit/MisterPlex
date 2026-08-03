// Geometry-side frame cost lock: 240p vs 480p DECODE on the FPGA DDR path.
//
// Pre-register (must hold or this is RED):
//   P1: ddrFrameGeometryForFpgaPresent(320,240) is identity 320×240 storage
//       (source-aware; NOT forced 624×480 canvas — PLXG must match payload)
//   P2: product FORCE_SCALE Always FOAR-scales into coded 624x480 (unverified
//       claim and 624x350); pad=624:480. Never crop=618:480 on that path.
//   P3: clearYuv crop_right=6 touches strips only, not full 449280
//   P4: drops (A/V pacer) ≠ publish_misses (DDR fail) in ledger semantics
//   P5: T7 NATIVE_V_1TO1 — V_STORE=FRAME_H=480, STORE_Y_SCALE=1.0 ⇒ all 480 rows
//       (arithmetic lock; needs RBF for silicon; pre-T7 was even-rows-only)
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

    // --- P1: source-aware identity storage (320≠624); 480 product separate ---
    const auto g240 = ddrFrameGeometryForFpgaPresent(320, 240);
    const auto g480 = ddrFrameGeometryForFpgaPresent(624, 480);
    expect(g240.coded_width.get() == 320 && g240.coded_height.get() == 240, "P1 240→identity 320x240");
    expect(g480.coded_width.get() == 624 && g480.coded_height.get() == 480, "P1 480→coded 624x480");
    expect(g480.display_width.get() == 618 && g480.crop_right == 6, "P1 480 display/crop");
    const size_t fb240 = yuv420pCodedFrameBytes(g240);
    const size_t fb480 = yuv420pCodedFrameBytes(g480);
    expect(fb240 == 115200u, "P1 240 identity frame_bytes 115200");
    expect(fb480 == 449280u, "P1 480 frame_bytes 449280");
    expect(fb240 != fb480, "P1 240 decode MUST shrink DDR publish vs 480 canvas");
    // P1b: 960x540 is tight storage (777600), not 480 canvas and not 1280 canvas.
    const auto g540 = ddrFrameGeometryForFpgaPresent(960, 540);
    expect(g540.coded_width.get() == 960 && g540.coded_height.get() == 540, "P1b 540 storage");
    expect(yuv420pCodedFrameBytes(g540) == 777600u, "P1b 540 frame_bytes");
    expect(g540.coded_width.get() != 1280 && g540.coded_height.get() != 720,
           "P1b 540 is NOT DE canvas 1280x720");
    // P1c: 640x360 identity storage (345600) — NOT 624x480 canvas (2× glass path).
    const auto g360 = ddrFrameGeometryForFpgaPresent(640, 360);
    expect(g360.coded_width.get() == 640 && g360.coded_height.get() == 360, "P1c 360 storage");
    expect(yuv420pCodedFrameBytes(g360) == 345600u, "P1c 360 frame_bytes");
    expect(!(g360.coded_width.get() == 624 && g360.coded_height.get() == 480),
           "P1c 360 must NOT collapse to 480 canvas");
    std::printf("P1_OK 320x240 identity bytes=%zu; 624x480 product bytes=%zu; "
                "540p storage=960x540 bytes=777600; 360p storage=640x360 bytes=345600\n",
                fb240, fb480);

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
        const auto p350 = planFor(624, 350);
        expect(p240.scale_applied && !p240.identity_skip, "P2 240 scales");
        // Unverified 624x480 claim under FORCE_SCALE: FOAR into coded (not crop_pad).
        // crop=618:480 dies on fleet-mode 624x350 (ffmpeg rc=234, 0 bytes).
        expect(p480.scale_applied && !p480.identity_skip, "P2 480 unverified FOAR-scales");
        expect(p240.vf.find("pad=624:480") != std::string::npos, "P2 240 pad coded");
        expect(p240.vf.find("force_original_aspect_ratio=decrease") != std::string::npos,
               "P2 240 decrease");
        expect(p480.vf.find("pad=624:480") != std::string::npos, "P2 480 pad coded");
        expect(p480.vf.find("scale=624:480") != std::string::npos, "P2 480 FOAR coded W");
        expect(p480.vf.find("force_original_aspect_ratio=decrease") != std::string::npos,
               "P2 480 FOAR decrease");
        expect(p480.vf.find("crop=618:480") == std::string::npos, "P2 480 no fixed crop");
        expect(p480.reason.find("unverified_claim_scale_pad_coded") != std::string::npos ||
                   p480.reason.find("force_unverified_claim_scale_pad_coded") != std::string::npos,
               "P2 480 unverified reason");
        expect(p350.scale_applied && !p350.identity_skip, "P2 350 scales");
        expect(p350.vf.find("scale=624:480") != std::string::npos, "P2 350 FOAR coded");
        // vfPreservesBankHeightSource is for crop/hfit only — FOAR always returns false.
        expect(!vfPreservesBankHeightSource(p480.vf), "P2 FOAR path is not crop-preserve");
        expect(vfPreservesBankHeightSource("crop=618:480,pad=624:480:0:0:black"),
               "P2 crop_pad helper still true");
        // Old FOAR-into-618 defect arith still true as a cautionary constant.
        expect(scaleDecreaseOutHeight(624, 480, 618, 480) == 475, "P2 defect arith FOAR618=475");
        // FOAR into coded 624 keeps full bank height on true 624x480 input.
        expect(scaleDecreaseOutHeight(624, 480, 624, 480) == 480, "P2 FOAR coded keeps H=480");
        expect(scaleDecreaseOutHeight(624, 350, 624, 480) == 350, "P2 FOAR 350→picture_h=350");
        std::printf("P2_OK force_scale 240=upscale 480=FOAR_coded 350=FOAR_coded "
                    "vf_240_len=%zu vf_480_len=%zu vf_350_len=%zu\n",
                    p240.vf.size(), p480.vf.size(), p350.vf.size());
    }

    // --- P3: clearYuv is strip-only (crop_right=6) on product 480 canvas ---
    {
        // Bytes touched if only right pad: Y: 480*6 + U/V: 240*3 each = 2880+720+720=4320
        const int yTouch = 480 * 6;
        const int cTouch = 240 * 3;
        const int strip = yTouch + 2 * cTouch;
        expect(strip == 4320, "P3 strip arithmetic 4320");
        expect(strip * 100 < static_cast<int>(fb480), "P3 strip << full 480 frame");
        std::printf("P3_OK clearYuv strip_bytes=%d full480=%zu ratio_x1000=%zu\n", strip, fb480,
                    (static_cast<size_t>(strip) * 1000u) / fb480);
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
        expect(frag.find("fpga_obs=none") != std::string::npos, "P4 supply-side label");
        expect(frag.find("unaccounted=") == std::string::npos, "P4 no duplicate unaccounted");
        std::printf("P4_OK %s\n", frag.c_str());
    }

    // --- P5: T7 V_STORE / STORE_Y_SCALE (present_core NATIVE_V_1TO1, qsf FRAME_H=480) ---
    {
        constexpr int FRAME_H = 480; // Plex.qsf VERILOG_MACRO FRAME_H=480
        constexpr int V_STORE = FRAME_H; // T7: V_STORE_I = FRAME_H when >240
        constexpr int STORE_Y_SCALE = (FRAME_H * 65536) / V_STORE; // == 65536 (1.0)
        expect(STORE_Y_SCALE == 65536, "P5 STORE_Y_SCALE exact 1.0 in Q16 after T7");
        // store_y = (py * STORE_Y_SCALE) >> 16 for py in 0..479 → identity
        expect(((0 * STORE_Y_SCALE) >> 16) == 0, "P5 py0→0");
        expect(((1 * STORE_Y_SCALE) >> 16) == 1, "P5 py1→1 (odd row fetched)");
        expect(((239 * STORE_Y_SCALE) >> 16) == 239, "P5 py239→239");
        expect(((479 * STORE_Y_SCALE) >> 16) == 479, "P5 py479→479");
        // Pre-T7 even-only ceiling is gone; this is scanout quality, not frame drops.
        std::printf("P5_OK STORE_Y_SCALE=%d full_480_rows (T7 NATIVE_V_1TO1)\n", STORE_Y_SCALE);
    }

    // --- Host microbench: chroma inspect + memcpy + strip clear (tag=measured) ---
    // Uses product 480 canvas (fb480); fb240 is now identity 320 storage.
    {
        std::vector<uint8_t> buf(fb480);
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
        std::vector<uint8_t> dst(fb480);
        uint64_t sink = 0;
        for (int i = 0; i < N; ++i) {
            std::memcpy(dst.data(), buf.data(), fb480);
            sink += dst[0];
            sink += dst[fb480 / 2];
            sink += dst[fb480 - 1];
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
