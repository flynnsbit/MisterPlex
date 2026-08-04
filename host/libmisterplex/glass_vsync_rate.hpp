#pragma once
// Glass / vsync free-run rate from product PLXD glass field.
//
// Source of truth (mailbox_abi_spec + tip ddr_frame_store pack):
//   PLXD @ doorbell + 0x128
//   product 720p doorbell 0x302FF000 → PLXD 0x302FF128
//   [47:36] glass_vsync[11:0] = bank_vsync_count LSBs (vsync free-run)
//   [63:48] frames_done[15:0] = bank swaps (NOT glass)
//
// Why modular Δ-rate:
//   MS2109 /dev/video0 reclocks → grabber PTS cannot RATE_PASS glass Hz.
//   Measure Δ glass_vsync (mod 2^12) over wall time ≥2 s instead.
//
// Live RBF 75065b0c (pre bank_vsync pack + pre cutb-sched-reg): glass field
// is zero/stale → STALE_OR_ZERO, never a PASS. After cutb-sched-reg RBF with
// bank_vsync pack: expect ~24.242 Hz at clk_pix=30.000 MHz, H=1650, V=750
// (30e6/(1650*750)), NOT 31.25 grabber.
//
// Soft-skip / UNSCORED ≠ PASS. No device required for pure modular math.

#include "mailbox_abi_spec.hpp"

#include <cmath>
#include <cstdint>

namespace misterplex {

constexpr unsigned kGlassVsyncModBits = mailbox_abi::kPlxdGlassVsyncWidth; // 12
constexpr uint32_t kGlassVsyncModulus = 1u << kGlassVsyncModBits;          // 4096
constexpr uint16_t kGlassVsyncMask =
    static_cast<uint16_t>(kGlassVsyncModulus - 1u); // 0x0FFF

// Ideal glass Hz @ product PRESENT_CLK_PIX_PLL 30.000 MHz pack totals.
// Derivation: f = clk_pix / (H_total * V_total) = 30e6 / (1650*750).
constexpr int kIdealGlassHTotal = 1650;
constexpr int kIdealGlassVTotal = 750;
constexpr int kIdealGlassClkPixHz = 30000000;
constexpr double kIdealGlassHzClkPix30 =
    static_cast<double>(kIdealGlassClkPixHz) /
    (static_cast<double>(kIdealGlassHTotal) * static_cast<double>(kIdealGlassVTotal));
// 24.2424... Hz — document only; measurement path never hard-passes against it.

// Forward modular distance on a free-running 12-bit counter: (c1 - c0) mod 4096.
inline constexpr uint16_t modular12Delta(uint16_t c0, uint16_t c1) {
    return static_cast<uint16_t>(
        (static_cast<uint32_t>(c1) - static_cast<uint32_t>(c0)) & kGlassVsyncMask);
}

// Extract glass_vsync[11:0] from PLXD upper 32 bits (same as plxd4GlassVsync).
inline constexpr uint16_t glassVsyncFromPlxdHi(uint32_t hi) {
    return static_cast<uint16_t>(
        (hi >> mailbox_abi::kPlxdGlassVsyncBit) &
        ((1u << mailbox_abi::kPlxdGlassVsyncWidth) - 1u));
}

struct GlassRateResult {
    bool ok = false;
    // MEASURED | STALE_OR_ZERO | UNSCORED | BAD_DT
    const char* verdict = "UNSCORED";
    uint16_t c0 = 0;
    uint16_t c1 = 0;
    uint16_t delta = 0;
    double dt_s = 0.0;
    double rate_hz = 0.0;
    const char* note = "";
};

// Compute modular12 Δ-rate over a wall interval.
// min_dt_s defaults to 2.0 s (acceptance: ≥2 s wall time).
// delta==0 after a long enough window → STALE_OR_ZERO (not PASS).
inline GlassRateResult glassRateFromPair(uint16_t c0, uint16_t c1, double dt_s,
                                         double min_dt_s = 2.0) {
    GlassRateResult r;
    r.c0 = static_cast<uint16_t>(c0 & kGlassVsyncMask);
    r.c1 = static_cast<uint16_t>(c1 & kGlassVsyncMask);
    r.dt_s = dt_s;
    r.delta = modular12Delta(r.c0, r.c1);

    if (!(dt_s > 0.0) || !std::isfinite(dt_s)) {
        r.verdict = "BAD_DT";
        r.note = "dt_s must be finite and > 0";
        r.rate_hz = 0.0;
        return r;
    }
    if (!(min_dt_s > 0.0) || !std::isfinite(min_dt_s)) {
        r.verdict = "BAD_DT";
        r.note = "min_dt_s must be finite and > 0";
        r.rate_hz = 0.0;
        return r;
    }
    if (dt_s + 1e-15 < min_dt_s) {
        r.verdict = "UNSCORED";
        r.note = "wall window shorter than min_dt_s (need >=2s for product gate)";
        r.rate_hz = static_cast<double>(r.delta) / dt_s;
        return r;
    }

    r.rate_hz = static_cast<double>(r.delta) / dt_s;
    if (r.delta == 0) {
        // Live 75065b0c (no glass pack) lands here — evidence of stale/zero field.
        r.verdict = "STALE_OR_ZERO";
        r.note = "glass_vsync did not advance; not a rate PASS "
                 "(pre-pack RBF or frozen vsync path)";
        r.ok = false;
        return r;
    }

    r.verdict = "MEASURED";
    r.ok = true;
    r.note = "rate_hz = modular12_delta(c0,c1) / wall_s; not MS2109 grabber PTS";
    return r;
}

} // namespace misterplex
