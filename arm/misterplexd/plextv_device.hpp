#pragma once
// plex.tv player device presence check / announce helper for MiSTerPlex.
//
// IMPORTANT (2026-07-30 research — see .agent-work/plextv-register/evidence.txt):
//   GET https://plex.tv/api/v2/resources is a DEVICE LIST, not a create/upsert.
//   HTTP 200 with self_in_body=0 means "listed others; we are not registered".
//   Legacy POST https://plex.tv/devices.xml returns 404 and must not be used.
//   Cloud device rows are created by sign-in/PIN device binding (device token),
//   not by GETting resources with a borrowed owner token.
//   LAN Select Player is driven primarily by PMS /clients (GDM), which is a
//   separate path from this module (Companion GDM + /resources).
//
// This module only:
//   - Optionally GETs resources with identity headers (opt-in PLEXTV_ANNOUNCE=1)
//   - Logs succeeded only when clientIdentifier appears in the body
//   - Logs no-op when 2xx but self absent; failed on non-2xx
//   - Refuses empty/defaulted/weak clientIdentifiers (collision guard)
//
// Fail-soft. Never blocks the playback path.

#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstdint>
#include <functional>
#include <mutex>
#include <string>
#include <thread>
#include <utility>
#include <vector>

namespace misterplex {

// Required prefix for safe player client identifiers. PMS machineIdentifiers
// are typically hex UUIDs without this prefix — keeping the namespaces apart
// is the primary collision guard.
inline constexpr const char kPlexTvClientIdPrefix[] = "misterplex-";

// Product identity for plex.tv — keep aligned with Companion GDM /resources.
struct PlexTvDeviceIdentity {
    std::string clientIdentifier; // Resource-Identifier / --id (e.g. misterplex-dev)
    std::string product = "MiSTerPlex";
    std::string version = "0.2.0";
    std::string platform = "Linux";
    std::string device = "MiSTer";
    std::string deviceName = "MiSTerPlex";
    std::string provides = "player";
    uint16_t port = 3005;
};

struct PlexTvHttpRequest {
    std::string method; // "GET"
    std::string url;
    std::vector<std::pair<std::string, std::string>> headers;
    std::string body; // unused for GET registration
};

// Returns empty when id is safe to send as X-Plex-Client-Identifier.
// Otherwise a short reason suitable for logs (no secrets).
// foreignIds: optional denylist (e.g. known PMS machineIdentifiers).
std::string plexTvClientIdentifierUnsafeReason(
    const std::string& id, const std::vector<std::string>& foreignIds = {});

inline bool isSafePlexTvClientIdentifier(const std::string& id,
                                         const std::vector<std::string>& foreignIds = {}) {
    return plexTvClientIdentifierUnsafeReason(id, foreignIds).empty();
}

// True when haystack (JSON or XML resources body) mentions clientIdentifier.
bool plexTvResourcesBodyMentionsClient(const std::string& body,
                                       const std::string& clientIdentifier);

// Build the registration GET. Requires non-empty token and a SAFE
// clientIdentifier. Returns false when inputs are insufficient / unsafe.
bool buildPlexTvRegisterRequest(const PlexTvDeviceIdentity& id, const std::string& token,
                                PlexTvHttpRequest& out,
                                const std::vector<std::string>& foreignIds = {});

// Detect a LAN IPv4 via UDP connect trick (same approach as Companion::lanIp).
// Returns empty on failure (never hardcodes a lab address). Used only for
// diagnostic log lines — not required for registration.
std::string detectLanIpv4();

// HTTP sink: perform request, return HTTP status code (0 = transport failure).
// Optional response body out-param for identity verification.
using PlexTvHttpFn = std::function<int(const PlexTvHttpRequest& req, std::string* responseBody)>;
using PlexTvLogFn = std::function<void(const std::string&)>;

// Default curl-based sink (uses the same style as plex_resolve). Unit tests inject a mock.
int defaultPlexTvHttp(const PlexTvHttpRequest& req, std::string* responseBody);

class PlexTvDeviceAnnouncer {
public:
    // Conservative refresh so the device does not go stale on plex.tv.
    static constexpr std::chrono::seconds kRefreshInterval{300}; // 5 minutes
    static constexpr std::chrono::seconds kInitialBackoff{30};
    static constexpr std::chrono::seconds kMaxBackoff{900}; // 15 minutes

    // Live endpoint parent measured as HTTP 200; registration is a side effect.
    static constexpr const char* kRegisterUrl =
        "https://plex.tv/api/v2/resources?includeHttps=1";

    explicit PlexTvDeviceAnnouncer(PlexTvHttpFn http = {}, bool async = true);
    ~PlexTvDeviceAnnouncer();

    PlexTvDeviceAnnouncer(const PlexTvDeviceAnnouncer&) = delete;
    PlexTvDeviceAnnouncer& operator=(const PlexTvDeviceAnnouncer&) = delete;

    void setLog(PlexTvLogFn log) { log_ = std::move(log); }

    // Configure before start(). enabled=false → start() is a no-op skip log.
    // foreignClientIds: known non-player identifiers (PMS machineIds) that must
    // never be sent as this player's X-Plex-Client-Identifier.
    void configure(PlexTvDeviceIdentity identity, std::string token, bool enabled,
                   std::vector<std::string> foreignClientIds = {});

    // Spawns the refresh worker when enabled. Always fail-soft; never throws.
    // Logs the first attempt outcome loudly for device-log grepping.
    // Makes ZERO network calls when the client identifier is unsafe.
    void start();

    // Stop refresh. No plex.tv DELETE (legacy devices.xml teardown is gone);
    // records age out when lastSeenAt stops updating.
    void stop();

    bool running() const { return running_.load(); }

private:
    void workerLoop();
    void attemptOnce(bool startup);
    void logLine(const std::string& s) const;

    PlexTvHttpFn http_;
    bool async_ = true;
    PlexTvLogFn log_;

    PlexTvDeviceIdentity identity_;
    std::string token_;
    bool enabled_ = false;
    std::vector<std::string> foreignClientIds_;

    std::mutex mu_;
    std::condition_variable cv_;
    std::atomic<bool> running_{false};
    bool stopRequested_ = false;
    bool workerStarted_ = false;
    std::thread worker_;

    int consecutiveFailures_ = 0;
};

} // namespace misterplex
