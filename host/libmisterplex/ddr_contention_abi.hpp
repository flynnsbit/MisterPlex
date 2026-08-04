// ddr_contention_abi.hpp — host view of fabric DDR contention counters (w-plxd).
//
// RTL: fpga/Plex_MiSTer/rtl/ddr_contention_status.sv
// Observation only (no arb policy). Counters are measured events on clk_ddr.
//
// Compact snapshot (4×64-bit LE words) — intended PLXC mailbox publish:
//   w0 [31:0]  magic 0x504C5843 "PLXC"
//   w0 [63:32] window_cycles
//   w1 [31:0]  m0_stall_cycles          (present backpressured)
//   w1 [63:32] m0_stall_while_m2        (present stalled AND publish cmd)
//   w2 [31:0]  m0_cmd_accepts
//   w2 [63:32] m0_rd_beats
//   w3 [31:0]  m2_cmd_accepts
//   w3 [63:32] m2_stall_while_m0
//
// Full counter set is on dedicated RTL ports (also noprune).
//
// Intended phys (once mailbox writer is muxed onto f2sdram — w-mem compose):
//   offset from DOORBELL_PHYS = 0x130 (after PLXD at +0x128)
//   product 480p doorbell 0x300FF000 → PLXC 0x300FF130
//   Option-C 720p doorbell 0x3047F000 → PLXC 0x3047F130
// Until the writer is on the bus, snap lives as fabric noprune only; the
// parent device command below will report magic!=PLXC (honest miss).

#pragma once

#include <cstdint>

#include "mailbox_abi_spec.hpp"

namespace misterplex::ddr_contention {

constexpr std::uint32_t kMagic = 0x504C5843u; // "PLXC"
constexpr std::uint32_t kMailboxOffset = 0x130u;
constexpr unsigned kSnapWords = 4;

inline constexpr std::uint32_t mailboxPhys(std::uint32_t doorbell_phys) {
    return mailbox_abi::frameStoreMailboxPhys(doorbell_phys, kMailboxOffset);
}

// Decode snap_w0 low half.
inline bool magicOk(std::uint32_t word0_lo) { return word0_lo == kMagic; }

// FAIL heuristic (parent lab): present stall-while-publish / window > 2%.
// Paper 720p24 concurrent duty is ~13.8% of ideal peak; m0 priority should
// keep m0_stall_while_m2 near quantum noise, not percent-level of the frame.
constexpr double kFailStallWhileM2Ratio = 0.02;

inline bool failPresentStarvedByPublish(std::uint32_t window,
                                        std::uint32_t m0_stall_while_m2) {
    if (window == 0)
        return false;
    return (static_cast<double>(m0_stall_while_m2) / static_cast<double>(window)) >
           kFailStallWhileM2Ratio;
}

// PREREG 720p24 steady-state (arithmetic, not measured on device):
//   I420 1_382_400 B/frame × 24 fps = 33_177_600 B/s/dir
//   beats/frame @8B = 172_800 present RD; copy R+W = 345_600
//   concurrent ≈ 99.53 MB/s ≈ 13.8% of 720 MB/s ideal @90 MHz×8B
//   Healthy: m0_stall_while_m2 / window << 0.02 over ≥1 frame
//   FAIL: ratio ≥ 0.02 sustained (line-buffer underrun risk)

} // namespace misterplex::ddr_contention
