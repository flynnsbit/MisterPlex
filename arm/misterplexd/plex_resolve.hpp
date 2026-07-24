#pragma once
// Slim Plex resolve for MiSTerPlex Phase 2/4 (transitional ARM decode).
// Harvested from mistercast-linux lessons; full feature set ports later.

#include <cstdint>
#include <string>
#include <vector>

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

struct QueueItem {
    std::string key;
    std::string ratingKey;
    std::string playQueueItemId;
    std::string title;
    int64_t durationMs = 0;
};

struct PlayQueue {
    bool ok = false;
    std::string detail;
    std::string playQueueId;
    std::string playQueueVersion;
    std::string containerKey; // /playQueues/N
    std::vector<QueueItem> items;
    int currentIndex = 0;
};

std::string urlDecode(const std::string& in);
std::string urlEncodeQuery(const std::string& s);

// Normalize a PMS base: trim, strip trailing slash, add http:// if bare host[:port].
std::string normalizePlexBase(const std::string& raw);

// Split comma/semicolon/whitespace-separated server list into normalized bases.
// Empty tokens skipped. Order preserved (first = default).
std::vector<std::string> parsePlexServerList(const std::string& csvOrSingle);

// Merge PLEX_SERVERS CSV + repeated PLEX_BASE values into a unique ordered list.
std::vector<std::string> mergePlexServers(const std::string& serversCsv,
                                          const std::vector<std::string>& baseLines);

// Build http(s)://host:port base. Rewrites Docker-bridge plex.direct to empty
// (caller should supply LAN fallback).
std::string buildPlexBase(const std::string& protocol, const std::string& address,
                          const std::string& port, const std::string& lanFallback = {});

// Weak ladder params for PMS universal transcoder (dual-A9 safe defaults).
struct WeakLadder {
    std::string videoResolution = "320x240"; // e.g. 320x240, 480x360, 640x480
    int maxVideoBitrateKbps = 1000;
    int videoQuality = 40;
    // Phase 4: ask PMS to burn subtitles into the universal ladder when set.
    bool burnSubtitles = false;
    int subtitleStreamId = -1; // -1 = PMS default / first
};

// Resolve a playMedia key against PMS, or pass through local/http paths.
// weakAlways: always request PMS universal H.264 ladder (recommended on dual A9).
ResolveResult resolvePlayTarget(const std::string& rawKeyOrPath, const std::string& plexBase,
                                const std::string& token, int64_t offsetMs = 0,
                                bool weakAlways = true, const WeakLadder& weak = {});

// Fetch /playQueues/{id} for next-episode / skipNext. currentKey or playQueueItemId
// selects currentIndex when present.
PlayQueue fetchPlayQueue(const std::string& queueIdOrContainerKey, const std::string& plexBase,
                         const std::string& token, const std::string& currentKey = {},
                         const std::string& playQueueItemId = {});

// Chrome-profile FFmpeg headers required by PMS universal transcoder.
std::string plexFfmpegHeaders(const std::string& sessionId, const std::string& token);

// Call /universal/decision before start.mp4 (PMS 1.43+).
bool ensureUniversalDecision(const std::string& startUrl, const std::string& sessionId,
                             const std::string& token);

} // namespace misterplex
