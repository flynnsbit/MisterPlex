#pragma once
// Per-publish Δframes_done + interval + vsync-phase ESTIMATE + cadence hold (w-instr/w-geom).
//
// ---------------------------------------------------------------------------
// TWO DIFFERENT METRICS — do not conflate (parent 2026-08-01 re-task)
// ---------------------------------------------------------------------------
// A) Δframes_done (p_delta0 / p_delta1 / p_delta_ge2):
//    Swap-counter RBF (frames_done_d2): Δ=1 expected per publish under free-gate;
//    Δ=0 = zero-refresh skip (pending overwrite). NOT a refresh-hold length.
// B) Hold cadence (p_hold_d1 / d2 / d3 / d_ge4), DERIVED:
//    hold_d = round(iv_ms / T_vsync). On 24fps@60Hz ideal is alternating 2 and 3
//    (33.3 / 50.0 ms), NEVER a single quantum at ideal_ms=41.667.
//    d=1 TOO_SHORT hitch · d=0 impossible for iv · d>=4 TOO_LONG · d=2|3 OK.
//
// ideal_ms = 1000/src_fps is the *mean publish* target. A perfect 3:2 *display*
// cadence still averages 41.667 ms; p_ge50 on publish iv does NOT equal
// "fraction of legitimate 3-refresh holds". Use hold_d histogram for judder.
// mean_ms ≈ ideal while the picture judders is expected when cadence is
// scrambled but rate-conserving — the instrument says so explicitly.
//
// p_ge50 gate (binding): if sigma_ms >= mean_ms, p_ge50 is NOT a score
// (tag=UNSCORED_SIGMA_GE_MEAN). Never pool high-sigma with clean sessions.
//
// TIP RTL packs frames_done_d2 (real swaps) into PLXD[63:48].
// DEPLOYED RBF c5382bee packed bank_vsync_count (HISTORICAL) — then Δfd tracks
// refreshes. Runtime: p_delta1 < 0.5 → fd_semantics=LIKELY_VSYNC_PACKED,
// skip_verdict=UNSCORED. Never emit NO_ZERO_REFRESH_SKIP when premise fails.
//
// phase_est_us = mono_us % T_vsync; default T from 60.000 Hz DEFAULT_ASSUMED.
// Prefer setVsyncHzMeasured() when parent measures refresh (glass pts / lab).

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
    static constexpr double kDefaultVsyncHz = 60.0;
    static constexpr double kDefaultSrcFps = 24.0;

    struct Sample {
        std::int64_t mono_us = 0;
        std::int64_t iv_us = -1;
        std::int64_t phase_est_us = 0;
        std::uint16_t frames_done = 0;
        int delta_fd = -1;
        int hold_d = -1;
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
    int last_hold_d = -1;

    std::int64_t pair_n = 0;
    std::int64_t delta0 = 0;
    std::int64_t delta1 = 0;
    std::int64_t delta_ge2 = 0;
    std::int64_t sum_delta = 0;

    std::int64_t ge50 = 0;
    std::int64_t iv_n = 0;
    double sum_iv_ms = 0;
    double sum_iv_ms2 = 0;

    std::int64_t hold_n = 0;
    std::int64_t hold_d1 = 0;
    std::int64_t hold_d2 = 0;
    std::int64_t hold_d3 = 0;
    std::int64_t hold_d_ge4 = 0;
    std::int64_t hold_d_other = 0;
    std::int64_t cad_pair_n = 0;
    std::int64_t cad_alt_n = 0;
    std::int64_t cad_same_n = 0;

    std::int64_t d0_phase_bin[4] = {};
    std::int64_t d1_phase_bin[4] = {};

    double vsync_hz_ = kDefaultVsyncHz;
    const char* vsync_tag_ = "DEFAULT_ASSUMED";
    double src_fps_ = kDefaultSrcFps;
    const char* src_fps_tag_ = "DEFAULT_ASSUMED";

    void reset() {
        count = head = filled = 0;
        last_us = -1;
        last_fd = -1;
        last_hold_d = -1;
        pair_n = delta0 = delta1 = delta_ge2 = ge50 = iv_n = 0;
        sum_iv_ms = sum_iv_ms2 = 0;
        sum_delta = 0;
        hold_n = hold_d1 = hold_d2 = hold_d3 = hold_d_ge4 = hold_d_other = 0;
        cad_pair_n = cad_alt_n = cad_same_n = 0;
        std::memset(d0_phase_bin, 0, sizeof(d0_phase_bin));
        std::memset(d1_phase_bin, 0, sizeof(d1_phase_bin));
        for (std::size_t i = 0; i < kCap; ++i)
            ring[i] = Sample{};
    }

    void setVsyncHzMeasured(double hz) {
        if (hz > 1.0 && hz < 240.0) {
            vsync_hz_ = hz;
            vsync_tag_ = "measured";
        }
    }

    void setVsyncHzDefaultAssumed(double hz = kDefaultVsyncHz) {
        vsync_hz_ = hz;
        vsync_tag_ = "DEFAULT_ASSUMED";
    }

    void setSrcFpsMeasured(double fps) {
        if (fps > 1.0 && fps < 120.0) {
            src_fps_ = fps;
            src_fps_tag_ = "measured";
        }
    }

    void setSrcFpsDefaultAssumed(double fps = kDefaultSrcFps) {
        src_fps_ = fps;
        src_fps_tag_ = "DEFAULT_ASSUMED";
    }

    double vsyncPeriodUs() const { return 1000000.0 / vsync_hz_; }
    double idealPublishMs() const { return 1000.0 / src_fps_; }

    static int unwrapFdDelta(int prev, int cur) { return (cur - prev) & 0xFFFF; }

    static int holdDFromIvMs(double iv_ms, double t_vsync_ms) {
        if (t_vsync_ms <= 0.0 || iv_ms <= 0.0)
            return -1;
        const int d = static_cast<int>(std::llround(iv_ms / t_vsync_ms));
        return d < 0 ? -1 : d;
    }

    void note(std::int64_t mono_us, std::uint16_t frames_done, std::uint8_t swap_pending,
              std::uint8_t free_mask, std::uint8_t disp_bank) {
        const double t_vs_us = vsyncPeriodUs();
        const double t_vs_ms = t_vs_us / 1000.0;

        Sample s;
        s.mono_us = mono_us;
        s.frames_done = frames_done;
        s.swap_pending = swap_pending;
        s.free_mask = free_mask;
        s.disp_bank = disp_bank;
        s.phase_est_us = static_cast<std::int64_t>(mono_us % static_cast<std::int64_t>(t_vs_us));

        if (last_us >= 0 && mono_us >= last_us) {
            s.iv_us = mono_us - last_us;
            ++iv_n;
            const double iv_ms = double(s.iv_us) / 1000.0;
            sum_iv_ms += iv_ms;
            sum_iv_ms2 += iv_ms * iv_ms;
            if (iv_ms > 50.0)
                ++ge50;

            s.hold_d = holdDFromIvMs(iv_ms, t_vs_ms);
            if (s.hold_d >= 0) {
                ++hold_n;
                if (s.hold_d == 1)
                    ++hold_d1;
                else if (s.hold_d == 2)
                    ++hold_d2;
                else if (s.hold_d == 3)
                    ++hold_d3;
                else if (s.hold_d >= 4)
                    ++hold_d_ge4;
                else
                    ++hold_d_other;

                if (last_hold_d == 2 || last_hold_d == 3) {
                    if (s.hold_d == 2 || s.hold_d == 3) {
                        ++cad_pair_n;
                        if (s.hold_d != last_hold_d)
                            ++cad_alt_n;
                        else
                            ++cad_same_n;
                    }
                }
                last_hold_d = s.hold_d;
            }
        }

        if (last_fd >= 0) {
            s.delta_fd = unwrapFdDelta(last_fd, static_cast<int>(frames_done));
            ++pair_n;
            sum_delta += s.delta_fd;
            const int bin =
                static_cast<int>((s.phase_est_us * 4) / static_cast<std::int64_t>(t_vs_us)) & 3;
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
        bool p_ge50_scoreable = false;
        const char* p_ge50_tag = "UNSCORED";
        const char* interval_verdict = "UNSCORED";

        std::int64_t hold_n = 0;
        double p_hold_d1 = 0;
        double p_hold_d2 = 0;
        double p_hold_d3 = 0;
        double p_hold_d_ge4 = 0;
        double p_hold_defect = 0;
        double cad_alt_frac = 0;
        const char* cadence_verdict = "UNSCORED";
        const char* hold_src = "derived_iv_over_Tvsync";

        const char* skip_verdict = "UNSCORED";
        const char* fd_semantics = "UNSCORED";

        double ideal_ms = 1000.0 / 24.0;
        const char* ideal_ms_tag = "DEFAULT_ASSUMED";
        double vsync_hz = 60.0;
        const char* vsync_tag = "DEFAULT_ASSUMED";
        double src_fps = 24.0;
        const char* src_fps_tag = "DEFAULT_ASSUMED";

        const char* mean_vs_cadence_note =
            "mean_ms~ideal_does_NOT_imply_smooth_cadence_score_hold_d";
    };

    Summary summarize() const {
        Summary s;
        s.notes = static_cast<std::int64_t>(count);
        s.pairs = pair_n;
        s.ideal_ms = idealPublishMs();
        s.ideal_ms_tag = src_fps_tag_;
        s.vsync_hz = vsync_hz_;
        s.vsync_tag = vsync_tag_;
        s.src_fps = src_fps_;
        s.src_fps_tag = src_fps_tag_;

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

            if (s.mean_ms > 0.0 && s.sigma_ms >= s.mean_ms) {
                s.p_ge50_scoreable = false;
                s.p_ge50_tag = "UNSCORED_SIGMA_GE_MEAN";
                s.interval_verdict = "UNSCORED_SIGMA_GE_MEAN";
            } else if (iv_n < 50) {
                s.p_ge50_scoreable = false;
                s.p_ge50_tag = "UNSCORED";
                s.interval_verdict = "UNSCORED";
            } else {
                s.p_ge50_scoreable = true;
                s.p_ge50_tag = "measured";
                if (s.p_ge50 >= 0.09 && s.p_ge50 <= 0.11)
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
        }

        s.hold_n = hold_n;
        if (hold_n >= 50) {
            s.p_hold_d1 = double(hold_d1) / double(hold_n);
            s.p_hold_d2 = double(hold_d2) / double(hold_n);
            s.p_hold_d3 = double(hold_d3) / double(hold_n);
            s.p_hold_d_ge4 = double(hold_d_ge4) / double(hold_n);
            s.p_hold_defect =
                double(hold_d1 + hold_d_ge4 + hold_d_other) / double(hold_n);
            if (cad_pair_n > 0)
                s.cad_alt_frac = double(cad_alt_n) / double(cad_pair_n);

            // NOTE: steady publish at ideal_ms=41.667 rounds to hold_d=2 or 3
            // (2.5→banker's even) for *every* sample — that is NOT display 3:2
            // alternation; it is a metronome publisher. Do not call it IRREGULAR.
            // True 2,3 alternation requires publish iv alternating ~33.3/50.0.
            const double p23 = s.p_hold_d2 + s.p_hold_d3;
            const bool near_ideal =
                (s.mean_ms > 0.0) &&
                (std::fabs(s.mean_ms - s.ideal_ms) <= 2.0) &&
                (s.sigma_ms < 8.0);
            if (s.p_hold_d1 >= 0.02)
                s.cadence_verdict = "HITCHY_D1";
            else if (s.p_hold_d_ge4 >= 0.05)
                s.cadence_verdict = "LONG_HOLDS";
            else if (p23 >= 0.95 && s.cad_alt_frac >= 0.85 && s.p_hold_d1 < 0.01)
                s.cadence_verdict = "CADENCE_32_CLEAN";
            else if (near_ideal && s.p_hold_d1 < 0.01 && s.p_hold_d_ge4 < 0.03)
                s.cadence_verdict = "CADENCE_METRONOME_OK";
            else if (p23 >= 0.90 && s.cad_alt_frac < 0.55 && s.sigma_ms >= 6.0)
                s.cadence_verdict = "CADENCE_IRREGULAR";
            else if (p23 >= 0.90)
                s.cadence_verdict = "CADENCE_OK_MILD";
            else
                s.cadence_verdict = "CADENCE_OTHER";
        } else {
            s.cadence_verdict = "UNSCORED";
        }

        if (pair_n < 50) {
            s.fd_semantics = "UNSCORED";
            s.skip_verdict = "UNSCORED";
        } else if (s.p_delta1 < 0.5) {
            if (s.p_delta_ge2 >= 0.5 && s.mean_delta >= 1.5 && s.mean_delta <= 5.0)
                s.fd_semantics = "LIKELY_VSYNC_PACKED";
            else
                s.fd_semantics = "UNKNOWN_NOT_SWAP";
            s.skip_verdict = "UNSCORED";
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
        char buf[1200];
        std::snprintf(
            buf, sizeof(buf),
            "publish_swap_delta notes=%lld pairs=%lld "
            "p_delta0=%.4f p_delta1=%.4f p_delta_ge2=%.4f mean_delta=%.3f "
            "p_ge50=%.4f p_ge50_tag=%s p_ge50_scoreable=%d "
            "mean_ms=%.3f sigma_ms=%.3f "
            "interval_verdict=%s skip_verdict=%s fd_semantics=%s "
            "p_hold_d1=%.4f p_hold_d2=%.4f p_hold_d3=%.4f p_hold_d_ge4=%.4f "
            "p_hold_defect=%.4f cad_alt_frac=%.4f cadence_verdict=%s "
            "hold_src=%s "
            "phase_tag=%s_vsync_hz ideal_ms=%.3f ideal_ms_tag=%s "
            "src_fps=%.6f src_fps_tag=%s vsync_hz=%.6f vsync_tag=%s "
            "mean_vs_cadence_note=%s tag=%s",
            static_cast<long long>(s.notes), static_cast<long long>(s.pairs), s.p_delta0,
            s.p_delta1, s.p_delta_ge2, s.mean_delta, s.p_ge50, s.p_ge50_tag,
            s.p_ge50_scoreable ? 1 : 0, s.mean_ms, s.sigma_ms, s.interval_verdict,
            s.skip_verdict, s.fd_semantics, s.p_hold_d1, s.p_hold_d2, s.p_hold_d3,
            s.p_hold_d_ge4, s.p_hold_defect, s.cad_alt_frac, s.cadence_verdict, s.hold_src,
            s.vsync_tag, s.ideal_ms, s.ideal_ms_tag, s.src_fps, s.src_fps_tag, s.vsync_hz,
            s.vsync_tag, s.mean_vs_cadence_note, tag);
        return std::string(buf);
    }

    std::string formatCompatAliasLine() const {
        const Summary s = summarize();
        char buf[512];
        std::snprintf(
            buf, sizeof(buf),
            "publish_swap_delta_alias p_d0=%.4f p_d1=%.4f p_dge2=%.4f "
            "p_d1_is=delta_frames_done_eq1_NOT_hold_refresh "
            "p_hold_d1=%.4f p_ge50=%.4f p_ge50_tag=%s cadence_verdict=%s",
            s.p_delta0, s.p_delta1, s.p_delta_ge2, s.p_hold_d1, s.p_ge50, s.p_ge50_tag,
            s.cadence_verdict);
        return std::string(buf);
    }

    std::string formatPhaseLine() const {
        char buf[320];
        const auto t_us = static_cast<std::int64_t>(vsyncPeriodUs());
        std::snprintf(buf, sizeof(buf),
                      "publish_swap_delta_phase_est d0_bins=%lld,%lld,%lld,%lld "
                      "d1_bins=%lld,%lld,%lld,%lld period_us=%lld vsync_tag=%s",
                      static_cast<long long>(d0_phase_bin[0]),
                      static_cast<long long>(d0_phase_bin[1]),
                      static_cast<long long>(d0_phase_bin[2]),
                      static_cast<long long>(d0_phase_bin[3]),
                      static_cast<long long>(d1_phase_bin[0]),
                      static_cast<long long>(d1_phase_bin[1]),
                      static_cast<long long>(d1_phase_bin[2]),
                      static_cast<long long>(d1_phase_bin[3]),
                      static_cast<long long>(t_us), vsync_tag_);
        return std::string(buf);
    }
};

} // namespace misterplex
