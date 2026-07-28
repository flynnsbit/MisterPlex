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
// !! READ THIS BEFORE PROBING A LIVE DEVICE !!
// The addresses in this block are the *default-parameter* window: they follow
// from PHYS_BASE=0x30000000 with HPS_BANK_STRIDE_BYTES=262144, which is
// ddram_frame_rd's own module default. It is NOT the RGB565 layout: RGB565
// ships a 786432-byte stride whose doorbell is 0x3017F000. 262144 belongs to no
// current layout family at all. Every offset is relative to a doorbell placed
// at PHYS_BASE + 2*stride - 0x1000, so a different bank stride moves the WHOLE
// window.
//
// present_core.sv instantiates ddr_frame_store with the YUV420p stride
// (524288), which puts the live window at 0x300FF000 — see the
// kYuv420p* constants below. Both windows exist in the address map, and DDR
// keeps whatever an older core last wrote at the other one, so reading the
// stale window returns plausible-looking magics that never change. Derive the
// window from the doorbell for the format you are actually running; do not
// hardcode 0x3007F1xx in a probe. Use scripts/mailbox_window.py, which derives
// the live window from the RTL and names the dead ones.

// PLXK — Doorbell (ARM→FPGA). ARM writes bank|format|seq to trigger a frame swap.
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
constexpr uint32_t kPlxdAddr  = 0x3007F128u;
constexpr uint32_t kPlxdMagic = 0x504C5844u; // "PLXD"
// Bit-field positions (in the upper 32 bits, i.e. offset from bit 32):
constexpr unsigned kPlxdFreeBankMaskBit = 0;  // bits [33:32] → [1:0] of upper word
constexpr unsigned kPlxdFreeBankMaskWidth = 2;
constexpr unsigned kPlxdDispBankBit = 2;      // bit [34] → bit 2 of upper word
constexpr unsigned kPlxdSwapPendingBit = 3;   // bit [35] → bit 3 of upper word
constexpr unsigned kPlxdFramesDoneBit = 16;   // bits [63:48] → [31:16] of upper word
constexpr unsigned kPlxdFramesDoneWidth = 16;

// ---- Mailbox window as a function of the doorbell -------------------------
// The offsets above are fixed relative to the doorbell; only the doorbell moves
// with the bank stride. Expressing that here means a probe or gate can be
// pointed at the window the running core actually uses instead of assuming the
// default-parameter one.
constexpr uint32_t kMboxOffsetStatus     = 0x100u; // PLXS
constexpr uint32_t kMboxOffsetInput      = 0x108u; // PLXI
constexpr uint32_t kMboxOffsetSdram      = 0x110u; // PLXM
constexpr uint32_t kMboxOffsetFrame      = 0x118u; // PLXF
constexpr uint32_t kMboxOffsetSdramDiag  = 0x120u; // raw diagnostic
constexpr uint32_t kMboxOffsetBank       = 0x128u; // PLXD

constexpr uint32_t doorbellForStride(uint32_t phys_base, uint32_t bank_stride_bytes) {
    return phys_base + 2u * bank_stride_bytes - 0x1000u;
}

// The window present_core.sv actually instantiates for the shipping I420 path
// (624x480 planar, bank stride 0x80000). These are the addresses a live probe
// must use.
//
// The 0x3007Fxxx block above is NOT the RGB565 window either: RGB565 ships a
// 0xC0000 stride, whose doorbell is 0x3017F000. 0x3007F000 is the doorbell for
// a 0x40000 stride that no current layout family uses, i.e. it is a legacy
// default that the fabric no longer writes. On real hardware it still answers
// with valid PLXK/PLXS/PLXF magics, because an older core left them there and
// nothing overwrites them, so a probe pointed at it reads plausible values that
// never change. Deriving these from doorbellForStride() rather than copying a
// literal is what keeps the two apart.
constexpr uint32_t kYuv420pDoorbellAddr = 0x300FF000u;
constexpr uint32_t kYuv420pPlxsAddr     = kYuv420pDoorbellAddr + kMboxOffsetStatus;
constexpr uint32_t kYuv420pPlxiAddr     = kYuv420pDoorbellAddr + kMboxOffsetInput;
constexpr uint32_t kYuv420pPlxmAddr     = kYuv420pDoorbellAddr + kMboxOffsetSdram;
constexpr uint32_t kYuv420pPlxfAddr     = kYuv420pDoorbellAddr + kMboxOffsetFrame;
constexpr uint32_t kYuv420pDiagAddr     = kYuv420pDoorbellAddr + kMboxOffsetSdramDiag;
constexpr uint32_t kYuv420pPlxdAddr     = kYuv420pDoorbellAddr + kMboxOffsetBank;

static_assert(kYuv420pDoorbellAddr == doorbellForStride(0x30000000u, 0x80000u),
              "YUV420p doorbell must follow the 0x80000 bank stride; it is written as a "
              "literal only so source-text gates can find it, not as an independent value");
static_assert(kYuv420pDoorbellAddr != kPlxkAddr,
              "the instantiated YUV window must stay distinct from the legacy default block");
static_assert(doorbellForStride(0x30000000u, 0x40000u) == kPlxkAddr,
              "the 0x3007F block must be the 0x40000-stride window");
static_assert(kPlxsAddr == kPlxkAddr + kMboxOffsetStatus, "PLXS offset drifted");
static_assert(kPlxiAddr == kPlxkAddr + kMboxOffsetInput, "PLXI offset drifted");
static_assert(kPlxmAddr == kPlxkAddr + kMboxOffsetSdram, "PLXM offset drifted");
static_assert(kPlxfAddr == kPlxkAddr + kMboxOffsetFrame, "PLXF offset drifted");
static_assert(kSdramDiagAddr == kPlxkAddr + kMboxOffsetSdramDiag, "DIAG offset drifted");
static_assert(kPlxdAddr == kPlxkAddr + kMboxOffsetBank, "PLXD offset drifted");

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
