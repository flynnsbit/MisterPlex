#pragma once
// ARM side of the fabric DDR publication-copy handover (w-plxd).
//
// STRATEGIC PREMISE (parent 2026-08-04, adopted with attribution — w-plxd has
// no device): MiSTer framework owns one A9 core at idle (~100% userspace spin);
// mpx-main ~0.8%. Dual-core decode||copy overlap is WITHDRAWN. The ~15 ms/frame
// host publication memcpy must retire into FPGA fabric (w-mem/w-path). This
// header names what the daemon STOPS doing once fabric owns the copy, and what
// remains. It is the ARM contract for that cut — not a fabric design.
//
// Control for the premise: parent /proc/stat 10 s deltas (USER_HZ=100).
// Control for "copy is on ARM today": quoted symbols below + unit static gate.
//
// M10K cost of this header: 0 (documentation / contract only).

#include <cstddef>

namespace misterplex {
namespace fabric_copy_handover {

// ---------------------------------------------------------------------------
// DELETE on fabric-owned copy (host hot path stops performing these).
// Each entry is a concrete symbol/site in the current origin/main tree.
// ---------------------------------------------------------------------------
inline constexpr const char* kDeleteSites[] = {
    // Whole-frame host→DDR bank memcpy (the retired cost class).
    "arm/misterplexd/fpga_spi.cpp:std::memcpy(ddrMap_ + bankOff, payload, len)",
    // Optional D-cache clean of the bank after memcpy (flush_us bucket).
    "arm/misterplexd/fpga_spi.cpp:cleanDcacheRange(ddrMap_ + bankOff, len)",
    // Timing bucket that measures host memcpy wall time.
    "arm/misterplexd/fpga_spi.hpp:DdrTiming::copy_us",
    "arm/misterplexd/fpga_spi.hpp:DdrTiming::flush_us",
    // Profile accumulation of host copy cost in the present path.
    "arm/misterplexd/media_player.cpp:prof.ddrCopyUs += dt.copy_us",
    "arm/misterplexd/media_player.cpp:prof.ddrFlushUs += dt.flush_us",
    // PLXD-absent prep sleep that stood in for "bank free" before host overwrite.
    // Once fabric DMA + PLXD own readiness, this blind sleep is not the copy path.
    "arm/misterplexd/fpga_spi.cpp:usleep(1500) // PLXD-absent prep before host memcpy",
    // Same-bank reuse floor wait that only protects host overwrite of a live bank.
    "arm/misterplexd/fpga_spi.cpp:kDdrBankReuseMinUs wait before host memcpy (absent path)",
};

// ---------------------------------------------------------------------------
// KEEP after fabric owns copy (handover / readiness / decode still ARM or shared).
// ---------------------------------------------------------------------------
inline constexpr const char* kKeepSites[] = {
    // Bank-select policy: free_mask / display-ack / drop (no force-write).
    "host/libmisterplex/ddr_bank_release_select.hpp:selectDdrWriteBank",
    // PLXD liveness / residue fallback.
    "host/libmisterplex/plxd_liveness.hpp:plxdLivenessTick",
    // Doorbell kick that tells the core a bank is ready (may become "DMA done"
    // ack from fabric later — still an ARM→core signal until fully offloaded).
    "arm/misterplexd/fpga_spi.cpp:kickDdrDoorbell",
    // Layout / geometry derivation (shared ABI with fabric).
    "host/libmisterplex/ddr_frame_layout.hpp",
    "host/libmisterplex/ddr_present_bank.hpp:buildDdrPublishPlan",
    // Publish entry that will post a descriptor instead of memcpy.
    "arm/misterplexd/fpga_spi.cpp:FpgaSpi::publishDdrFrame",
    "arm/misterplexd/media_player.cpp:MediaPlayer::publishDdrFrame",
    // Decode / pipe produce host or ring buffers that fabric DMA may source.
    // (Not deleted — source of pixels moves, not "no pixels".)
    "arm/misterplexd/media_player.cpp:playback DDR path frame assembly",
};

// ---------------------------------------------------------------------------
// UNKNOWN until w-mem fabric design lands (do not invent).
// ---------------------------------------------------------------------------
// - Whether ARM still owns a bounce buffer or posts phys addresses only.
// - Whether kickDdrDoorbell remains or is replaced by fabric-completion IRQ/mailbox.
// - Exact M10K/ALM of the fabric copy engine (w-mem must state; w-plxd M10K=0 here).
// - DDR bandwidth contention vs present scanout reader (rd-duck / w-mem).

inline constexpr std::size_t kDeleteCount =
    sizeof(kDeleteSites) / sizeof(kDeleteSites[0]);
inline constexpr std::size_t kKeepCount = sizeof(kKeepSites) / sizeof(kKeepSites[0]);

// Compile-time non-empty inventory (catches accidental wipe).
static_assert(kDeleteCount >= 6, "fabric copy DELETE inventory too small");
static_assert(kKeepCount >= 5, "fabric copy KEEP inventory too small");

} // namespace fabric_copy_handover
} // namespace misterplex
