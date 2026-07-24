#pragma once
// Slim Plex resolve for MiSTerPlex Phase 2 (transitional ARM decode).
// Harvested from mistercast-linux lessons; full feature set ports later.

#include <cstdint>
#include <string>

namespace misterplex {

struct ResolveResult {
    bool ok = false;
    bool transcoded = false;
    std::string playable;     // path or http(s) URL for FFmpeg
    std::string httpHeaders;  // FFmpeg -headers (CRLF), if any
    std::string title;
    std::string detail;
    int64_t durationMs = 0;
    int64_t viewOffsetMs = 0;
    std::string ratingKey;
};

std::string urlDecode(const std::string& in);
std::string urlEncodeQuery(const std::string& s);

// Build http(s)://host:port base. Rewrites Docker-bridge plex.direct to empty
// (caller should supply LAN fallback).
std::string buildPlexBase(const std::string& protocol, const std::string& address,
                          const std::string& port, const std::string& lanFallback = {});

// Resolve a playMedia key against PMS, or pass through local/http paths.
// weakAlways: always request PMS universal H.264 ladder (recommended on dual A9).
ResolveResult resolvePlayTarget(const std::string& rawKeyOrPath, const std::string& plexBase,
                                const std::string& token, int64_t offsetMs = 0,
                                bool weakAlways = true);

// Chrome-profile FFmpeg headers required by PMS universal transcoder.
std::string plexFfmpegHeaders(const std::string& sessionId, const std::string& token);

// Call /universal/decision before start.mp4 (PMS 1.43+).
bool ensureUniversalDecision(const std::string& startUrl, const std::string& sessionId,
                             const std::string& token);

} // namespace misterplex
