#pragma once
// Per-publish Δframes_done + interval + vsync-phase ESTIMATE (w-geom).
//
// frames_done is the PRODUCT swap counter (not vsync). Between consecutive
// successful publishes under free-gated double-buffer:
//   Δ=1 → previous frame was swapped/displayed at least once
//   Δ=0 → no swap between publishes → pending_bank overwrite class
//         (ddr_frame_store.sv doorbell edge) → true zero-refresh skip
//   Δ≥2 → unexpected (log; free-gate should prevent)
//
// vsync_toggle is NOT ARM-readable on product PLXD. Phase is therefore:
//   phase_est_us = mono_us % kVsyncPeriodUs   tag=ESTIMATE (assumes 60.000 Hz)
// Parent ERROR 21: mean-preserving ±1 hold can come from CDC even with clean
// intervals — phase near edge is the discriminant for Mechanism 1.
//
// Corrected pre-register (parent ERROR 21):
//   p_ge50 ∈ [0.09,0.11] → ARM_LATE
//   p_ge50 < 0.03        → ARM_EXONERATED (redirect to CDC/DDR-complete), NOT "dead"

#include "libmisterplex/publish_interval_ledger.hpp"

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <string>

namespace misterplex {

struct PublishSwapDeltaLedger {
    static constexpr std::size_t kCap = 4096;
    static constexpr std::int64_t kVsyncPeriodUs = 1000000 / 60; // ESTIMATE 60.000 Hz

    struct Sample {
        std::int64_t mono_us = 0;
        std::int64_t iv_us = -1;      // -1 = first sample
        std::int64_t phase_est_us = 0; // mono % kVsyncPeriodUs, ESTIMATE
        std::uint16_t frames_done = 0;
        int delta_fd = -1; // -1 first; else unwrap16 diff
        std::uint8_t swap_pending = 0;
        std::uint8_t free_mask = 0;
        std::uint8_t disp_bank = 0;
    };

    Sample ring[kCap]{};
    std::size_t count = 0;
    std::size_t head = 0;
    std::size_t filled = 0;

    std::int64_t last_us = -1;
    int last_fd = -1;

    // Counters over noted samples with a prior (iv valid).
    std::int64_t pair_n = 0;
    std::int64_t delta0 = 0;
    std::int64_t delta1 = 0;
    std::int64_t delta_ge2 = 0;
    std::int64_t sum_delta = 0;
    std::int64_t ge50 = 0;
    std::int64_t iv_n = 0;
    double sum_iv_ms = 0;
    double sum_iv_ms2 = 0;
    // Phase bins when delta0 (skip class): which ESTIMATE phase quadrant
    std::int64_t d0_phase_bin[4] = {};
    std::int64_t d1_phase_bin[4] = {};

    void reset() {
        count = head = filled = 0;
        last_us = -1;
        last_fd = -1;
        pair_n = delta0 = delta1 = delta_ge2 = ge50 = iv_n = 0;
        sum_iv_ms = sum_iv_ms2 = 0;
        sum_delta = 0;
        std::memset(d0_phase_bin, 0, sizeof(d0_phase_bin));
        std::memset(d1_phase_bin, 0, sizeof(d1_phase_bin));
        for (std::size_t i = 0; i < kCap; ++i)
            ring[i] = Sample{};
    }

    static int unwrapFdDelta(int prev, int cur) {
        // uint16 modular difference in [0,65535]
        return (cur - prev) & 0xFFFF;
    }

    void note(std::int64_t mono_us, std::uint16_t frames_done, std::uint8_t swap_pending,
              std::uint8_t free_mask, std::uint8_t disp_bank) {
        Sample s;
        s.mono_us = mono_us;
        s.frames_done = frames_done;
        s.swap_pending = swap_pending;
        s.free_mask = free_mask;
        s.disp_bank = disp_bank;
        s.phase_est_us = mono_us % kVsyncPeriodUs; // ESTIMATE
        if (last_us >= 0 && mono_us >= last_us) {
            s.iv_us = mono_us - last_us;
            ++iv_n;
            const double iv_ms = double(s.iv_us) / 1000.0;
            sum_iv_ms += iv_ms;
            sum_iv_ms2 += iv_ms * iv_ms;
            if (iv_ms > 50.0)
                ++ge50;
        }
        if (last_fd >= 0) {
            s.delta_fd = unwrapFdDelta(last_fd, static_cast<int>(frames_done));
            ++pair_n;
            sum_delta += s.delta_fd;
            const int bin = static_cast<int>((s.phase_est_us * 4) / kVsyncPeriodUs) & 3;
            if (s.delta_fd == 0) {
                ++delta0;
                ++d0_phase_bin[bin];
            } else if (s.delta_fd == 1) {
                ++delta1;
                ++d1_phase_bin[bin];
            } else {
                ++delta_ge2;
            }
        }

        ring[head] = s;
        head = (head + 1) % kCap;
        if (filled < kCap)
            ++filled;
        ++count;
        last_us = mono_us;
        last_fd = static_cast<int>(frames_done);
    }

    struct Summary {
        std::int64_t notes = 0;
        std::int64_t pairs = 0;
        double p_delta0 = 0;
        double p_delta1 = 0;
        double p_delta_ge2 = 0;
        double mean_delta = 0;
        double p_ge50 = 0;
        double mean_ms = 0;
        double sigma_ms = 0;
        const char* interval_verdict = "UNSCORED";
        const char* skip_verdict = "UNSCORED";
        // fd_semantics: SWAP_COUNTER only if p_d1 dominates; else not a skip meter.
        const char* fd_semantics = "UNSCORED";
    };

    Summary summarize() const {
        Summary s;
        s.notes = static_cast<std::int64_t>(count);
        s.pairs = pair_n;
        if (pair_n > 0) {
            s.p_delta0 = double(delta0) / double(pair_n);
            s.p_delta1 = double(delta1) / double(pair_n);
            s.p_delta_ge2 = double(delta_ge2) / double(pair_n);
            s.mean_delta = double(sum_delta) / double(pair_n);
        }
        if (iv_n > 0) {
            s.mean_ms = sum_iv_ms / double(iv_n);
            const double var =
                std::max(0.0, sum_iv_ms2 / double(iv_n) - s.mean_ms * s.mean_ms);
            s.sigma_ms = std::sqrt(var);
            s.p_ge50 = double(ge50) / double(iv_n);
            // Parent fleet 2026-08-01: p_ge50 vs pre-reg band is UNSCORED when
            // σ ≫ mean (e.g. σ=500ms, mean=50ms). Fat tail from preemption is
            // not a late-publisher score. Never treat as MISS/HIT.
            if (s.mean_ms > 0.0 && s.sigma_ms > 2.0 * s.mean_ms)
                s.interval_verdict = "UNSCORED";
            else if (s.p_ge50 >= 0.09 && s.p_ge50 <= 0.11)
                s.interval_verdict = "ARM_LATE_MATCH_HOLD45";
            else if (s.p_ge50 < 0.03 && s.sigma_ms < 4.0)
                s.interval_verdict = "ARM_EXONERATED_FPGA_SIDE";
            else if (s.p_ge50 > 0.03 && s.p_ge50 < 0.09)
                s.interval_verdict = "ARM_LATE_MILD";
            else if (s.p_ge50 > 0.11)
                s.interval_verdict = "ARM_LATE_OR_BIMODAL";
            else
                s.interval_verdict = "ARM_OTHER";
        }

        // Premise for skip: Δfd ∈ {0,1} with p_d1 ≈ 1 (real swap counter).
        // Parent soak on c5382bee: p_dge2≈0.97 → NOT a swap counter; skip UNSCORED.
        if (pair_n < 50) {
            s.fd_semantics = "UNSCORED";
            s.skip_verdict = "UNSCORED";
        } else if (s.p_delta1 < 0.5) {
            // Inconsistent with per-publish swap counter.
            if (s.p_delta_ge2 >= 0.5 && s.mean_delta >= 1.5 && s.mean_delta <= 5.0)
                s.fd_semantics = "LIKELY_VSYNC_PACKED"; // Δ tracks refreshes/interval
            else
                s.fd_semantics = "UNKNOWN_NOT_SWAP";
            s.skip_verdict = "UNSCORED"; // NEVER pass when premise violated
        } else {
            s.fd_semantics = "SWAP_COUNTER";
            if (s.p_delta0 < 0.001)
                s.skip_verdict = "NO_ZERO_REFRESH_SKIP";
            else if (s.p_delta0 < 0.01)
                s.skip_verdict = "RARE_ZERO_REFRESH_SKIP";
            else
                s.skip_verdict = "ZERO_REFRESH_SKIPS_PRESENT";
        }
        return s;
    }

    std::string formatSummaryLine(const char* tag = "measured") const {
        const Summary s = summarize();
        char buf[768];
        std::snprintf(
            buf, sizeof(buf),
            "publish_swap_delta notes=%lld pairs=%lld p_d0=%.4f p_d1=%.4f p_dge2=%.4f "
            "mean_delta=%.3f p_ge50=%.4f mean_ms=%.3f sigma_ms=%.3f "
            "interval_verdict=%s skip_verdict=%s fd_semantics=%s "
            "phase_tag=ESTIMATE_60Hz ideal_ms=%.3f tag=%s",
            static_cast<long long>(s.notes), static_cast<long long>(s.pairs), s.p_delta0,
            s.p_delta1, s.p_delta_ge2, s.mean_delta, s.p_ge50, s.mean_ms, s.sigma_ms,
            s.interval_verdict, s.skip_verdict, s.fd_semantics, 1000.0 / 24.0, tag);
        return std::string(buf);
    }

    std::string formatPhaseLine() const {
        char buf[320];
        std::snprintf(buf, sizeof(buf),
                      "publish_swap_delta_phase_est d0_bins=%lld,%lld,%lld,%lld "
                      "d1_bins=%lld,%lld,%lld,%lld period_us=%lld tag=ESTIMATE_60Hz",
                      static_cast<long long>(d0_phase_bin[0]),
                      static_cast<long long>(d0_phase_bin[1]),
                      static_cast<long long>(d0_phase_bin[2]),
                      static_cast<long long>(d0_phase_bin[3]),
                      static_cast<long long>(d1_phase_bin[0]),
                      static_cast<long long>(d1_phase_bin[1]),
                      static_cast<long long>(d1_phase_bin[2]),
                      static_cast<long long>(d1_phase_bin[3]),
                      static_cast<long long>(kVsyncPeriodUs));
        return std::string(buf);
    }
};

} // namespace misterplex
