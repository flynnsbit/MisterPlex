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
//   PLXF +0x118, DIAG +0x120, PLXD +0x128,
//   PLXC +0x130 (reserved), glass +0x138 (reserved),
//   PLXG +0x140 (fabric kick cmd), PLXH +0x158 (fabric status)
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
// PLXC +0x130 reserved RBF build-id; +0x138 reserved glass 16-bit extension
// (comment-only; not fabric). Host fabric kick ABI lands after those:
// PLXG +0x140..+0x157 (cmd + job params), PLXH +0x158..+0x15F (status).
constexpr uint32_t kPlxcReservedOffset = 0x130u; // RBF build-id (reserved)
constexpr uint32_t kGlassExtReservedOffset = 0x138u; // glass 16-bit (reserved)
constexpr uint32_t kPlxgOffset = 0x140u;           // PLXG_LO magic + PLXG_HI cmd
constexpr uint32_t kPlxgSrcOffset = 0x148u;        // SRC_PHYS[31:0]
constexpr uint32_t kPlxgBankPhysOffset = 0x14Cu;   // BANK_PHYS[31:0]
constexpr uint32_t kPlxgFrameBytesOffset = 0x150u; // FRAME_BYTES[31:0]
constexpr uint32_t kPlxgReservedPadOffset = 0x154u; // pad / future seq mirror
constexpr uint32_t kPlxhOffset = 0x158u;           // PLXH_LO magic + PLXH_HI status
// End of fabric kick block (inclusive last used byte = +0x15F).
constexpr uint32_t kPlxgPlxhSpanEndExclusive = 0x160u;

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
//   [47:36]  glass_vsync[11:0]   — bank_vsync_count LSBs (vsync free-run; NOT swaps)
//   [63:48]  frames_done[15:0]   — monotonic bank-swap counter (wraps at 65535)
//
// Semantics:
//   !swap_pending → free_bank_mask = disp_bank ? 0b01 : 0b10
//   swap_pending  → free_bank_mask = 0b00 (both banks in use)
//   On vsync swap: old disp_bank becomes free, frames_done++
//   On every vsync (swap or not): bank_vsync_count++ → glass_vsync field (12-bit)
// Full 16-bit glass counter needs a future extension word (e.g. +0x138); PLXC
// @ +0x130 is reserved for RBF build-id. 12-bit wrap ~68 s @60 Hz is enough
// for modular Δ-rate. NEVER put glass_vsync into frames_done (c5382bee class).
// Legacy absolute (example base only) — product live addr is doorbell+0x128:
constexpr uint32_t kPlxdAddr  = 0x3007F128u;
constexpr uint32_t kPlxdMagic = 0x504C5844u; // "PLXD"
// Bit-field positions (in the upper 32 bits, i.e. offset from bit 32):
constexpr unsigned kPlxdFreeBankMaskBit = 0;  // bits [33:32] → [1:0] of upper word
constexpr unsigned kPlxdFreeBankMaskWidth = 2;
constexpr unsigned kPlxdDispBankBit = 2;      // bit [34] → bit 2 of upper word
constexpr unsigned kPlxdSwapPendingBit = 3;   // bit [35] → bit 3 of upper word
constexpr unsigned kPlxdGlassVsyncBit = 4;    // bits [47:36] → [15:4] of upper word
constexpr unsigned kPlxdGlassVsyncWidth = 12;
constexpr unsigned kPlxdFramesDoneBit = 16;   // bits [63:48] → [31:16] of upper word
constexpr unsigned kPlxdFramesDoneWidth = 16;

// ---- Fabric publish kick / handshake (PHASE2 host ABI; RTL consumer later) ----
// Compact 32B control block at doorbell +0x140..+0x15F (RECOMMENDED packing):
//   +0x140  PLXG_LO   magic 0x504C5847 "PLXG"
//   +0x144  PLXG_HI   command word (start/toggle/clr/bank_sel/cmd_seq)
//   +0x148  SRC_PHYS  [31:0]
//   +0x14C  BANK_PHYS [31:0]
//   +0x150  FRAME_BYTES [31:0]
//   +0x154  RESERVED
//   +0x158  PLXH_LO   magic 0x504C5848 "PLXH"
//   +0x15C  PLXH_HI   status word (busy/done_sticky/err_*/done_seq)
// Host still owns PLXK after fabric done. Product fabric path hard OFF
// (kDdrPublishFabricPathEnabledInProduct=false). No RTL apply in host land.
// Literals for legacy example base — runtime: frameStoreMailboxPhys(doorbell, off).
constexpr uint32_t kPlxgAddr = 0x3007F140u;
constexpr uint32_t kPlxgMagic = 0x504C5847u; // "PLXG"
constexpr uint32_t kPlxhAddr = 0x3007F158u;
constexpr uint32_t kPlxhMagic = 0x504C5848u; // "PLXH"
// Multi-word data slots (legacy absolute examples; same offsets as kPlxg*).
constexpr uint32_t kPlxgSrcAddr = 0x3007F148u;
constexpr uint32_t kPlxgBankPhysAddr = 0x3007F14Cu;
constexpr uint32_t kPlxgFrameBytesAddr = 0x3007F150u;

// PLXG_HI command word bit positions (upper 32 of PLXG qword / word at +0x144).
constexpr unsigned kPlxgStartWBit = 0;       // host writes 1 to request start
constexpr unsigned kPlxgStartToggleBit = 1;  // preferred pulse CDC: edge on toggle
constexpr unsigned kPlxgClrDoneBit = 2;      // ARM W1C: clear done/err sticky
constexpr unsigned kPlxgClrErrBit = 3;       // optional separate err clear
constexpr unsigned kPlxgBankSelBit = 4;      // 0|1; must match bank_phys check
constexpr unsigned kPlxgUseBankSelBit = 5;   // 1: RTL derives bank_phys from sel
constexpr unsigned kPlxgAbortBit = 6;        // research: force idle if busy
// [15:7] reserved0
constexpr unsigned kPlxgCmdSeqBit = 16;      // [31:16] host-incremented job id
constexpr unsigned kPlxgCmdSeqWidth = 16;

// PLXH_HI status word bit positions (upper 32 of PLXH qword / word at +0x15C).
constexpr unsigned kPlxhBusyBit = 0;         // fabric job in flight
constexpr unsigned kPlxhDoneStickyBit = 1;   // set on done pulse; clr via clr_done
constexpr unsigned kPlxhErrAlignBit = 2;     // start with !align_ok
constexpr unsigned kPlxhErrTimeoutBit = 3;   // optional FPGA watchdog
constexpr unsigned kPlxhErrBusyKickBit = 4;  // start while busy ignored
constexpr unsigned kPlxhAcceptedBit = 5;     // job latched (debug)
// [15:6] reserved1
constexpr unsigned kPlxhDoneSeqBit = 16;     // [31:16] latches completed cmd_seq
constexpr unsigned kPlxhDoneSeqWidth = 16;

// PLXG command HI pack/unpack (host ABI only — no MMIO side effects here).
struct PlxgCmdHi {
    bool start_w = false;
    bool start_toggle = false;
    bool clr_done = false;
    bool clr_err = false;
    bool bank_sel = false;
    bool use_bank_sel = false;
    bool abort = false;
    uint16_t cmd_seq = 0;
};

inline constexpr uint32_t packPlxgCmdHi(const PlxgCmdHi& c) {
    return (c.start_w ? (1u << kPlxgStartWBit) : 0u) |
           (c.start_toggle ? (1u << kPlxgStartToggleBit) : 0u) |
           (c.clr_done ? (1u << kPlxgClrDoneBit) : 0u) |
           (c.clr_err ? (1u << kPlxgClrErrBit) : 0u) |
           (c.bank_sel ? (1u << kPlxgBankSelBit) : 0u) |
           (c.use_bank_sel ? (1u << kPlxgUseBankSelBit) : 0u) |
           (c.abort ? (1u << kPlxgAbortBit) : 0u) |
           ((static_cast<uint32_t>(c.cmd_seq) &
             ((1u << kPlxgCmdSeqWidth) - 1u))
            << kPlxgCmdSeqBit);
}

inline constexpr PlxgCmdHi unpackPlxgCmdHi(uint32_t hi) {
    PlxgCmdHi c;
    c.start_w = ((hi >> kPlxgStartWBit) & 1u) != 0;
    c.start_toggle = ((hi >> kPlxgStartToggleBit) & 1u) != 0;
    c.clr_done = ((hi >> kPlxgClrDoneBit) & 1u) != 0;
    c.clr_err = ((hi >> kPlxgClrErrBit) & 1u) != 0;
    c.bank_sel = ((hi >> kPlxgBankSelBit) & 1u) != 0;
    c.use_bank_sel = ((hi >> kPlxgUseBankSelBit) & 1u) != 0;
    c.abort = ((hi >> kPlxgAbortBit) & 1u) != 0;
    c.cmd_seq = static_cast<uint16_t>(
        (hi >> kPlxgCmdSeqBit) & ((1u << kPlxgCmdSeqWidth) - 1u));
    return c;
}

// PLXH status HI pack/unpack.
struct PlxhStatusHi {
    bool busy = false;
    bool done_sticky = false;
    bool err_align = false;
    bool err_timeout = false;
    bool err_busy_kick = false;
    bool accepted = false;
    uint16_t done_seq = 0;
};

inline constexpr uint32_t packPlxhStatusHi(const PlxhStatusHi& s) {
    return (s.busy ? (1u << kPlxhBusyBit) : 0u) |
           (s.done_sticky ? (1u << kPlxhDoneStickyBit) : 0u) |
           (s.err_align ? (1u << kPlxhErrAlignBit) : 0u) |
           (s.err_timeout ? (1u << kPlxhErrTimeoutBit) : 0u) |
           (s.err_busy_kick ? (1u << kPlxhErrBusyKickBit) : 0u) |
           (s.accepted ? (1u << kPlxhAcceptedBit) : 0u) |
           ((static_cast<uint32_t>(s.done_seq) &
             ((1u << kPlxhDoneSeqWidth) - 1u))
            << kPlxhDoneSeqBit);
}

inline constexpr PlxhStatusHi unpackPlxhStatusHi(uint32_t hi) {
    PlxhStatusHi s;
    s.busy = ((hi >> kPlxhBusyBit) & 1u) != 0;
    s.done_sticky = ((hi >> kPlxhDoneStickyBit) & 1u) != 0;
    s.err_align = ((hi >> kPlxhErrAlignBit) & 1u) != 0;
    s.err_timeout = ((hi >> kPlxhErrTimeoutBit) & 1u) != 0;
    s.err_busy_kick = ((hi >> kPlxhErrBusyKickBit) & 1u) != 0;
    s.accepted = ((hi >> kPlxhAcceptedBit) & 1u) != 0;
    s.done_seq = static_cast<uint16_t>(
        (hi >> kPlxhDoneSeqBit) & ((1u << kPlxhDoneSeqWidth) - 1u));
    return s;
}

// Poll success contract (host): magic==PLXH && done_sticky && done_seq==cmd_seq
// && !err_align && !busy. Implemented as pure predicate for unit tests / future path.
inline constexpr bool plxhStatusSuccess(const PlxhStatusHi& s, uint16_t cmd_seq) {
    return s.done_sticky && !s.busy && !s.err_align && !s.err_timeout &&
           !s.err_busy_kick && s.done_seq == cmd_seq;
}

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
    {"PLXG", kPlxgMagic},
    {"PLXH", kPlxhMagic},
}};

// ---- All addressed mailboxes (for address-collision detection) ----
// Every occupied DDR mailbox slot. Gate rejects overlapping addresses.
// PLXG size covers cmd qword + SRC/BANK/LEN/pad (0x140..0x157 = 24 B).
// PLXH is the status qword (0x158..0x15F = 8 B).
constexpr std::array<MailboxEntry, 10> kAllMailboxes = {{
    {"PLXK", kPlxkAddr,     kPlxkMagic,     8,  "arm_to_fpga",  true},
    {"PLXS", kPlxsAddr,     kPlxsMagic,     8,  "fpga_to_arm",  true},
    {"PLXI", kPlxiAddr,     kPlxiMagic,     8,  "fpga_to_arm",  true},
    {"PLXM", kPlxmAddr,     kPlxmMagic,     8,  "fpga_to_arm",  true},
    {"PLXF", kPlxfAddr,     kPlxfMagic,     8,  "fpga_to_arm",  true},
    {"DIAG", kSdramDiagAddr, 0,             8,  "fpga_to_arm",  false},
    {"PLXD", kPlxdAddr,     kPlxdMagic,     8,  "fpga_to_arm",  true},
    {"PLXG", kPlxgAddr,     kPlxgMagic,     24, "arm_to_fpga",  true},
    {"PLXH", kPlxhAddr,     kPlxhMagic,     8,  "fpga_to_arm",  true},
    {"PLXB", kPlxbAddr,     kPlxbMagic,     8,  "arm_to_fpga",  true},
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
