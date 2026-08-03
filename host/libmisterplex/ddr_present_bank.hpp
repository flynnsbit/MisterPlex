#pragma once

#include "libmisterplex/ddr_frame_layout.hpp"

#include <cstddef>
#include <cstdint>
#include <string>

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
};

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
    // Payload must match derived geometry frame_bytes (full coded bank).
    // Tight native-into-larger-canvas is a separate pack step
    // (packYuv420pCentered / copyYuv420pNativeOrigin) before publish.
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
    (void)payload; // caller memcpy's payload_bytes at bank_offset
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
