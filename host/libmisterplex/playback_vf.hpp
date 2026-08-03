#pragma once
// Pure ffmpeg -vf construction for the ARM rawvideo playback path.
// Identity skip: when source coded size already equals the decode bank, emit NO
// scale/pad — free CPU against the measured 0.939x 720p wall.

#include <string>

namespace misterplex {

// Build the video filter chain for decode → bank geometry.
// source_w/source_h: known coded delivery size (0 = unknown → must scale/pad).
// target_w/target_h: daemon outW_/outH_ bank.
// fps_num/fps_den: optional fps= filter (0 = omit).
//
// Identity: source == target on both axes → empty scale/pad (fps-only or empty).
// Non-identity: scale=Tw:Th:force_original_aspect_ratio=decrease,pad=Tw:Th:(ow-iw)/2:(oh-ih)/2
inline std::string buildPlaybackVideoFilter(int target_w, int target_h, int source_w,
                                            int source_h, int fps_num = 0,
                                            int fps_den = 0) {
    std::string vf;
    const bool known = source_w > 0 && source_h > 0;
    const bool identity =
        known && source_w == target_w && source_h == target_h && target_w > 0 &&
        target_h > 0;

    if (!identity && target_w > 0 && target_h > 0) {
        vf = "scale=" + std::to_string(target_w) + ":" + std::to_string(target_h) +
             ":force_original_aspect_ratio=decrease,pad=" + std::to_string(target_w) +
             ":" + std::to_string(target_h) + ":(ow-iw)/2:(oh-ih)/2";
    }
    if (fps_num > 0 && fps_den > 0) {
        if (!vf.empty())
            vf += ",";
        vf += "fps=" + std::to_string(fps_num) + "/" + std::to_string(fps_den);
    }
    return vf;
}

// True if vf contains a scale= or pad= stage (for tests / startup asserts).
inline bool playbackVfHasGeometryFilter(const std::string& vf) {
    return vf.find("scale=") != std::string::npos ||
           vf.find("pad=") != std::string::npos;
}

} // namespace misterplex
