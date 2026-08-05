#pragma once
// fabric_dma_host.hpp — RESEARCH-ONLY host helpers for PLXG/PLXH fabric kick.
//
// SoT: DESIGN_CARD_HOST_FABRIC_KICK_MAILBOX §2 write order + §4 ordering
//      DESIGN_CARD_FABRIC_STAGING_BRINGUP S4/S5
//      LAND_HOST_PLXG_ABI / integ phase2 kick RTL (ddr_publish_kick_mbox)
//
// Contract:
//   1) programFabricKick writes SRC/BANK/LEN then PLXG_HI then PLXG_LO magic
//      last (PLXK-style barriers). Does NOT ring PLXK.
//   2) waitFabricKickDone polls PLXH busy/done/err; still never rings PLXK.
//   3) Caller owns kickDdrDoorbell / PLXK AFTER done + payload barrier.
//   4) Product path stays OFF (kDdrPublishFabricPathEnabledInProduct=false).
//      sendDdrFrame hot path is NOT wired here.
//
// Lab enable (optional): MISTERPLEX_FABRIC_DMA=1 via fabricResearchPathEnvEnabled().
// Compile gate: helpers always available; product skip still requires PRODUCT_WIRE
// + fabric flag + successful PLXH (not this land).

#include "libmisterplex/ddr_zero_copy_ingest.hpp"
#include "libmisterplex/mailbox_abi_spec.hpp"

#include <cstddef>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <vector>

namespace misterplex {

// ---- Job / host state -------------------------------------------------------

struct FabricDmaJob {
    uint32_t src_phys = 0;
    uint32_t bank_phys = 0;
    uint32_t frame_bytes = 0;
    bool bank_sel = false;      // PLXG_HI bank_sel bit
    bool use_bank_sel = false;  // 1: RTL derives bank_phys from sel
    uint16_t cmd_seq = 0;       // host job id; must match PLXH.done_seq
};

enum class FabricStartMode {
    Toggle, // preferred: flip start_toggle (edge CDC)
    StartW, // level: start_w=1 (RTL accepts rising edge of start_w)
};

// Host-side sticky bits that must persist across kicks (toggle edge).
struct FabricKickHostState {
    bool last_start_toggle = false;
    uint16_t last_cmd_seq = 0;
};

enum class FabricKickWaitResult {
    Success,
    Timeout,
    ErrAlign,
    ErrTimeout,
    ErrBusyKick,
    MagicMissing,
    BusyStuck, // done_seq match missing while busy observed then stuck
    BadArgs,
};

inline const char* fabricKickWaitResultName(FabricKickWaitResult r) {
    switch (r) {
    case FabricKickWaitResult::Success:
        return "Success";
    case FabricKickWaitResult::Timeout:
        return "Timeout";
    case FabricKickWaitResult::ErrAlign:
        return "ErrAlign";
    case FabricKickWaitResult::ErrTimeout:
        return "ErrTimeout";
    case FabricKickWaitResult::ErrBusyKick:
        return "ErrBusyKick";
    case FabricKickWaitResult::MagicMissing:
        return "MagicMissing";
    case FabricKickWaitResult::BusyStuck:
        return "BusyStuck";
    case FabricKickWaitResult::BadArgs:
        return "BadArgs";
    }
    return "Unknown";
}

// Align contract mirrors ddr_frame_dma / kick mbox: 8B aligned non-zero len.
inline constexpr bool fabricKickAlignOk(uint32_t src_phys, uint32_t bank_phys,
                                        uint32_t frame_bytes) {
    return (src_phys & 7u) == 0u && (bank_phys & 7u) == 0u &&
           (frame_bytes & 7u) == 0u && frame_bytes != 0u;
}

// Optional lab runtime gate (default OFF). Product binary must still keep
// kDdrPublishFabricPathEnabledInProduct=false; this env alone never enables
// skip-memcpy in product sendDdrFrame (hot path not wired).
inline bool fabricResearchPathEnvEnabled() {
    const char* v = std::getenv("MISTERPLEX_FABRIC_DMA");
    if (!v || !v[0])
        return false;
    return v[0] == '1' && v[1] == '\0';
}

// ---- Abstract MMIO (mockable) -----------------------------------------------
// Offsets are doorbell-relative (same as mailbox_abi::kPlxg*).
// Implementations MUST NOT write PLXK (+0x000) from these helpers — callers
// own present doorbell after waitFabricKickDone succeeds.

struct FabricKickMemIo {
    virtual ~FabricKickMemIo() = default;
    virtual void write32(uint32_t doorbell_rel_off, uint32_t value) = 0;
    virtual uint32_t read32(uint32_t doorbell_rel_off) const = 0;
    virtual void barrier() = 0;
};

// In-process mock control page for unit tests (4 KiB page model).
// Records write order of (offset, value) for pack-order gates.
struct MockFabricKickMem : FabricKickMemIo {
    static constexpr size_t kPageBytes = 0x1000u;
    std::vector<uint32_t> words; // little-endian words over page
    struct WriteEvent {
        uint32_t off;
        uint32_t value;
    };
    std::vector<WriteEvent> write_log;
    unsigned barrier_count = 0;

    MockFabricKickMem() : words(kPageBytes / 4u, 0u) {}

    void write32(uint32_t doorbell_rel_off, uint32_t value) override {
        if (doorbell_rel_off + 4u > kPageBytes)
            return;
        write_log.push_back({doorbell_rel_off, value});
        words[doorbell_rel_off / 4u] = value;
    }

    uint32_t read32(uint32_t doorbell_rel_off) const override {
        if (doorbell_rel_off + 4u > kPageBytes)
            return 0u;
        return words[doorbell_rel_off / 4u];
    }

    void barrier() override { ++barrier_count; }

    // Seed PLXH status (FPGA→ARM) for waitFabricKickDone tests.
    void seedPlxh(uint32_t status_hi) {
        words[mailbox_abi::kPlxhOffset / 4u] = mailbox_abi::kPlxhMagic;
        words[(mailbox_abi::kPlxhOffset + 4u) / 4u] = status_hi;
    }

    void clearWriteLog() {
        write_log.clear();
        barrier_count = 0;
    }

    // True if any write touched PLXK present doorbell (+0x000..+0x007).
    bool wrotePlxk() const {
        for (const auto& e : write_log) {
            if (e.off < 8u)
                return true;
        }
        return false;
    }
};

// Volatile MMIO adapter for real /dev/mem doorbell page (lab path only).
// base points at doorbell_phys mapped byte*; never used in product hot path.
struct VolatileFabricKickMem : FabricKickMemIo {
    volatile uint32_t* base = nullptr; // doorbell page as u32*
    size_t map_bytes = 0;

    VolatileFabricKickMem() = default;
    VolatileFabricKickMem(volatile void* doorbell_page, size_t bytes)
        : base(reinterpret_cast<volatile uint32_t*>(doorbell_page)),
          map_bytes(bytes) {}

    void write32(uint32_t doorbell_rel_off, uint32_t value) override {
        if (!base || doorbell_rel_off + 4u > map_bytes)
            return;
        base[doorbell_rel_off / 4u] = value;
    }

    uint32_t read32(uint32_t doorbell_rel_off) const override {
        if (!base || doorbell_rel_off + 4u > map_bytes)
            return 0u;
        return base[doorbell_rel_off / 4u];
    }

    void barrier() override { __sync_synchronize(); }
};

// ---- Program kick (pack order) ----------------------------------------------
//
// ARM write order (DESIGN_CARD §2.1 + PLXK-style magic-last):
//   1) SRC_PHYS @ +0x148, BANK_PHYS @ +0x14C, FRAME_BYTES @ +0x150
//   2) barrier
//   3) PLXG_HI @ +0x144  (cmd_seq + start_toggle flip or start_w=1)
//   4) barrier
//   5) PLXG_LO @ +0x140  magic 0x504C5847  (LAST — same class as PLXK)
//
// FORBID: writing PLXK / ringing present doorbell from this helper.

inline bool programFabricKick(FabricKickMemIo& io, FabricKickHostState& st,
                              const FabricDmaJob& job,
                              FabricStartMode mode = FabricStartMode::Toggle,
                              bool require_align = true) {
    if (require_align &&
        !fabricKickAlignOk(job.src_phys, job.bank_phys, job.frame_bytes)) {
        return false;
    }

    // 1) Stable multi-bit job params first.
    io.write32(mailbox_abi::kPlxgSrcOffset, job.src_phys);
    io.write32(mailbox_abi::kPlxgBankPhysOffset, job.bank_phys);
    io.write32(mailbox_abi::kPlxgFrameBytesOffset, job.frame_bytes);

    // 2) Visibility before command sample.
    io.barrier();

    // 3) PLXG_HI: cmd_seq + start edge; never PLXK.
    mailbox_abi::PlxgCmdHi cmd;
    cmd.cmd_seq = job.cmd_seq;
    cmd.bank_sel = job.bank_sel;
    cmd.use_bank_sel = job.use_bank_sel;
    cmd.clr_done = false;
    cmd.clr_err = false;
    cmd.abort = false;
    if (mode == FabricStartMode::Toggle) {
        st.last_start_toggle = !st.last_start_toggle;
        cmd.start_toggle = st.last_start_toggle;
        cmd.start_w = false;
    } else {
        cmd.start_w = true;
        cmd.start_toggle = st.last_start_toggle; // hold prior toggle
    }
    const uint32_t hi = mailbox_abi::packPlxgCmdHi(cmd);
    io.write32(mailbox_abi::kPlxgOffset + 4u, hi);

    // 4) Barrier before magic commit.
    io.barrier();

    // 5) Magic LAST (PLXK-style): FPGA may treat magic+valid as live command.
    io.write32(mailbox_abi::kPlxgOffset, mailbox_abi::kPlxgMagic);
    io.barrier();

    st.last_cmd_seq = job.cmd_seq;
    return true;
}

// Clear done/err stickies (ARM W1C request via clr_done / clr_err).
// Does not start a job and does not ring PLXK.
inline void clearFabricKickDone(FabricKickMemIo& io, FabricKickHostState& st,
                                bool clr_err = true) {
    mailbox_abi::PlxgCmdHi cmd;
    cmd.cmd_seq = st.last_cmd_seq;
    cmd.start_w = false;
    cmd.start_toggle = st.last_start_toggle;
    cmd.clr_done = true;
    cmd.clr_err = clr_err;
    io.write32(mailbox_abi::kPlxgOffset + 4u, mailbox_abi::packPlxgCmdHi(cmd));
    io.barrier();
    io.write32(mailbox_abi::kPlxgOffset, mailbox_abi::kPlxgMagic);
    io.barrier();
}

// ---- Wait done (PLXH poll) --------------------------------------------------
//
// success: magic==PLXH && done_sticky && done_seq==cmd_seq && !err_* && !busy
// NEVER rings PLXK. Caller must barrier payload then kickDdrDoorbell.

inline FabricKickWaitResult waitFabricKickDone(FabricKickMemIo& io,
                                               uint16_t cmd_seq,
                                               unsigned max_polls = 10000u) {
    if (max_polls == 0u)
        return FabricKickWaitResult::BadArgs;

    bool saw_busy = false;
    for (unsigned i = 0; i < max_polls; ++i) {
        const uint32_t lo = io.read32(mailbox_abi::kPlxhOffset);
        const uint32_t hi = io.read32(mailbox_abi::kPlxhOffset + 4u);
        io.barrier();
        // Stable re-read (same class as PLXD/PLXS double-load).
        const uint32_t lo2 = io.read32(mailbox_abi::kPlxhOffset);
        const uint32_t hi2 = io.read32(mailbox_abi::kPlxhOffset + 4u);
        if (lo != lo2 || hi != hi2)
            continue;
        if (lo != mailbox_abi::kPlxhMagic)
            continue; // not published yet

        const auto st = mailbox_abi::unpackPlxhStatusHi(hi);
        if (st.busy)
            saw_busy = true;

        if (st.err_align)
            return FabricKickWaitResult::ErrAlign;
        if (st.err_timeout)
            return FabricKickWaitResult::ErrTimeout;
        if (st.err_busy_kick)
            return FabricKickWaitResult::ErrBusyKick;

        if (mailbox_abi::plxhStatusSuccess(st, cmd_seq))
            return FabricKickWaitResult::Success;

        // done_sticky with wrong seq while !busy → keep polling (stale).
        (void)saw_busy;
    }

    // Distinguish missing magic vs timeout after activity.
    const uint32_t lo_final = io.read32(mailbox_abi::kPlxhOffset);
    if (lo_final != mailbox_abi::kPlxhMagic)
        return FabricKickWaitResult::MagicMissing;
    if (saw_busy)
        return FabricKickWaitResult::BusyStuck;
    return FabricKickWaitResult::Timeout;
}

// Convenience: program + wait. Still never rings PLXK.
inline FabricKickWaitResult programAndWaitFabricKick(
    FabricKickMemIo& io, FabricKickHostState& st, const FabricDmaJob& job,
    FabricStartMode mode = FabricStartMode::Toggle,
    unsigned max_polls = 10000u, bool require_align = true) {
    if (!programFabricKick(io, st, job, mode, require_align))
        return FabricKickWaitResult::BadArgs;
    return waitFabricKickDone(io, job.cmd_seq, max_polls);
}

// Expected write offsets in programFabricKick success path (for unit tests).
// Order: SRC, BANK, LEN, HI, LO-magic.
inline constexpr uint32_t kFabricKickPackOffSrc = mailbox_abi::kPlxgSrcOffset;
inline constexpr uint32_t kFabricKickPackOffBank = mailbox_abi::kPlxgBankPhysOffset;
inline constexpr uint32_t kFabricKickPackOffLen = mailbox_abi::kPlxgFrameBytesOffset;
inline constexpr uint32_t kFabricKickPackOffHi = mailbox_abi::kPlxgOffset + 4u;
inline constexpr uint32_t kFabricKickPackOffLo = mailbox_abi::kPlxgOffset;

} // namespace misterplex
