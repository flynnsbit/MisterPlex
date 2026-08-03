#pragma once
// Explicit supported content geometries for MiSTerPlex host/daemon.
// Data-driven: menu, DECODE conf, PMS weak ladder, and present budget must pick
// from this table — never silently clamp an oversized request down to 480p.

#include <cstddef>
#include <optional>
#include <string>
#include <string_view>

namespace misterplex {

struct ContentMode {
    const char* name;          // "240p", "480p", "720p"
    int width = 0;
    int height = 0;
    // PMS universal / weak-ladder knobs (aligned with plexTranscodeProfiles).
    int maxVideoBitrateKbps = 0;
    int videoQuality = 0;
    const char* h264Profile = "baseline";
    int h264Level = 30; // Plex integer form: 30 == Level 3.0
};

// Ordered low → high. Product path is ARM decode → DDR/SPI present (no fabric decode).
inline constexpr ContentMode kContentModes[] = {
    {"240p", 320, 240, 1000, 40, "baseline", 30},
    {"480p", 640, 480, 2500, 60, "baseline", 30},
    // 720p: Constrained Baseline L3.0. Bitrate 3000 kbps is a product knee —
    // enough headroom above the lab CB 720p24 asset (~488 kbps) without asking
    // PMS for High/CABAC or level > 3.0. Not a fitted W*H formula.
    {"720p", 1280, 720, 3000, 70, "baseline", 30},
};

inline constexpr std::size_t kContentModeCount =
    sizeof(kContentModes) / sizeof(kContentModes[0]);

inline constexpr int kMaxContentWidth = 1280;
inline constexpr int kMaxContentHeight = 720;

inline const ContentMode* findContentModeByName(std::string_view name) {
    for (std::size_t i = 0; i < kContentModeCount; ++i) {
        if (name == kContentModes[i].name)
            return &kContentModes[i];
    }
    return nullptr;
}

inline const ContentMode* findContentModeExact(int w, int h) {
    for (std::size_t i = 0; i < kContentModeCount; ++i) {
        if (kContentModes[i].width == w && kContentModes[i].height == h)
            return &kContentModes[i];
    }
    return nullptr;
}

// Map a requested WxH onto the largest supported mode that does not exceed the
// request in either dimension when possible; never collapse a true 720p request
// into 480p. Sizes above the product ceiling pin to 720p (caller still validates
// weak ladder / present budget separately).
inline const ContentMode& contentModeFromSize(int w, int h) {
    if (w <= 0 || h <= 0)
        return kContentModes[0];
    if (const ContentMode* exact = findContentModeExact(w, h))
        return *exact;
    // Prefer 720p when either axis reaches the 720p tier (DECODE=1280x720).
    if (w >= 1280 || h >= 720)
        return kContentModes[2];
    if (w >= 640 || h >= 480)
        return kContentModes[1];
    return kContentModes[0];
}

inline std::string contentModeVideoResolution(const ContentMode& m) {
    return std::to_string(m.width) + "x" + std::to_string(m.height);
}

// True iff (w,h) is an explicitly supported product content size.
inline bool isSupportedContentSize(int w, int h) {
    return findContentModeExact(w, h) != nullptr;
}

} // namespace misterplex
