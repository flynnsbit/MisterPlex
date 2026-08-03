#pragma once
// DDR bank map policy (w-mem).
//
// Parent 2026-08-03 /dev/mem ceiling (clean device, prereg 0/5 HIT):
//   --sync ............ 88.045 MiB/s  14.974 ms/f
//   --no-sync ......... 85.670 MiB/s  15.389 ms/f  (SLOWER; flag inert)
//   --no-sync --flush . 66.595 MiB/s  19.797 ms/f
// Mechanism (quoted parent + rd-duck kernel-source correction):
//   /proc/cmdline mem=511M memmap=513M$511M
//   /proc/iomem   "00000000-1fefffff : System RAM"  only
//   Bank @0x30000000 / Option-C @0x30180000 sit OUTSIDE kernel System RAM →
//   pfn_valid() false → /dev/mem uses pgprot_noncached regardless of O_SYNC
//   (both benchmark arms got the same strongly-ordered map — flag inert).
//
// NARROWED CLAIM (parent 2026-08-03, after rd-duck audit — do not overstate):
//   **88 MiB/s is structural for /dev/mem mappings of the reserved region.**
//   It is NOT proven for a dedicated driver mapping pgprot_writecombine.
//   Serial true-720p feasibility needs ~230.2 MiB/s (2.615×) — open, falsifiable
//   via kernel WC map (w-path). Userspace unbind of dma-pl330 WEDGED the SoC;
//   product DMA owner must be kernel-side (dmaengine client), not raw DMAGO.
//
// RETRACTED: "88 MiB/s is structural and not tunable" (overbroad).
// RETRACTED: "make the copy faster" via /dev/mem flag/memcpy/align tricks.
// STILL DEAD via /dev/mem: decode+full-frame CPU move at true 720p (>=50.9).
// Product path: 960x540 native push @~8.42 ms + fabric upscale (margin +7.16).
//
// Ordering hazard (kept): if anyone ever maps write-combine/cacheable, payload
// MUST be visible before doorbell — real DMB/DSB, not atomic_signal_fence
// (rd-duck: compiler fence alone is insufficient). See bank_producer_order.
//
#include <cstddef>
#include <cstdint>
#include <fcntl.h>

namespace misterplex {

enum class DdrMemMapPolicy : uint8_t {
    // Product default: open(/dev/mem, O_RDWR|O_CLOEXEC|O_SYNC).
    // Reserved-region PFN invalid → kernel forces noncached (rd-duck).
    StronglyOrderedSync = 0,
    // Lab only: open without O_SYNC. On reserved banks still noncached via
    // pfn_valid path — flag inert (parent 0/5). Kept for ordinary-RAM experiments.
    CachedExplicitFlush = 1,
    // OPEN route (w-path): dedicated kernel driver maps bank pgprot_writecombine.
    // Not reachable via /dev/mem. Requires real outer-shareable store barrier
    // before doorbell. Default OFF until measured >= 230.2 MiB/s serial target.
    WriteCombineDriver = 2,
};

struct DdrMemMapOpenSpec {
    int open_flags = 0;
    bool requires_dcache_flush_before_doorbell = false;
    DdrMemMapPolicy policy = DdrMemMapPolicy::StronglyOrderedSync;
};

inline DdrMemMapOpenSpec ddrMemMapOpenSpec(DdrMemMapPolicy policy) {
    DdrMemMapOpenSpec s{};
    s.policy = policy;
    s.open_flags = O_RDWR | O_CLOEXEC;
    if (policy == DdrMemMapPolicy::StronglyOrderedSync) {
        s.open_flags |= O_SYNC;
        // Device/strongly-ordered stores drain in order; still need producer
        // credit→fill→visible→doorbell (not a substitute for DMB on WC maps).
        s.requires_dcache_flush_before_doorbell = false;
    } else if (policy == DdrMemMapPolicy::WriteCombineDriver) {
        // No /dev/mem open — driver mmap. Always barrier before doorbell.
        s.open_flags = 0;
        s.requires_dcache_flush_before_doorbell = true;
    } else {
        s.requires_dcache_flush_before_doorbell = true;
    }
    return s;
}

// True only for the /dev/mem reserved-bank path parent measured.
inline bool ddrMemMapIsDevMemReservedBankCeiling(DdrMemMapPolicy policy) {
    return policy == DdrMemMapPolicy::StronglyOrderedSync ||
           policy == DdrMemMapPolicy::CachedExplicitFlush;
}


inline DdrMemMapPolicy ddrMemMapPolicyFromConf(bool ddrMemSync, bool /*ddrMemFlush*/) {
    return ddrMemSync ? DdrMemMapPolicy::StronglyOrderedSync
                      : DdrMemMapPolicy::CachedExplicitFlush;
}

inline bool ddrMemMapConfPublishSafe(bool ddrMemSync, bool ddrMemFlush) {
    if (ddrMemSync)
        return true;
    return ddrMemFlush;
}

inline bool ddrMemMayRingDoorbell(DdrMemMapPolicy policy, bool flushCompleted) {
    if (policy == DdrMemMapPolicy::StronglyOrderedSync)
        return true;
    return flushCompleted;
}

// Sweep-3 bank rates (MiB/s, 1024^2). Primary budget rate = best bank path.
constexpr double kParentDdrMappedBank720pMibpsArchiveSweep3 = 86.262; // Sweep-3 --no-sync
constexpr double kParentDdrMappedBank720pMibps = 88.045; // parent --sync control 2026-08-03
// Serial true-720p source needs this rate if ARM still CPU-stores full I420.
// 1382400 B / (41.667 - 35.94) ms residual ≈ 230.2 MB/s (parent arithmetic).
constexpr double kSerialTrue720pSourceRequiredMibps = 230.2;
constexpr double kDevMemReservedBankCeilingMibps = kParentDdrMappedBank720pMibps;
constexpr double kWriteCombineSpeedupNeededVsDevMem =
    kSerialTrue720pSourceRequiredMibps / kDevMemReservedBankCeilingMibps; // ~2.615
constexpr double kParentDdrMappedBank720pSyncMibps = 83.639;
constexpr double kParentDdrMappedBank720pCoherentFlushMibps = 66.380;
constexpr double kParentDdrMappedBank480pMibps = 89.363; // prior sweep; bandwidth-limited
// Ordinary RAM only — NEVER use as bank budget (unreachable for FPGA-visible).
constexpr double kParentDdrHostCopyOrdinaryRamMibps = 439.788;

constexpr double kParentDdrBestBank720pFrameMsArchiveSweep3 = 15.283;
constexpr double kParentDdrBestBank720pFrameMs = 14.974; // parent --sync clean
constexpr double kParentDdrSyncBank720pFrameMs = 15.762;
constexpr double kParentDdrCoherentFlush720pFrameMs = 19.861;
constexpr double kParentDdrHostCopyOrdinaryRam720pFrameMs = 2.998;

// Aliases kept so older call sites compile; mapped == best bank.
constexpr double kParentDdrMapped720pFrameMs = kParentDdrBestBank720pFrameMs;
// Deprecated alias: was "host-copy ceiling"; value retained for tests that
// assert unreachability, not ship acceptance.
constexpr double kParentDdrHostCopy720pFrameMs = kParentDdrHostCopyOrdinaryRam720pFrameMs;
constexpr double kParentDdrHostCopyCeilingMibps = kParentDdrHostCopyOrdinaryRamMibps;

constexpr double kFrameBudget24fpsMsLocal = 41.667;

inline bool ddr720p24DecodePlusCopyFitsBudget(double decodeMs, double copyMs,
                                              double budgetMs = kFrameBudget24fpsMsLocal) {
    return (decodeMs + copyMs) <= budgetMs;
}

// Serial ARM decode then bank copy — fails every measured real-720p tier.
inline bool ddr720p24SerialArmDecodePlusBankCopyFits(double decodeMs,
                                                     double copyMs = kParentDdrBestBank720pFrameMs,
                                                     double budgetMs = kFrameBudget24fpsMsLocal) {
    return ddr720p24DecodePlusCopyFitsBudget(decodeMs, copyMs, budgetMs);
}

// 1500k is NOT a delivery tier for coded 1280x720 (PMS serves 720x404 <=3000k).
// Kept for decode residual arithmetic only.
inline bool ddr720p24MappedPathFitsAt1500k(
    double decodeMs = 32.427, double mappedCopyMs = kParentDdrBestBank720pFrameMs) {
    return ddr720p24SerialArmDecodePlusBankCopyFits(decodeMs, mappedCopyMs);
}

// Product tier (maxBR 3100 / content ~2600k): decode 36.27 + copy 15.283 = 51.55 FAIL.
inline bool ddr720p24SerialPathFitsAt2600k(
    double decodeMs = 36.27, double copyMs = kParentDdrBestBank720pFrameMs) {
    return ddr720p24SerialArmDecodePlusBankCopyFits(decodeMs, copyMs);
}

// Archive PMS floor name (>=3500); serial still fails. Prefer At2600k for product.
inline bool ddr720p24SerialPathFitsAt3500k(
    double decodeMs = 38.751, double copyMs = kParentDdrBestBank720pFrameMs) {
    return ddr720p24SerialArmDecodePlusBankCopyFits(decodeMs, copyMs);
}

inline bool ddr720p24SerialPathFitsAt4000k(
    double decodeMs = 41.073, double copyMs = kParentDdrBestBank720pFrameMs) {
    return ddr720p24SerialArmDecodePlusBankCopyFits(decodeMs, copyMs);
}

// Host-copy ordinary RAM is NOT a bank path — always report does-not-ship.
inline bool ddr720p24HostCopyIsReachableBankRate() { return false; }

// Was: hypothesis PASS. Now: hard false — unreachable for FPGA-visible bank.
inline bool ddr720p24HostCopyCeilingFitsAt1500k(
    double /*decodeMs*/ = 32.427, double /*hostCopyMs*/ = kParentDdrHostCopyOrdinaryRam720pFrameMs) {
    return false;
}

// Coherent flush costs ms vs best bank (positive = flush is slower).
inline double ddr720p24CoherentFlushPenaltyMs() {
    return kParentDdrCoherentFlush720pFrameMs - kParentDdrBestBank720pFrameMs; // ~4.578
}

// RETRACTED "map_ms_saved" — was host_copy - mapped; that path is unreachable.
// Returns 0 so callers cannot claim a cache win.
inline double ddr720p24MappedToHostCopyMsSaved() { return 0.0; }

// Map flags cannot raise /dev/mem reserved-bank rate (parent prereg 0/5; pfn invalid).
inline bool ddrBankCpuStoreMapFlagIsInert() { return true; }
// Narrowed: structural uncached ceiling applies to /dev/mem reserved banks only.
// WriteCombineDriver is an open falsifiable route (not yet measured).
inline bool ddrBankCpuStoreIsStructuralUncachedCeiling() {
    return ddrMemMapIsDevMemReservedBankCeiling(DdrMemMapPolicy::StronglyOrderedSync);
}
inline bool ddrBankCpuStoreIsStructuralUncachedCeilingFor(DdrMemMapPolicy policy) {
    return ddrMemMapIsDevMemReservedBankCeiling(policy);
}
// Full-frame CPU move via /dev/mem cannot close true 720p24 with clean decode 35.94.
inline bool ddr720p24CpuFullFrameMovePathIsDead(
    double decodeMs = 35.94, double copyMs = kParentDdrBestBank720pFrameMs,
    double budgetMs = kFrameBudget24fpsMsLocal) {
    return (decodeMs + copyMs) > budgetMs;
}
// WC route would need this speedup vs measured /dev/mem to revive serial true-720p.
inline bool ddrWriteCombineMeetsSerialTrue720pTarget(double measuredWcMibps) {
    return measuredWcMibps >= kSerialTrue720pSourceRequiredMibps;
}

// Route A sketch only: max(decode, copy) — NOT proven (DDR contention unknown).
inline bool ddr720p24OverlapMaxDecodeCopyFits(double decodeMs, double copyMs,
                                              double budgetMs = kFrameBudget24fpsMsLocal) {
    const double m = (decodeMs > copyMs) ? decodeMs : copyMs;
    return m <= budgetMs;
}

// Product-tier overlap sketch (parent 36.27 decode): PASS on paper; contention unmeasured.
inline bool ddr720p24OverlapSketchFitsAt2600k(
    double decodeMs = 36.27, double copyMs = kParentDdrBestBank720pFrameMs,
    double budgetMs = kFrameBudget24fpsMsLocal) {
    return ddr720p24OverlapMaxDecodeCopyFits(decodeMs, copyMs, budgetMs);
}

} // namespace misterplex
