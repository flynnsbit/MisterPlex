// Red-before-green: supply bucket + ffmpeg frame= parse + pipe identity.
// Parent: 22 glass skips with residual=0 — need PRE vs POST split.
// true rc direct. No device.
#include "libmisterplex/supply_bucket.hpp"

#include <cmath>
#include <cstdio>
#include <cstring>
#include <string>

static int fails = 0;
#define CHECK(c)                                                                                 \
    do {                                                                                         \
        if (!(c)) {                                                                              \
            std::fprintf(stderr, "FAIL %s:%d: %s\n", __FILE__, __LINE__, #c);                     \
            ++fails;                                                                             \
        }                                                                                        \
    } while (0)

int main() {
    using namespace misterplex;

    // --- parse frame= (RED if we only accept exact "frame=N" without spaces) ---
    {
        int64_t v = -1;
        CHECK(parseFfmpegFrameCountLine("frame=123", &v) && v == 123);
        CHECK(parseFfmpegFrameCountLine("frame=  456 fps=24 q=-1.0", &v) && v == 456);
        CHECK(parseFfmpegFrameCountLine("frame=1\r", &v) && v == 1);
        CHECK(!parseFfmpegFrameCountLine("fps=24", &v));
        CHECK(!parseFfmpegFrameCountLine("Stream #0:0", &v));
        CHECK(!parseFfmpegFrameCountLine(nullptr, &v));
        std::printf("PASS parse frame=\n");
    }

    // --- CR progress lines (RED if pump only splits on \\n) ---
    {
        std::string acc = "frame=  10 fps=24\rframe=  20 fps=24\r\nframe=30\npartial";
        std::string line;
        CHECK(takeFfmpegStderrLine(acc, &line));
        int64_t v = -1;
        CHECK(parseFfmpegFrameCountLine(line, &v) && v == 10);
        CHECK(takeFfmpegStderrLine(acc, &line));
        CHECK(parseFfmpegFrameCountLine(line, &v) && v == 20);
        CHECK(takeFfmpegStderrLine(acc, &line));
        CHECK(parseFfmpegFrameCountLine(line, &v) && v == 30);
        CHECK(!takeFfmpegStderrLine(acc, &line)); // "partial" has no separator yet
        CHECK(acc == "partial");
        std::printf("PASS takeFfmpegStderrLine CR/LF\n");
    }

    // --- pipe identity ---
    {
        const size_t fb = 449280u;
        auto ok = supplyPipeIdentity(fb * 100u, fb, 100);
        CHECK(ok.ok && ok.byte_aligned && ok.delta_frames_vs_bytes == 0);
        auto bad = supplyPipeIdentity(fb * 100u + 50u, fb, 100);
        CHECK(!bad.byte_aligned && !bad.ok);
        auto mismatch = supplyPipeIdentity(fb * 100u, fb, 99);
        CHECK(mismatch.byte_aligned && !mismatch.ok && mismatch.delta_frames_vs_bytes == -1);
        std::printf("PASS pipe identity\n");
    }

    // --- 1 s bucket: perfect 24 fps ---
    {
        SupplyCounters a{}, b{};
        a.wall_s = 10.0;
        a.frames = 240;
        a.presents = 232;
        a.drops = 8;
        a.publish_misses = 0;
        a.pipe_bytes = 240LL * 449280;
        a.ffmpeg_out_frames = 240;
        b = a;
        b.wall_s = 11.0;
        b.frames = 264;
        b.presents = 256;
        b.drops = 8;
        b.pipe_bytes = 264LL * 449280;
        b.ffmpeg_out_frames = 264;
        const auto d = supplyBucketDelta(a, b, 24, 1);
        CHECK(std::fabs(d.d_wall_s - 1.0) < 1e-9);
        CHECK(d.d_frames == 24);
        CHECK(d.d_drops == 0);
        CHECK(d.d_residual == 0);
        CHECK(std::fabs(d.expected_frames - 24.0) < 1e-9);
        CHECK(std::fabs(d.supply_gap) < 1e-9);
        CHECK(d.ffmpeg_out_known && d.d_ffmpeg_out == 24);
        CHECK(std::strcmp(supplyStageHint(d, /*glass*/ 15, false), "POST_PRESENT_SCANOUT") == 0);
        std::printf("PASS perfect 1s bucket → POST when glass holes\n");
    }

    // --- supply short 15 in one second (extreme) ---
    {
        SupplyCounters a{}, b{};
        a.wall_s = 10;
        a.frames = 100;
        a.ffmpeg_out_frames = 100;
        b.wall_s = 11;
        b.frames = 109; // expected 24, got 9 → gap 15
        b.ffmpeg_out_frames = 109;
        b.presents = 109;
        const auto d = supplyBucketDelta(a, b, 24, 1);
        CHECK(d.d_frames == 9);
        CHECK(d.supply_gap >= 10.0);
        CHECK(std::strcmp(supplyStageHint(d, 15, false), "PRE_FFMPEG_SUPPLY") == 0 ||
              std::strcmp(supplyStageHint(d, 15, false), "PRE_FRAMEINDEX_SUPPLY") == 0);
        std::printf("PASS supply short stage=%s\n", supplyStageHint(d, 15, false));
    }

    // --- pipe read short: ffmpeg +24, frames +9 ---
    {
        SupplyCounters a{}, b{};
        a.wall_s = 10;
        a.frames = 100;
        a.ffmpeg_out_frames = 100;
        b.wall_s = 11;
        b.frames = 109;
        b.presents = 109;
        b.ffmpeg_out_frames = 124;
        const auto d = supplyBucketDelta(a, b, 24, 1);
        CHECK(d.d_ffmpeg_out == 24);
        CHECK(std::strcmp(supplyStageHint(d, 15, false), "PIPE_READ_SHORT") == 0);
        std::printf("PASS PIPE_READ_SHORT\n");
    }

    // --- PIPE wins ---
    {
        SupplyBucketDelta d{};
        CHECK(std::strcmp(supplyStageHint(d, 15, true), "PIPE") == 0);
    }

    // --- format lines contain required keys ---
    {
        SupplyBucketDelta d{};
        d.d_wall_s = 1;
        d.d_frames = 24;
        d.expected_frames = 24;
        d.supply_gap = 0;
        d.d_ffmpeg_out = 24;
        d.ffmpeg_out_known = true;
        const std::string line =
            formatSupplyBucketLine(d, 11.0, 264, 256, 8, 0, 0, 264, 24, 1, "1.2");
        CHECK(line.find("supply_bucket") != std::string::npos);
        CHECK(line.find("d_frames=24") != std::string::npos);
        CHECK(line.find("d_residual=") != std::string::npos);
        CHECK(line.find("residual_eq=frames-presents-drops") != std::string::npos);
        CHECK(line.find("fpga_obs=none") != std::string::npos);
        CHECK(line.find("d_unaccounted=") == std::string::npos);
        CHECK(line.find("ffmpeg_out_frames=264") != std::string::npos);
        CHECK(line.find("session_epoch=1.2") != std::string::npos);
        auto id = supplyPipeIdentity(449280u * 10u, 449280u, 10);
        const std::string td = formatSupplyTeardownLine(id, 449280u * 10u, 449280u, 10, "POST");
        CHECK(td.find("supply_ledger") != std::string::npos);
        CHECK(td.find("identity_ok=1") != std::string::npos);
        std::printf("PASS format lines\n");
    }

    // --- resolution: FLAT=2 cannot hide 15 ---
    CHECK(kSupplyGapFlatFrames < 15 && kSupplyGapHitFrames <= 15);
    CHECK(kSupplyGapFlatFrames + 1 < kSupplyGapHitFrames);

    // --- supply_ratio = audio_s/wall_s (parent 480p link RCA; single starvation signal) ---
    {
        // Parent collapse: audio_s/wall ≈ 0.467 → STARVED
        const auto starved = classifySupplyRealtime(0.467 * 20.0, 20.0);
        CHECK(starved.ratio_known);
        CHECK(std::fabs(starved.ratio - 0.467) < 1e-9);
        CHECK(std::strcmp(starved.class_name, "STARVED") == 0);
        CHECK(std::strcmp(starved.der, "audio_s/wall_s") == 0);
        const auto ok = classifySupplyRealtime(0.993 * 30.0, 30.0);
        CHECK(ok.ratio_known);
        CHECK(std::fabs(ok.ratio - 0.993) < 1e-9);
        CHECK(std::strcmp(ok.class_name, "OK") == 0);
        const auto marg = classifySupplyRealtime(0.90 * 10.0, 10.0);
        CHECK(std::strcmp(marg.class_name, "MARGINAL") == 0);
        const auto warm = classifySupplyRealtime(1.0, 2.0);
        CHECK(std::strcmp(warm.class_name, "WARMUP") == 0);
        CHECK(warm.ratio_known && std::fabs(warm.ratio - 0.5) < 1e-9);
        const auto nod = classifySupplyRealtime(1.0, 0.0);
        CHECK(!nod.ratio_known);
        CHECK(std::strcmp(nod.class_name, "NO-DATA") == 0);
        const auto fmt = formatSupplyRealtimeFields(starved);
        CHECK(fmt.find("supply_ratio=0.467") != std::string::npos);
        CHECK(fmt.find("supply_class=STARVED") != std::string::npos);
        CHECK(fmt.find("supply_ratio_der=audio_s/wall_s") != std::string::npos);
        const auto fmtNd = formatSupplyRealtimeFields(nod);
        CHECK(fmtNd.find("supply_ratio=NO-DATA") != std::string::npos);
        CHECK(kSupplyRealtimeStarvedLt == 0.85);
        CHECK(kSupplyRealtimeOkGe == 0.95);
        CHECK(kSupplyRealtimeMinWallS == 5.0);
        std::printf("PASS supply_ratio audio_s/wall_s class\n");
    }

    if (fails) {
        std::fprintf(stderr, "test_supply_bucket: %d FAIL(s)\n", fails);
        return 1;
    }
    std::printf("test_supply_bucket: OK\n");
    return 0;
}
