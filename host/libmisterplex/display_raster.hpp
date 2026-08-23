#pragma once
// F12 Display → /dev/MiSTer_cmd video_mode. Unknown label = no write.
// L4 product stays on CEA 720p60. kVideoModeCmd720p24 is legal, unused.
// HDMI-LCD scoring must not emit 15 kHz ascal (kVideoModeCmd240p / 480i).

#include "libmisterplex/osd_menu.hpp"

#include <cstdio>
#include <cstring>
#include <fcntl.h>
#include <unistd.h>

namespace misterplex {

inline constexpr const char* kMisterCmdPath = "/dev/MiSTer_cmd";
inline constexpr std::size_t kMisterCmdBuf = 80;

// 15 kHz NTSC 240p (bob). Htot=416 Vtot=262 Fpix=6.5 MHz → ~15.625 kHz / 59.6 Hz.
// VGA/RGB CRT TV. Not HDMI-safe (below TMDS floor). Present store stays 640×480.
inline constexpr const char* kVideoModeCmd240p = "video_mode 320,16,32,48,240,4,3,15,6500";
// Legacy 31 kHz LCD/VGA monitor "240p" (VESA 640×480@59.94, ascal preset 6).
inline constexpr const char* kVideoModeCmd240pLcd = "video_mode 640,16,96,48,480,10,2,33,25175";
// 15 kHz NTSC 480i weave. BT.601 858×262 field, 13.5 MHz → 15.734 kHz / 60.05 field.
// vact=240 is one field; ascal weaves even/odd lines of the 640×480 store.
inline constexpr const char* kVideoModeCmd480i = "video_mode 720,19,62,57,240,4,3,15,13500";
// VESA SVGA 800×600@60 (ascal preset 5). LCD / 31 kHz VGA.
inline constexpr const char* kVideoModeCmd480p = "video_mode 800,40,128,88,600,1,4,23,40000";
// CEA-861 720p60 (ascal preset 0). Not 24 Hz.
inline constexpr const char* kVideoModeCmd720p = "video_mode 1280,110,40,220,720,5,5,20,74250";
// CEA 720p24. Legal cmd; L4 stays on 720p60 (ascal 60→24 hurt decode).
inline constexpr const char* kVideoModeCmd720p24 =
    "video_mode 1280,110,40,220,720,5,5,28,30000";

static_assert(sizeof("video_mode 1280,110,40,220,720,5,5,20,74250\n") < kMisterCmdBuf,
              "CEA 720p60 cmd + NL must fit kMisterCmdBuf");
static_assert(sizeof("video_mode 1280,110,40,220,720,5,5,28,30000\n") < kMisterCmdBuf,
              "CEA 720p24 cmd + NL must fit kMisterCmdBuf");

inline const char* videoModeCmdForDisplayLabel(const char* label) {
    if (!label || !label[0])
        return nullptr;
    if (std::strcmp(label, "240p") == 0)
        return kVideoModeCmd240p;
    if (std::strcmp(label, "240p_lcd") == 0)
        return kVideoModeCmd240pLcd;
    if (std::strcmp(label, "480i") == 0)
        return kVideoModeCmd480i;
    if (std::strcmp(label, "480p") == 0)
        return kVideoModeCmd480p;
    if (std::strcmp(label, "720p") == 0)
        return kVideoModeCmd720p;
    return nullptr;
}

inline const char* videoModeCmdForDisplaySel(unsigned displaySel, const char* contentLabel) {
    switch (displaySel & 3u) {
    case 1:
        return videoModeCmdForDisplayLabel("240p");
    case 2:
        return videoModeCmdForDisplayLabel("480p");
    case 3:
        return videoModeCmdForDisplayLabel("720p");
    default:
        return videoModeCmdForDisplayLabel(contentLabel);
    }
}

inline const char* videoModeCmdForOsdWord(uint16_t word) {
    const OsdSettings s = decodeOsdWord(word);
    return videoModeCmdForDisplayLabel(s.displayResolution.label);
}

inline bool videoModeCmdIsSafe(const char* cmd) {
    return cmd && (std::strcmp(cmd, kVideoModeCmd240p) == 0 ||
                   std::strcmp(cmd, kVideoModeCmd240pLcd) == 0 ||
                   std::strcmp(cmd, kVideoModeCmd480i) == 0 ||
                   std::strcmp(cmd, kVideoModeCmd480p) == 0 ||
                   std::strcmp(cmd, kVideoModeCmd720p) == 0 ||
                   std::strcmp(cmd, kVideoModeCmd720p24) == 0);
}

inline const char* videoModeCmdIfChanged(const char* nextCmd, const char* lastCmd) {
    if (!videoModeCmdIsSafe(nextCmd))
        return nullptr;
    if (lastCmd && lastCmd[0] && std::strcmp(nextCmd, lastCmd) == 0)
        return nullptr;
    return nextCmd;
}

// Content O[5:4] applies live. Display O[15:14] latches at daemon start / core
// reset only — flipping F12 Display must not poke video_mode until reset.
inline bool displayRasterApplyOnOsdChange() { return false; }
inline bool contentResApplyOnOsdChange() { return true; }
inline bool displayRasterApplyOnStartup() { return true; }
// Cast/play must not rewrite /dev/MiSTer_cmd when the latched CEA mode is
// already live. force=true renegotiates HDMI, drops vsync, and leaves glass
// on the last chevron while Plex Web still reports playing (hw_presents=0).
inline constexpr bool kForceDisplayRasterOnPlay = false;

// Last comma field of a frozen custom modeline is Fpix in kHz.
inline int videoModePixelKhz(const char* cmd) {
    if (!cmd || !cmd[0])
        return 0;
    const char* last = std::strrchr(cmd, ',');
    if (!last || !last[1])
        return 0;
    int khz = 0;
    for (const char* p = last + 1; *p >= '0' && *p <= '9'; ++p)
        khz = khz * 10 + (*p - '0');
    return khz;
}

// 31 kHz LCD/VGA floor. 15 kHz CRT modes (240p 6.5 MHz, 480i 13.5 MHz) are
// legal and listed in videoModeCmdIsSafe; they are below this floor on purpose.
inline constexpr int kVgaMinPixelKhz = 25175;
inline constexpr int kHdmiLcdMinLineHz = 31000;
inline bool videoModeIsCrt15k(const char* cmd) {
    return cmd && (std::strcmp(cmd, kVideoModeCmd240p) == 0 ||
                   std::strcmp(cmd, kVideoModeCmd480i) == 0);
}

enum class DisplaySink {
    HdmiLcd, // ascal HDMI / ≥31 kHz VGA monitor (800×600@60 or 640×480@60)
    Crt15k,  // analog 15 kHz RGB CRT (VGA DAC, vga_scaler=0)
};

// video_mode hact,hfp,hs,hbp,vact,vfp,vs,vbp,Fpix_kHz
inline bool videoModeParseFields(const char* cmd, int out[9]) {
    if (!cmd || !out)
        return false;
    const char* p = cmd;
    if (std::strncmp(p, "video_mode ", 11) == 0)
        p += 11;
    else
        return false;
    for (int i = 0; i < 9; ++i) {
        if (*p < '0' || *p > '9')
            return false;
        int v = 0;
        while (*p >= '0' && *p <= '9') {
            v = v * 10 + (*p - '0');
            ++p;
        }
        out[i] = v;
        if (i < 8) {
            if (*p != ',')
                return false;
            ++p;
        }
    }
    return true;
}

inline int videoModeHtotal(const char* cmd) {
    int f[9] = {};
    if (!videoModeParseFields(cmd, f))
        return 0;
    return f[0] + f[1] + f[2] + f[3];
}

inline int videoModeVtotal(const char* cmd) {
    int f[9] = {};
    if (!videoModeParseFields(cmd, f))
        return 0;
    return f[4] + f[5] + f[6] + f[7];
}

// Analog / ascal horizontal rate. Not clk_sys (fabric PLL 20/24 MHz).
inline int videoModeLineHz(const char* cmd) {
    const int htot = videoModeHtotal(cmd);
    const int khz = videoModePixelKhz(cmd);
    if (htot <= 0 || khz <= 0)
        return 0;
    return static_cast<int>((static_cast<long long>(khz) * 1000LL) / htot);
}

inline bool videoModeForbiddenOnHdmiLcd(const char* cmd) {
    if (!cmd || !cmd[0])
        return false;
    if (videoModeIsCrt15k(cmd))
        return true;
    if (std::strcmp(cmd, kVideoModeCmd720p24) == 0)
        return true;
    const int lineHz = videoModeLineHz(cmd);
    if (lineHz > 0 && lineHz < kHdmiLcdMinLineHz)
        return true;
    const int khz = videoModePixelKhz(cmd);
    return khz > 0 && khz < kVgaMinPixelKhz;
}

inline bool videoModeCmdIsHdmiLcdSafe(const char* cmd) {
    return cmd && cmd[0] && !videoModeForbiddenOnHdmiLcd(cmd);
}

// HDMI-LCD scoring: Display "240p" → 640×480@60 ascal, never 15 kHz 240p.
// 480i is CRT-only (nullptr, no HDMI poke). 24 Hz HDMI is never selected.
inline const char* videoModeCmdForScoringPath(const char* label, DisplaySink sink) {
    if (sink == DisplaySink::HdmiLcd) {
        if (!label || !label[0])
            return nullptr;
        if (std::strcmp(label, "240p") == 0 || std::strcmp(label, "240p_lcd") == 0)
            return kVideoModeCmd240pLcd;
        if (std::strcmp(label, "480p") == 0)
            return kVideoModeCmd480p;
        if (std::strcmp(label, "480i") == 0)
            return nullptr;
        if (std::strcmp(label, "720p") == 0)
            return kVideoModeCmd720p;
        return nullptr;
    }
    return videoModeCmdForDisplayLabel(label);
}

inline const char* videoModeCmdForOsdWordOnSink(uint16_t word, DisplaySink sink) {
    const OsdSettings s = decodeOsdWord(word);
    return videoModeCmdForScoringPath(s.displayResolution.label, sink);
}

inline int writeMisterCmdLine(const char* path, const char* line) {
    if (!path || !path[0] || !videoModeCmdIsSafe(line))
        return 0;
    const int fd = ::open(path, O_WRONLY | O_CLOEXEC);
    if (fd < 0)
        return -1;
    char buf[kMisterCmdBuf];
    const int n = std::snprintf(buf, sizeof(buf), "%s\n", line);
    ssize_t w = -1;
    if (n > 0 && static_cast<std::size_t>(n) < sizeof(buf))
        w = ::write(fd, buf, static_cast<std::size_t>(n));
    ::close(fd);
    if (w != static_cast<ssize_t>(n))
        return -1;
    return 1;
}

} // namespace misterplex
