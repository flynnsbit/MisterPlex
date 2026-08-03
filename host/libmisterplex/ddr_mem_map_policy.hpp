#pragma once

// DDR frame-bank /dev/mem map policy (w-mem).
//
// Parent Sweep-3 2026-08-03 ddr_write_bench into REAL FPGA-visible bank (true rc=0):
//   --no-sync (no flush)         86.262 MiB/s  15.283 ms/f  <- BEST on bank
//   --sync                       83.639 MiB/s  15.762 ms/f
//   --no-sync --flush (coherent) 66.380 MiB/s  19.861 ms/f  <- WORSE by 4.578 ms
//   --host-copy (ordinary RAM)  439.788 MiB/s   2.998 ms/f  <- NOT REACHABLE on bank
//
// RETRACTED: "mmap cache policy is worth 12.212 ms/f". Coherent mapping costs
// more than it saves (flush). Host-copy is ordinary RAM, not a bank rate.
// Best ARM bank copy stays ~15.28 ms/f.
//
// Serial decode+copy is DEAD at every measured tier (see helpers below).
// Ship path = fabric owns pixels (publish_bytes=0). Route A (PL330 overlap)
// is parent-owned measurement; not assumed here.
//
// Ordering hazard (kept): if anyone ever maps cacheable, payload MUST be
// FPGA-visible BEFORE doorbell (flush+barrier). Do not weaken this gate.

#include <cstddef>
#include <cstdint>
#include <fcntl.h>

namespace misterplex {

enum class DdrMemMapPolicy : uint8_t {
    // Product default: open(/dev/mem, O_RDWR|O_CLOEXEC|O_SYNC).
    StronglyOrderedSync = 0,
    // Lab only: open without O_SYNC. Requires explicit dcache clean + DSB
    // before doorbell. NOT a performance win on this SoC (Sweep-3).
    CachedExplicitFlush = 1,
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
        s.requires_dcache_flush_before_doorbell = false;
    } else {
        s.requires_dcache_flush_before_doorbell = true;
    }
    return s;
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
constexpr double kParentDdrMappedBank720pMibps = 86.262; // --no-sync no flush
constexpr double kParentDdrMappedBank720pSyncMibps = 83.639;
constexpr double kParentDdrMappedBank720pCoherentFlushMibps = 66.380;
constexpr double kParentDdrMappedBank480pMibps = 89.363; // prior sweep; bandwidth-limited
// Ordinary RAM only — NEVER use as bank budget (unreachable for FPGA-visible).
constexpr double kParentDdrHostCopyOrdinaryRamMibps = 439.788;

constexpr double kParentDdrBestBank720pFrameMs = 15.283;
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

// PMS floor for real 1280x720: >=3500 kbit (w-path). Serial still fails.
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

// Route A sketch only: max(decode, copy) — NOT proven (DDR contention unknown).
inline bool ddr720p24OverlapMaxDecodeCopyFits(double decodeMs, double copyMs,
                                              double budgetMs = kFrameBudget24fpsMsLocal) {
    const double m = (decodeMs > copyMs) ? decodeMs : copyMs;
    return m <= budgetMs;
}

} // namespace misterplex
