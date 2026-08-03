#pragma once
// Frame publish visibility barrier (w-mem).
//
// rd-duck found w-path used atomic_signal_fence as a claimed "DMB" — that is a
// *compiler* fence only and does not order stores against the FPGA observing
// the reserved bank. Ringing PLXK before payload is visible → intermittent tear.
//
// Product sendDdrFrame (fpga_spi.cpp) uses __sync_synchronize() after memcpy.
// On GCC/Clang for AArch32/AArch64 that builtin is a full memory barrier
// (emits DMB), not a signal_fence. This header makes the requirement explicit
// and gives callers a single helper that cannot be mistaken for signal_fence.
//
// Ordering (bank_producer_order / fabric_bank_credit):
//   credit → fill → payload_visible(+this barrier) → ONE doorbell
//
// /dev/mem strongly-ordered maps: barrier still documents the publish edge;
// WriteCombineDriver maps: barrier is mandatory (see ddr_mem_map_policy.hpp).

#include "libmisterplex/ddr_mem_map_policy.hpp"

#include <atomic>
#include <cstddef>
#include <cstdint>

namespace misterplex {

// Hardware-visible store barrier (seq_cst thread fence). NOT atomic_signal_fence.
inline void ddrPublishPayloadBarrier() {
    std::atomic_thread_fence(std::memory_order_seq_cst);
}

// True when this map policy requires an explicit barrier/clean before doorbell.
inline bool ddrPublishRequiresExplicitVisibility(DdrMemMapPolicy policy) {
    return ddrMemMapOpenSpec(policy).requires_dcache_flush_before_doorbell;
}

// Scoreboard: was a real barrier observed between fill and doorbell?
struct DdrPublishVisibility {
    bool payload_stores_done = false;
    bool barrier_done = false;
    bool doorbell_rung = false;
    bool tore = false; // set if doorbell without barrier while required
};

inline bool ddrPublishMarkStoresDone(DdrPublishVisibility& v) {
    if (v.doorbell_rung) {
        v.tore = true;
        return false;
    }
    v.payload_stores_done = true;
    return true;
}

inline bool ddrPublishMarkBarrier(DdrPublishVisibility& v) {
    if (!v.payload_stores_done) {
        v.tore = true;
        return false;
    }
    if (v.doorbell_rung) {
        v.tore = true;
        return false;
    }
    ddrPublishPayloadBarrier();
    v.barrier_done = true;
    return true;
}

// policy: if explicit visibility required, barrier_done must be set.
// For StronglyOrderedSync, still require barrier_done when enforce_always
// so unit tests and WC path share one contract (cheap on SO maps).
inline bool ddrPublishMarkDoorbell(DdrPublishVisibility& v, DdrMemMapPolicy policy,
                                   bool enforce_always = true) {
    if (!v.payload_stores_done) {
        v.tore = true;
        return false;
    }
    const bool need = enforce_always || ddrPublishRequiresExplicitVisibility(policy);
    if (need && !v.barrier_done) {
        v.tore = true;
        return false;
    }
    v.doorbell_rung = true;
    return true;
}

// NEG helper: signal_fence must never satisfy the visibility contract.
inline bool ddrPublishSignalFenceIsHardwareBarrier() {
    // Documented false — atomic_signal_fence does not emit DMB on ARM.
    return false;
}

// Bytes that must be ordered before doorbell for a native publish.
inline size_t ddrPublishOrderedBytes(size_t payload_len) {
    return payload_len;
}

} // namespace misterplex
