#pragma once
// Session-latched HDMI A/V offset discriminator helpers (source-derived).
//
// Parent measured ~117.10 ms bimodal clusters (SESSION-LATCHED, device-side).
// RTL answers: audio sample quantum ~20.8 us (not 117 ms); 3×24 fps = 125 ms
// REJECTED; NTSC display tick T from colorbars+pll = 16.715600 ms, 7×T≈117.01.
//
// This header does NOT claim H-VDISP7 is proven — it formats probes and maps a
// measured delta_ms onto the nearest integer display-tick multiple so parent
// can FALSIFY H-VDISP7 offline from daemon logs + HDMI cluster id.
//
// Labels: constants are DERIVED_FROM_RTL (quoted sources in comments), not
// measured on silicon by this lane.

#include "libmisterplex/mraudio_status.hpp"

#include <cstdint>
#include <cstdio>
#include <cstring>

namespace misterplex {
namespace av_bimodal {

// colorbars.sv: H_LAST=637 → H_COUNT=638; V NTSC progressive half = 262;
// CE_PIXEL doubles effective period → ×2. pll_0002.v: clk_sys = 20_000_000 Hz.
constexpr int64_t kClkSysHz = 20000000LL;       // DERIVED_FROM_RTL pll_0002.v
constexpr int64_t kColorbarsHCount = 638LL;     // DERIVED_FROM_RTL colorbars.sv H_LAST+1
constexpr int64_t kColorbarsVHalf = 262LL;      // DERIVED_FROM_RTL colorbars.sv NTSC
constexpr int64_t kCepixelPeriodMul = 2LL;      // DERIVED_FROM_RTL CE_PIXEL cadence

// T_disp_s = (H*V*2) / f_clk
constexpr int64_t kDisplayTickCycles =
    kColorbarsHCount * kColorbarsVHalf * kCepixelPeriodMul; // 334312
// Exact ms as rational: cycles * 1000 / Hz
// 334312 * 1000 / 20000000 = 16.7156 ms exactly as 167156/10000
constexpr double kDisplayTickMs =
    (1000.0 * static_cast<double>(kDisplayTickCycles)) / static_cast<double>(kClkSysHz);

// Parent cluster separation (MEASURED by parent instrument, not this lane).
constexpr double kParentClusterSepMs = 117.10; // MEASURED (parent); not used as proof

struct TickMatch {
    int n = 0;                 // nearest integer n for n * T_disp
    double n_times_T_ms = 0.0; // n * T
    double err_ms = 0.0;       // |delta_ms| - n*T  (signed: delta_abs - nT)
    double abs_err_ms = 0.0;
};

// Map |delta_ms| onto nearest n∈[0,32] of display ticks. Pure arithmetic.
inline TickMatch nearestDisplayTicks(double delta_ms) {
    TickMatch m;
    const double absd = delta_ms < 0.0 ? -delta_ms : delta_ms;
    if (!(kDisplayTickMs > 0.0))
        return m;
    bool have = false;
    double bestAbsErr = 0.0;
    for (int n = 0; n <= 32; ++n) {
        const double pred = static_cast<double>(n) * kDisplayTickMs;
        const double err = absd - pred;
        const double aerr = err < 0.0 ? -err : err;
        if (!have || aerr < bestAbsErr) {
            have = true;
            bestAbsErr = aerr;
            m.n = n;
            m.n_times_T_ms = pred;
            m.err_ms = err;
            m.abs_err_ms = aerr;
        }
    }
    return m;
}

// Content-frame hypothesis (24.000 fps MEASURED by parent ffprobe): 3 frames = 125 ms.
// Parent REJECTED: |117.10-125.0|=7.9 ms vs within-cluster ~10-15 ms — borderline but
// display-tick 7× is closer. Still expose for explicit kill tests.
constexpr double kContentFpsAssumed = 24.0; // MEASURED (parent fixture); labeled assumed here
inline double contentFramesMs(double n_frames) {
    if (!(kContentFpsAssumed > 0.0))
        return 0.0;
    return (n_frames * 1000.0) / kContentFpsAssumed;
}

// Format one parseable daemon line (no trailing newline). buf must be >= 384.
// Returns bytes written excluding NUL, or -1.
inline int formatBimodalLatchLine(char* buf, size_t buflen, const char* tag, int64_t wall_ms,
                                  int64_t dt_audio_ms, int64_t mra_rptr, int64_t mra_wptr,
                                  int64_t mra_len, int64_t mra_comp, int plxd_ok, int free_mask,
                                  int disp_bank, int swap_pending, int frames_done,
                                  int presents) {
    if (!buf || buflen < 64 || !tag)
        return -1;
    // Keep key=value stable for parent awk/grep.
    const int n = std::snprintf(
        buf, buflen,
        "BIMODAL_LATCH tag=%s wall_ms=%lld dt_audio_ms=%lld "
        "mra_rptr=%lld mra_wptr=%lld mra_len=%lld mra_comp=%lld "
        "plxd_ok=%d free_mask=%d disp_bank=%d swap_pending=%d frames_done=%d "
        "presents=%d T_disp_ms=%.6f",
        tag, static_cast<long long>(wall_ms), static_cast<long long>(dt_audio_ms),
        static_cast<long long>(mra_rptr), static_cast<long long>(mra_wptr),
        static_cast<long long>(mra_len), static_cast<long long>(mra_comp), plxd_ok, free_mask,
        disp_bank, swap_pending, frames_done, presents, kDisplayTickMs);
    if (n < 0 || static_cast<size_t>(n) >= buflen)
        return -1;
    return n;
}

// Offline classifier string for a measured HDMI offset delta between two runs
// (or a single-run offset difference vs a reference). Pure host tool.
inline int formatTickClassifyLine(char* buf, size_t buflen, double delta_ms) {
    if (!buf || buflen < 64)
        return -1;
    const TickMatch m = nearestDisplayTicks(delta_ms);
    const double f3 = contentFramesMs(3.0);
    const double absd = delta_ms < 0.0 ? -delta_ms : delta_ms;
    const double err3 = absd - f3;
    const double aerr3 = err3 < 0.0 ? -err3 : err3;
    const int n = std::snprintf(
        buf, buflen,
        "BIMODAL_TICK_CLASS delta_ms=%.3f abs_ms=%.3f nearest_n=%d nT_ms=%.6f "
        "err_nT_ms=%.6f content_3f_ms=%.6f err_3f_ms=%.6f "
        "H_VDISP7_pred_n=7 H_VDISP7_pred_ms=%.6f",
        delta_ms, absd, m.n, m.n_times_T_ms, m.err_ms, f3, err3 < 0 ? -aerr3 : aerr3,
        7.0 * kDisplayTickMs);
    if (n < 0 || static_cast<size_t>(n) >= buflen)
        return -1;
    return n;
}

} // namespace av_bimodal
} // namespace misterplex
