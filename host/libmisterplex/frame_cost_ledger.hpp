#pragma once
// Per-frame *work* cost ledger for the STREAM=0 rawvideo path (media_player :3219).
//
// Three attributed stages (NOT one aggregate — parent 2026-08-04):
//   pipe_us     = parent blocked on ffmpeg stdout fill (child decode+vf+write latency
//                 appears here; this is NOT an isolated decode_null probe)
//   pixel_us    = host chroma pad / dead-chroma repair on the raw frame
//   present_us  = DDR publish (prep+copy+flush+doorbell+post-wait)
//   work_us     = pipe + pixel + present  (EXCLUDES A/V pacing wait)
//
// There is no separate decode_us on the product path — decode runs in the ffmpeg
// child. Isolated decode_null is a different instrument (ffmpeg_cpu_probe -f null).
// formatLine still emits decode_us=0 with note=decode_in_child so dashboards do not
// invent a fourth bucket.
//
// Hot path: note() stores three uint32_t — no log, no sort, no alloc.
// Cap 8192 samples. Overhead must stay << 0.05 ms.

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <string>
#include <vector>

namespace misterplex {

struct FrameCostSample {
    std::uint32_t pipe_us = 0;
    std::uint32_t pixel_us = 0;
    std::uint32_t present_us = 0;
    std::uint32_t work_us() const {
        const std::uint64_t s = static_cast<std::uint64_t>(pipe_us) + pixel_us + present_us;
        return s > UINT32_MAX ? UINT32_MAX : static_cast<std::uint32_t>(s);
    }
};

struct FrameCostLedger {
    static constexpr std::size_t kCap = 8192;

    FrameCostSample samples[kCap]{};
    std::size_t head = 0;
    std::size_t filled = 0;
    std::uint64_t count = 0;

    std::uint64_t sum_pipe_us = 0;
    std::uint64_t sum_pixel_us = 0;
    std::uint64_t sum_present_us = 0;
    std::uint64_t sum_work_us = 0;
    std::uint32_t max_work_us = 0;
    std::uint32_t min_work_us = UINT32_MAX;
    std::uint32_t max_present_us = 0;
    std::uint32_t max_pipe_us = 0;

    void reset() {
        head = filled = 0;
        count = 0;
        sum_pipe_us = sum_pixel_us = sum_present_us = sum_work_us = 0;
        max_work_us = max_present_us = max_pipe_us = 0;
        min_work_us = UINT32_MAX;
        for (std::size_t i = 0; i < kCap; ++i) samples[i] = FrameCostSample{};
    }

    // Hot path — no alloc, no log. Prefer three-field note.
    void note(std::uint32_t pipe_us, std::uint32_t pixel_us, std::uint32_t present_us) {
        FrameCostSample s;
        s.pipe_us = pipe_us;
        s.pixel_us = pixel_us;
        s.present_us = present_us;
        const std::uint32_t w = s.work_us();
        samples[head] = s;
        head = (head + 1) % kCap;
        if (filled < kCap)
            ++filled;
        ++count;
        sum_pipe_us += pipe_us;
        sum_pixel_us += pixel_us;
        sum_present_us += present_us;
        sum_work_us += w;
        if (w > max_work_us)
            max_work_us = w;
        if (w < min_work_us)
            min_work_us = w;
        if (present_us > max_present_us)
            max_present_us = present_us;
        if (pipe_us > max_pipe_us)
            max_pipe_us = pipe_us;
    }

    // Backward-compat: single work total → attributed entirely to pipe (unknown split).
    void note(std::uint32_t work_us_only) { note(work_us_only, 0, 0); }

    bool empty() const { return filled == 0; }

    static double pctOfSorted(std::vector<std::uint32_t>& v, double p) {
        if (v.empty())
            return 0;
        const double idx = (p / 100.0) * static_cast<double>(v.size() - 1);
        const std::size_t i = static_cast<std::size_t>(idx);
        const double f = idx - static_cast<double>(i);
        if (i + 1 < v.size())
            return v[i] * (1.0 - f) + v[i + 1] * f;
        return static_cast<double>(v.back());
    }

    void collectField(std::vector<std::uint32_t>& out,
                      std::uint32_t FrameCostSample::*field) const {
        out.clear();
        out.reserve(filled);
        if (filled < kCap) {
            for (std::size_t i = 0; i < filled; ++i)
                out.push_back(samples[i].*field);
        } else {
            for (std::size_t i = 0; i < kCap; ++i)
                out.push_back(samples[(head + i) % kCap].*field);
        }
    }

    void collectWork(std::vector<std::uint32_t>& out) const {
        out.clear();
        out.reserve(filled);
        if (filled < kCap) {
            for (std::size_t i = 0; i < filled; ++i)
                out.push_back(samples[i].work_us());
        } else {
            for (std::size_t i = 0; i < kCap; ++i)
                out.push_back(samples[(head + i) % kCap].work_us());
        }
    }

    // Off hot path — may alloc/sort.
    std::string formatLine(const char* tag) const {
        if (filled == 0)
            return std::string("frame_cost tag=") + (tag ? tag : "?") + " n=0";

        std::vector<std::uint32_t> work, pipe, pixel, present;
        collectWork(work);
        collectField(pipe, &FrameCostSample::pipe_us);
        collectField(pixel, &FrameCostSample::pixel_us);
        collectField(present, &FrameCostSample::present_us);

        const double n = static_cast<double>(count);
        const double mean_w = static_cast<double>(sum_work_us) / n;
        const double mean_pipe = static_cast<double>(sum_pipe_us) / n;
        const double mean_pixel = static_cast<double>(sum_pixel_us) / n;
        const double mean_present = static_cast<double>(sum_present_us) / n;

        double var = 0;
        for (auto u : work) {
            const double d = static_cast<double>(u) - mean_w;
            var += d * d;
        }
        const double sd = work.empty() ? 0.0 : std::sqrt(var / static_cast<double>(work.size()));
        const double p50 = pctOfSorted(work, 50);
        const double p95 = pctOfSorted(work, 95);
        const double p99 = pctOfSorted(work, 99);
        const double pipe_p50 = pctOfSorted(pipe, 50);
        const double pipe_p99 = pctOfSorted(pipe, 99);
        const double present_p50 = pctOfSorted(present, 50);
        const double present_p99 = pctOfSorted(present, 99);
        const double pixel_p50 = pctOfSorted(pixel, 50);
        const std::uint32_t mn = min_work_us == UINT32_MAX ? 0 : min_work_us;

        char buf[768];
        std::snprintf(
            buf, sizeof(buf),
            "frame_cost tag=%s n=%llu ring=%zu "
            "work_mean_ms=%.3f work_p50_ms=%.3f work_p95_ms=%.3f work_p99_ms=%.3f "
            "work_max_ms=%.3f work_min_ms=%.3f work_sd_ms=%.3f work_p99_minus_mean_ms=%.3f "
            "pipe_mean_ms=%.3f pipe_p50_ms=%.3f pipe_p99_ms=%.3f pipe_max_ms=%.3f "
            "pixel_mean_ms=%.3f pixel_p50_ms=%.3f "
            "present_mean_ms=%.3f present_p50_ms=%.3f present_p99_ms=%.3f present_max_ms=%.3f "
            "decode_us=0 decode_note=in_ffmpeg_child_see_pipe "
            "unit=pipe_pixel_present_excl_pacing",
            tag ? tag : "?", static_cast<unsigned long long>(count), filled,
            mean_w / 1000.0, p50 / 1000.0, p95 / 1000.0, p99 / 1000.0, max_work_us / 1000.0,
            mn / 1000.0, sd / 1000.0, (p99 - mean_w) / 1000.0, mean_pipe / 1000.0,
            pipe_p50 / 1000.0, pipe_p99 / 1000.0, max_pipe_us / 1000.0, mean_pixel / 1000.0,
            pixel_p50 / 1000.0, mean_present / 1000.0, present_p50 / 1000.0,
            present_p99 / 1000.0, max_present_us / 1000.0);
        return std::string(buf);
    }
};

inline bool frameCostPctSmoke(const std::uint32_t* us, std::size_t n, double* p50_ms,
                              double* p99_ms) {
    if (!us || n == 0 || !p50_ms || !p99_ms)
        return false;
    FrameCostLedger led;
    for (std::size_t i = 0; i < n; ++i)
        led.note(us[i], 0, 0);
    std::vector<std::uint32_t> body(us, us + n);
    *p50_ms = FrameCostLedger::pctOfSorted(body, 50) / 1000.0;
    body.assign(us, us + n);
    *p99_ms = FrameCostLedger::pctOfSorted(body, 99) / 1000.0;
    return true;
}

} // namespace misterplex
