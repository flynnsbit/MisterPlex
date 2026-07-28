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
    DdrFrameLayout layout =
        makeDdrFrameLayout(frame.geometry, kDdrFramePhysBase, kDdrFrameStrideAlign, frame.format);
    if (!ddrFrameLayoutValid(layout)) {
        if (err)
            *err = "publishDdrFrame: invalid DDR frame geometry";
        return false;
    }
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
