#pragma once

// DDR frame-bank /dev/mem map policy (w-mem).
//
// Parent device 2026-08-03 ddr_write_bench (true rc=0):
//   mapped bank (product path) 86.676 MiB/s → 15.210 ms / 720p frame
//   ordinary RAM memcpy        439.788 MiB/s →  2.998 ms / 720p frame (UPPER BOUND)
//   480p mapped bank           89.363 MiB/s → bandwidth-limited, not fixed-cost
//
// Hypothesis (unproven on bank): the 5.07x gap is mmap cache attribute
// (O_SYNC → strongly-ordered/device), not DRAM physics. Remap without O_SYNC
// + explicit dcache clean before doorbell may close the gap. Parent measures.
//
// Ordering (absolute): every payload byte must be FPGA-visible BEFORE doorbell.
// Cached/WC maps MUST clean+barrier before kickDdrDoorbell — or tear (88509163 class).

#include <cstddef>
#include <cstdint>
#include <fcntl.h>

namespace misterplex {

enum class DdrMemMapPolicy : uint8_t {
    // Product default: open(/dev/mem, O_RDWR|O_CLOEXEC|O_SYNC). Stores ordered;
    // no dcache clean required before doorbell.
    StronglyOrderedSync = 0,
    // Lab / 720p candidate: open without O_SYNC (cacheable or WC attribute on
    // this kernel). Requires explicit dcache clean of the written range + DSB
    // before doorbell. Refusing flush is a hard error.
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

// Conf knobs DDR_MEM_SYNC / DDR_MEM_FLUSH → policy.
// SYNC=1 → StronglyOrderedSync (FLUSH ignored for ordering; may still be 0).
// SYNC=0 → CachedExplicitFlush; FLUSH must be 1 or the publish path must refuse.
inline DdrMemMapPolicy ddrMemMapPolicyFromConf(bool ddrMemSync, bool /*ddrMemFlush*/) {
    return ddrMemSync ? DdrMemMapPolicy::StronglyOrderedSync
                      : DdrMemMapPolicy::CachedExplicitFlush;
}

// True when conf pair is safe to publish (no doorbell-before-visibility hole).
inline bool ddrMemMapConfPublishSafe(bool ddrMemSync, bool ddrMemFlush) {
    if (ddrMemSync)
        return true;
    return ddrMemFlush; // cached path requires flush
}

// May the producer ring the doorbell now?
// flushCompleted = dcache clean of payload range succeeded this frame (or N/A).
inline bool ddrMemMayRingDoorbell(DdrMemMapPolicy policy, bool flushCompleted) {
    if (policy == DdrMemMapPolicy::StronglyOrderedSync)
        return true;
    return flushCompleted;
}

// Parent-measured rates (MiB/s, 1024^2). Use for budget projections.
constexpr double kParentDdrMappedBank720pMibps = 86.676;
constexpr double kParentDdrMappedBank480pMibps = 89.363;
// Ordinary RAM memcpy on device — NOT a proven bank rate. Hypothesis ceiling only.
constexpr double kParentDdrHostCopyCeilingMibps = 439.788;
// 720p frame wall ms at those rates (1382400 B).
constexpr double kParentDdrMapped720pFrameMs = 15.210;
constexpr double kParentDdrHostCopy720pFrameMs = 2.998;
// Mapped vs host-copy speedup (86.676 → 439.788).
constexpr double kParentDdrMappedToHostCopySpeedup = 5.07;

// Budget: decode_ms + copy_ms <= 41.667?
inline bool ddr720p24DecodePlusCopyFitsBudget(double decodeMs, double copyMs,
                                              double budgetMs = 41.667) {
    return (decodeMs + copyMs) <= budgetMs;
}

// Product mapped path at candidate 1500k decode — FAILS (parent arithmetic).
inline bool ddr720p24MappedPathFitsAt1500k(
    double decodeMs = 32.427, double mappedCopyMs = kParentDdrMapped720pFrameMs) {
    return ddr720p24DecodePlusCopyFitsBudget(decodeMs, mappedCopyMs);
}

// Host-copy ceiling hypothesis at 1500k — PASSES numbers but UNPROVEN on bank.
inline bool ddr720p24HostCopyCeilingFitsAt1500k(
    double decodeMs = 32.427, double hostCopyMs = kParentDdrHostCopy720pFrameMs) {
    return ddr720p24DecodePlusCopyFitsBudget(decodeMs, hostCopyMs);
}

// ms saved if bank write reached host-copy ceiling vs mapped (parent).
inline double ddr720p24MappedToHostCopyMsSaved() {
    return kParentDdrMapped720pFrameMs - kParentDdrHostCopy720pFrameMs; // 12.212
}

} // namespace misterplex
