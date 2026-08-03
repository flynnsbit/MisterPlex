#pragma once
// PLXG 6-qword geometry record packers (path lane).
// Wire lockstep: present_geom_latch.sv + mailbox_abi_spec.hpp.
// q5 reserved[63:34] MUST stay 0 (parent arbitration #4 — no fps_1001 on bit34).
// q5 MUST ride full-record seqlock (rd-duck): never standalone +0x828 product write.

#include "libmisterplex/ddr_frame_layout.hpp"
#include "libmisterplex/plxg_q5_aspect_cadence.hpp"

#include <cstdint>
#include <cstring>

namespace misterplex {

// Wire ABI (parent freeze). Local constants — path mailbox_abi may lag w-mem PLXG rows.
constexpr uint32_t kPlxgMagic = 0x504C5847u; // "PLXG"
constexpr uint32_t kPlxgRecordQwords = 6u;
constexpr uint32_t kPlxgRecordBytes = kPlxgRecordQwords * 8u; // 48
static_assert(kPlxgRecordQwords == 6u, "PLXG is 6 qwords");
static_assert(kPlxgRecordBytes == 48u, "record bytes");
static_assert(kPlxgRecordByteOffset == 0x800u, "record at +0x800");
static_assert(kPlxgQ5ByteOffset == 0x828u, "q5 at +0x828");

struct PlxgRecord {
    uint64_t q[kPlxgRecordQwords]{};
    uint16_t seq = 0;
    bool valid = false;
};

// q0: [31:0] magic  [32] win  [33] geom  [47:34] epoch  [63:48] seq
inline uint64_t packPlxgQ0(bool winEnable, bool geomEnable, uint16_t seq,
                           uint16_t epoch = 1) {
    uint64_t hi = 0;
    if (winEnable)
        hi |= 1ull << 0;
    if (geomEnable)
        hi |= 1ull << 1;
    hi |= (static_cast<uint64_t>(epoch & 0x3FFFu) << 2);
    hi |= (static_cast<uint64_t>(seq) << 16);
    return (hi << 32) | static_cast<uint64_t>(kPlxgMagic);
}

inline uint64_t packPlxgQ1(int contentW, int contentH, int x0, int y0) {
    const uint64_t w = static_cast<uint64_t>(contentW) & 0x7FFu;
    const uint64_t h = static_cast<uint64_t>(contentH) & 0x7FFu;
    const uint64_t x = static_cast<uint64_t>(x0) & 0x7FFu;
    const uint64_t y = static_cast<uint64_t>(y0) & 0x7FFu;
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

// q5: DAR+fps; reserved[63:34]==0 (parent #4). Uses cadence reserved check.
inline uint64_t packPlxgQ5Fields(unsigned darX, unsigned darY, unsigned contentFps, bool darValid,
                                 bool fpsValid) {
    PlxgAspectCadence c{};
    c.dar_x = static_cast<uint16_t>(darX & kPlxgDarFieldMax);
    c.dar_y = static_cast<uint16_t>(darY & kPlxgDarFieldMax);
    c.content_fps = static_cast<uint8_t>(contentFps & 0xFFu);
    c.dar_valid = darValid;
    c.fps_valid = fpsValid;
    uint64_t q = 0;
    if (!packPlxgQ5(c, &q))
        return 0;
    return q;
}

// Back-compat name used by Legacy480/FromGeometry builders.
inline uint64_t packPlxgQ5(unsigned darX, unsigned darY, unsigned contentFps, bool darValid,
                           bool fpsValid) {
    return packPlxgQ5Fields(darX, darY, contentFps, darValid, fpsValid);
}

inline void unpackPlxgQ1(uint64_t q1, int* cw, int* ch, int* x0, int* y0) {
    if (cw)
        *cw = static_cast<int>(q1 & 0x7FFu);
    if (ch)
        *ch = static_cast<int>((q1 >> 16) & 0x7FFu);
    if (x0)
        *x0 = static_cast<int>((q1 >> 32) & 0x7FFu);
    if (y0)
        *y0 = static_cast<int>((q1 >> 48) & 0x7FFu);
}

inline void unpackPlxgQ2(uint64_t q2, int* hDe, int* vDe, int* codedW, int* codedH) {
    if (hDe)
        *hDe = static_cast<int>(q2 & 0x7FFu);
    if (vDe)
        *vDe = static_cast<int>((q2 >> 16) & 0x7FFu);
    if (codedW)
        *codedW = static_cast<int>((q2 >> 32) & 0x7FFu);
    if (codedH)
        *codedH = static_cast<int>((q2 >> 48) & 0x7FFu);
}

inline void unpackPlxgQ3(uint64_t q3, int* yStride, int* chromaStride, int* displayW,
                         int* displayH) {
    if (yStride)
        *yStride = static_cast<int>(q3 & 0xFFFu);
    if (chromaStride)
        *chromaStride = static_cast<int>((q3 >> 16) & 0x7FFu);
    if (displayW)
        *displayW = static_cast<int>((q3 >> 32) & 0x7FFu);
    if (displayH)
        *displayH = static_cast<int>((q3 >> 48) & 0x7FFu);
}

inline void unpackPlxgQ4(uint64_t q4, int* presentX, int* presentY, int* cropLeft,
                         int* cropTop) {
    if (presentX)
        *presentX = static_cast<int>(q4 & 0x7FFu);
    if (presentY)
        *presentY = static_cast<int>((q4 >> 16) & 0x7FFu);
    if (cropLeft)
        *cropLeft = static_cast<int>((q4 >> 32) & 0x7FFu);
    if (cropTop)
        *cropTop = static_cast<int>((q4 >> 48) & 0x7FFu);
}

// Product 480p mode-exit (pillarbox 618 in 624 / DE 640×480).
inline PlxgRecord makePlxgRecordLegacy480(uint16_t seq) {
    PlxgRecord r{};
    r.seq = seq;
    r.q[0] = packPlxgQ0(/*win*/ true, /*geom*/ true, seq);
    r.q[1] = packPlxgQ1(/*cw*/ 624, /*ch*/ 480, /*x0*/ 0, /*y0*/ 0);
    r.q[2] = packPlxgQ2(/*h_de*/ 640, /*v_de*/ 480, /*coded*/ 624, /*ch*/ 480);
    r.q[3] = packPlxgQ3(/*y*/ 624, /*c*/ 312, /*dw*/ 618, /*dh*/ 480);
    r.q[4] = packPlxgQ4(/*px*/ 11, /*py*/ 0, /*cl*/ 0, /*ct*/ 0);
    r.q[5] = packPlxgQ5(0, 0, 0, false, false);
    r.valid = true;
    return r;
}

// Capacity-selected PLXG from the *same* geometry/layout the payload was built for.
// Prevents: copy 320×240 I420 while programming Legacy480 624×480 (shear).
// DE uses presented dims (ascal/glass input island); coded/stride follow storage.
inline PlxgRecord makePlxgRecordFromGeometry(const DdrFrameGeometry& g,
                                             const DdrFrameLayout& layout, uint16_t seq) {
    PlxgRecord r{};
    if (!ddrFrameLayoutValid(layout) || g.coded_width.get() <= 0 || g.coded_height.get() <= 0)
        return r;
    // Layout must describe this geometry — silent mismatch is the shear class.
    if (layout.coded_width.get() != g.coded_width.get() ||
        layout.coded_height.get() != g.coded_height.get() ||
        layout.frame_bytes != yuv420pFrameBytes(g.coded_width, g.coded_height))
        return r;

    const int cw = g.coded_width.get();
    const int ch = g.coded_height.get();
    const int dw = g.display_width.get() > 0 ? g.display_width.get() : cw;
    const int dh = g.display_height.get() > 0 ? g.display_height.get() : ch;
    const int deW = g.presented_width.get() > 0 ? g.presented_width.get() : cw;
    const int deH = g.presented_height.get() > 0 ? g.presented_height.get() : ch;
    const int yStride = layout.line_bytes > 0 ? layout.line_bytes : cw;
    const int cStride = layout.chroma_line_bytes > 0 ? layout.chroma_line_bytes : (cw / 2);

    r.seq = seq;
    r.q[0] = packPlxgQ0(/*win*/ true, /*geom*/ true, seq);
    // Content window = visible display at present origin (usually 0,0 for identity).
    r.q[1] = packPlxgQ1(dw, dh, g.present_x, g.present_y);
    r.q[2] = packPlxgQ2(deW, deH, cw, ch);
    r.q[3] = packPlxgQ3(yStride, cStride, dw, dh);
    r.q[4] = packPlxgQ4(g.present_x, g.present_y, g.crop_left, g.crop_top);
    r.q[5] = packPlxgQ5(0, 0, 0, false, false); // q5 DAR/fps overlaid by path publisher
    r.valid = true;
    return r;
}

// True when a publish PLXG body matches payload geometry (q2 coded + q3 stride).
inline bool plxgRecordMatchesStorage(const PlxgRecord& r, int codedW, int codedH,
                                     int yStride, int chromaStride) {
    if (!r.valid)
        return false;
    int cw = 0, ch = 0, ys = 0, cs = 0;
    unpackPlxgQ2(r.q[2], nullptr, nullptr, &cw, &ch);
    unpackPlxgQ3(r.q[3], &ys, &cs, nullptr, nullptr);
    return cw == codedW && ch == codedH && ys == yStride && cs == chromaStride &&
           plxgQ5ReservedOk(r.q[5]);
}

// NEG oracle: Legacy480 PLXG must NOT be paired with a non-480 payload.
inline bool plxgLegacy480MismatchesPayload(int payloadCodedW, int payloadCodedH) {
    return payloadCodedW != 624 || payloadCodedH != 480;
}

// Bootstrap page (poller fixed read) — product LEG doorbell. NOT Option-C active.
// Route through ddr_frame_layout single-source (rtl_invariants literal ban).
constexpr uint32_t kPlxgBootstrapDoorbellPhys = kPlex480pYuv420pDoorbellPhys;
constexpr uint32_t kPlxgQ5ByteOffsetInRecord = 0x28u; // q5 within record (= +0x828 page)
constexpr uint32_t kPlxgBootstrapRecordPhys =
    kPlxgBootstrapDoorbellPhys + kPlxgRecordByteOffset; // doorbell+0x800
static_assert(kPlxgBootstrapDoorbellPhys == kPlex480pYuv420pDoorbellPhys,
              "bootstrap == product LEG doorbell");
static_assert(kPlxgQ5ByteOffsetInRecord + kPlxgRecordByteOffset == kPlxgQ5ByteOffset,
              "q5 in-record offset");

constexpr uint16_t kPlxgDoorbellSeqFieldMask = 0x1FFFu;

inline uint16_t plxgSeqDoorbellField(uint16_t fullSeq) {
    return static_cast<uint16_t>(fullSeq & kPlxgDoorbellSeqFieldMask);
}

inline bool plxgSeqDoorbellFieldIsReservedUngated(uint16_t fullSeq) {
    return plxgSeqDoorbellField(fullSeq) == 0;
}

inline uint16_t plxgNextSeq(uint16_t softwareLast, bool retainedValid, uint16_t retainedSeq) {
    uint32_t seed = softwareLast;
    if (retainedValid && static_cast<uint32_t>(retainedSeq) > seed)
        seed = retainedSeq;
    uint16_t use = static_cast<uint16_t>(seed + 1u);
    for (int i = 0; i < 16; ++i) {
        if (use != 0 && !plxgSeqDoorbellFieldIsReservedUngated(use))
            return use;
        use = static_cast<uint16_t>(use + 1u);
    }
    return 1;
}

// Inject DAR/fps q5 into a publish plan — ONLY legal product path for q5
// (rd-duck: no standalone doorbell+0x828 write; poller needs new q0 seq).
inline bool injectPlxgQ5IntoRecord(uint64_t plxg_q[6], uint64_t q5) {
    if (!plxg_q || !plxgQ5ReservedOk(q5))
        return false;
    plxg_q[5] = q5;
    return true;
}

// Seqlock publish into a control page (offset 0 = page base, record at +0x800).
// Returns committed seq. Models writePlxgRecord body path for host E2E tests.
inline bool plxgSeqlockPublishToPage(uint8_t* ctrlPage, size_t pageBytes, const uint64_t qIn[6],
                                     uint16_t softwareLast, uint16_t* committedSeqOut) {
    if (!ctrlPage || !qIn || pageBytes < kPlxgRecordByteOffset + kPlxgRecordBytes)
        return false;
    uint32_t* base =
        reinterpret_cast<uint32_t*>(ctrlPage + kPlxgRecordByteOffset);
    bool retainedValid = false;
    uint16_t retainedSeq = 0;
    if (base[0] == kPlxgMagic) {
        retainedValid = true;
        retainedSeq = static_cast<uint16_t>(base[1] >> 16);
    }
    const uint16_t useSeq = plxgNextSeq(softwareLast, retainedValid, retainedSeq);
    uint64_t words[6];
    for (int i = 0; i < 6; ++i)
        words[i] = qIn[i];
    uint64_t flags = (words[0] >> 32) & 0xFFFFull;
    if (((flags >> 2) & 0x3FFFull) == 0)
        flags |= (1ull << 2);
    words[0] = (static_cast<uint64_t>(useSeq) << 48) | (flags << 32) |
               static_cast<uint64_t>(kPlxgMagic);

    auto dmb = []() { __sync_synchronize(); };
    // 1) invalidate magic
    base[0] = 0u;
    dmb();
    // 2) body q1..q5
    for (int qi = 1; qi < 6; ++qi) {
        base[qi * 2 + 1] = static_cast<uint32_t>(words[qi] >> 32);
        dmb();
        base[qi * 2 + 0] = static_cast<uint32_t>(words[qi]);
        dmb();
    }
    // 3) q0 high then magic-last
    base[1] = static_cast<uint32_t>(words[0] >> 32);
    dmb();
    base[0] = static_cast<uint32_t>(words[0]);
    dmb();
    if (committedSeqOut)
        *committedSeqOut = useSeq;
    return true;
}

// Minimal poller: promote only when q0 magic+seq stable and seq != last.
struct PlxgPollerSim {
    uint16_t last_seq = 0;
    bool has_last = false;
    uint64_t latched_q[6]{};
    bool latched = false;

    bool tryCommit(const uint8_t* ctrlPage, size_t pageBytes) {
        if (!ctrlPage || pageBytes < kPlxgRecordByteOffset + kPlxgRecordBytes)
            return false;
        const uint32_t* base = reinterpret_cast<const uint32_t*>(
            ctrlPage + kPlxgRecordByteOffset);
        const uint32_t lo0 = base[0];
        const uint32_t hi0 = base[1];
        if (lo0 != kPlxgMagic)
            return false;
        const uint16_t seq = static_cast<uint16_t>(hi0 >> 16);
        if (has_last && seq == last_seq)
            return false; // skip body — q5-only write never reaches here
        // re-read q0
        const uint32_t lo1 = base[0];
        const uint32_t hi1 = base[1];
        if (lo1 != lo0 || hi1 != hi0 || lo1 != kPlxgMagic)
            return false;
        uint64_t body[6];
        body[0] = (static_cast<uint64_t>(hi1) << 32) | lo1;
        for (int i = 1; i < 6; ++i)
            body[i] = (static_cast<uint64_t>(base[i * 2 + 1]) << 32) |
                      static_cast<uint64_t>(base[i * 2 + 0]);
        // re-read q0 again (seqlock)
        if (base[0] != lo1 || base[1] != hi1)
            return false;
        for (int i = 0; i < 6; ++i)
            latched_q[i] = body[i];
        last_seq = seq;
        has_last = true;
        latched = true;
        return true;
    }
};

// Standalone q5 poke at +0x828 without new q0 — poller must NOT promote (NEG).
inline void plxgFaultWriteQ5Only(uint8_t* ctrlPage, uint64_t q5) {
    if (!ctrlPage)
        return;
    uint32_t* q5w = reinterpret_cast<uint32_t*>(ctrlPage + kPlxgRecordByteOffset +
                                                kPlxgQ5ByteOffsetInRecord);
    q5w[0] = static_cast<uint32_t>(q5);
    q5w[1] = static_cast<uint32_t>(q5 >> 32);
}

// E2E: inject q5 into plan, seqlock publish, poller latches nonzero DAR/fps.
// Bootstrap page is always LEG phys (poller fixed); content plan may be LEG or Opt-C.
inline bool plxgQ5FullRecordE2E(const uint64_t plan_q_in[6], uint64_t q5, uint16_t softLast,
                                uint16_t* committedOut, uint64_t* latchedQ5Out) {
    if (!plan_q_in || !plxgQ5ReservedOk(q5))
        return false;
    uint64_t plan_q[6];
    for (int i = 0; i < 6; ++i)
        plan_q[i] = plan_q_in[i];
    if (!injectPlxgQ5IntoRecord(plan_q, q5))
        return false;
    if (plan_q[5] != q5)
        return false;
    uint8_t page[0x1000]{};
    uint16_t committed = 0;
    if (!plxgSeqlockPublishToPage(page, sizeof(page), plan_q, softLast, &committed))
        return false;
    if (plxgSeqDoorbellFieldIsReservedUngated(committed))
        return false;
    PlxgPollerSim pol{};
    // First commit after empty may baseline — require promote with new seq
    if (!pol.tryCommit(page, sizeof(page)))
        return false;
    if (pol.latched_q[5] != q5)
        return false;
    if (pol.last_seq != committed)
        return false;
    // NEG: q5-only poke with same q0 must not re-promote a different q5
    const uint64_t evil = packPlxgQ5(4, 3, 25, true, true);
    plxgFaultWriteQ5Only(page, evil);
    PlxgPollerSim pol2 = pol;
    if (pol2.tryCommit(page, sizeof(page)))
        return false; // must skip — same seq
    if (pol.latched_q[5] != q5)
        return false;
    if (committedOut)
        *committedOut = committed;
    if (latchedQ5Out)
        *latchedQ5Out = pol.latched_q[5];
    return true;
}

} // namespace misterplex
