#pragma once
// Core -> HPS playback input mailbox constants.
//
// The daemon must read these from DDR; it must not poll keyboard/controller
// state through SPI because MiSTer Main owns the HPS<->FPGA SPI handshake.

#include <cstdint>

namespace misterplex {

constexpr uint32_t kInputMailboxPhys = 0x3007F108u;
constexpr uint32_t kInputMailboxMagic = 0x504C5849u; // "PLXI"

enum class PlaybackCommand : uint8_t {
    None = 0,
    PlayPause = 1,
    Stop = 2,
    SkipForward = 3,
    SkipBack = 4,
};

} // namespace misterplex
