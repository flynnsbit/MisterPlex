#pragma once
// Publish-side interval ledger (w-geom / judder root-cause).
//
// Product DDR swap is async: vsync_pulse && swap_pending && pending_ready_s2.
// Hold-length irregularity on a crystal pixel clock must originate in WHEN the
// daemon raises swap_req (doorbell), not in the latch itself.
//
// This ring records host steady_clock timestamps at each successful publish
// (swap request raised). Intervals are derived offline / at dump — no heap,
// no logging in the hot path except an optional periodic summary.
//
// PRE-REGISTER (parent device soak — commit before measuring):
//   clean:  σ_ms < 4, ≥99% in [41.67-8, 41.67+8], P(iv>50ms) < 0.03
//           → ARM clean; late-publish FALSIFIED; look vsync domain
//   late:   P(iv>50ms) ∈ [0.09, 0.11] ≈ parent 4/5-hold fraction
//           → ARM publishing late; fix scheduling/CPU, NOT RTL
//   bimodal/long tail >83ms → late + catch-up; correlates with hold=1 via
//           pending_bank overwrite (ddr_frame_store.sv doorbell edge)
//
// steady_clock::now() is typically VDSO on Linux A9 — not a full syscall.

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <string>
#include <vector>

namespace misterplex {

struct PublishIntervalLedger {
    static constexpr std::size_t kCap = 4096; // ~170 s @ 24 fps

    std::int64_t mono_us[kCap]{};
    std::size_t count = 0;       // total notes (may exceed kCap)
    std::size_t head = 0;        // next write index
    std::size_t filled = 0;      // min(count, kCap)
    std::int64_t last_us = -1;
    std::int64_t short_then_ok = 0; // iv_i < 25ms and iv_{i+1} in band (catch-up class)
    std::int64_t ge50_count = 0;
    std::int64_t ge83_count = 0;
    std::int64_t lt25_count = 0;
    std::int64_t in_band_count = 0; // [41.67-8, 41.67+8]
    double sum_iv_ms = 0;
    double sum_iv_ms2 = 0;
    std::int64_t iv_n = 0;

    void reset() {
        count = head = filled = 0;
        last_us = -1;
        short_then_ok = ge50_count = ge83_count = lt25_count = in_band_count = 0;
        sum_iv_ms = sum_iv_ms2 = 0;
        iv_n = 0;
        std::memset(mono_us, 0, sizeof(mono_us));
    }

    // Hot path: one steady timestamp + a few arithmetic ops.
    void note(std::int64_t now_us) {
        mono_us[head] = now_us;
        head = (head + 1) % kCap;
        if (filled < kCap)
            ++filled;
        ++count;

        if (last_us >= 0 && now_us >= last_us) {
            const double iv_ms = double(now_us - last_us) / 1000.0;
            ++iv_n;
            sum_iv_ms += iv_ms;
            sum_iv_ms2 += iv_ms * iv_ms;
            if (iv_ms > 50.0)
                ++ge50_count;
            if (iv_ms > 83.0)
                ++ge83_count;
            if (iv_ms < 25.0)
                ++lt25_count;
            // Ideal 24.000 fps period = 1000/24 ms
            constexpr double kIdeal = 1000.0 / 24.0;
            if (iv_ms >= (kIdeal - 8.0) && iv_ms <= (kIdeal + 8.0))
                ++in_band_count;
        }
        last_us = now_us;
    }

    // Drop first/last notes when scoring steady-state (startup/teardown).
    static constexpr std::size_t kDropHeadNotes = 48; // ~2 s @24
    static constexpr std::size_t kDropTailNotes = 24; // ~1 s @24

    struct Summary {
        std::int64_t notes = 0;
        std::int64_t intervals = 0;
        double mean_ms = 0;       // raw (all intervals; can be outlier-skewed)
        double sigma_ms = 0;      // raw
        double median_ms = 0;     // steady window
        double trimmed_mean_ms = 0; // steady, 10% each tail
        double steady_sigma_ms = 0;
        double p_ge50 = 0;        // raw all intervals
        double p_ge50_steady = 0; // steady window — use for verdict
        double p_ge83 = 0;
        double p_lt25 = 0;
        double p_in_band = 0;
        std::int64_t steady_n = 0;
        const char* verdict = "UNSCORED";
    };

    static double percentileSorted(std::vector<double>& v, double q) {
        if (v.empty())
            return 0;
        std::sort(v.begin(), v.end());
        const double idx = q * double(v.size() - 1);
        const std::size_t lo = static_cast<std::size_t>(idx);
        const std::size_t hi = std::min(lo + 1, v.size() - 1);
        const double f = idx - double(lo);
        return v[lo] * (1.0 - f) + v[hi] * f;
    }

    // Intervals from chronological mono; optional head/tail note drops.
    void collectIntervalsMs(std::vector<double>& out, bool steady_window) const {
        out.clear();
        std::int64_t tmp[kCap];
        std::size_t n = 0;
        copyChronological(tmp, &n);
        if (n < 2)
            return;
        std::size_t i0 = 0, i1 = n;
        if (steady_window && n > kDropHeadNotes + kDropTailNotes + 2) {
            i0 = kDropHeadNotes;
            i1 = n - kDropTailNotes;
        }
        for (std::size_t i = i0 + 1; i < i1; ++i) {
            if (tmp[i] < tmp[i - 1])
                continue;
            out.push_back(double(tmp[i] - tmp[i - 1]) / 1000.0);
        }
    }

    Summary summarize() const {
        Summary s;
        s.notes = static_cast<std::int64_t>(count);
        s.intervals = iv_n;
        if (iv_n <= 0) {
            s.verdict = "UNSCORED";
            return s;
        }
        s.mean_ms = sum_iv_ms / double(iv_n);
        const double var = std::max(0.0, sum_iv_ms2 / double(iv_n) - s.mean_ms * s.mean_ms);
        s.sigma_ms = std::sqrt(var);
        s.p_ge50 = double(ge50_count) / double(iv_n);
        s.p_ge83 = double(ge83_count) / double(iv_n);
        s.p_lt25 = double(lt25_count) / double(iv_n);
        s.p_in_band = double(in_band_count) / double(iv_n);

        // Steady-state robust stats (exclude startup/teardown notes).
        std::vector<double> steady;
        collectIntervalsMs(steady, true);
        s.steady_n = static_cast<std::int64_t>(steady.size());
        if (!steady.empty()) {
            std::vector<double> sorted = steady;
            s.median_ms = percentileSorted(sorted, 0.5);
            // 10% trimmed mean
            std::sort(steady.begin(), steady.end());
            const std::size_t trim = steady.size() / 10;
            const std::size_t a = trim;
            const std::size_t b = steady.size() - trim;
            double sum = 0;
            std::size_t m = 0;
            double sum2 = 0;
            int ge50s = 0;
            for (std::size_t i = a; i < b; ++i) {
                sum += steady[i];
                sum2 += steady[i] * steady[i];
                ++m;
            }
            for (double v : steady) {
                if (v > 50.0)
                    ++ge50s;
            }
            if (m > 0) {
                s.trimmed_mean_ms = sum / double(m);
                const double v2 = std::max(0.0, sum2 / double(m) - s.trimmed_mean_ms * s.trimmed_mean_ms);
                s.steady_sigma_ms = std::sqrt(v2);
            }
            s.p_ge50_steady = double(ge50s) / double(steady.size());
        }

        // Verdict on STEADY p_ge50 (parent ERROR 21 mapping). Fall back to raw.
        const double p50 = (s.steady_n >= 100) ? s.p_ge50_steady : s.p_ge50;
        const double sig = (s.steady_n >= 100) ? s.steady_sigma_ms : s.sigma_ms;
        if (sig < 4.0 && s.p_in_band >= 0.99 && p50 < 0.03)
            s.verdict = "ARM_EXONERATED_FPGA_SIDE";
        else if (p50 >= 0.09 && p50 <= 0.11)
            s.verdict = "ARM_LATE_MATCH_HOLD45";
        else if (p50 > 0.03 && p50 < 0.09)
            s.verdict = "ARM_LATE_MILD";
        else if (p50 > 0.11 || s.p_ge83 > 0.02)
            s.verdict = "ARM_LATE_OR_BIMODAL";
        else
            s.verdict = "ARM_OTHER";
        return s;
    }

    // Rebuild intervals from ring (for correlation / dump). oldest→newest.
    void copyChronological(std::int64_t* out, std::size_t* n_out) const {
        const std::size_t n = filled;
        *n_out = n;
        if (n == 0)
            return;
        std::size_t start = (count <= kCap) ? 0 : head; // oldest
        for (std::size_t i = 0; i < n; ++i)
            out[i] = mono_us[(start + i) % kCap];
    }

    std::string formatSummaryLine(const char* tag = "measured") const {
        const Summary s = summarize();
        char buf[768];
        std::snprintf(buf, sizeof(buf),
                      "publish_interval notes=%lld intervals=%lld mean_ms=%.3f sigma_ms=%.3f "
                      "median_ms=%.3f trimmed_mean_ms=%.3f steady_sigma_ms=%.3f steady_n=%lld "
                      "p_ge50=%.4f p_ge50_steady=%.4f p_ge83=%.4f p_lt25=%.4f p_in_band=%.4f "
                      "verdict=%s ideal_ms=%.3f tag=%s",
                      static_cast<long long>(s.notes), static_cast<long long>(s.intervals),
                      s.mean_ms, s.sigma_ms, s.median_ms, s.trimmed_mean_ms, s.steady_sigma_ms,
                      static_cast<long long>(s.steady_n), s.p_ge50, s.p_ge50_steady, s.p_ge83,
                      s.p_lt25, s.p_in_band, s.verdict, 1000.0 / 24.0, tag);
        return std::string(buf);
    }

    // Adjacent-interval correlation: short (<25ms) followed by next — for hold=1 class.
    // Returns count of (iv_i < short_ms) pairs and how many of those have iv_{i+1} < 50.
    struct ShortCorr {
        int short_n = 0;
        int short_then_lt50 = 0;
        int short_then_ge50 = 0;
    };
    ShortCorr shortIntervalCorrelation(double short_ms = 25.0) const {
        ShortCorr c;
        std::int64_t tmp[kCap];
        std::size_t n = 0;
        copyChronological(tmp, &n);
        if (n < 3)
            return c;
        for (std::size_t i = 1; i + 1 < n; ++i) {
            const double a = double(tmp[i] - tmp[i - 1]) / 1000.0;
            const double b = double(tmp[i + 1] - tmp[i]) / 1000.0;
            if (a < short_ms) {
                ++c.short_n;
                if (b < 50.0)
                    ++c.short_then_lt50;
                else
                    ++c.short_then_ge50;
            }
        }
        return c;
    }

    std::string formatCorrLine() const {
        const auto c = shortIntervalCorrelation(25.0);
        char buf[256];
        std::snprintf(buf, sizeof(buf),
                      "publish_interval_corr short_lt25_n=%d short_then_lt50=%d "
                      "short_then_ge50=%d tag=derived",
                      c.short_n, c.short_then_lt50, c.short_then_ge50);
        return std::string(buf);
    }

    // Interval histogram (ms bins). Parent needs full shape, not only p_ge50.
    // Bins: <25, 25-33, 33-42, 42-50, 50-67, 67-83, 83-100, >=100
    std::string formatHistLine() const {
        std::int64_t tmp[kCap];
        std::size_t n = 0;
        copyChronological(tmp, &n);
        int b[8] = {};
        int tot = 0;
        for (std::size_t i = 1; i < n; ++i) {
            if (tmp[i] < tmp[i - 1])
                continue;
            const double ms = double(tmp[i] - tmp[i - 1]) / 1000.0;
            ++tot;
            if (ms < 25.0)
                ++b[0];
            else if (ms < 33.0)
                ++b[1];
            else if (ms < 42.0)
                ++b[2];
            else if (ms < 50.0)
                ++b[3];
            else if (ms < 67.0)
                ++b[4];
            else if (ms < 83.0)
                ++b[5];
            else if (ms < 100.0)
                ++b[6];
            else
                ++b[7];
        }
        char buf[384];
        std::snprintf(buf, sizeof(buf),
                      "publish_interval_hist n=%d lt25=%d b25_33=%d b33_42=%d b42_50=%d "
                      "b50_67=%d b67_83=%d b83_100=%d ge100=%d tag=derived",
                      tot, b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7]);
        return std::string(buf);
    }

    // Lag-1 Pearson autocorrelation of consecutive intervals.
    // Bursty late publishes → positive rho (long followed by long).
    // Catch-up after late → negative rho (long followed by short).
    double lag1Autocorr() const {
        std::int64_t tmp[kCap];
        std::size_t n = 0;
        copyChronological(tmp, &n);
        if (n < 3)
            return 0.0;
        std::vector<double> iv;
        iv.reserve(n);
        for (std::size_t i = 1; i < n; ++i) {
            if (tmp[i] < tmp[i - 1])
                continue;
            iv.push_back(double(tmp[i] - tmp[i - 1]) / 1000.0);
        }
        if (iv.size() < 3)
            return 0.0;
        double mean = 0;
        for (double v : iv)
            mean += v;
        mean /= double(iv.size());
        double num = 0, den = 0;
        for (std::size_t i = 0; i + 1 < iv.size(); ++i) {
            const double a = iv[i] - mean;
            const double b = iv[i + 1] - mean;
            num += a * b;
            den += a * a;
        }
        // Use population variance of all samples for den stability
        double den_all = 0;
        for (double v : iv) {
            const double d = v - mean;
            den_all += d * d;
        }
        if (den_all <= 1e-18)
            return 0.0;
        // Standard lag-1: num / sqrt(sum a^2 * sum b^2) ≈ num/den_all for long series
        (void)den;
        return num / den_all;
    }

    std::string formatAutocorrLine() const {
        char buf[160];
        std::snprintf(buf, sizeof(buf),
                      "publish_interval_acf lag1=%.4f tag=derived", lag1Autocorr());
        return std::string(buf);
    }

    // Write chronological mono_us (one per line) for offline parent analysis.
    // Returns false if path empty or open fails.
    bool dumpMonoUs(const char* path) const {
        if (!path || !path[0])
            return false;
        FILE* f = std::fopen(path, "w");
        if (!f)
            return false;
        std::int64_t tmp[kCap];
        std::size_t n = 0;
        copyChronological(tmp, &n);
        std::fprintf(f, "# publish_interval mono_us chronological notes=%zu cap=%zu\n", n,
                     kCap);
        for (std::size_t i = 0; i < n; ++i)
            std::fprintf(f, "%lld\n", static_cast<long long>(tmp[i]));
        std::fclose(f);
        return true;
    }
};

// Pure helper: given sorted publish mono_us, compute P(iv>50ms).
inline double publishIntervalPGe50(const std::int64_t* mono_us, std::size_t n) {
    if (n < 2)
        return 0;
    int ge = 0, tot = 0;
    for (std::size_t i = 1; i < n; ++i) {
        if (mono_us[i] < mono_us[i - 1])
            continue;
        const double ms = double(mono_us[i] - mono_us[i - 1]) / 1000.0;
        ++tot;
        if (ms > 50.0)
            ++ge;
    }
    return tot ? double(ge) / double(tot) : 0;
}

} // namespace misterplex
