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

namespace mailbox_abi {

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
//
// RTL places the control page relative to DOORBELL_PHYS:
//   PLXK +0x000, PLXS +0x100, PLXI +0x108, PLXM +0x110,
//   PLXF +0x118, DIAG +0x120, PLXD +0x128
// Product 480p YUV doorbell is 0x300FF000 → PLXD live at 0x300FF128.
// The 0x3007F000 family below is the *legacy example base* (older packed-320
// map). Consumers MUST resolve via frameStoreMailboxPhys(doorbell, offset),
// never hard-read the legacy absolute PLXD/PLXF addresses against a product
// doorbell — that reads bank0 padding / boot residue and desyncs bank select
// (parent bank0 U≈0x04/0x19 green-cast class on c5382bee).

// Byte offsets from DOORBELL_PHYS (single source for ARM + invariant gates).
constexpr uint32_t kPlxkOffset = 0x000u;
constexpr uint32_t kPlxsOffset = 0x100u;
constexpr uint32_t kPlxiOffset = 0x108u;
constexpr uint32_t kPlxmOffset = 0x110u;
constexpr uint32_t kPlxfOffset = 0x118u;
constexpr uint32_t kSdramDiagOffset = 0x120u;
constexpr uint32_t kPlxdOffset = 0x128u;
// plex_chrome semantic list (ARM→FPGA) and optional HDMI mirror (FPGA→ARM).
// Doorbell-relative only — never hardcode absolute phys (see PLXD lesson).
constexpr uint32_t kPlxcOffset = 0x130u;
constexpr uint32_t kPlxoOffset = 0x138u;

// Legacy example doorbell base (historical 0x3007F000 control page).
constexpr uint32_t kLegacyFrameStoreDoorbellPhys = 0x3007F000u;

inline constexpr uint32_t frameStoreMailboxPhys(uint32_t doorbell_phys, uint32_t offset) {
    return doorbell_phys + offset;
}

// Absolute addresses for the legacy example base — table/collision gates only.
// Literals (not base+offset expressions) so static parsers in test_rtl_invariants
// can resolve them. Must equal kLegacyFrameStoreDoorbellPhys + k*Offset.
// Runtime ARM paths must use frameStoreMailboxPhys(ddrLayout_.doorbell_phys, …).
constexpr uint32_t kPlxkAddr  = 0x3007F000u;
constexpr uint32_t kPlxkMagic = 0x504C584Bu; // "PLXK"

// PLXS — Status (FPGA→ARM). OSD word + heartbeat.
constexpr uint32_t kPlxsAddr  = 0x3007F100u;
constexpr uint32_t kPlxsMagic = 0x504C5853u; // "PLXS"

// PLXI — Input (FPGA→ARM). Playback commands (pause/resume/seek).
constexpr uint32_t kPlxiAddr  = 0x3007F108u;
constexpr uint32_t kPlxiMagic = 0x504C5849u; // "PLXI"

// PLXM — SDRAM bring-up (FPGA→ARM). Memory test state.
constexpr uint32_t kPlxmAddr  = 0x3007F110u;
constexpr uint32_t kPlxmMagic = 0x504C584Du; // "PLXM"

// PLXF — Frame-store status (FPGA→ARM). Underrun count + debug state.
constexpr uint32_t kPlxfAddr  = 0x3007F118u;
constexpr uint32_t kPlxfMagic = 0x504C5846u; // "PLXF"

// SDRAM diagnostic (FPGA→ARM). No magic header, raw layout.
constexpr uint32_t kSdramDiagAddr = 0x3007F120u;
// No magic — raw diagnostic word.

// PLXD — Bank-release ACK (FPGA→ARM). Tells ARM which bank is safe to write.
// Layout (64-bit, little-endian):
//   [31:0]   magic 0x504C5844 "PLXD"
//   [33:32]  free_bank_mask[1:0] — bit i=1 means bank i is safe to overwrite
//   [34]     disp_bank           — currently displayed bank (0 or 1)
//   [35]     swap_pending        — doorbell received, vsync flip pending
//   [47:36]  reserved (0)
//   [63:48]  frames_done[15:0]   — monotonic bank-swap counter (wraps at 65535)
//
// Semantics:
//   !swap_pending → free_bank_mask = disp_bank ? 0b01 : 0b10
//   swap_pending  → free_bank_mask = 0b00 (both banks in use)
//   On vsync swap: old disp_bank becomes free, frames_done++
// Legacy absolute (example base only) — product live addr is doorbell+0x128:
constexpr uint32_t kPlxdAddr  = 0x3007F128u;
constexpr uint32_t kPlxdMagic = 0x504C5844u; // "PLXD"

// PLXC — Chrome list control (ARM→FPGA). Semantic cmds only; fabric owns scale.
// Layout (64-bit LE): [31:0] magic "PLXC", [32] enable, [33] bank_sel,
// [47:34] cmd_count, [63:48] seq. List payload at doorbell+0x140 (design).
constexpr uint32_t kPlxcAddr  = 0x3007F130u; // legacy example base + 0x130
constexpr uint32_t kPlxcMagic = 0x504C5843u; // "PLXC"

// PLXO — Chrome telemetry (FPGA→ARM). Applied HDMI_W/H mirror + chrome_hw.
// Telemetry only — NOT geometry authority (fabric uses HDMI_WIDTH/HEIGHT wires).
constexpr uint32_t kPlxoAddr  = 0x3007F138u;
constexpr uint32_t kPlxoMagic = 0x504C584Fu; // "PLXO"
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

constexpr std::array<MagicEntry, 9> kAllMagics = {{
    {"PLXK", kPlxkMagic},
    {"PLXS", kPlxsMagic},
    {"PLXI", kPlxiMagic},
    {"PLXM", kPlxmMagic},
    {"PLXF", kPlxfMagic},
    {"PLXD", kPlxdMagic},
    {"PLXB", kPlxbMagic},
    {"PLXC", kPlxcMagic},
    {"PLXO", kPlxoMagic},
}};

// ---- All addressed mailboxes (for address-collision detection) ----
// Every occupied DDR mailbox slot. Gate rejects overlapping addresses.
constexpr std::array<MailboxEntry, 10> kAllMailboxes = {{
    {"PLXK", kPlxkAddr,     kPlxkMagic,     8, "arm_to_fpga",  true},
    {"PLXS", kPlxsAddr,     kPlxsMagic,     8, "fpga_to_arm",  true},
    {"PLXI", kPlxiAddr,     kPlxiMagic,     8, "fpga_to_arm",  true},
    {"PLXM", kPlxmAddr,     kPlxmMagic,     8, "fpga_to_arm",  true},
    {"PLXF", kPlxfAddr,     kPlxfMagic,     8, "fpga_to_arm",  true},
    {"DIAG", kSdramDiagAddr, 0,             8, "fpga_to_arm",  false},
    {"PLXD", kPlxdAddr,     kPlxdMagic,     8, "fpga_to_arm",  true},
    {"PLXC", kPlxcAddr,     kPlxcMagic,     8, "arm_to_fpga",  true},
    {"PLXO", kPlxoAddr,     kPlxoMagic,     8, "fpga_to_arm",  true},
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
