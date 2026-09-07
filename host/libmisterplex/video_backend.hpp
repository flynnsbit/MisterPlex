#pragma once

#include <cstdlib>
#include <cstring>
#include <string>

namespace misterplex {

enum class VideoBackend { Unselected, LegacySoftware, FpgaH264 };

inline VideoBackend configuredVideoBackend() {
    const char* value = std::getenv("MPX_VIDEO_BACKEND");
    if (value && std::strcmp(value, "fpga-h264") == 0)
        return VideoBackend::FpgaH264;
    if (value && std::strcmp(value, "legacy-software") == 0)
        return VideoBackend::LegacySoftware;
    return VideoBackend::Unselected;
}

inline bool matchedLegacyVideoCore(const std::string& livePrefix, const char* expected) {
    if (!expected || livePrefix != expected)
        return false;
    return livePrefix == "dfebf2bf" || livePrefix == "41adb98c" ||
           livePrefix == "07f54d9f" || livePrefix == "4d6efef9" ||
           livePrefix == "61db00e7";
}

} // namespace misterplex
