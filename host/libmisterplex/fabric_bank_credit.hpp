#pragma once
// Fabric bank credit / doorbell contract (w-mem write ↔ w-scaler read).
//
// Option-C 720p (parent-verified reserved window):
//   base 0x30180000  stride 0x180000  doorbell 0x3047F000
//   PLXD = doorbell + 0x128  (free_mask / disp / swap_pending / frames_done)
//
// Producer protocol (fabric_ddr_writer, PL330, or ARM):
//   1. Observe free_mask; bit i=1 means bank i is safe to fill.
//   2. Claim bank i exclusively.
//   3. Write full I420 at base + i*stride (layout from ddr_frame_layout.hpp).
//   4. Payload visible, then ONE PLXK doorbell {bank, fmt=YUV420P, seq}.
//   5. Never write a bank with free bit clear (scanout may be reading it).
//
// Consumer (ddr_frame_store / w-scaler):
//   PLXK → pending_bank + swap_pending + free_mask=0
//   vsync → disp←pending, free old disp, frames_done++
//
// Overlap path: fill free bank while scanning disp is legal iff free_mask holds.

#include "libmisterplex/input_mailbox.hpp"

#include <cstdint>

namespace misterplex {

constexpr uint32_t kFabric720pPhysBase = 0x30180000u;
constexpr uint32_t kFabric720pBankStride = 0x00180000u;
constexpr uint32_t kFabric720pDoorbellPhys = 0x3047F000u;

inline uint32_t fabric720pBankPhys(unsigned bank) {
    return kFabric720pPhysBase + static_cast<uint32_t>(bank & 1u) * kFabric720pBankStride;
}

inline uint32_t fabric720pPlxdPhys() {
    return bankReleaseMailboxPhys(kFabric720pDoorbellPhys);
}

inline uint32_t packFabricPlxdHi(uint8_t free_mask, uint8_t disp_bank, bool swap_pending,
                                 uint16_t frames_done) {
    uint32_t hi = 0;
    hi |= static_cast<uint32_t>(free_mask & 3u);
    hi |= static_cast<uint32_t>(disp_bank & 1u) << 2;
    if (swap_pending)
        hi |= 1u << 3;
    hi |= static_cast<uint32_t>(frames_done) << 16;
    return hi;
}

inline bool fabricBankWritable(uint8_t free_mask, unsigned bank) {
    return (free_mask & (1u << (bank & 1u))) != 0;
}

inline bool fabricWriterPathIsZeroArmPerPixel() { return true; }

} // namespace misterplex
