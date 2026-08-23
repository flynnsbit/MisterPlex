#pragma once
// Combinational analog_sel decode — lockstep with fpga/Plex_MiSTer/Plex.sv
// analog_menu / analog_from_content / analog_follow_lcd.
//
// analog_menu O[15:14]: 0=Follow content, 1=240p 15kHz, 2=480p 31kHz, 3=480i
// analog_sel:           0=240p15,         1=480p31,      2=480i
// analog_from_content:  content O[5:4]==0 → 240p15 else 480p31 (720p parked)
// forced_scandoubler + Follow → LCD-safe 31 kHz (sel 1), never 15 kHz HDMI.
//
// analog_raster_mux RESET-LATCHES analog_sel (v1). Content O[5:4] is DECODE.
// Live content change without reset is not an analog H-class jump.

#include <cstdint>

namespace misterplex {

inline constexpr uint8_t kAnalogSel240p15 = 0;
inline constexpr uint8_t kAnalogSel480p31 = 1;
inline constexpr uint8_t kAnalogSel480i = 2;

inline constexpr uint8_t kAnalogMenuFollow = 0;
inline constexpr uint8_t kAnalogMenu240p15 = 1;
inline constexpr uint8_t kAnalogMenu480p31 = 2;
inline constexpr uint8_t kAnalogMenu480i = 3;

inline uint8_t analogFromContent(uint8_t content_res_sel) {
    return ((content_res_sel & 3u) == 0u) ? kAnalogSel240p15 : kAnalogSel480p31;
}

// Combinational analog_sel (mux input). Does not latch.
inline uint8_t analogSelRequested(uint8_t analog_menu, uint8_t content_res_sel,
                                  bool forced_scandoubler) {
    analog_menu = static_cast<uint8_t>(analog_menu & 3u);
    content_res_sel = static_cast<uint8_t>(content_res_sel & 3u);
    const bool follow_lcd = forced_scandoubler && analog_menu == kAnalogMenuFollow;
    if (follow_lcd)
        return kAnalogSel480p31;
    if (analog_menu == kAnalogMenuFollow)
        return analogFromContent(content_res_sel);
    if (analog_menu == kAnalogMenu240p15)
        return kAnalogSel240p15;
    if (analog_menu == kAnalogMenu480p31)
        return kAnalogSel480p31;
    return kAnalogSel480i;
}

// v1 reset-latch. Live F12 / live content must not retarget H class.
inline uint8_t analogSelLatch(bool reset, uint8_t latched, uint8_t requested) {
    return reset ? requested : latched;
}

// Content O[5:4] live change is DECODE, not analog. Reset may load analog_sel.
inline bool analogLiveContentChangeIsAnalogJump(bool reset_pulse) {
    (void)reset_pulse;
    return false;
}

} // namespace misterplex
