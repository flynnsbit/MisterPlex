#pragma once
// Publish-side interval ledger (w-geom / judder root-cause).
//
// Product DDR swap is async: vsync_pulse && swap_pending && pending_ready_s2.
//
// LATE-ARRIVAL vs LATE-OBSERVATION discriminator (parent 2026-08-01):
//   note(pre_us, post_us) where:
//     pre_us  = steady_clock immediately BEFORE DDR/SPI write begins
//     post_us = steady_clock immediately AFTER write returns
//   write_us = post - pre
//   arrival interval = pre[i] - pre[i-1]   (publisher cadence, not observation)
//
// PRE-REGISTER discriminator (commit before soak):
//   arrival_iv = pre[i]-pre[i-1]   (publisher cadence)
//   write_us   = post-pre
//   LATE_ARRIVAL: arrival p_ge50 elevated AND write duration flat
//     (pre timestamps themselves spread; write_us ~ constant)
//   LATE_OBSERVATION: arrival p_ge50 low/clean AND write_us has fat tail
//     (a post-only or post-inflated series would look "late"; pre proves
//      the publisher arrived on time — preemption was inside the write)
//   MIXED: arrival late AND write fat on those samples
//   Prior post-only p_ge50 is UNSCORED for lateness.
//
// Interval verdict bands (ERROR 21) apply to ARRIVAL (pre-to-pre) p_ge50_steady.
// Prefer median_ms / trimmed_mean_ms / p_ge50_steady over raw mean/sigma.
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

    std::int64_t pre_us[kCap]{};
    std::int64_t write_us[kCap]{}; // post-pre, >=0
    std::size_t count = 0;
    std::size_t head = 0;
    std::size_t filled = 0;
    std::int64_t last_pre_us = -1;
    std::int64_t last_write_us = 0; // write of previous sample (blocks next pre)
    std::int64_t last_us = -1;      // alias: last pre (tests use last_us)
    std::int64_t ge50_count = 0;
    std::int64_t ge83_count = 0;
    std::int64_t lt25_count = 0;
    std::int64_t in_band_count = 0;
    double sum_iv_ms = 0;
    double sum_iv_ms2 = 0;
    std::int64_t iv_n = 0;
    // write duration accumulators
    double sum_write_us = 0;
    double sum_write_us2 = 0;
    std::int64_t write_n = 0;
    // write_us paired with the arrival interval that ends at this sample
    // (cause = prior write if thread was blocked — see note()).
    double sum_write_us_late = 0;
    std::int64_t write_n_late = 0;
    double sum_write_us_ok = 0;
    std::int64_t write_n_ok = 0;
    // Fat-tail write detector (independent of arrival lateness).
    std::int64_t write_ge1ms_n = 0;
    std::int64_t write_ge5ms_n = 0;
    std::int64_t write_max_us = 0;

    void reset() {
        count = head = filled = 0;
        last_pre_us = last_us = -1;
        last_write_us = 0;
        ge50_count = ge83_count = lt25_count = in_band_count = 0;
        sum_iv_ms = sum_iv_ms2 = 0;
        iv_n = 0;
        sum_write_us = sum_write_us2 = 0;
        write_n = write_n_late = write_n_ok = 0;
        sum_write_us_late = sum_write_us_ok = 0;
        write_ge1ms_n = write_ge5ms_n = 0;
        write_max_us = 0;
        std::memset(pre_us, 0, sizeof(pre_us));
        std::memset(write_us, 0, sizeof(write_us));
    }

    // Backward-compat: single stamp treated as pre=post (write=0). Prefer note(pre,post).
    void note(std::int64_t now_us) { note(now_us, now_us); }

    // Hot path: two VDSO timestamps around the DDR write.
    void note(std::int64_t pre, std::int64_t post) {
        if (post < pre)
            post = pre;
        const std::int64_t wus = post - pre;
        pre_us[head] = pre;
        write_us[head] = wus;
        head = (head + 1) % kCap;
        if (filled < kCap)
            ++filled;
        ++count;

        sum_write_us += double(wus);
        sum_write_us2 += double(wus) * double(wus);
        ++write_n;
        if (wus >= 1000)
            ++write_ge1ms_n;
        if (wus >= 5000)
            ++write_ge5ms_n;
        if (wus > write_max_us)
            write_max_us = wus;

        if (last_pre_us >= 0 && pre >= last_pre_us) {
            const double iv_ms = double(pre - last_pre_us) / 1000.0;
            ++iv_n;
            sum_iv_ms += iv_ms;
            sum_iv_ms2 += iv_ms * iv_ms;
            // Pair THIS sample's write with the arrival gap into this sample.
            // (If prior write blocked the thread past the next ideal pre, the
            // gap is large and last_write_us is the cause — also accumulated.)
            const double pair_w = double(wus);
            const double cause_w = double(last_write_us);
            if (iv_ms > 50.0) {
                ++ge50_count;
                sum_write_us_late += cause_w; // prior write as delay cause
                // also track current write for "blocked during long iv" view
                (void)pair_w;
                ++write_n_late;
            } else {
                sum_write_us_ok += pair_w;
                ++write_n_ok;
            }
            if (iv_ms > 83.0)
                ++ge83_count;
            if (iv_ms < 25.0)
                ++lt25_count;
            constexpr double kIdeal = 1000.0 / 24.0;
            if (iv_ms >= (kIdeal - 8.0) && iv_ms <= (kIdeal + 8.0))
                ++in_band_count;
        }
        last_pre_us = pre;
        last_us = pre;
        last_write_us = wus;
    }

    static constexpr std::size_t kDropHeadNotes = 48;
    static constexpr std::size_t kDropTailNotes = 24;

    struct Summary {
        std::int64_t notes = 0;
        std::int64_t intervals = 0;
        double mean_ms = 0;
        double sigma_ms = 0;
        double median_ms = 0;
        double trimmed_mean_ms = 0;
        double steady_sigma_ms = 0;
        double p_ge50 = 0;
        double p_ge50_steady = 0;
        double p_ge83 = 0;
        double p_lt25 = 0;
        double p_in_band = 0;
        std::int64_t steady_n = 0;
        // Write duration (us)
        double mean_write_us = 0;
        double mean_write_us_late = 0; // prior-write on arrival_iv>50ms
        double mean_write_us_ok = 0;   // write on arrival_iv<=50ms
        double write_late_ratio = 0;   // mean_late / mean_all (1.0 = flat)
        double p_write_ge1ms = 0;
        double p_write_ge5ms = 0;
        std::int64_t write_max_us = 0;
        const char* verdict = "UNSCORED";
        const char* disc_verdict = "UNSCORED"; // LATE_ARRIVAL / LATE_OBSERVATION / ...
        const char* axis = "arrival_pre";      // intervals are pre-to-pre
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

    void copyChronologicalPre(std::int64_t* out, std::size_t* n_out) const {
        const std::size_t n = filled;
        *n_out = n;
        if (n == 0)
            return;
        std::size_t start = (count <= kCap) ? 0 : head;
        for (std::size_t i = 0; i < n; ++i)
            out[i] = pre_us[(start + i) % kCap];
    }

    void copyChronologicalWrite(std::int64_t* out, std::size_t* n_out) const {
        const std::size_t n = filled;
        *n_out = n;
        if (n == 0)
            return;
        std::size_t start = (count <= kCap) ? 0 : head;
        for (std::size_t i = 0; i < n; ++i)
            out[i] = write_us[(start + i) % kCap];
    }

    // Alias used by older call sites / dump
    void copyChronological(std::int64_t* out, std::size_t* n_out) const {
        copyChronologicalPre(out, n_out);
    }

    void collectIntervalsMs(std::vector<double>& out, bool steady_window) const {
        out.clear();
        std::int64_t tmp[kCap];
        std::size_t n = 0;
        copyChronologicalPre(tmp, &n);
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
        s.axis = "arrival_pre";
        if (write_n > 0) {
            s.mean_write_us = sum_write_us / double(write_n);
            if (write_n_late > 0)
                s.mean_write_us_late = sum_write_us_late / double(write_n_late);
            if (write_n_ok > 0)
                s.mean_write_us_ok = sum_write_us_ok / double(write_n_ok);
            if (s.mean_write_us > 0.0)
                s.write_late_ratio = s.mean_write_us_late / s.mean_write_us;
            s.p_write_ge1ms = double(write_ge1ms_n) / double(write_n);
            s.p_write_ge5ms = double(write_ge5ms_n) / double(write_n);
            s.write_max_us = write_max_us;
        }
        if (iv_n <= 0) {
            s.verdict = "UNSCORED";
            s.disc_verdict = "UNSCORED";
            return s;
        }
        s.mean_ms = sum_iv_ms / double(iv_n);
        const double var = std::max(0.0, sum_iv_ms2 / double(iv_n) - s.mean_ms * s.mean_ms);
        s.sigma_ms = std::sqrt(var);
        s.p_ge50 = double(ge50_count) / double(iv_n);
        s.p_ge83 = double(ge83_count) / double(iv_n);
        s.p_lt25 = double(lt25_count) / double(iv_n);
        s.p_in_band = double(in_band_count) / double(iv_n);

        std::vector<double> steady;
        collectIntervalsMs(steady, true);
        s.steady_n = static_cast<std::int64_t>(steady.size());
        if (!steady.empty()) {
            std::vector<double> sorted = steady;
            s.median_ms = percentileSorted(sorted, 0.5);
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
                const double v2 =
                    std::max(0.0, sum2 / double(m) - s.trimmed_mean_ms * s.trimmed_mean_ms);
                s.steady_sigma_ms = std::sqrt(v2);
            }
            s.p_ge50_steady = double(ge50s) / double(steady.size());
        }

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

        // Discriminator (needs enough writes). Reuses p50 from verdict block.
        const bool arrival_late = p50 > 0.03;
        const bool write_fat = (s.p_write_ge5ms >= 0.05) ||
                               (s.write_max_us >= 10000 && s.p_write_ge1ms >= 0.05) ||
                               (s.mean_write_us >= 2000.0);
        const bool write_flat = (s.p_write_ge5ms < 0.01) && (s.write_max_us < 5000) &&
                                (s.mean_write_us < 2000.0);
        if (write_n < 50) {
            s.disc_verdict = "UNSCORED";
        } else if (arrival_late && write_flat) {
            s.disc_verdict = "LATE_ARRIVAL";
        } else if (!arrival_late && write_fat) {
            // Clean pre cadence + fat write tail: post-only would look late.
            s.disc_verdict = "LATE_OBSERVATION";
        } else if (arrival_late && write_fat) {
            s.disc_verdict = "MIXED";
        } else if (!arrival_late && write_flat) {
            s.disc_verdict = "CLEAN_ARRIVAL_AND_WRITE";
        } else {
            s.disc_verdict = "UNSCORED";
        }
        return s;
    }

    std::string formatSummaryLine(const char* tag = "measured") const {
        const Summary s = summarize();
        char buf[1024];
        std::snprintf(
            buf, sizeof(buf),
            "publish_interval axis=%s notes=%lld intervals=%lld mean_ms=%.3f sigma_ms=%.3f "
            "median_ms=%.3f trimmed_mean_ms=%.3f steady_sigma_ms=%.3f steady_n=%lld "
            "p_ge50=%.4f p_ge50_steady=%.4f p_ge83=%.4f p_lt25=%.4f p_in_band=%.4f "
            "mean_write_us=%.1f mean_write_us_late=%.1f mean_write_us_ok=%.1f "
            "write_late_ratio=%.3f p_write_ge5ms=%.4f write_max_us=%lld "
            "disc_verdict=%s verdict=%s ideal_ms=%.3f tag=%s",
            s.axis, static_cast<long long>(s.notes), static_cast<long long>(s.intervals),
            s.mean_ms, s.sigma_ms, s.median_ms, s.trimmed_mean_ms, s.steady_sigma_ms,
            static_cast<long long>(s.steady_n), s.p_ge50, s.p_ge50_steady, s.p_ge83, s.p_lt25,
            s.p_in_band, s.mean_write_us, s.mean_write_us_late, s.mean_write_us_ok,
            s.write_late_ratio, s.p_write_ge5ms, static_cast<long long>(s.write_max_us),
            s.disc_verdict, s.verdict, 1000.0 / 24.0, tag);
        return std::string(buf);
    }

    std::string formatDiscLine() const {
        const Summary s = summarize();
        char buf[512];
        std::snprintf(buf, sizeof(buf),
                      "publish_disc disc_verdict=%s mean_write_us=%.1f mean_write_us_late=%.1f "
                      "mean_write_us_ok=%.1f write_late_ratio=%.3f p_write_ge1ms=%.4f "
                      "p_write_ge5ms=%.4f write_max_us=%lld write_n_late=%lld "
                      "p_ge50_steady=%.4f axis=arrival_pre "
                      "rule=late_arr=arrival_late+write_flat;late_obs=arrival_clean+write_fat "
                      "tag=measured",
                      s.disc_verdict, s.mean_write_us, s.mean_write_us_late, s.mean_write_us_ok,
                      s.write_late_ratio, s.p_write_ge1ms, s.p_write_ge5ms,
                      static_cast<long long>(s.write_max_us),
                      static_cast<long long>(write_n_late), s.p_ge50_steady);
        return std::string(buf);
    }

    struct ShortCorr {
        int short_n = 0;
        int short_then_lt50 = 0;
        int short_then_ge50 = 0;
    };
    ShortCorr shortIntervalCorrelation(double short_ms = 25.0) const {
        ShortCorr c;
        std::int64_t tmp[kCap];
        std::size_t n = 0;
        copyChronologicalPre(tmp, &n);
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

    std::string formatHistLine() const {
        std::int64_t tmp[kCap];
        std::size_t n = 0;
        copyChronologicalPre(tmp, &n);
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
        char buf[320];
        std::snprintf(buf, sizeof(buf),
                      "publish_interval_hist n=%d lt25=%d b25_33=%d b33_42=%d b42_50=%d "
                      "b50_67=%d b67_83=%d b83_100=%d ge100=%d axis=arrival_pre",
                      tot, b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7]);
        return std::string(buf);
    }

    double lag1Autocorr() const {
        std::vector<double> iv;
        collectIntervalsMs(iv, true);
        if (iv.size() < 3)
            return 0;
        double lo = iv[0], hi = iv[0], mean = 0;
        for (double v : iv) {
            mean += v;
            if (v < lo)
                lo = v;
            if (v > hi)
                hi = v;
        }
        // Constant (or FP-noise-only) series: sample mean drifts by ulps so
        // every residual is ~equal and num/den → (n-1)/n ≈ 0.99 spuriously.
        if ((hi - lo) < 1e-9)
            return 0;
        mean /= double(iv.size());
        double num = 0, den = 0;
        for (std::size_t i = 0; i < iv.size(); ++i) {
            const double d = iv[i] - mean;
            den += d * d;
            if (i + 1 < iv.size())
                num += d * (iv[i + 1] - mean);
        }
        if (den <= 0)
            return 0;
        return num / den;
    }

    std::string formatAutocorrLine() const {
        char buf[128];
        std::snprintf(buf, sizeof(buf), "publish_interval_acf lag1=%.4f axis=arrival_pre",
                      lag1Autocorr());
        return std::string(buf);
    }

    bool dumpMonoUs(const char* path) const {
        FILE* f = std::fopen(path, "w");
        if (!f)
            return false;
        std::int64_t p[kCap], w[kCap];
        std::size_t n = 0, nw = 0;
        copyChronologicalPre(p, &n);
        copyChronologicalWrite(w, &nw);
        std::fprintf(f, "pre_us,write_us\n");
        for (std::size_t i = 0; i < n; ++i)
            std::fprintf(f, "%lld,%lld\n", static_cast<long long>(p[i]),
                         static_cast<long long>(i < nw ? w[i] : 0));
        std::fclose(f);
        return true;
    }
};

} // namespace misterplex
