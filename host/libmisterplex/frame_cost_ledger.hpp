#pragma once
// Per-frame *work* cost ledger for the STREAM=0 rawvideo path (media_player :3219).
//
// Records work_us = pipe_read_wall_us + present_wall_us  (EXCLUDES A/V pacing wait).
// That is the deadline-relevant cost: decode/pack blocked-on-pipe + DDR present.
// Paced intervals (~41.7 ms @24) are NOT recorded here — they measure the clock, not ARM.
//
// Hot path cost bound (design):
//   - one steady_clock sample pair already taken by present_profile paths; this ledger
//     only stores a uint32_t and bumps indices — no log, no sort, no alloc on note().
//   - dump() sorts a stack/heap copy once at session end (or rare N-frame summary).
//   - Cap 8192 samples (~5.7 min @24, ~4.5 min @30). Older samples drop (ring).
//
// Overhead budget: note() is O(1) store; must stay << 0.05 ms. No syscalls in note().

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <string>
#include <vector>

namespace misterplex {

struct FrameCostLedger {
    static constexpr std::size_t kCap = 8192;

    std::uint32_t work_us[kCap]{};
    std::size_t head = 0;
    std::size_t filled = 0;
    std::uint64_t count = 0;
    std::uint64_t sum_us = 0;
    std::uint32_t max_us = 0;
    std::uint32_t min_us = UINT32_MAX;

    void reset() {
        head = filled = 0;
        count = sum_us = 0;
        max_us = 0;
        min_us = UINT32_MAX;
        std::memset(work_us, 0, sizeof(work_us));
    }

    // Hot path — no alloc, no log.
    void note(std::uint32_t us) {
        work_us[head] = us;
        head = (head + 1) % kCap;
        if (filled < kCap)
            ++filled;
        ++count;
        sum_us += us;
        if (us > max_us)
            max_us = us;
        if (us < min_us)
            min_us = us;
    }

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

    // Off hot path — may alloc/sort.
    std::string formatLine(const char* tag) const {
        if (filled == 0)
            return std::string("frame_cost tag=") + (tag ? tag : "?") + " n=0";

        std::vector<std::uint32_t> body;
        body.reserve(filled);
        if (filled < kCap) {
            for (std::size_t i = 0; i < filled; ++i)
                body.push_back(work_us[i]);
        } else {
            // ring full: head is oldest
            for (std::size_t i = 0; i < kCap; ++i)
                body.push_back(work_us[(head + i) % kCap]);
        }
        const double mean = static_cast<double>(sum_us) / static_cast<double>(count);
        // population sd over ring contents only (approx when count > filled)
        double var = 0;
        for (auto u : body) {
            const double d = static_cast<double>(u) - mean;
            var += d * d;
        }
        const double sd = body.empty() ? 0.0 : std::sqrt(var / static_cast<double>(body.size()));
        const double p50 = pctOfSorted(body, 50);
        const double p95 = pctOfSorted(body, 95);
        const double p99 = pctOfSorted(body, 99);
        const std::uint32_t mn = min_us == UINT32_MAX ? 0 : min_us;

        char buf[512];
        std::snprintf(buf, sizeof(buf),
                      "frame_cost tag=%s n=%llu ring=%zu mean_ms=%.3f p50_ms=%.3f p95_ms=%.3f "
                      "p99_ms=%.3f max_ms=%.3f min_ms=%.3f sd_ms=%.3f p99_minus_mean_ms=%.3f "
                      "unit=work_us_excl_pacing",
                      tag ? tag : "?", static_cast<unsigned long long>(count), filled,
                      mean / 1000.0, p50 / 1000.0, p95 / 1000.0, p99 / 1000.0,
                      max_us / 1000.0, mn / 1000.0, sd / 1000.0, (p99 - mean) / 1000.0);
        return std::string(buf);
    }
};

// Pure helper for unit tests — percentile of a vector in microseconds → ms string fields.
inline bool frameCostPctSmoke(const std::uint32_t* us, std::size_t n, double* p50_ms,
                              double* p99_ms) {
    if (!us || n == 0 || !p50_ms || !p99_ms)
        return false;
    FrameCostLedger led;
    for (std::size_t i = 0; i < n; ++i)
        led.note(us[i]);
    std::vector<std::uint32_t> body(us, us + n);
    *p50_ms = FrameCostLedger::pctOfSorted(body, 50) / 1000.0;
    body.assign(us, us + n);
    *p99_ms = FrameCostLedger::pctOfSorted(body, 99) / 1000.0;
    return true;
}

} // namespace misterplex
