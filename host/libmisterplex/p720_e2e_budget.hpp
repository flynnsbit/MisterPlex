// p720_e2e_budget — measured pins for 720p24 end-to-end feasibility (host path).
//
// Source of truth (parent hardware, archived):
//   Memory/lab/session-archive/2026-08-03-session-state/misterplex-parent-720p-decode-verdict.txt
//   Sweep 9  :303-319  1,382,400-B /dev/mem bank copy 14.978 ms/f (cpu 14.763)
//   Sweep 11 :354-385  sync/no-sync 14.974/15.389 — O_SYNC inert; bank outside System RAM
//   Sweep 116: decode-only with GDM fix 32.705 ms/f (1.3x, 6541 ms / 200 frames)
//
// Product path (current tree): playback calls MediaPlayer::publishDdrFrame →
// FpgaSpi::publishDdrFrame → sendDdrFrame which std::memcpy's the full I420
// bank (fpga_spi.cpp sendDdrFrame copy). That is a CPU store into the uncached
// frame bank — same class as the ddr_write_bench measurement.
//
// Caveat (rd-duck): child FFmpeg may overlap decode with the parent present
// thread through the pipe, so product throughput is NOT proven equal to the
// serial sum. Serial sum is a HARD UPPER bound on "no overlap"; with partial
// overlap the floor is max(decode, copy) and the realistic band is in between.
// Do NOT claim "720p works" from decode-only 1.3x. Do NOT claim strict product
// FAIL from serial arithmetic alone without a pipeline A/B.
//
// What IS established:
//   1) CPU full-frame copy to the bank is ~15 ms/f structural (uncached mapping).
//   2) Decode-only headroom after Sweep 116 is 41.667-32.705 = 8.962 ms/f.
//   3) 8.962 < 14.978 → copy cannot hide entirely inside decode headroom.
//   4) Making memcpy faster via O_SYNC/flags is DEAD (Sweep 11).
//   5) Fabric decode or non-CPU (DMA/PL330) move is required for a true fit.

#pragma once

#include <cstddef>

namespace misterplex {
namespace p720_budget {

// 1280x720 I420 bytes — matches ddr_write_bench --len and product bank size.
inline constexpr std::size_t kFrameBytes720pI420 = 1280u * 720u * 3u / 2u; // 1,382,400

inline constexpr double kDeadline24Ms = 1000.0 / 24.0; // 41.666...

// Parent Sweep 9 clean bank copy (no-sync, 60 loops, bank 1).
inline constexpr double kCpuCopyMsPerFrame = 14.978;
inline constexpr double kCpuCopyCpuMsPerFrame = 14.763;
inline constexpr double kCpuCopyMibps = 88.022;

// Parent Sweep 116 decode-only (daemon running, GDM fix, 200 frames @1.3x).
// wall_ms_total/frames = 6541/200.
inline constexpr double kDecodeOnlyMsPerFrameSweep116 = 32.705;

// Older product-tier decode pin from same archive (pre-GDM-fix context): 35.94.
inline constexpr double kDecodeOnlyMsPerFrameLegacy = 35.94;

// Serial upper bound (no overlap).
inline constexpr double serialDecodePlusCopyMs(double decode_ms, double copy_ms) {
    return decode_ms + copy_ms;
}

// Headroom left for present/copy after decode-only, at 24 fps.
inline constexpr double headroomAfterDecodeMs(double decode_ms) {
    return kDeadline24Ms - decode_ms;
}

// True iff serial decode+copy meets the 24 fps deadline (no overlap assumed).
inline constexpr bool serialCpuPathMeets24(double decode_ms, double copy_ms) {
    return serialDecodePlusCopyMs(decode_ms, copy_ms) <= kDeadline24Ms;
}

// True iff the measured copy cost alone exceeds remaining headroom after decode.
// When true, copy cannot be "free" inside decode slack even with perfect
// non-overlap scheduling of other work — something must give (drop fps, DMA,
// or fabric decode).
inline constexpr bool copyExceedsDecodeHeadroom(double decode_ms, double copy_ms) {
    return copy_ms > headroomAfterDecodeMs(decode_ms);
}

// Established pins: serial path with Sweep 116 decode does NOT meet 24.
inline constexpr bool kSerialSweep116Meets24 =
    serialCpuPathMeets24(kDecodeOnlyMsPerFrameSweep116, kCpuCopyMsPerFrame);

inline constexpr bool kCopyExceedsSweep116Headroom =
    copyExceedsDecodeHeadroom(kDecodeOnlyMsPerFrameSweep116, kCpuCopyMsPerFrame);

} // namespace p720_budget
} // namespace misterplex
