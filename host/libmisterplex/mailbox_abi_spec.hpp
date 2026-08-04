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
//   PLXF +0x118, DIAG +0x120, PLXD +0x128, PLXC +0x130, PLXO +0x138, list +0x140
//   PLXG +0x800  (FIXED present-geometry slot — independent of MAX_CMDS; MUST NOT use +0x130)
// Product 480p YUV doorbell is 0x300FF000 → PLXD live at 0x300FF128.
// PLXC/PLXG fabric bootstrap is FIXED on that product page (chicken-egg safe
// when Option-C moves the *frame* doorbell to 0x3047F000).
//
// The 0x3007F000 family below is the *packed-320 example map only* — NOT the
// product YUV legacy base and NOT what plex_chrome_ddr_loader polls. Consumers
// MUST resolve via frameStoreMailboxPhys(doorbell, offset). Never hard-read
// packed-320 absolute PLXD/PLXF against a product doorbell (bank0 padding /
// residue → bank desync; parent green-cast class on c5382bee).

// Byte offsets from DOORBELL_PHYS (single source for ARM + invariant gates).
constexpr uint32_t kPlxkOffset = 0x000u;
constexpr uint32_t kPlxsOffset = 0x100u;
constexpr uint32_t kPlxiOffset = 0x108u;
constexpr uint32_t kPlxmOffset = 0x110u;
constexpr uint32_t kPlxfOffset = 0x118u;
constexpr uint32_t kSdramDiagOffset = 0x120u;
constexpr uint32_t kPlxdOffset = 0x128u;
// plex_chrome semantic list (ARM→FPGA) and HDMI mirror (FPGA→ARM).
// Doorbell-relative only — fabric bootstrap uses product door below.
constexpr uint32_t kPlxcOffset = 0x130u;
constexpr uint32_t kPlxoOffset = 0x138u;
constexpr uint32_t kPlxlOffset = 0x140u; // list payload base (64-bit cmds)
// List depth must match plex_chrome_cmds::kMaxCmds / RTL MAX_CMDS (112).
// 112 × 8B = 0x380 → +0x140 .. +0x4BF. Room to grow until PLXG.
//
// PLXG is a FIXED wire ABI at +0x800 — NOT derived from list depth.
// (Parent freeze: UI tuning must not relocate present-geometry mailbox.)
constexpr uint32_t kPlxcListMaxCmds = 112u;
constexpr uint32_t kPlxgOffset = 0x800u; // FIXED — do not re-derive from MAX_CMDS
// HARD RULE: PLXG must never be placed at kPlxcOffset (0x130). PLXC owns it.
// HARD RULE: chrome list must not grow into PLXG (bound, not equality).

// ---- Doorbell bases (three distinct maps — do not conflate) ----
// Packed-320 historical example (table absolutes below). NOT product YUV.
constexpr uint32_t kPacked320ExampleDoorbellPhys = 0x3007F000u;
// Alias kept for older call sites; means packed-320 example, not product.
constexpr uint32_t kLegacyFrameStoreDoorbellPhys = kPacked320ExampleDoorbellPhys;
// Product 480p YUV — fabric PLXC/PLXG bootstrap + shipping frame doorbell.
constexpr uint32_t kProductYuv480pDoorbellPhys = 0x300FF000u;
// Option-C 720p frame doorbell (banks at 0x30180000). PLXC fabric stays on product.
constexpr uint32_t kOptionC720pDoorbellPhys = 0x3047F000u;

inline constexpr uint32_t frameStoreMailboxPhys(uint32_t doorbell_phys, uint32_t offset) {
    return doorbell_phys + offset;
}

// Fabric chrome bootstrap absolutes (product door + offset). Loader default.
constexpr uint32_t kPlxcBootstrapPhys =
    frameStoreMailboxPhys(kProductYuv480pDoorbellPhys, kPlxcOffset); // 0x300FF130
constexpr uint32_t kPlxoBootstrapPhys =
    frameStoreMailboxPhys(kProductYuv480pDoorbellPhys, kPlxoOffset); // 0x300FF138
constexpr uint32_t kPlxlBootstrapPhys =
    frameStoreMailboxPhys(kProductYuv480pDoorbellPhys, kPlxlOffset); // 0x300FF140
constexpr uint32_t kPlxgBootstrapPhys =
    frameStoreMailboxPhys(kProductYuv480pDoorbellPhys, kPlxgOffset); // 0x300FF800

// Absolute addresses for the packed-320 *example* base — table/collision gates only.
// Literals (not base+offset expressions) so static parsers in test_rtl_invariants
// can resolve them. Must equal kPacked320ExampleDoorbellPhys + k*Offset.
// Runtime ARM frame paths: frameStoreMailboxPhys(ddrLayout_.doorbell_phys, …).
// Runtime ARM chrome list: bootstrap product door (kPlxcBootstrapPhys family).
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
// Packed-320 example absolute only — product live PLXD is doorbell+0x128
// (0x300FF128 on product YUV, 0x3047F128 on Option-C):
constexpr uint32_t kPlxdAddr  = 0x3007F128u;
constexpr uint32_t kPlxdMagic = 0x504C5844u; // "PLXD"

// PLXC — Chrome list control (ARM→FPGA). Semantic cmds only; fabric owns scale.
// Layout (64-bit LE): [31:0] magic "PLXC", [32] enable, [33] reserved,
// [47:34] cmd_count, [63:48] seq. List payload at doorbell+0x140.
// Seqlock publish (required): clear magic → write list body → write ctrl HIGH
// half (enable/count/seq) → DMB → write magic LOW last. Magic-then-hi is a
// hole: fabric can re-read stable magic + stale/zero hi and accept empty/old
// control. Fabric re-reads full PLXC after body; mismatch/missing magic aborts.
// Fabric polls bootstrap product page (kPlxcBootstrapPhys), not packed-320.
constexpr uint32_t kPlxcAddr  = 0x3007F130u; // packed-320 example table only
constexpr uint32_t kPlxcMagic = 0x504C5843u; // "PLXC"

// PLXO — Chrome telemetry (FPGA→ARM). Applied HDMI_W/H mirror + chrome_hw.
constexpr uint32_t kPlxoAddr  = 0x3007F138u; // packed-320 example table only
constexpr uint32_t kPlxoMagic = 0x504C584Fu; // "PLXO"

// PLXG — Present / glass geometry (ARM→FPGA). Coded + display window for scaler.
// FIXED offset +0x800 (parent ABI freeze). Magic "PLXG". w-scaler/w-mem; not w-osd.
// History: +0x2C0 @48-cmd, briefly +0x4C0 when list grew with MAX_CMDS — frozen off that.
// Live bootstrap: kPlxgBootstrapPhys (0x300FF800). kPlxgAddr is packed-320 example.
constexpr uint32_t kPlxgAddr  = 0x3007F800u; // packed-320 example + FIXED 0x800
constexpr uint32_t kPlxgMagic = 0x504C5847u; // "PLXG"
static_assert(kPlxcBootstrapPhys == 0x300FF130u, "PLXC bootstrap product page");
static_assert(kPlxgBootstrapPhys == 0x300FF800u, "PLXG bootstrap product page");
static_assert(kProductYuv480pDoorbellPhys != kPacked320ExampleDoorbellPhys,
              "product YUV door must not equal packed-320 example");
static_assert(kOptionC720pDoorbellPhys != kProductYuv480pDoorbellPhys,
              "Option-C door must not equal product bootstrap");
static_assert(kPlxgOffset != kPlxcOffset, "PLXG must not collide with PLXC +0x130");
static_assert(kPlxgOffset == 0x800u, "PLXG wire ABI is FIXED at +0x800");
// Bound only: list may leave a hole before PLXG; it must not overrun into PLXG.
static_assert(kPlxlOffset + kPlxcListMaxCmds * 8u <= kPlxgOffset,
              "chrome list must not grow into fixed PLXG +0x800");
static_assert(kPlxcListMaxCmds == 112u, "list depth must match kMaxCmds/RTL MAX_CMDS");
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

constexpr std::array<MagicEntry, 10> kAllMagics = {{
    {"PLXK", kPlxkMagic},
    {"PLXS", kPlxsMagic},
    {"PLXI", kPlxiMagic},
    {"PLXM", kPlxmMagic},
    {"PLXF", kPlxfMagic},
    {"PLXD", kPlxdMagic},
    {"PLXB", kPlxbMagic},
    {"PLXC", kPlxcMagic},
    {"PLXO", kPlxoMagic},
    {"PLXG", kPlxgMagic},
}};

// ---- All addressed mailboxes (for address-collision detection) ----
// Every occupied DDR mailbox slot. Gate rejects overlapping addresses.
constexpr std::array<MailboxEntry, 11> kAllMailboxes = {{
    {"PLXK", kPlxkAddr,     kPlxkMagic,     8, "arm_to_fpga",  true},
    {"PLXS", kPlxsAddr,     kPlxsMagic,     8, "fpga_to_arm",  true},
    {"PLXI", kPlxiAddr,     kPlxiMagic,     8, "fpga_to_arm",  true},
    {"PLXM", kPlxmAddr,     kPlxmMagic,     8, "fpga_to_arm",  true},
    {"PLXF", kPlxfAddr,     kPlxfMagic,     8, "fpga_to_arm",  true},
    {"DIAG", kSdramDiagAddr, 0,             8, "fpga_to_arm",  false},
    {"PLXD", kPlxdAddr,     kPlxdMagic,     8, "fpga_to_arm",  true},
    {"PLXC", kPlxcAddr,     kPlxcMagic,     8, "arm_to_fpga",  true},
    {"PLXO", kPlxoAddr,     kPlxoMagic,     8, "fpga_to_arm",  true},
    {"PLXG", kPlxgAddr,     kPlxgMagic,     8, "arm_to_fpga",  true},
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
