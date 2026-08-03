#pragma once
// PLXG 6-qword geometry record packers (path lane).
// Wire lockstep: present_geom_latch.sv + mailbox_abi_spec.hpp.
// q5 reserved[63:34] MUST stay 0 (parent arbitration #4 — no fps_1001 on bit34).

#include "libmisterplex/ddr_frame_layout.hpp"

#include <cstdint>

namespace misterplex {

// Wire ABI (parent freeze). Local constants — path mailbox_abi may lag w-mem PLXG rows.
constexpr uint32_t kPlxgMagic = 0x504C5847u; // "PLXG"
constexpr uint32_t kPlxgRecordQwords = 6u;
constexpr uint32_t kPlxgRecordBytes = kPlxgRecordQwords * 8u; // 48
static_assert(kPlxgRecordQwords == 6u, "PLXG is 6 qwords");
static_assert(kPlxgRecordBytes == 48u, "record bytes");

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

// q5: DAR+fps; reserved[63:34]==0 (parent #4).
inline uint64_t packPlxgQ5(unsigned darX, unsigned darY, unsigned contentFps, bool darValid,
                           bool fpsValid) {
    uint64_t w = 0;
    w |= static_cast<uint64_t>(darX & 0xFFFu);
    w |= static_cast<uint64_t>(darY & 0xFFFu) << 12;
    w |= static_cast<uint64_t>(contentFps & 0xFFu) << 24;
    if (darValid)
        w |= 1ull << 32;
    if (fpsValid)
        w |= 1ull << 33;
    return w;
}

inline bool plxgQ5ReservedOk(uint64_t q5) {
    return (q5 >> 34) == 0;
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

} // namespace misterplex
