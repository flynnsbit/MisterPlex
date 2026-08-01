#pragma once
// Exact A/V phase quanta derived from in-tree RTL literals ONLY.
//
// Purpose: lock source arithmetic for audio sample period, display frame
// period T_disp, a_en2 mute, F2 FIFO depth, and PLXD4 pack — so agents cannot
// re-derive wrong periods from memory.
//
// Every constant is a LITERAL from the cited RTL file — not a lab measurement
// and not a DEFAULT_ASSUMED instrument default. Label when printing:
//   tag=rtl-literal  or  tag=derived-from-rtl-literal
//
// RETRACTION (2026-08-01): Parent HDMI "cluster sep 117.10 ms" was an OLD-argv
// instrument artifact, not a device two-state. This header MUST NOT encode that
// number, pin 7×T_disp to it, or reject other hyps solely by distance to it.
// 7×T_disp remains available as pure RTL arithmetic (≈117.01 ms) without any
// claim that it is a product defect quantum.
//
// Citations (product tree fpga/Plex_MiSTer/):
//   sys/alsa.sv:24 CLK_RATE=24576000; :149-153 ce_sample NCO +48000
//   sys/audio_out.sv:24,66 AUDIO_RATE=48000; :176-196 a_en2 dly2[13]
//   sys/pll_audio.v gui_output_clock_frequency0=24.576
//   rtl/pll.v gui_output_clock_frequency0=20.0; Plex.sv:849 CLK_VIDEO=clk_sys
//   rtl/colorbars.sv:39 H_LAST=637; :65-78 NTSC scandouble vc wrap 523
//   rtl/ddr_frame_store.sv:271-284 swap on vsync; :1041-1049 PLXD pack
//   Plex.sv:748 audio_en=0 (F2 not product heard path)
//   rtl/audio_fifo.sv:11-12 DEPTH=2048 (F2 only)

#include <cstdint>

namespace misterplex {
namespace av_phase_rtl {

// --- Audio clock domain (MrAudio consumer = sys/alsa.sv) --------------------
inline constexpr int64_t kAlsaClkRateHz = 24576000; // alsa.sv CLK_RATE
inline constexpr int64_t kAudioSampleRateHz = 48000; // audio_out.sv AUDIO_RATE

// ce_sample period: CLK_RATE/48000 cycles at hurryup=0.
inline constexpr int64_t kAlsaSamplePeriodCycles = kAlsaClkRateHz / kAudioSampleRateHz; // 512

// Sample quantum in nanoseconds (exact: 1e9/48000 = 20833 + 1/3; use floor ns).
inline constexpr int64_t kAudioSamplePeriodNs = 1000000000LL / kAudioSampleRateHz; // 20833

// audio_out a_en2: sample_ce ticks until dly2[13] at sample_rate=0 → 8192 samples.
inline constexpr int64_t kAudioOutAen2MuteSamples = 8192; // 1<<13

// F2 FIFO (NOT product heard path under MrAudio).
inline constexpr int64_t kF2AudioFifoDepthSamples = 2048;

// --- Video display domain (colorbars + clk_sys) -----------------------------
inline constexpr int64_t kClkSysHz = 20000000; // pll.v outclk_0 = 20.0 MHz
inline constexpr int64_t kColorbarsHLast = 637; // colorbars.sv H_LAST
inline constexpr int64_t kColorbarsHPeriod = kColorbarsHLast + 1; // 638 clocks/line
// NTSC scandouble: vc wraps when vc==523 → 524 lines (colorbars.sv).
inline constexpr int64_t kNtscScandoubleLines = 524;

// T_disp seconds = H_PERIOD * LINES / CLK_SYS
// T_disp_ns = 638 * 524 * 1e9 / 20e6 = 638 * 524 * 50
inline constexpr int64_t kNtscDispFrameNs =
    kColorbarsHPeriod * kNtscScandoubleLines * (1000000000LL / kClkSysHz);
// 638 * 524 * 50 = 16_715_600 ns = 16.715600 ms

// Content frame @ exact 24.000 fps (fixtures; ERROR 17 retracted 23.976 default).
inline constexpr int64_t kContentFps24 = 24;
// 3 content frames @ 24 fps = 125.00 ms exact (ms*100).
inline constexpr int64_t kHyp3Content24MsX100 = 12500;

// --- Helpers (pure RTL / content arithmetic; no parent HDMI sep) ------------

inline constexpr int64_t iabs(int64_t x) { return x < 0 ? -x : x; }

// n * T_disp in ms*100 (rounded nearest from ns).
inline constexpr int64_t nDisplayFramesMsX100(int n) {
    const int64_t ns = static_cast<int64_t>(n) * kNtscDispFrameNs;
    return (ns + 5000) / 10000; // round to 0.01 ms
}

// 7 * T_disp — pure RTL product. ≈117.01 ms. NOT a device cluster constant.
inline constexpr int64_t kSevenDispMsX100 = nDisplayFramesMsX100(7); // 11701

// One audio sample ≪ 1 ms; reject "sample phase explains ≥1 ms sep".
inline constexpr bool audioSampleQuantumCanExplainMsX100(int64_t sep_ms_x100) {
    return sep_ms_x100 < 100;
}

inline constexpr int64_t aen2MuteMsX100() {
    // 8192/48000 s → ms*100 = 8192*100000/48000
    return (kAudioOutAen2MuteSamples * 100000LL + 24000) / 48000; // round nearest
}

// Compare a_en2 mute to an arbitrary sep (tests use 125 ms content hyp, etc.).
inline constexpr bool aen2MuteEqualsSepMsX100(int64_t sep_ms_x100) {
    return iabs(aen2MuteMsX100() - sep_ms_x100) <= 5; // 0.05 ms tol
}

// PLXD high word (devmem +4 / "PLXD4"): bits match ddr_frame_store pack.
// hi = (frames_done<<16) | (swap<<3) | (disp<<2) | free_mask
inline constexpr uint16_t plxd4FramesDone(uint32_t hi) {
    return static_cast<uint16_t>(hi >> 16);
}
inline constexpr uint8_t plxd4FreeMask(uint32_t hi) {
    return static_cast<uint8_t>(hi & 0x3u);
}
inline constexpr uint8_t plxd4DispBank(uint32_t hi) {
    return static_cast<uint8_t>((hi >> 2) & 1u);
}
inline constexpr bool plxd4SwapPending(uint32_t hi) {
    return ((hi >> 3) & 1u) != 0;
}

// Phys addresses for PLXD live at doorbell+0x128 — do NOT hardcode product doorbell phys
// here (test_rtl_invariants quarantines those literals to ddr_frame_layout.hpp /
// mailbox_abi_spec.hpp). Consumers: mailbox_abi::frameStoreMailboxPhys(
//   ddr_frame_layout::kPlex480pYuv420pDoorbellPhys, mailbox_abi::kPlxdOffset).

} // namespace av_phase_rtl
} // namespace misterplex
