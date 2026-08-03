#pragma once

#include "libmisterplex/ddr_frame_layout.hpp"
#include "libmisterplex/plxg_record.hpp"

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
    // Capacity-selected PLXG body matching layout/geometry (rd-duck shear fix).
    bool program_plxg = false;
    uint64_t plxg_q[6]{};
    uint16_t plxg_seq = 0;
    size_t copy_bytes = 0; // 0 ⇒ layout.frame_bytes
    DdrBankMap bank_map = DdrBankMap::Legacy480p;
};

inline size_t ddrPublishCopyBytes(const DdrPublishPlan& plan) {
    if (plan.copy_bytes > 0)
        return plan.copy_bytes;
    return plan.layout.frame_bytes;
}

inline bool makeDdrPublishPlan(const DdrPublishFrame& frame, int bank, DdrPublishPlan& out,
                               std::string* err = nullptr) {
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

    // Content plane layout from geometry (coded W/H, strides, plane offs, frame_bytes).
    // Bank window is NOT geometry-derived — RTL only has LEG (0x80000/0x300FF000)
    // or Option-C. alignUp(115200)→0x40000/0x3007F000 is the wrong physical map
    // (rd-duck amplifier on generic-native).
    DdrFrameLayout layout =
        makeDdrFrameLayout(frame.geometry, kDdrFramePhysBase, kDdrFrameStrideAlign, frame.format);
    if (frame.len != layout.frame_bytes) {
        if (err)
            *err = "publishDdrFrame: frame size does not match derived DDR geometry";
        return false;
    }

    const DdrBankMap map = ddrSelectBankMapForPayloadBytes(frame.len);
    if (!ddrPinLayoutToBankMap(layout, map)) {
        if (err)
            *err = "publishDdrFrame: payload does not fit capacity-selected bank map";
        return false;
    }
    if (!ddrFrameLayoutValid(layout)) {
        if (err)
            *err = "publishDdrFrame: invalid DDR frame geometry after bank-map pin";
        return false;
    }
    if (ddrLayoutBankMapIsGeometryDerived(layout)) {
        if (err)
            *err = "publishDdrFrame: refused geometry-derived bank map (LEG/Option-C only)";
        return false;
    }

    const size_t bankOff = static_cast<size_t>(bank) * layout.bank_stride;
    if (bankOff + frame.len > layout.map_bytes || layout.phys_base + bankOff < layout.phys_base) {
        if (err)
            *err = "publishDdrFrame: derived bank offset is outside DDR frame window";
        return false;
    }

    // PLXG tracks storage content geometry (not bank canvas). Product 480 keeps
    // pillarbox Legacy480 body; other tiers pack from geometry+layout.
    PlxgRecord plxg{};
    const bool product480 =
        frame.geometry.coded_width.get() == kPlex480pCodedWidth.get() &&
        frame.geometry.coded_height.get() == kPlex480pCodedHeight.get() &&
        layout.line_bytes == kPlex480pYStrideBytes;
    if (product480) {
        plxg = makePlxgRecordLegacy480(/*seq=*/1);
    } else {
        plxg = makePlxgRecordFromGeometry(frame.geometry, layout, /*seq=*/1);
    }
    if (!plxg.valid) {
        if (err)
            *err = "publishDdrFrame: failed to build capacity-selected PLXG";
        return false;
    }
    if (!plxgRecordMatchesStorage(plxg, layout.coded_width.get(), layout.coded_height.get(),
                                  layout.line_bytes, layout.chroma_line_bytes)) {
        if (err)
            *err = "publishDdrFrame: PLXG storage mismatch vs layout (shear guard)";
        return false;
    }

    out.layout = layout;
    out.bank = bank;
    out.bank_offset = bankOff;
    out.bank_phys = layout.phys_base + static_cast<uint32_t>(bankOff);
    out.copy_bytes = frame.len;
    out.program_plxg = true;
    out.plxg_seq = plxg.seq;
    out.bank_map = map;
    for (int i = 0; i < 6; ++i)
        out.plxg_q[i] = plxg.q[i];
    // Default q5=0; inject DAR/fps via injectPlxgQ5IntoPublishPlan before
    // writePlxgRecord (never standalone doorbell+0x828 product write).
    return true;
}

// Overlay path DAR/fps q5 onto a publish plan for the same generation as bank kick.
inline bool injectPlxgQ5IntoPublishPlan(DdrPublishPlan& plan, uint64_t q5) {
    if (!injectPlxgQ5IntoRecord(plan.plxg_q, q5))
        return false;
    plan.program_plxg = true;
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
