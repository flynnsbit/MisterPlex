// Classify ffmpeg stderr lines for the daemon pump.
// Geometry banners are parsed elsewhere; progress noise is dropped; everything
// else is Diagnostic and MUST be logged — silent discard of Error/Invalid lines
// is how a zero-frame session can leave no cause on device (ce727a43 class).
#pragma once

#include <cctype>
#include <string>

namespace misterplex {

enum class FfmpegStderrClass {
    Empty = 0,
    ProgressNoise,     // frame= / -stats CR lines — do not log every tick
    GeometryCandidate, // may carry Stream Video WxH
    Diagnostic,        // errors, warnings, other — always surface
};

inline void trimInPlaceAscii(std::string& s) {
    while (!s.empty() && (s.back() == '\r' || s.back() == ' ' || s.back() == '\t'))
        s.pop_back();
    size_t i = 0;
    while (i < s.size() && (s[i] == ' ' || s[i] == '\t' || s[i] == '\r'))
        ++i;
    if (i)
        s.erase(0, i);
}

// Split one line from an accumulating stderr buffer. Honours '\n' and bare '\r'
// (ffmpeg -stats progress uses CR updates). Returns false if no complete line.
inline bool takeFfmpegStderrLine(std::string& acc, std::string* out) {
    if (!out)
        return false;
    out->clear();
    size_t i = 0;
    for (; i < acc.size(); ++i) {
        const char c = acc[i];
        if (c == '\n' || c == '\r')
            break;
    }
    if (i >= acc.size())
        return false;
    *out = acc.substr(0, i);
    // Consume delimiter; swallow CR LF as one break.
    size_t skip = i + 1;
    if (acc[i] == '\r' && skip < acc.size() && acc[skip] == '\n')
        ++skip;
    acc.erase(0, skip);
    trimInPlaceAscii(*out);
    return true;
}

inline FfmpegStderrClass classifyFfmpegStderrLine(const std::string& lineIn) {
    std::string line = lineIn;
    trimInPlaceAscii(line);
    if (line.empty())
        return FfmpegStderrClass::Empty;

    // -stats / residual progress (must not spam the daemon log).
    if (line.rfind("frame=", 0) == 0)
        return FfmpegStderrClass::ProgressNoise;
    // "size=… time=… bitrate=…" progress without Stream/Video tokens.
    const bool hasFpsToken = line.find("fps=") != std::string::npos;
    const bool hasStream = line.find("Stream") != std::string::npos;
    const bool hasVideo = line.find("Video:") != std::string::npos ||
                          line.find("video:") != std::string::npos;
    if (hasFpsToken && !hasStream && !hasVideo)
        return FfmpegStderrClass::ProgressNoise;
    if (line.rfind("size=", 0) == 0 && line.find("time=") != std::string::npos && !hasVideo)
        return FfmpegStderrClass::ProgressNoise;

    if (hasVideo)
        return FfmpegStderrClass::GeometryCandidate;

    return FfmpegStderrClass::Diagnostic;
}

// True when a Diagnostic line should be elevated (still logged either way).
inline bool ffmpegStderrLooksFatal(const std::string& line) {
    auto has = [&](const char* s) { return line.find(s) != std::string::npos; };
    return has("Error") || has("error") || has("Invalid") || has("failed") ||
           has("Failed") || has("Nothing was written") || has("Conversion failed") ||
           has("No such file") || has("Connection refused") || has("Server returned") ||
           has("HTTP error") || has("Option not found") || has("Unrecognized option");
}

} // namespace misterplex
