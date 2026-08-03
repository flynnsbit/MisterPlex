#pragma once

#include "libmisterplex/ddr_frame_layout.hpp"

#include <cstddef>
#include <cstdint>
#include <cstring>
#include <string>
#include <vector>

namespace misterplex {

constexpr uint8_t kDdrSpiResetBitLo = 0x01u;  // status[0]
constexpr uint8_t kDdrSpiStartBitHi = 0x10u;  // status[12]
constexpr uint8_t kDdrSpiBankBitHi = 0x20u;   // status[13]
constexpr uint8_t kDdrSpiFlushBitHi = 0x02u;  // status[9]

inline int nextDdrPresentBank(int currentBank, bool sendOk) {
    return sendOk ? (currentBank ^ 1) : currentBank;
}

struct DdrPublishFrame {
    const uint8_t* payload = nullptr;
    size_t len = 0;
    DdrFrameGeometry geometry{};
    DdrFrameFormat format = DdrFrameFormat::Yuv420p;
};

struct DdrPublishPlan {
    DdrFrameLayout layout{};
    int bank = 0;
    size_t bank_offset = 0;
    uint32_t bank_phys = 0;
    // Bytes to memcpy into the bank. 0 ⇒ layout.frame_bytes (full canvas).
    // Native 960×540 Option-C path sets this to 777600 while layout still
    // describes the Option-C map window (stride/doorbell/phys).
    size_t copy_bytes = 0;
    bool native_push = false;
    bool program_plxg = false;
    uint64_t plxg_geom = 0;
    uint64_t plxg_window = 0;
    uint64_t plxg_origin = 0;
};

// Effective payload length for a plan (native or full canvas).
inline size_t ddrPublishCopyBytes(const DdrPublishPlan& plan) {
    if (plan.copy_bytes > 0)
        return plan.copy_bytes;
    return plan.layout.frame_bytes;
}

inline bool makeDdrPublishPlan(const DdrPublishFrame& frame, int bank, DdrPublishPlan& out,
                               std::string* err = nullptr,
                               uint32_t physBase = kDdrFramePhysBase) {
    if (!frame.payload) {
        if (err)
            *err = "publishDdrFrame: null frame payload";
        return false;
    }
    if (bank < 0 || bank > 1) {
        if (err)
            *err = "publishDdrFrame: bank must be 0 or 1";
        return false;
    }
    DdrFrameLayout layout =
        makeDdrFrameLayout(frame.geometry, physBase, kDdrFrameStrideAlign, frame.format);
    if (!ddrFrameLayoutValid(layout)) {
        if (err)
            *err = "publishDdrFrame: invalid DDR frame geometry";
        return false;
    }
    // Full-canvas path: payload must match derived geometry frame_bytes.
    // Native path uses makeDdrFabricOwnedPublishPlan (copy_bytes < canvas).
    if (frame.len != layout.frame_bytes) {
        if (err)
            *err = "publishDdrFrame: frame size does not match derived DDR geometry";
        return false;
    }
    const size_t bankOff = static_cast<size_t>(bank) * layout.bank_stride;
    if (bankOff + frame.len > layout.map_bytes || layout.phys_base + bankOff < layout.phys_base) {
        if (err)
            *err = "publishDdrFrame: derived bank offset is outside DDR frame window";
        return false;
    }
    out.layout = layout;
    out.bank = bank;
    out.bank_offset = bankOff;
    out.bank_phys = layout.phys_base + static_cast<uint32_t>(bankOff);
    out.copy_bytes = frame.len;
    out.native_push = false;
    out.program_plxg = false;
    return true;
}

// 720p Option-C publish plan (phys base after bitstream ring).
inline bool makePlex720pDdrPublishPlan(const DdrPublishFrame& frame, int bank, DdrPublishPlan& out,
                                       std::string* err = nullptr) {
    return makeDdrPublishPlan(frame, bank, out, err, kPlex720pDdrFramePhysBase);
}

// Fabric-owned present publish: payload length is *native* content bytes, not
// canvas frame_bytes. layout still describes the tier bank (stride/doorbell);
// ARM memcpy only plan.publish-sized payload at bank_offset (+ optional origin
// byte offset when fabric places at x0,y0 — origin offset is plane-aware and
// applied by the writer using content_x0/y0, not here).
struct DdrFabricOwnedPublishPlan {
    DdrFabricOwnedPresentPlan present{};
    DdrPublishPlan publish{};
    size_t payload_bytes = 0; // == present.publish_bytes
};

inline bool makeDdrFabricOwnedPublishPlan(const uint8_t* payload, int bank,
                                          const DdrFabricOwnedPresentPlan& present,
                                          DdrFabricOwnedPublishPlan& out,
                                          std::string* err = nullptr) {
    out = DdrFabricOwnedPublishPlan{};
    if (!present.valid) {
        if (err)
            *err = "fabricOwnedPublish: invalid present plan";
        return false;
    }
    if (!payload) {
        if (err)
            *err = "fabricOwnedPublish: null payload";
        return false;
    }
    if (bank < 0 || bank > 1) {
        if (err)
            *err = "fabricOwnedPublish: bank must be 0 or 1";
        return false;
    }
    if (!ddrPresentOffloadHas(present.offload, DdrPresentOffload::FabricScale) ||
        !fabricOwnedForbidsArmFfmpegScalePad()) {
        if (err)
            *err = "fabricOwnedPublish: path is not fabric-owned scale";
        return false;
    }
    // Payload must be tight native — rejecting full-canvas length is the gate
    // that prevents silently keeping ARM on the pad path.
    if (present.publish_bytes == 0 ||
        present.publish_bytes != present.native.native_bytes) {
        if (err)
            *err = "fabricOwnedPublish: publish_bytes must equal native content I420";
        return false;
    }
    // Refuse a full-canvas payload when content is smaller — that is the ARM
    // pad path we are evacuating.
    if (present.native.native_bytes < present.native.canvas_bytes &&
        present.publish_bytes == present.native.canvas_bytes) {
        if (err)
            *err = "fabricOwnedPublish: refused full-canvas payload on fabric-owned path";
        return false;
    }
    const DdrFrameLayout& layout = present.canvas_layout;
    if (!ddrFrameLayoutValid(layout)) {
        if (err)
            *err = "fabricOwnedPublish: invalid canvas layout";
        return false;
    }
    const size_t bankOff = static_cast<size_t>(bank) * layout.bank_stride;
    if (bankOff + present.publish_bytes > layout.map_bytes) {
        if (err)
            *err = "fabricOwnedPublish: native payload exceeds bank window";
        return false;
    }
    out.present = present;
    out.payload_bytes = present.publish_bytes;
    out.publish.layout = layout;
    out.publish.bank = bank;
    out.publish.bank_offset = bankOff;
    out.publish.bank_phys = layout.phys_base + static_cast<uint32_t>(bankOff);
    out.publish.copy_bytes = present.publish_bytes;
    out.publish.native_push = true;
    out.publish.program_plxg = true;
    out.publish.plxg_geom = present.plxg_word;
    out.publish.plxg_window = present.plxg_window_word;
    out.publish.plxg_origin = present.plxg_origin_word;
    (void)payload; // caller/sendDdrFrame memcpy's copy_bytes at bank_offset
    return true;
}

// Host-only native publish + plane readback (no device). Proves 777600 B lands
// on Option-C with storage strides 960/480 and U/V @ 518400/648000 — the
// detector that would have caught an unwired 1280 canvas path.
inline bool ddrNativeOptionCPublishReadbackOk(std::string* err = nullptr) {
    const auto present = makePlex720pOutputFrom540pSourcePlan();
    if (!present.valid) {
        if (err)
            *err = "native readback: present plan invalid";
        return false;
    }
    if (present.publish_bytes != 777600u || present.content_w != 960 ||
        present.content_h != 540) {
        if (err)
            *err = "native readback: expected 960x540 / 777600";
        return false;
    }
    if (present.content_layout.y_stride != 960 || present.content_layout.chroma_stride != 480 ||
        present.content_layout.u_offset != 518400u ||
        present.content_layout.v_offset != 648000u) {
        if (err)
            *err = "native readback: storage plane contract mismatch";
        return false;
    }
    int gw = 0, gh = 0;
    bool en = false, np = false;
    if (!decodePlxgGeometryWord(present.plxg_word, gw, gh, en, np) || !en || !np || gw != 960 ||
        gh != 540) {
        if (err)
            *err = "native readback: PLXG geometry must be storage 960x540";
        return false;
    }
    std::vector<uint8_t> src(present.publish_bytes);
    // Distinct plane tags so wrong U/V base is obvious.
    std::memset(src.data() + present.content_layout.y_offset, 0x11,
                static_cast<size_t>(present.content_w) * static_cast<size_t>(present.content_h));
    std::memset(src.data() + present.content_layout.u_offset, 0x22,
                static_cast<size_t>(present.content_layout.chroma_stride) *
                    static_cast<size_t>(present.content_h / 2));
    std::memset(src.data() + present.content_layout.v_offset, 0x33,
                static_cast<size_t>(present.content_layout.chroma_stride) *
                    static_cast<size_t>(present.content_h / 2));

    DdrFabricOwnedPublishPlan pub{};
    if (!makeDdrFabricOwnedPublishPlan(src.data(), /*bank=*/0, present, pub, err))
        return false;
    if (ddrPublishCopyBytes(pub.publish) != 777600u || pub.publish.native_push != true) {
        if (err)
            *err = "native readback: publish plan copy_bytes/native_push wrong";
        return false;
    }
    if (pub.publish.layout.phys_base != kPlex720pDdrFramePhysBase ||
        pub.publish.layout.bank_stride != kPlex720pYuv420pBankStride ||
        pub.publish.layout.doorbell_phys != kPlex720pYuv420pDoorbellPhys) {
        if (err)
            *err = "native readback: Option-C map not selected";
        return false;
    }
    // Simulated DDR window (two banks).
    std::vector<uint8_t> ddr(pub.publish.layout.map_bytes, 0);
    if (pub.publish.bank_offset + pub.publish.copy_bytes > ddr.size()) {
        if (err)
            *err = "native readback: bank window too small";
        return false;
    }
    std::memcpy(ddr.data() + pub.publish.bank_offset, src.data(), pub.publish.copy_bytes);
    const uint8_t* bank0 = ddr.data() + pub.publish.bank_offset;
    if (bank0[present.content_layout.y_offset] != 0x11 ||
        bank0[present.content_layout.u_offset] != 0x22 ||
        bank0[present.content_layout.v_offset] != 0x33) {
        if (err)
            *err = "native readback: plane tags not at storage offsets";
        return false;
    }
    // NEG: canvas U offset must NOT be where U landed.
    if (present.content_layout.u_offset == static_cast<uint32_t>(kPlex720pUPlaneOffset)) {
        if (err)
            *err = "native readback: storage U collided with canvas U (1280 path)";
        return false;
    }
    if (bank0[kPlex720pUPlaneOffset] == 0x22) {
        if (err)
            *err = "native readback: U tag appeared at canvas 921600 — wrong path";
        return false;
    }
    // bank1 end of payload must not reach doorbell page.
    const uint32_t bank1 = pub.publish.layout.phys_base + pub.publish.layout.bank_stride;
    const uint32_t bank1End = bank1 + static_cast<uint32_t>(pub.publish.copy_bytes);
    if (bank1End > pub.publish.layout.doorbell_phys) {
        if (err)
            *err = "native readback: payload overlaps doorbell page";
        return false;
    }
    return true;
}

inline void encodeDdrSpiKickStatusWord(const uint8_t in[16], int bank, bool startPulse,
                                       uint8_t out[16]) {
    for (int i = 0; i < 16; ++i)
        out[i] = in[i];
    out[0] = static_cast<uint8_t>(out[0] & ~kDdrSpiResetBitLo);
    if (bank)
        out[1] = static_cast<uint8_t>(out[1] | kDdrSpiBankBitHi);
    else
        out[1] = static_cast<uint8_t>(out[1] & ~kDdrSpiBankBitHi);
    if (startPulse)
        out[1] = static_cast<uint8_t>(out[1] | kDdrSpiStartBitHi);
    else
        out[1] = static_cast<uint8_t>(out[1] & ~kDdrSpiStartBitHi);
    out[1] = static_cast<uint8_t>(out[1] & ~kDdrSpiFlushBitHi);
}

} // namespace misterplex
