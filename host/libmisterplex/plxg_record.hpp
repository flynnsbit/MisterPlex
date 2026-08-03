#pragma once
// PLXG 5-qword atomic geometry record — lockstep with present_geom_latch.sv.
//
// Offset: doorbell + 0x2C0 (NOT +0x130 — PLXC chrome ctrl owns +0x130).
// Bootstrap phys: product legacy doorbell 0x300FF000 + 0x2C0 = 0x300FF2C0.
// Fabric poller always reads the bootstrap page (chicken-egg with Option-C).
//
// Write model — seqlock (rd-duck retained-DDR/reset + ABA):
//   0) Read retained q0 seq (magic-valid); next seq = max(sw,retained)+1
//      Commit seq MUST differ from retained — invalidate alone is insufficient:
//      FPGA reset last_seq=0 + daemon restart emitting same seq1 lets poller
//      sample q0=1, host update body, recommit q0=1; reread matches → torn ABA.
//   1) Invalidate q0 low32 = 0 (clear magic) + DMB
//   2) Store body q[1]..q[4]
//   3) Store q0 high32, then q0 low32 = magic LAST (commit)
//   Poller reads q0..q4 then RE-READS q0; commit only if magic+seq match.
// Without step 1, post-reset last_seq=0 + retained q0 seq=1 lets the poller
// accept a mixed body while reread still sees the old q0. Never three temporal
// beats to one slot. Legacy path must publish geom_enable=0.

#include "libmisterplex/mailbox_abi_spec.hpp"

#include <cstdint>
#include <cstring>

namespace misterplex {

// Forward decls — keep call order independent of definition order (rd-duck:
// plxgRawGeomOk must not compile-fail if helpers are reordered in this header).
inline bool plxgGeomDimsOk(int codedW, int codedH, int yStride, int chromaStride);
inline bool plxgRawGeomOk(int codedW, int codedH, int yStride, int chromaStride,
                          int maxW = 1280, int maxH = 720);

constexpr uint32_t kPlxgRecordQwords = 5u;
constexpr uint32_t kPlxgRecordBytes = kPlxgRecordQwords * 8u; // 40

// Bit pack matches present_geom_latch.sv shadow decode.
struct PlxgRecord {
    uint64_t q[kPlxgRecordQwords]{};
    uint16_t seq = 0;
    bool valid = false;
};

// Body indices after q0 invalidate; q0 commit is separate (magic-last).
inline constexpr int kPlxgBodyOrder[4] = {1, 2, 3, 4};
// Legacy name: body then logical q0 slot (invalidate is step 0, not in this list).
inline constexpr int kPlxgPublishOrder[5] = {1, 2, 3, 4, 0};

inline uint64_t packPlxgQ0(bool winEnable, bool geomEnable, uint16_t seq) {
    uint64_t hi = 0;
    if (winEnable)
        hi |= 1ull << 0; // bit 32
    if (geomEnable)
        hi |= 1ull << 1; // bit 33
    hi |= (static_cast<uint64_t>(seq) << 16); // bits 63:48 → hi[31:16]
    return (hi << 32) | static_cast<uint64_t>(mailbox_abi::kPlxgMagic);
}

inline uint64_t packPlxgQ1(int contentW, int contentH, int x0, int y0) {
    const uint64_t w = static_cast<uint64_t>(contentW) & 0x7FFu;
    const uint64_t h = static_cast<uint64_t>(contentH) & 0x7FFu;
    const uint64_t x = static_cast<uint64_t>(x0) & 0x7FFu;
    const uint64_t y = static_cast<uint64_t>(y0) & 0x7FFu;
    // [10:0]w [26:16]h [42:32]x0 [58:48]y0
    return w | (h << 16) | (x << 32) | (y << 48);
}

inline uint64_t packPlxgQ2(int hDe, int vDe, int codedW, int codedH) {
    const uint64_t hd = static_cast<uint64_t>(hDe) & 0x7FFu;
    const uint64_t vd = static_cast<uint64_t>(vDe) & 0x7FFu;
    const uint64_t cw = static_cast<uint64_t>(codedW) & 0x7FFu;
    const uint64_t ch = static_cast<uint64_t>(codedH) & 0x7FFu;
    return hd | (vd << 16) | (cw << 32) | (ch << 48);
}

inline uint64_t packPlxgQ3(int yStride, int chromaStride, int displayW, int displayH) {
    const uint64_t ys = static_cast<uint64_t>(yStride) & 0xFFFu;
    const uint64_t cs = static_cast<uint64_t>(chromaStride) & 0x7FFu;
    const uint64_t dw = static_cast<uint64_t>(displayW) & 0x7FFu;
    const uint64_t dh = static_cast<uint64_t>(displayH) & 0x7FFu;
    return ys | (cs << 16) | (dw << 32) | (dh << 48);
}

inline uint64_t packPlxgQ4(int presentX, int presentY, int cropLeft, int cropTop) {
    const uint64_t px = static_cast<uint64_t>(presentX) & 0x7FFu;
    const uint64_t py = static_cast<uint64_t>(presentY) & 0x7FFu;
    const uint64_t cl = static_cast<uint64_t>(cropLeft) & 0x7FFu;
    const uint64_t ct = static_cast<uint64_t>(cropTop) & 0x7FFu;
    return px | (py << 16) | (cl << 32) | (ct << 48);
}

// Product 960×540 storage → Option-C canvas DE 1280×720, native_push geom.
inline PlxgRecord makePlxgRecord960x540Native(uint16_t seq) {
    PlxgRecord r{};
    r.seq = seq;
    // STORAGE dims in coded/stride/display fields so ddr_frame_store plane bases
    // match native_push (U@518400). DE canvas is h_de/v_de = 1280×720.
    r.q[0] = packPlxgQ0(/*win*/ true, /*geom*/ true, seq);
    r.q[1] = packPlxgQ1(/*cw*/ 960, /*ch*/ 540, /*x0*/ 0, /*y0*/ 0);
    r.q[2] = packPlxgQ2(/*h_de*/ 1280, /*v_de*/ 720, /*coded*/ 960, /*ch*/ 540);
    r.q[3] = packPlxgQ3(/*y*/ 960, /*c*/ 480, /*dw*/ 960, /*dh*/ 540);
    r.q[4] = packPlxgQ4(/*px*/ 0, /*py*/ 0, /*cl*/ 0, /*ct*/ 0);
    r.valid = true;
    return r;
}

// Mode-exit / legacy publish: geom_enable=0 so ddr_frame_store leaves Option-C.
// Seq MUST change vs last committed (caller / writePlxgRecord bumps).
inline PlxgRecord makePlxgRecordDisable(uint16_t seq) {
    PlxgRecord r{};
    r.seq = seq;
    r.q[0] = packPlxgQ0(/*win*/ false, /*geom*/ false, seq);
    r.q[1] = 0;
    r.q[2] = 0;
    r.q[3] = 0;
    r.q[4] = 0;
    r.valid = true;
    return r;
}

// Decode seq from a packed q0 qword (bits 63:48). 0 if magic invalid.
inline bool plxgQ0Seq(uint64_t q0, uint16_t* seqOut) {
    if (static_cast<uint32_t>(q0) != mailbox_abi::kPlxgMagic)
        return false;
    if (seqOut)
        *seqOut = static_cast<uint16_t>(q0 >> 48);
    return true;
}

// Restart-safe next seq (rd-duck): software last alone is not enough — after
// daemon/FpgaSpi reconstruct, plxgLastSeq_=0 while FPGA last_seq and retained
// DDR q0 may still be N. If N==1 the naive useSeq=1 is rejected as stale and a
// single mode-disable never commits. Seed from max(softwareLast, retainedSeq)
// when retained q0 magic is valid, then +1 (skip 0).
inline uint16_t plxgNextSeq(uint16_t softwareLast, bool retainedValid,
                            uint16_t retainedSeq) {
    uint32_t seed = softwareLast;
    if (retainedValid) {
        // Both are 16-bit counters; without a full ACK ring take the larger
        // numerical seed so a cold software object catches up to live FPGA/DDR.
        // (Wrap: if retained=0xFFFF and software=0 after many wraps, +1→1 still
        // differs from 0xFFFF so the poller accepts.)
        if (static_cast<uint32_t>(retainedSeq) > seed)
            seed = retainedSeq;
    }
    uint16_t use = static_cast<uint16_t>(seed + 1u);
    if (use == 0)
        use = 1;
    return use;
}

// FAULT twin: ignore retained DDR (pre-fix writePlxgRecord).
inline uint16_t plxgNextSeqFaultIgnoreRetained(uint16_t softwareLast) {
    return plxgNextSeq(softwareLast, /*retainedValid=*/false, 0);
}

// Host-side model of poller tear check: after q0..q4 snap, q0 must still match.
inline bool plxgPollerAcceptsSnapshot(const uint64_t snap[5], uint64_t q0_reread,
                                      uint16_t lastSeq) {
    if (static_cast<uint32_t>(snap[0]) != mailbox_abi::kPlxgMagic)
        return false;
    const uint16_t seq = static_cast<uint16_t>(snap[0] >> 48);
    if (seq == lastSeq)
        return false;
    return q0_reread == snap[0];
}

// Read one little-endian qword from control page at PLXG slot qi.
inline uint64_t plxgCtrlLoadQ(const uint8_t* ctrlPage, int qi) {
    uint64_t w = 0;
    std::memcpy(&w, ctrlPage + mailbox_abi::kPlxgOffset + static_cast<size_t>(qi) * 8u, 8);
    return w;
}

inline void plxgCtrlStoreQ(uint8_t* ctrlPage, int qi, uint64_t w) {
    std::memcpy(ctrlPage + mailbox_abi::kPlxgOffset + static_cast<size_t>(qi) * 8u, &w, 8);
}

// Step 1: invalidate retained q0 magic (low32=0). Poller must reject in-progress.
inline void plxgHostInvalidateQ0(uint8_t* ctrlPage) {
    const size_t off = mailbox_abi::kPlxgOffset;
    // Little-endian qword: clear low32 (magic) only; high may be stale until commit.
    std::memset(ctrlPage + off, 0, 4);
}

// Step 2: body q1..q4.
inline void plxgHostStoreBody(uint8_t* ctrlPage, const PlxgRecord& rec) {
    for (int k = 0; k < 4; ++k) {
        const int qi = kPlxgBodyOrder[k];
        plxgCtrlStoreQ(ctrlPage, qi, rec.q[qi]);
    }
}

// Step 3: q0 high then magic-last low32 (commit).
inline void plxgHostCommitQ0(uint8_t* ctrlPage, uint64_t q0) {
    const size_t off = mailbox_abi::kPlxgOffset;
    const uint32_t lo = static_cast<uint32_t>(q0);
    const uint32_t hi = static_cast<uint32_t>(q0 >> 32);
    std::memcpy(ctrlPage + off + 4, &hi, 4); // high first
    std::memcpy(ctrlPage + off + 0, &lo, 4); // magic last
}

// Full seqlock write (matches writePlxgRecord).
inline void plxgHostStoreAtomic(uint8_t* ctrlPage, const PlxgRecord& rec) {
    plxgHostInvalidateQ0(ctrlPage);
    plxgHostStoreBody(ctrlPage, rec);
    plxgHostCommitQ0(ctrlPage, rec.q[0]);
}

// Read retained q0 seq from control page (before invalidate). Magic required.
inline bool plxgCtrlLoadRetainedSeq(const uint8_t* ctrlPage, uint16_t* seqOut) {
    return plxgQ0Seq(plxgCtrlLoadQ(ctrlPage, 0), seqOut);
}

// FAULT twin: body then q0 without invalidate — retained-DDR/reset accepts torn.
inline void plxgHostStoreFaultNoInvalidate(uint8_t* ctrlPage, const PlxgRecord& rec) {
    plxgHostStoreBody(ctrlPage, rec);
    plxgHostCommitQ0(ctrlPage, rec.q[0]);
}

// Poller one-shot snapshot model (q0..q4 then reread q0).
inline bool plxgPollerTryCommit(const uint8_t* ctrlPage, uint16_t lastSeq,
                                uint64_t snapOut[5] = nullptr) {
    uint64_t snap[5];
    for (int i = 0; i < 5; ++i)
        snap[i] = plxgCtrlLoadQ(ctrlPage, i);
    const uint64_t q0b = plxgCtrlLoadQ(ctrlPage, 0); // reread
    if (snapOut) {
        for (int i = 0; i < 5; ++i)
            snapOut[i] = snap[i];
    }
    return plxgPollerAcceptsSnapshot(snap, q0b, lastSeq);
}

// Model writePlxgRecord seq selection + seqlock publish (daemon-object restart).
// softwareLast models plxgLastSeq_ on a (possibly new) FpgaSpi instance.
// Returns committed seq; updates *softwareLastInOut like plxgLastSeq_.
inline uint16_t plxgHostWriteRecordRestartSafe(uint8_t* ctrlPage, PlxgRecord rec,
                                               uint16_t* softwareLastInOut,
                                               bool honorRetained = true) {
    uint16_t retained = 0;
    const bool have = honorRetained && plxgCtrlLoadRetainedSeq(ctrlPage, &retained);
    const uint16_t sw = softwareLastInOut ? *softwareLastInOut : 0;
    const uint16_t use =
        honorRetained ? plxgNextSeq(sw, have, retained) : plxgNextSeqFaultIgnoreRetained(sw);
    const uint64_t flags = (rec.q[0] >> 32) & 0xFFFFull;
    rec.q[0] = (static_cast<uint64_t>(use) << 48) | (flags << 32) |
               static_cast<uint64_t>(mailbox_abi::kPlxgMagic);
    rec.seq = use;
    plxgHostStoreAtomic(ctrlPage, rec);
    if (softwareLastInOut)
        *softwareLastInOut = use;
    return use;
}

// Daemon restart + FPGA still live: retained q0 seq=N, FPGA last_seq=N,
// new software object last=0, one disable publish must commit (seq != N).
inline bool plxgDaemonRestartDisableCommits(uint16_t liveSeq, bool honorRetained) {
    std::uint8_t page[0x1000]{};
    const PlxgRecord live = makePlxgRecord960x540Native(liveSeq);
    for (int i = 0; i < 5; ++i)
        plxgCtrlStoreQ(page, i, live.q[i]);
    uint16_t swLast = 0; // new FpgaSpi
    const PlxgRecord dis = makePlxgRecordDisable(1); // advisory seq ignored
    const uint16_t used =
        plxgHostWriteRecordRestartSafe(page, dis, &swLast, honorRetained);
    return plxgPollerTryCommit(page, /*lastSeq=*/liveSeq) && used != liveSeq &&
           swLast == used;
}

// Retained-DDR / FPGA-reset interleaving oracle.
// old rec seq=1 live in DDR; FPGA last_seq=0; host rewrites to new rec mid-poll.
// FAULT (no invalidate): poller can accept mixed body under old q0.
// GOOD (invalidate first): same window rejects.
inline bool plxgRetainedDdrResetTornAcceptedWithFaultWriter(const PlxgRecord& oldRec,
                                                            const PlxgRecord& newRec) {
    std::uint8_t page[0x1000]{};
    // Install complete old record (retained DDR across FPGA reset).
    for (int i = 0; i < 5; ++i)
        plxgCtrlStoreQ(page, i, oldRec.q[i]);
    // Host FAULT path starts body rewrite without invalidating q0.
    plxgHostStoreBody(page, newRec); // q0 still old valid seq
    // Poller after FPGA reset (last_seq=0): sees old q0 + new body, reread old q0.
    uint64_t snap[5];
    for (int i = 0; i < 5; ++i)
        snap[i] = plxgCtrlLoadQ(page, i);
    // q0 still old (host has not committed new q0 yet)
    return plxgPollerAcceptsSnapshot(snap, snap[0], /*lastSeq=*/0);
}

inline bool plxgRetainedDdrResetRejectedWithSeqlockWriter(const PlxgRecord& oldRec,
                                                          const PlxgRecord& newRec) {
    std::uint8_t page[0x1000]{};
    for (int i = 0; i < 5; ++i)
        plxgCtrlStoreQ(page, i, oldRec.q[i]);
    // GOOD: invalidate q0 first, then body — poller mid-update must not accept.
    plxgHostInvalidateQ0(page);
    plxgHostStoreBody(page, newRec);
    uint64_t snap[5];
    for (int i = 0; i < 5; ++i)
        snap[i] = plxgCtrlLoadQ(page, i);
    // First q0 sample has magic cleared → reject; reread also invalid.
    if (plxgPollerAcceptsSnapshot(snap, snap[0], /*lastSeq=*/0))
        return false; // should have rejected
    // After full commit, accept once.
    plxgHostCommitQ0(page, newRec.q[0]);
    return plxgPollerTryCommit(page, /*lastSeq=*/0);
}

// ABA tear (rd-duck): FPGA reset → poller last_seq=0; retained q0 still seq=1.
// Poller samples q0=seq1, then host invalidate+new body+recommit *bit-identical*
// q0 (same seq and flags). q0 reread matches first sample despite mixed body —
// invalidation alone is NOT enough; commit seq MUST differ from retained q0.
// Returns true if FAULT same-q0 recommit accepts torn snapshot.
inline bool plxgAbaSameSeqRecommitAcceptsTorn(uint16_t retainedSeq = 1) {
    std::uint8_t page[0x1000]{};
    const PlxgRecord oldR = makePlxgRecord960x540Native(retainedSeq);
    for (int i = 0; i < 5; ++i)
        plxgCtrlStoreQ(page, i, oldR.q[i]);
    // Poller (post FPGA reset, last_seq=0) samples q0 first.
    const uint64_t snap0 = plxgCtrlLoadQ(page, 0);
    uint16_t s0 = 0;
    if (!plxgQ0Seq(snap0, &s0) || s0 != retainedSeq)
        return false;
    // Host FAULT: body rewrite under seqlock but recommit identical q0 word
    // (daemon restart reusing seq1 without bump — ABA).
    PlxgRecord neu = makePlxgRecordDisable(retainedSeq);
    // Keep neu body; force q0 bit-identical to retained (seq+flags).
    neu.q[0] = oldR.q[0];
    plxgHostInvalidateQ0(page);
    plxgHostStoreBody(page, neu);
    plxgHostCommitQ0(page, neu.q[0]); // == snap0
    // Poller finishes: body is disable, q0 reread equals snap0 (ABA).
    uint64_t snap[5];
    snap[0] = snap0;
    for (int i = 1; i < 5; ++i)
        snap[i] = plxgCtrlLoadQ(page, i);
    const uint64_t q0b = plxgCtrlLoadQ(page, 0);
    // Body must actually differ or this is not a tear.
    if (snap[1] == oldR.q[1] && snap[2] == oldR.q[2])
        return false;
    return plxgPollerAcceptsSnapshot(snap, q0b, /*lastSeq=*/0);
}

// GOOD twin: same interleaving, but commit seq = retained+1. Poller that already
// sampled old q0 sees reread mismatch → reject torn; a fresh poll then commits.
inline bool plxgAbaIncrementSeqRejectsTornThenFreshCommits(uint16_t retainedSeq = 1) {
    std::uint8_t page[0x1000]{};
    const PlxgRecord oldR = makePlxgRecord960x540Native(retainedSeq);
    for (int i = 0; i < 5; ++i)
        plxgCtrlStoreQ(page, i, oldR.q[i]);
    const uint64_t snap0 = plxgCtrlLoadQ(page, 0);
    uint16_t sw = 0; // new daemon
    const uint16_t used =
        plxgHostWriteRecordRestartSafe(page, makePlxgRecordDisable(1), &sw, true);
    if (used == retainedSeq || sw != used)
        return false;
    // In-flight poller: first q0 was old retained; reread is new seq → torn reject.
    uint64_t snap[5];
    snap[0] = snap0;
    for (int i = 1; i < 5; ++i)
        snap[i] = plxgCtrlLoadQ(page, i);
    const uint64_t q0b = plxgCtrlLoadQ(page, 0);
    if (plxgPollerAcceptsSnapshot(snap, q0b, /*lastSeq=*/0))
        return false; // must not accept ABA
    // Fresh poll after host finished: last_seq=0, clean disable record.
    return plxgPollerTryCommit(page, /*lastSeq=*/0);
}

// Transaction-safe m1 sub-owner model (ddr_m1_subarb.sv): owner latched through
// RD response; WE does NOT set outstanding (DDR writes have no dout_ready).
enum class DdrM1Owner : uint8_t { None = 0, Stream = 1, Plxg = 2 };
struct DdrM1SubarbModel {
    DdrM1Owner grant = DdrM1Owner::None;
    bool outstanding = false; // RD only
    int rsp_left = 0;
    // issue_rd: accepted RD this cycle. issue_we: accepted WE (must NOT stick).
    // rd_beats: burst length for multi-beat RD (default 1).
    void tick(bool s_want, bool p_want, bool issue_rd, bool dout_ready,
              bool /*issue_we*/ = false, int rd_beats = 1) {
        if (issue_rd && grant != DdrM1Owner::None) {
            outstanding = true;
            rsp_left = rd_beats > 0 ? rd_beats : 1;
        } else if (dout_ready && outstanding) {
            if (rsp_left <= 1) {
                outstanding = false;
                rsp_left = 0;
            } else {
                --rsp_left;
            }
        }
        const bool can_pick =
            !outstanding &&
            (grant == DdrM1Owner::None ||
             (grant == DdrM1Owner::Stream && !s_want) ||
             (grant == DdrM1Owner::Plxg && !p_want));
        if (can_pick) {
            if (s_want)
                grant = DdrM1Owner::Stream;
            else if (p_want)
                grant = DdrM1Owner::Plxg;
            else
                grant = DdrM1Owner::None;
        }
    }
    bool doutToStream(bool dout_ready) const {
        return dout_ready && grant == DdrM1Owner::Stream;
    }
    bool doutToPlxg(bool dout_ready) const {
        return dout_ready && grant == DdrM1Owner::Plxg;
    }
};

// Behavioral latch (host/TB) — same promotion rules as present_geom_latch.sv.
struct PlxgLatchModel {
    bool win_enable = false;
    bool geom_enable = false;
    int content_w = 0, content_h = 0, content_x0 = 0, content_y0 = 0;
    int h_de = 0, v_de = 0, coded_w = 0, coded_h = 0;
    int y_stride = 0, chroma_stride = 0, display_w = 0, display_h = 0;
    int present_x = 0, present_y = 0, crop_left = 0, crop_top = 0;
    bool live_valid = false;
    uint16_t live_seq = 0;
    uint16_t last_seq = 0;
    uint64_t sh[5]{};
};

inline void plxgLatchWrite(PlxgLatchModel& m, unsigned idx, uint64_t data) {
    if (idx < 5)
        m.sh[idx] = data;
}

inline bool plxgLatchCommit(PlxgLatchModel& m) {
    if (static_cast<uint32_t>(m.sh[0]) != mailbox_abi::kPlxgMagic)
        return false;
    const uint16_t seq = static_cast<uint16_t>(m.sh[0] >> 48);
    if (seq == m.last_seq)
        return false;
    m.win_enable = ((m.sh[0] >> 32) & 1ull) != 0;
    m.geom_enable = ((m.sh[0] >> 33) & 1ull) != 0;
    m.live_seq = seq;
    m.last_seq = seq;
    m.live_valid = true;
    m.content_w = static_cast<int>(m.sh[1] & 0x7FFu);
    m.content_h = static_cast<int>((m.sh[1] >> 16) & 0x7FFu);
    m.content_x0 = static_cast<int>((m.sh[1] >> 32) & 0x7FFu);
    m.content_y0 = static_cast<int>((m.sh[1] >> 48) & 0x7FFu);
    m.h_de = static_cast<int>(m.sh[2] & 0x7FFu);
    m.v_de = static_cast<int>((m.sh[2] >> 16) & 0x7FFu);
    m.coded_w = static_cast<int>((m.sh[2] >> 32) & 0x7FFu);
    m.coded_h = static_cast<int>((m.sh[2] >> 48) & 0x7FFu);
    m.y_stride = static_cast<int>(m.sh[3] & 0xFFFu);
    m.chroma_stride = static_cast<int>((m.sh[3] >> 16) & 0x7FFu);
    m.display_w = static_cast<int>((m.sh[3] >> 32) & 0x7FFu);
    m.display_h = static_cast<int>((m.sh[3] >> 48) & 0x7FFu);
    m.present_x = static_cast<int>(m.sh[4] & 0x7FFu);
    m.present_y = static_cast<int>((m.sh[4] >> 16) & 0x7FFu);
    m.crop_left = static_cast<int>((m.sh[4] >> 32) & 0x7FFu);
    m.crop_top = static_cast<int>((m.sh[4] >> 48) & 0x7FFu);
    return true;
}

// Simulate host seqlock write (invalidate q0, body, magic-last) + latch.
inline bool plxgProgramRecord(uint8_t* ctrlPage /* at least 0x2C0+40 */,
                              const PlxgRecord& rec, PlxgLatchModel& latch) {
    if (!rec.valid || !ctrlPage)
        return false;
    plxgHostStoreAtomic(ctrlPage, rec);
    for (unsigned i = 0; i < kPlxgRecordQwords; ++i)
        plxgLatchWrite(latch, i, rec.q[i]);
    return plxgLatchCommit(latch);
}

// Exact I420 payload bytes from storage strides (host/RTL oracle).
inline size_t plxgI420PayloadBytes(int yStride, int chromaStride, int height) {
    if (yStride <= 0 || chromaStride <= 0 || height <= 0 || (height & 1))
        return 0;
    return static_cast<size_t>(yStride) * static_cast<size_t>(height) +
           2u * static_cast<size_t>(chromaStride) * static_cast<size_t>(height / 2);
}

// Option-C when payload exceeds legacy usable 520192 (exact bytes, not qword floor).
// 0x80000 - 0x1000 = 520192 — mirror kPlex480pYuv420pBankUsableBytes.
constexpr size_t kPlxgLegacyUsableBytes = 520192u;
inline bool plxgPayloadNeedsOptionC(size_t payloadBytes) {
    return payloadBytes > kPlxgLegacyUsableBytes;
}

// Geom dims accepted by RTL.
// coded_w must be a multiple of 16: chroma fetch is coded_w>>4 qwords (= w/2 bytes).
// 8-aligned-only widths (e.g. 968 with chroma_stride 488) pass stride%8 checks but
// drop the last 4 chroma bytes under >>4 fetch — reject them here (rd-duck).
// Height: even only (4:2:0). Display 540 is valid; do NOT require h%16.
inline bool plxgGeomDimsOk(int codedW, int codedH, int yStride, int chromaStride) {
    if (codedW <= 0 || codedH <= 0 || yStride <= 0 || chromaStride <= 0)
        return false;
    if ((codedW & 15) != 0 || (codedH & 1) != 0)
        return false;
    if ((yStride & 7) != 0 || (chromaStride & 7) != 0)
        return false;
    if (yStride < codedW || chromaStride < (codedW / 2))
        return false;
    // Fetch coverage oracle: (coded_w>>4)*8 == coded_w/2.
    if (((codedW >> 4) * 8) != (codedW / 2))
        return false;
    return true;
}

// Raw geometry accepted by ddr_frame_store (nonzero, ≤MAX, aligned) — no clamp.
// Defaults live on the forward declaration above (not repeated here).
inline bool plxgRawGeomOk(int codedW, int codedH, int yStride, int chromaStride,
                          int maxW, int maxH) {
    if (!plxgGeomDimsOk(codedW, codedH, yStride, chromaStride))
        return false;
    if (codedW > maxW || codedH > maxH || yStride > maxW || chromaStride > (maxW / 2))
        return false;
    return true;
}

} // namespace misterplex
