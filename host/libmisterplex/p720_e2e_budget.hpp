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
// rd-duck BLOCKING corrections (2026-08-03, accepted by w-path):
//   A) Sweep116 "49% idle" was sampled BEFORE decode, not during it
//      (Memory/scratch/busyfix.sh:70 idle_pct then :71 decode). Do NOT budget a
//      free core concurrent with decode. Simultaneous CPU availability is
//      UNKNOWN until same-window /proc/stat + wait4. kIdlePctSweep116 is an
//      idle-at-rest pin only.
//   B) "Fabric DMA ⇒ ARM never touches the frame" is TOO STRONG. Software
//      decode/rawvideo pipe still writes pixels somewhere. DMA can retire the
//      uncached *publication* memcpy only after pinned contiguous/SG +
//      cache-coherency contract. Prefer dynamic-base direct fabric reader over
//      a source→bank mover (mover adds read+write traffic).
//   C) Fit release: BOTH w-nostub reclaim AND w-osd full 720p 20:90 stalled
//      real-reader proof are blockers unless parent explicitly resolves.
//
// PARENT 2026-08-04 — effective ARM capacity is ONE core, not two:
//   clean 10 s /proc/stat per-core: cpu0 idle=97.6% busy=2.4%;
//   cpu1 idle=0.0% busy=100%; MiSTer pid 19729 = 1004 ticks/10s = 100.4% of
//   one core; mpx-main (daemon comm, NOT misterplexd) pid 9525 = 0.8%.
//   USER_HZ=100 → 10 s = 1000 ticks/core. Framework permanently burns one
//   entire core at idle doing non-work. Any budget that assumed two free
//   cores for decode||copy pipeline is wrong by ~2× on capacity.
//   Sweep 127: renice MiSTer → 13.0% decode speedup (order-balanced); further
//   proof the burned core is contended non-work, not spare capacity.
//
// Overlap model (corrected): with only one usable core, two CPU-bound stages
// (decode + publication memcpy) CANNOT achieve wall = max(decode, copy).
// That floor required a free second core. On one core the right model for two
// CPU-bound stages is serial sum (or worse under framework contention).
// Offload (KernelDma/WC publication, or fabric reader) is the only way to
// drop a stage off the single ARM core. Do NOT claim "720p works" from
// decode-only 1.3x.
//
// What IS established:
//   1) CPU full-frame copy to the bank is ~15 ms/f structural (uncached mapping).
//   2) Decode-only headroom after Sweep 116 is 41.667-32.705 = 8.962 ms/f.
//   3) 8.962 < 14.978 → copy cannot hide inside decode headroom on one core.
//   4) Making memcpy faster via O_SYNC/flags is DEAD (Sweep 11).
//   5) Publication must leave the single ARM core (DMA/WC or fabric reader).
//   6) Effective product ARM cores = 1 (MiSTer owns the other at 100% idle).
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

// Sweep 118 parent correction: serial deficit after GDM fix.
// headroom 8.962 − needed 14.978 = SHORT by 6.016 ms/frame at 24 fps.
inline constexpr double kSerialDeficitSweep118Ms =
    kCpuCopyMsPerFrame - (kDeadline24Ms - kDecodeOnlyMsPerFrameSweep116); // 6.016

// Payload RATE (not interchangeable with T_copy_arm CPU time).
inline constexpr double kPayloadRate720p24MBps =
    static_cast<double>(kFrameBytes720pI420) * 24.0 / 1e6; // 33.1776

// Sweep 116 "49% idle" is IDLE-AT-REST and is NOT "half of two cores free".
// Parent 2026-08-04 control: one core is 100% MiSTer, the other ~98% idle at
// rest — the 49% aggregate was one free core + one burned core, not spare
// concurrent capacity during decode.
inline constexpr double kIdlePctSweep116AtRest = 49.0;
inline constexpr bool kIdlePctSweep116IsConcurrentWithDecode = false;
inline constexpr bool kIdlePctSweep116MeansHalfSystemCapacity = false; // forbidden

// Parent 2026-08-04 /proc/stat 10 s window (USER_HZ=100 → 1000 ticks/core).
// Control quoted by parent: cpu0 idle 97.6%, cpu1 idle 0.0%;
// MiSTer 1004 ticks, mpx-main 8 ticks. Look up daemon as comm=mpx-main.
inline constexpr int kArmCoreCountPhysical = 2;
inline constexpr int kEffectiveProductArmCores = 1; // MiSTer owns the other
inline constexpr double kMisterFrameworkBusyPctOfOneCoreAtIdle = 100.4;
inline constexpr double kMpxMainBusyPctOfOneCoreAtIdle = 0.8;
inline constexpr double kCpu0IdlePctAtRestParent = 97.6;
inline constexpr double kCpu1IdlePctAtRestParent = 0.0;
// Sweep 127 parent: renice MiSTer → 13.0% decode wall speedup (order-balanced).
inline constexpr double kSweep127DecodeSpeedupFracFromMisterRenice = 0.130;
inline constexpr bool kMayAssumeTwoCoreDecodeCopyPipeline = false;
// With one usable core, max(decode,copy) is NOT an achievable wall for two
// CPU-bound stages. Serial sum is the correct single-core model.
inline constexpr bool kMaxOfStagesIsAchievableWallOnOneCore = false;

// What DMA can retire (narrow claim): uncached publication memcpy only.
// Decode/rawvideo pipe still produces pixels in some buffer first.
inline constexpr bool kDmaRetiresPublicationMemcpyOnly = true;
inline constexpr bool kDmaMeansArmNeverTouchesPixels = false; // TOO STRONG — forbidden claim

// Prefer fabric reader of decode output (dynamic base) over HPS source→bank mover.
enum class PreferredPublishPath : unsigned char {
    CpuSerialDevMem = 0,       // product today — T_copy_arm structural
    KernelDmaOrWriteCombine = 1, // retires publication memcpy if coherency OK
    FabricDirectReader = 2,    // preferred strategic: fabric reads decode buffer
    SourceToBankMover = 3,     // DISPREFERRED — adds read+write traffic
};
inline constexpr PreferredPublishPath kStrategicPublishPreference =
    PreferredPublishPath::FabricDirectReader;
inline constexpr bool kSourceToBankMoverPreferred = false;

// Fit-release blockers (rd-duck). PRODUCT_NO_STUB landed on origin/main as
// PR #2 e937d37d (QSF VERILOG_MACRO PRODUCT_NO_STUB=1) — nostub reclaim is no
// longer a source-side blocker. Remaining: w-osd full 720p 20:90 stalled
// real-reader proof. Post-fit M10K after strip is UNVERIFIED here (parent
// predicts 197 = 465-268; control is next fit.rpt entity table).
inline constexpr bool kFitBlockerNostubReclaim = false; // landed e937d37d
inline constexpr bool kFitBlockerOsd720pRealReader2090Stalled = true;
inline constexpr int kFitReleaseBlockerCount = 1; // w-osd only

// Overlap of decode||copy on a second core is NOT available (one-core capacity).
inline constexpr bool kDecodeCopyOverlapProven = false;
inline constexpr bool kMayBudgetFreeCoreDuringDecode = false;
// Feasibility under contended single-core CPU path (no offload):
// serial Sweep116+copy already misses 24; one-core closes the "pipeline out"
// escape. Conclusion moves: parallel-CPU rescue INFEASIBLE; offload required.
inline constexpr bool kTwoCorePipelineRescueFeasible = false;
inline constexpr bool kSingleCoreSerialCpuPathFeasible24 = kSerialSweep116Meets24; // false
inline constexpr bool kOffloadRequiredFor720p24CpuPath =
    !kSingleCoreSerialCpuPathFeasible24 && !kTwoCorePipelineRescueFeasible;

// ---------------------------------------------------------------------------
// Fabric DPB one-byte fetch tax (rd-duck UPDATED; source-quoted, not entropy-only)
// h264_dpb_one_ref issues fixed windows regardless of part_w/h:
//   luma issue_idx 0..440 → 441 B; chroma U/V 0..80 → 81 B each → 603 B/partition
//   (h264_dpb.sv: issue_idx==9'd440 / 9'd80; lat_part_w/h only "observed")
// 720p MB grid 80×45 = 3600 MB; one P16x16-ref per MB:
//   603 * 3600 = 2_170_800 one-byte read cycles
// @ clk_sys 20 MHz → 108.54 ms  (>> 41.667 ms @24 fps) — structural without burst/wide DPB
// Full I420 write 1_382_400 B @ 1 B/clk → 69.12 ms @20 MHz
// decode_stub dpb_mem[17:0] aliases 256 KiB @ FRAME 640×480 — does NOT prove 720p DPB.
// PRODUCT_NO_STUB removes the stub/back-end branch entirely.
// Remaining work is NOT "entropy frontend only".
// ---------------------------------------------------------------------------
inline constexpr int kDpbLumaFetchBytesPerPart = 441;   // 21×21 qpel window
inline constexpr int kDpbChromaFetchBytesPerPart = 81;  // 9×9 epel window (each plane)
inline constexpr int kDpbFetchBytesPerPartition =
    kDpbLumaFetchBytesPerPart + 2 * kDpbChromaFetchBytesPerPart; // 603
inline constexpr bool kDpbPartWhNarrowsFetch = false; // lat_part_* observed only

inline constexpr int kMbCount720p = (1280 / 16) * (720 / 16); // 80*45 = 3600
inline constexpr long long kDpbP16x16RefFetchCycles720p =
    static_cast<long long>(kDpbFetchBytesPerPartition) * kMbCount720p; // 2170800

inline constexpr double kClkSysHzProduct = 20.0e6;
inline constexpr double kDpbP16x16RefFetchMs720pAt20MHz =
    1000.0 * static_cast<double>(kDpbP16x16RefFetchCycles720p) / kClkSysHzProduct; // 108.54

inline constexpr long long kI420WriteByteCycles720p = 1382400LL;
inline constexpr double kI420WriteMs720pAt20MHz =
    1000.0 * static_cast<double>(kI420WriteByteCycles720p) / kClkSysHzProduct; // 69.12

inline constexpr bool kDpbOneByteFetchMeets24At20MHz =
    kDpbP16x16RefFetchMs720pAt20MHz <= kDeadline24Ms; // false
inline constexpr bool kRemainingWorkIsEntropyFrontendOnly = false;
inline constexpr bool kStubDpbMemProves720p = false; // 640×480 + [17:0] alias

} // namespace p720_budget
} // namespace misterplex
