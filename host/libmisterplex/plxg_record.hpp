#pragma once
// PLXG 5-qword atomic geometry record — lockstep with present_geom_latch.sv.
//
// Offset: doorbell + 0x2C0 (NOT +0x130 — PLXC chrome ctrl owns +0x130).
// Bootstrap phys: product legacy doorbell 0x300FF000 + 0x2C0 = 0x300FF2C0.
// Fabric poller always reads the bootstrap page (chicken-egg with Option-C).
//
// Write model: host stores q[0..4] contiguously, then fabric reads all five and
// pulses commit. q[0] seq must change for the latch to accept. Never overwrite
// a single 8-byte slot with three temporal "beats".

#include "libmisterplex/mailbox_abi_spec.hpp"

#include <cstdint>
#include <cstring>

namespace misterplex {

constexpr uint32_t kPlxgRecordQwords = 5u;
constexpr uint32_t kPlxgRecordBytes = kPlxgRecordQwords * 8u; // 40

// Bit pack matches present_geom_latch.sv shadow decode.
struct PlxgRecord {
    uint64_t q[kPlxgRecordQwords]{};
    uint16_t seq = 0;
    bool valid = false;
};

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

// Simulate host multi-slot write into a control-page image then latch commit.
inline bool plxgProgramRecord(uint8_t* ctrlPage /* at least 0x2C0+40 */,
                              const PlxgRecord& rec, PlxgLatchModel& latch) {
    if (!rec.valid || !ctrlPage)
        return false;
    const size_t off = mailbox_abi::kPlxgOffset;
    for (unsigned i = 0; i < kPlxgRecordQwords; ++i) {
        std::memcpy(ctrlPage + off + i * 8u, &rec.q[i], 8);
        plxgLatchWrite(latch, i, rec.q[i]);
    }
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

// Geom dims accepted by RTL (multiple of 8 width, even height, strides aligned).
inline bool plxgGeomDimsOk(int codedW, int codedH, int yStride, int chromaStride) {
    if (codedW <= 0 || codedH <= 0 || yStride <= 0 || chromaStride <= 0)
        return false;
    if ((codedW & 7) != 0 || (codedH & 1) != 0)
        return false;
    if ((yStride & 7) != 0 || (chromaStride & 7) != 0)
        return false;
    if (yStride < codedW || chromaStride < (codedW / 2))
        return false;
    return true;
}

} // namespace misterplex
