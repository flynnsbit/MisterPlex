// Host microbench: bound PlaybackOverlay cost vs full-frame chroma inspect.
// NOT device silicon — x86_64 host times only. Use for ratio / order-of-magnitude.
// Build: g++ -O2 -std=c++17 -Ihost tools/overlay_cost_bench.cpp -o build/overlay_cost_bench
// Optional -DOVERLAY_HEADER=path to hires worktree header.

#include <chrono>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <string>
#include <vector>

#ifndef OVERLAY_HEADER
#include "libmisterplex/playback_overlay.hpp"
#else
#include OVERLAY_HEADER
#endif
#include "libmisterplex/yuv420p_chroma_health.hpp"

using namespace misterplex;
using clock_type = std::chrono::steady_clock;

static int64_t usBetween(clock_type::time_point a, clock_type::time_point b) {
    return std::chrono::duration_cast<std::chrono::microseconds>(b - a).count();
}

int main(int argc, char** argv) {
    int w = 624, h = 480, iters = 200;
    for (int i = 1; i + 1 < argc; ++i) {
        if (std::string(argv[i]) == "-w")
            w = std::atoi(argv[++i]);
        else if (std::string(argv[i]) == "-h")
            h = std::atoi(argv[++i]);
        else if (std::string(argv[i]) == "-n")
            iters = std::atoi(argv[++i]);
    }
    if (w <= 0 || h <= 0 || (w & 1) || (h & 1) || iters < 1) {
        std::fprintf(stderr, "bad args\n");
        return 2;
    }

    const size_t frameBytes = static_cast<size_t>(w) * h * 3 / 2;
    std::vector<uint8_t> yuv(frameBytes);
    fillYuv420pStudioBlack(yuv.data(), w, h);

    PlaybackOverlay ov;
    const int64_t t0ms = 1'000'000;
    ov.showAt(PlaybackOverlayState::Paused, 12'345, 3'600'000, t0ms);

    OverlayRect dirty = ov.dirtyBoundsAt(w, h, t0ms + 100);
    const OverlayLayoutMetrics m = PlaybackOverlay::layoutMetrics(w, h);
    const OverlayRect panel = PlaybackOverlay::panelBounds(w, h);

    // Warm
    for (int i = 0; i < 5; ++i)
        ov.renderYuv420pAt(yuv.data(), w, h, t0ms + 100);

    auto t0 = clock_type::now();
    for (int i = 0; i < iters; ++i)
        ov.renderYuv420pAt(yuv.data(), w, h, t0ms + 100);
    auto t1 = clock_type::now();
    const double yuv_us = static_cast<double>(usBetween(t0, t1)) / iters;

    // separate RGB565 buffer (must be w*h*2 — never reuse I420 storage)
    std::vector<uint8_t> rgb(static_cast<size_t>(w) * h * 2, 0);
    for (int i = 0; i < 5; ++i)
        ov.renderRgb565LeAt(rgb.data(), w, h, t0ms + 100);
    t0 = clock_type::now();
    for (int i = 0; i < iters; ++i)
        ov.renderRgb565LeAt(rgb.data(), w, h, t0ms + 100);
    t1 = clock_type::now();
    const double rgb_us = static_cast<double>(usBetween(t0, t1)) / iters;

    volatile uint64_t sink = 0;
    t0 = clock_type::now();
    for (int i = 0; i < iters; ++i) {
        const auto hth = inspectYuv420pChroma(yuv.data(), w, h);
        sink += static_cast<uint64_t>(hth.mean_u) + hth.c_bytes + (hth.dead_chroma ? 1 : 0);
    }
    t1 = clock_type::now();
    const double inspect_us = static_cast<double>(usBetween(t0, t1)) / iters;

    t0 = clock_type::now();
    for (int i = 0; i < iters; ++i) {
        const bool repaired = repairDeadYuv420pChroma(yuv.data(), w, h);
        sink += repaired ? 1 : 0;
    }
    t1 = clock_type::now();
    const double repair_us = static_cast<double>(usBetween(t0, t1)) / iters;

    std::vector<uint8_t> yuv2(frameBytes);
    fillYuv420pStudioBlack(yuv2.data(), w, h);
    // product 480p crop_right=6 side-strip clear proxy (not full clearYuv helper)
    t0 = clock_type::now();
    for (int i = 0; i < iters; ++i) {
        for (int y = 0; y < h; ++y)
            std::memset(yuv2.data() + static_cast<size_t>(y) * w + (w - 6), 16, 6);
        sink += yuv2[0];
    }
    t1 = clock_type::now();
    const double clear_proxy_us = static_cast<double>(usBetween(t0, t1)) / iters;
    if (sink == UINT64_MAX)
        std::fprintf(stderr, "sink\n");

    const int panel_px = dirty.empty() ? 0 : dirty.w * dirty.h;
    std::printf("host_overlay_cost_bench w=%d h=%d iters=%d\n", w, h, iters);
    std::printf("panel_metrics margin=%d panelH=%d panel=%dx%d dirty=%d,%d %dx%d panel_px=%d "
                "frame_px=%d frac=%.4f\n",
                m.margin, m.panelH, panel.w, panel.h, dirty.x, dirty.y, dirty.w, dirty.h, panel_px,
                w * h, panel_px / double(w * h));
    std::printf("us_per_call renderYuv420p=%.2f renderRgb565Le=%.2f inspectChroma=%.2f "
                "repairDead=%.2f clear_right6_proxy=%.2f\n",
                yuv_us, rgb_us, inspect_us, repair_us, clear_proxy_us);
    std::printf("ratio_yuv_over_inspect=%.2f ratio_yuv_over_repair=%.2f "
                "ratio_yuv_over_rgb565=%.2f\n",
                (inspect_us > 0 ? yuv_us / inspect_us : -1.0),
                (repair_us > 0 ? yuv_us / repair_us : -1.0),
                (rgb_us > 0 ? yuv_us / rgb_us : -1.0));
    std::printf("budget_24fps_us=41666.7 yuv_frac_of_frame_budget=%.4f\n", yuv_us / 41666.7);
    std::printf("NOTE=HOST_NOT_SILICON times are order-of-magnitude on this CPU only\n");
    return 0;
}
