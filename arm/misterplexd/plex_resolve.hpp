#pragma once
// Slim Plex resolve for MiSTerPlex Phase 2/4 (transitional ARM decode).
// Harvested from mistercast-linux lessons; full feature set ports later.

#include <cstdint>
#include <string>
#include <utility>
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
    // Phase 4 match-source-Hz / Content FPS hints from PMS metadata.
    std::string videoFrameRate; // raw Media@videoFrameRate (e.g. 24p, NTSC, 60p)
    std::string frameRate;      // raw Stream@frameRate (e.g. 23.976)
    int sourceFpsHint = 0;      // nearest OSD Content FPS: 12/24/30/60, or 0 unknown
    // Exact content rate as a rational (24000/1001 for 23.976). 0/0 = unknown.
    // Drives A/V pacing; must NOT be bucketed (23.976 vs 24 = ~1 ms/s of lipsync drift).
    int fpsNum = 0;
    int fpsDen = 0;
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

struct PlexTranscodeProfile {
    std::string name;
    std::string videoResolution;
    int maxVideoBitrateKbps = 0;
    int videoQuality = 0;
    // H.264 constraints advertised to PMS. Keep these aligned with the FPGA/host
    // decoder; do not ask PMS for Main/High/CABAC when only baseline-ish vectors
    // are proven.
    std::string h264Profile;
    int h264Level = 0; // Plex capability/profile-extra integer form: 30 == Level 3.0.
};

// Built-in PMS universal transcode profiles. 240p is the legacy shipping profile;
// 480p requests 624x480 coded (39 MB columns) to match the proven DDR frame-store geometry.
const std::vector<PlexTranscodeProfile>& plexTranscodeProfiles();

// Match by profile name ("240p"/"480p") or exact WxH resolution.
bool applyPlexTranscodeProfile(const std::string& nameOrResolution,
                               struct WeakLadder& weak);

// Weak ladder params for PMS universal transcoder (dual-A9 safe defaults).
struct WeakLadder {
    std::string profileName = "240p";
    std::string videoResolution = "320x240"; // e.g. 320x240, 480x360, 640x480
    int maxVideoBitrateKbps = 1000;
    int videoQuality = 40;
    std::string videoCodec = "h264";
    std::string audioCodec = "aac";
    std::string h264Profile = "baseline";
    int h264Level = 30;
    // Server-side PMS profile that forces Baseline/CAVLC/ref=1 transcodes.
    // If the XML is absent, tested PMS versions fall back gracefully to Generic.
    std::string clientProfileName = "MiSTerPlex";
    // Phase 4: ask PMS to burn subtitles into the universal ladder when set.
    bool burnSubtitles = false;
    int subtitleStreamId = -1; // -1 = PMS default / first
};

// Guard rails for built-in and configured ladders.
bool validateWeakLadder(const WeakLadder& weak, std::string* why = nullptr);
std::string plexClientProfileExtra(const WeakLadder& weak);
std::string plexClientCapabilities(const WeakLadder& weak);
std::string buildUniversalTranscodeUrl(const std::string& base,
                                       const std::string& metadataKey,
                                       const std::string& token,
                                       const std::string& session,
                                       int64_t offsetMs,
                                       const WeakLadder& weak);

// True when metadata Media@videoCodec looks like H.264/AVC (direct Part friendly for STREAM).
bool mediaVideoIsH264(const std::string& plexMetadataXml);

// Resolve a playMedia key against PMS, or pass through local/http paths.
// weakAlways: always request PMS universal H.264 ladder (recommended on dual A9 / STREAM=0).
// preferDirectH264: when true (STREAM=1 product path), use direct Part stream if source is
// already H.264 so host CAVLC recon can run on Baseline/Main without High/CABAC remux.
// Non-H.264 still falls through to the weak universal ladder.
ResolveResult resolvePlayTarget(const std::string& rawKeyOrPath, const std::string& plexBase,
                                const std::string& token, int64_t offsetMs = 0,
                                bool weakAlways = true, const WeakLadder& weak = {},
                                bool preferDirectH264 = false);

// Fetch /playQueues/{id} for next-episode / skipNext. currentKey or playQueueItemId
// selects currentIndex when present.
PlayQueue fetchPlayQueue(const std::string& queueIdOrContainerKey, const std::string& plexBase,
                         const std::string& token, const std::string& currentKey = {},
                         const std::string& playQueueItemId = {});

// Companion offsets are milliseconds; PMS universal `offset=` is whole seconds.
// Rounds half-up so 1500 ms → 2 s (matches buildUniversal).
inline int64_t universalOffsetSeconds(int64_t offsetMs) {
    if (offsetMs <= 0)
        return 0;
    return (offsetMs + 500) / 1000;
}

// Chrome-profile FFmpeg headers required by PMS universal transcoder.
std::string plexFfmpegHeaders(const std::string& sessionId, const std::string& token);
std::string plexFfmpegHeaders(const std::string& sessionId, const std::string& token,
                              const WeakLadder& weak);

// Best-effort PMS GET using the same curl-based Plex client identity as resolve.
// Headers are name/value pairs; response body is discarded by callers.
// Success is HTTP 2xx only — a non-empty 401 HTML body is a failure (not "ok").
struct PlexHttpNoBodyResult {
    bool ok = false;
    int httpStatus = 0; // 0 = transport/parse failure; otherwise curl %{http_code}
};

// True iff status is an HTTP success (2xx). status<=0 is never ok.
bool plexHttpStatusOk(int httpStatus);

// Parse curl -w '%{http_code}' output (trims whitespace). Returns 0 if not a 3-digit code.
int parseCurlHttpCode(const std::string& curlWriteOut);

PlexHttpNoBodyResult plexHttpGetNoBodyResult(
    const std::string& url, const std::vector<std::pair<std::string, std::string>>& headers = {},
    int timeoutSec = 4);

bool plexHttpGetNoBody(const std::string& url,
                       const std::vector<std::pair<std::string, std::string>>& headers = {},
                       int timeoutSec = 4);

// Call /universal/decision before start.mp4 (PMS 1.43+).
bool ensureUniversalDecision(const std::string& startUrl, const std::string& sessionId,
                             const std::string& token);
bool ensureUniversalDecision(const std::string& startUrl, const std::string& sessionId,
                             const std::string& token, const WeakLadder& weak);

// Map PMS videoFrameRate / frameRate strings to OSD Content FPS (12/24/30/60).
// Returns 0 when unknown. Prefers numeric frameRate when present.
int contentFpsHint(const std::string& videoFrameRate, const std::string& frameRate = {});

// Apply conf SOURCE_FPS (auto|12|24|30|60|off) over a resolved hint.
// "auto"/empty → use resolvedHint; "off" → 0; numeric → forced bucket.
int applySourceFpsConf(const std::string& sourceFpsConf, int resolvedHint);

// Exact content frame rate as a rational — NOT bucketed.
// Prefers numeric Stream@frameRate ("23.976"), falls back to Media@videoFrameRate
// tokens ("24p", "NTSC", "PAL"). Snaps near-values onto the standard broadcast family
// so 23.976 becomes exactly 24000/1001 rather than a lossy decimal.
// Returns false and leaves num/den at 0 when the rate cannot be determined.
bool parseExactFps(const std::string& videoFrameRate, const std::string& frameRate,
                   int& num, int& den);

// Parse conf AV_CONTENT_FPS override ("auto"|"off"|"23.976"|"24000/1001"|"25").
// "auto"/empty keeps the resolved rate; "off" forces unknown (0/0).
// Returns true when num/den were set from the conf (including the "off" case).
bool applyContentFpsConf(const std::string& conf, int& num, int& den);

} // namespace misterplex
