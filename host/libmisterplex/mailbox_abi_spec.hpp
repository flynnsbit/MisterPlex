// mailbox_abi_spec.hpp — SINGLE SOURCE OF TRUTH for MiSTerPlex DDR mailbox ABI.
//
// Every mailbox in the DDR address map is defined here ONCE. Both the RTL
// (SystemVerilog parameters/localparams) and the ARM C++ (constexpr constants)
// must be checked against these values. The invariant gate
// (tests/unit/test_rtl_invariants.py) statically asserts both sides match.
//
// To add a new mailbox:
//   1. Add it to the MailboxEntry table below.
//   2. If it has a magic header, register it in kAllMagics.
//   3. Run `python3 tests/unit/test_rtl_invariants.py` — it MUST pass.
//   4. If the gate fails, one side drifted. Fix it before committing.
//
// ====== NEVER hand-maintain magic or address constants in two places. ======
// If the RTL and C++ disagree, this file is authoritative.

#pragma once
#include <cstdint>
#include <array>

#include "ddr_frame_layout.hpp"

namespace mailbox_abi {

// ===== 2026-07-28 CORRECTION: mailbox base was one bank stride too low. =====
// Every constant below used to be a hand-written literal at 0x3007Fxxx. The RTL
// computes DOORBELL_PHYS = PHYS_BASE + (2 * HPS_BANK_STRIDE_BYTES) - 0x1000,
// which for the active YUV420p layout (stride 0x80000) is 0x300FF000. The old
// literals used ONE stride instead of two, so they addressed 0x80000 low —
// inside frame-bank payload, not the mailbox page.
//
// Consequence: every mailbox READ (PLXS/PLXI/PLXM/PLXF/PLXD) landed on unwritten
// DDR and returned zeros, while the frame data path — which correctly used
// misterplex::kPlex480pYuv420pDoorbellPhys — worked. That divergence is why the
// logo rendered while PLXD looked "silent".
//
// Verified on hardware 2026-07-28 against resident core 3b1e8435:
//   0x300FF000 = 0x504C584B "PLXK"   0x300FF100 = 0x504C5853 "PLXS"
//   0x300FF118 = 0x504C5846 "PLXF"   0x300FF128 = 0x504C5844 "PLXD"
//   0x3007F000/100/118/128 = 0x00000000 (all zero)
//
// The base is now DERIVED from the frame-layout header rather than restated, so
// the two sources cannot drift apart again.
constexpr uint32_t kMailboxBase = misterplex::kPlex480pYuv420pDoorbellPhys;
static_assert(kMailboxBase ==
                  misterplex::kDdrFramePhysBase +
                      2u * misterplex::kPlex480pYuv420pBankStride - 0x1000u,
              "mailbox base must equal the RTL DOORBELL_PHYS expression "
              "PHYS_BASE + 2*HPS_BANK_STRIDE_BYTES - 0x1000");

// --- Mailbox address table (physical DDR addresses) -------------------------
// Each entry: {name, phys_addr, magic, size_bytes, direction, has_magic}

struct MailboxEntry {
    const char* name;
    uint32_t phys_addr;
    uint32_t magic;       // 0 if no magic header
    unsigned size_bytes;   // 8 = one 64-bit qword
    const char* direction; // "fpga_to_arm", "arm_to_fpga", "bidirectional"
    bool has_magic;
};

// ---- Core frame-store mailboxes (ddram_frame_rd / ddr_frame_store) ----

// PLXK — Doorbell (ARM→FPGA). ARM writes bank|format|seq to trigger a frame swap.
constexpr uint32_t kPlxkAddr  = kMailboxBase + 0x000u;
constexpr uint32_t kPlxkMagic = 0x504C584Bu; // "PLXK"

// PLXS — Status (FPGA→ARM). OSD word + heartbeat.
constexpr uint32_t kPlxsAddr  = kMailboxBase + 0x100u;
constexpr uint32_t kPlxsMagic = 0x504C5853u; // "PLXS"

// PLXI — Input (FPGA→ARM). Playback commands (pause/resume/seek).
constexpr uint32_t kPlxiAddr  = kMailboxBase + 0x108u;
constexpr uint32_t kPlxiMagic = 0x504C5849u; // "PLXI"

// PLXM — SDRAM bring-up (FPGA→ARM). Memory test state.
constexpr uint32_t kPlxmAddr  = kMailboxBase + 0x110u;
constexpr uint32_t kPlxmMagic = 0x504C584Du; // "PLXM"

// PLXF — Frame-store status (FPGA→ARM). Underrun count + debug state.
constexpr uint32_t kPlxfAddr  = kMailboxBase + 0x118u;
constexpr uint32_t kPlxfMagic = 0x504C5846u; // "PLXF"

// SDRAM diagnostic (FPGA→ARM). No magic header, raw layout.
constexpr uint32_t kSdramDiagAddr = kMailboxBase + 0x120u;
// No magic — raw diagnostic word.

// PLXD — Bank-release ACK (FPGA→ARM). Tells ARM which bank is safe to write.
// Layout (64-bit, little-endian):
//   [31:0]   magic 0x504C5844 "PLXD"
//   [33:32]  free_bank_mask[1:0] — bit i=1 means bank i is safe to overwrite
//   [34]     disp_bank           — currently displayed bank (0 or 1)
//   [35]     swap_pending        — doorbell received, vsync flip pending
//   [47:36]  reserved (0)
//   [63:48]  frames_done[15:0]   — MISNOMER: this is bank_vsync_count, a
//                                  FREE-RUNNING VSYNC COUNTER, not a swap count.
//
// ** 2026-07-28: do not use [63:48] as evidence that frames are being swapped. **
// ddr_frame_store toggles `vsync_toggle` in BOTH arms of the vsync branch
// (rtl/ddr_frame_store.sv:244 on a successful swap, :246 on a plain vsync with
// no swap pending), and bank_vsync_count counts those toggles. It therefore
// advances at the full ~60 Hz refresh rate even when ZERO frames are submitted.
// Measured 2026-07-28 on core 3b1e8435: this field advanced ~67/s while the PLXK
// doorbell was completely static (0x2000005C, seq frozen) — i.e. no frame was
// ever submitted or swapped during the entire measurement.
// The genuine swap counter is the separate `frames_done` register at
// rtl/ddr_frame_store.sv:243, which is NOT published in this mailbox.
//
// Semantics:
//   !swap_pending → free_bank_mask = disp_bank ? 0b01 : 0b10
//   swap_pending  → free_bank_mask = 0b00 (both banks in use)
//   On vsync swap: old disp_bank becomes free, frames_done++
//
// ** free_bank_mask is DERIVED, not independently measured. ** The RTL packs it
// as `swap_pending ? 2'b00 : (disp_bank ? 2'b01 : 2'b10)` in one expression
// (rtl/ddr_frame_store.sv:951-953), so "free_bank_mask == 0" and
// "swap_pending == 1" are the SAME BIT reported twice. Citing both as
// corroborating observations overstates the evidence by exactly one fact.
constexpr uint32_t kPlxdAddr  = kMailboxBase + 0x128u;
constexpr uint32_t kPlxdMagic = 0x504C5844u; // "PLXD"
// Bit-field positions (in the upper 32 bits, i.e. offset from bit 32):
constexpr unsigned kPlxdFreeBankMaskBit = 0;  // bits [33:32] → [1:0] of upper word
constexpr unsigned kPlxdFreeBankMaskWidth = 2;
constexpr unsigned kPlxdDispBankBit = 2;      // bit [34] → bit 2 of upper word
constexpr unsigned kPlxdSwapPendingBit = 3;   // bit [35] → bit 3 of upper word
constexpr unsigned kPlxdFramesDoneBit = 16;   // bits [63:48] → [31:16] of upper word
constexpr unsigned kPlxdFramesDoneWidth = 16;

// ---- Bitstream ring mailboxes (ddr_bitstream_reader) ----

// PLXB — Ring CTRL (ARM→FPGA). Bitstream ring control word.
constexpr uint32_t kPlxbAddr  = 0x30140000u;
constexpr uint32_t kPlxbMagic = 0x504C5842u; // "PLXB"
// PLXD in the PLXB CTRL slot marks the bitstream producer intentionally dormant
// (STREAM=0). This is an in-band diagnostic value at kPlxbAddr, not a separate
// addressed mailbox; it intentionally reuses the PLXD magic value defined above.
constexpr uint32_t kPlxbDormantMagic = kPlxdMagic;

// ---- All magics (for collision detection) ----
// Every PLX-prefixed magic in the system. Gate rejects duplicates.
struct MagicEntry {
    const char* name;
    uint32_t magic;
};

constexpr std::array<MagicEntry, 7> kAllMagics = {{
    {"PLXK", kPlxkMagic},
    {"PLXS", kPlxsMagic},
    {"PLXI", kPlxiMagic},
    {"PLXM", kPlxmMagic},
    {"PLXF", kPlxfMagic},
    {"PLXD", kPlxdMagic},
    {"PLXB", kPlxbMagic},
}};

// ---- All addressed mailboxes (for address-collision detection) ----
// Every occupied DDR mailbox slot. Gate rejects overlapping addresses.
constexpr std::array<MailboxEntry, 8> kAllMailboxes = {{
    {"PLXK", kPlxkAddr,     kPlxkMagic,     8, "arm_to_fpga",  true},
    {"PLXS", kPlxsAddr,     kPlxsMagic,     8, "fpga_to_arm",  true},
    {"PLXI", kPlxiAddr,     kPlxiMagic,     8, "fpga_to_arm",  true},
    {"PLXM", kPlxmAddr,     kPlxmMagic,     8, "fpga_to_arm",  true},
    {"PLXF", kPlxfAddr,     kPlxfMagic,     8, "fpga_to_arm",  true},
    {"DIAG", kSdramDiagAddr, 0,             8, "fpga_to_arm",  false},
    {"PLXD", kPlxdAddr,     kPlxdMagic,     8, "fpga_to_arm",  true},
    {"PLXB", kPlxbAddr,     kPlxbMagic,     8, "arm_to_fpga",  true},
}};

// ---- Bitstream ring additional magics (not address-mapped; in-band) ----
// These are record/status magics used within the bitstream ring protocol,
// not standalone mailboxes. Listed here for magic-collision detection only.
constexpr std::array<MagicEntry, 9> kBitstreamRingMagics = {{
    {"PLXR", 0x504C5852u},  // read pointer
    {"PLXE", 0x504C5845u},  // error
    {"PLXN", 0x504C584Eu},  // record header (NAL)
    {"PLXT", 0x504C5854u},  // ring level stat
    {"PLXU", 0x504C5855u},  // consumer seq stat
    {"PLXV", 0x504C5856u},  // last bad seq stat
    {"PLXW", 0x504C5857u},  // session low stat
    {"PLXY", 0x504C5859u},  // session high stat
    {"PLXZ", 0x504C585Au},  // underrun/overrun stat
}};

// Additional in-band magic (not in ring stats array above):
constexpr MagicEntry kPlxqMagic_entry = {"PLXQ", 0x504C5851u}; // desync/state flags

} // namespace mailbox_abi
