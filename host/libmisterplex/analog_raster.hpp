#pragma once
// v1 analog raster: reset-latched O[15:14] + pulse status[0] at daemon start.
// Live F12 Analog is forbidden. OSD_CONTROL stays 0 (do not poll-rewrite).
//
// analog_menu bits 15:14 (Plex.sv v10):
//   0 Follow content, 1=240p15, 2=480p31, 3=480i
// analog_sel (fabric mux) is 0=240p15, 1=480p31, 2=480i — do not write that
// encoding into OSD bits.
//
// Conf ANALOG_RASTER=240p15|480p31|480i|follow. Empty conf = follow.
// Pulse status[0] in the same UIO_SET_STATUS2 word as O[15:14] so the mux
// latches analog_sel while reset is held (FpgaSpi::setStatusBits already
// clears bit 0 after the pulse).

#include <cctype>
#include <cstddef>
#include <cstdint>
#include <cstring>

namespace misterplex {

inline constexpr unsigned kAnalogRasterFollow = 0;
inline constexpr unsigned kAnalogRaster240p15 = 1;
inline constexpr unsigned kAnalogRaster480p31 = 2;
inline constexpr unsigned kAnalogRaster480i = 3;

inline bool analogRasterApplyOnStart() { return true; }

#ifdef ANALOG_RASTER_FAULT_LIVE_APPLY
// RED twin: live OSD poll rewrite (forbidden v1).
inline bool analogRasterApplyOnOsdChange() { return true; }
#else
inline bool analogRasterApplyOnOsdChange() { return false; }
#endif

inline bool analogRasterPulseResetOnStart() { return analogRasterApplyOnStart(); }

inline unsigned analogRasterMenuBitsFromConf(const char* v) {
    char buf[32];
    size_t n = 0;
    if (!v)
        return kAnalogRasterFollow;
    while (*v == ' ' || *v == '\t' || *v == '\n' || *v == '\r')
        ++v;
    while (*v && n + 1 < sizeof(buf)) {
        if (*v == ' ' || *v == '\t' || *v == '\n' || *v == '\r')
            break;
        buf[n++] = static_cast<char>(std::tolower(static_cast<unsigned char>(*v++)));
    }
    buf[n] = 0;
#ifdef ANALOG_RASTER_FAULT_SWAP_BITS
    // RED twin: 480p31 written as analog_sel=1 instead of analog_menu=2.
    if (std::strcmp(buf, "480p31") == 0)
        return 1;
#endif
    if (buf[0] == 0 || std::strcmp(buf, "follow") == 0 || std::strcmp(buf, "0") == 0)
        return kAnalogRasterFollow;
    if (std::strcmp(buf, "240p15") == 0)
        return kAnalogRaster240p15;
    if (std::strcmp(buf, "480p31") == 0)
        return kAnalogRaster480p31;
    if (std::strcmp(buf, "480i") == 0)
        return kAnalogRaster480i;
    return kAnalogRasterFollow;
}

inline uint16_t analogRasterEncodeOsdWord(uint16_t word, unsigned bits15_14) {
    const unsigned b = bits15_14 & 3u;
    return static_cast<uint16_t>((word & static_cast<uint16_t>(~(3u << 14))) |
                                 static_cast<uint16_t>(b << 14));
}

inline unsigned analogRasterOsdBits1514(uint16_t word) {
    return (static_cast<unsigned>(word) >> 14) & 3u;
}

// Bit/value pairs for FpgaSpi::setStatusBits: O[14], O[15], then status[0]=1.
struct AnalogRasterStartPlan {
    unsigned bits15_14 = 0;
    bool pulseReset = true;
    bool applyLive = false;
    int pairs[8] = {};
    int nPairs = 0;
};

inline AnalogRasterStartPlan analogRasterStartPlan(const char* conf) {
    AnalogRasterStartPlan p;
    p.bits15_14 = analogRasterMenuBitsFromConf(conf);
    p.pulseReset = analogRasterPulseResetOnStart();
    p.applyLive = analogRasterApplyOnOsdChange();
    p.pairs[0] = 14;
    p.pairs[1] = (p.bits15_14 & 1u) ? 1 : 0;
    p.pairs[2] = 15;
    p.pairs[3] = (p.bits15_14 & 2u) ? 1 : 0;
    p.nPairs = 2;
    if (p.pulseReset) {
        p.pairs[4] = 0;
        p.pairs[5] = 1;
        p.nPairs = 3;
    }
    return p;
}

} // namespace misterplex
