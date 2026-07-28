#pragma once

#include <cstdint>

namespace misterplex {

constexpr uint8_t kDdrSpiResetBitLo = 0x01u;  // status[0]
constexpr uint8_t kDdrSpiStartBitHi = 0x10u;  // status[12]
constexpr uint8_t kDdrSpiBankBitHi = 0x20u;   // status[13]
constexpr uint8_t kDdrSpiFlushBitHi = 0x02u;  // status[9]

inline int nextDdrPresentBank(int currentBank, bool sendOk) {
    return sendOk ? (currentBank ^ 1) : currentBank;
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
