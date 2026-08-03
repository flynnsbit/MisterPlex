#pragma once
// Fabric-side DDR bandwidth budget (w-mem). Numbers from layout constants +
// product clocks — NOT device-measured fabric BW (parent measures post-fit).
//
// Clean parent ARM baseline (2026-08-03):
//   decode alone 35.94 ms/f  budget 41.667  margin +5.73
//   CPU bank store STRUCTURAL ~88 MiB/s (14.97 ms/f) — map flags inert
//   (bank outside kernel System RAM → uncached /dev/mem always)
//   decode+CPU move >=50.9 FAIL — closed. "Faster copy" family DEAD.
//   Fabric decode = endgame; PL330 = open (w-path); Route A into bank SUSPECT.
//
// f2sdram peak (theoretical): clk_ddr * 8 B/cycle if 100% util.
// Real efficiency unknown until parent measures — do not claim closes on glass.

#include "libmisterplex/ddr_frame_layout.hpp"

#include <cstdint>

namespace misterplex {

// Product clocks (rtl/pll/pll_0002.v is SoT; pll.v stale).
constexpr double kClkDdrHz = 90.0e6;
constexpr double kClkSysHz = 20.0e6;
constexpr int kDdrBeatsBytes = 8; // 64-bit f2sdram beat

// Theoretical peak if every clk_ddr cycle moves one beat (upper bound).
constexpr double kFabricDdrPeakMBps = (kClkDdrHz * static_cast<double>(kDdrBeatsBytes)) / 1.0e6;
// 720.0 MB/s

// I420 frame bytes (Option-C / 720p tier).
constexpr int kFabric720pFrameBytes = kPlex720pYuv420pBytes; // 1382400

// Writer sustained payload rate (no doorbell overhead): bytes * fps.
inline double fabricWriterMBps(double fps) {
    return (static_cast<double>(kFabric720pFrameBytes) * fps) / 1.0e6;
}

// Scan-out read of full planar I420 once per displayed frame (present path).
// Multi-pixel (N ppc) reduces *clk_sys* demand, not DDR bytes/frame.
inline double fabricScanoutReadMBps(double fps) {
    return fabricWriterMBps(fps); // same payload size if full-frame I420 read
}

inline double fabricCombinedRwMBps(double fps) {
    return fabricWriterMBps(fps) + fabricScanoutReadMBps(fps);
}

// Fraction of theoretical peak (NOT of measured efficient BW).
inline double fabricBusFracOfPeak(double mbps) {
    return mbps / kFabricDdrPeakMBps;
}

// Beats per frame at BURSTCNT=1 (one beat = 8 B).
constexpr int kFabric720pFrameBeats = kFabric720pFrameBytes / kDdrBeatsBytes; // 172800

// Minimum clk_ddr cycles to move one frame at 100% util, outstanding=1.
constexpr double kFabric720pFrameMinMsAtPeak =
    (static_cast<double>(kFabric720pFrameBeats) / kClkDdrHz) * 1000.0; // ~1.920 ms

// CEA 720p timing (for multi-pixel clk_sys arithmetic — w-clock owns wiring).
// 720p60: 1650 x 750 = 1_237_500 pixels/frame (incl blanking)
constexpr int kCea720pHTotal = 1650;
constexpr int kCea720pVTotal = 750;
constexpr int kCea720pActiveW = 1280;
constexpr int kCea720pActiveH = 720;

inline double cea720pPixelClockHz(double fps) {
    return static_cast<double>(kCea720pHTotal) * static_cast<double>(kCea720pVTotal) * fps;
}

// clk_sys required for N pixels/clock active path (active pixels only vs full timing).
// w-clock: 720p24 @ 2 ppc needs ~11.06 MHz using full CEA line rate / N.
inline double clkSysHzForPpc(double fps, int ppc) {
    if (ppc <= 0)
        return 0.0;
    return cea720pPixelClockHz(fps) / static_cast<double>(ppc);
}

// --- Budget tables (compile-time friendly constants) ---
constexpr double kFps24 = 24.0;
constexpr double kFps30 = 30.0;
constexpr double kFps60 = 60.0;

constexpr double kWriterMBps24 = (1382400.0 * 24.0) / 1.0e6; // 33.1776
constexpr double kWriterMBps30 = (1382400.0 * 30.0) / 1.0e6; // 41.472
constexpr double kWriterMBps60 = (1382400.0 * 60.0) / 1.0e6; // 82.944

constexpr double kScanMBps24 = kWriterMBps24;
constexpr double kScanMBps60 = kWriterMBps60;

constexpr double kCombinedMBps24 = kWriterMBps24 + kScanMBps24; // 66.3552
constexpr double kCombinedMBps60 = kWriterMBps60 + kScanMBps60; // 165.888

constexpr double kCombinedFracPeak24 = kCombinedMBps24 / 720.0; // ~0.0922
constexpr double kCombinedFracPeak60 = kCombinedMBps60 / 720.0; // ~0.2304

// ARM clean budget (parent).
constexpr double kParentCleanDecodeAloneMs = 35.94;
constexpr double kParentCleanCopyBank1Ms = 14.974; // --sync control
constexpr double kParentCleanBankStoreMibps = 88.045;
constexpr bool kParentBankCpuStoreStructuralCeiling = true;
constexpr double kParentCleanDecodePlusMemPeerMs = 46.57;
constexpr double kFrameBudget24Ms = 41.667;
constexpr double kParentCleanDecodeMarginMs = kFrameBudget24Ms - kParentCleanDecodeAloneMs; // ~5.727

// If fabric RW steals the same DDR controller as decode, residual shrinks.
// Unknown mapping of fabric MB/s → decode ms inflation — parent must measure.
// Floor claim only: serial ARM copy already exceeds margin; fabric must own pixels.

inline bool fabricCombinedFitsTheoreticalPeak(double fps, double util_cap = 0.85) {
    // util_cap: leave headroom for refresh/efficiency; NOT a measured number.
    return fabricBusFracOfPeak(fabricCombinedRwMBps(fps)) <= util_cap;
}

// Sticky-m2 lockout duration if whole frame held (historical defect class).
inline double stickyM2FullFrameLockoutMs() { return kFabric720pFrameMinMsAtPeak; }

// With per-beat release, m0 can interleave every other cycle in steady WE stream
// → writer gets ~50% when both always-want (lower bound model).
inline double writerShareWhenM0AlwaysWants() { return 0.5; }

inline bool writerClosesAtFpsWithHalfShare(double fps) {
    // Need writer_mbps <= 0.5 * peak_efficient. Use theoretical peak * half.
    const double avail = 0.5 * kFabricDdrPeakMBps;
    return fabricWriterMBps(fps) <= avail;
}

} // namespace misterplex
