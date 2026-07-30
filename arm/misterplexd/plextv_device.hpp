#pragma once
// plex.tv player device registration for MiSTerPlex.
//
// Modern Plex clients populate the cast/player picker from the account's
// plex.tv device list (provides containing "player"). GDM alone is not enough
// when the browsing PMS never probes the LAN. This module POSTs the daemon as
// a player to https://plex.tv/devices.xml and refreshes on a background timer.
//
// Fail-soft and opt-in (PLEXTV_ANNOUNCE=1). Never blocks the playback path.

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
    std::string method; // "POST" or "DELETE"
    std::string url;
    std::vector<std::pair<std::string, std::string>> headers;
    std::string body; // form-urlencoded for POST; empty for DELETE
};

// Build the registration POST. Requires non-empty token, clientIdentifier, and
// lanAddress. Returns false when inputs are insufficient (caller logs + skips).
bool buildPlexTvRegisterRequest(const PlexTvDeviceIdentity& id, const std::string& token,
                                const std::string& lanAddress, PlexTvHttpRequest& out);

// Best-effort unregister. deviceId comes from a prior registration response.
// Returns false when inputs are insufficient.
bool buildPlexTvUnregisterRequest(const std::string& token, const std::string& clientIdentifier,
                                  const std::string& deviceId, PlexTvHttpRequest& out);

// Parse Device@id from a plex.tv devices.xml response body (best-effort).
std::string parsePlexTvDeviceId(const std::string& xml);

// Detect a LAN IPv4 via UDP connect trick (same approach as Companion::lanIp).
// Returns empty on failure (never hardcodes a lab address).
std::string detectLanIpv4();

// HTTP sink: perform request, return HTTP status code (0 = transport failure).
// Optional response body out-param for device-id parsing.
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

    explicit PlexTvDeviceAnnouncer(PlexTvHttpFn http = {}, bool async = true);
    ~PlexTvDeviceAnnouncer();

    PlexTvDeviceAnnouncer(const PlexTvDeviceAnnouncer&) = delete;
    PlexTvDeviceAnnouncer& operator=(const PlexTvDeviceAnnouncer&) = delete;

    void setLog(PlexTvLogFn log) { log_ = std::move(log); }

    // Configure before start(). enabled=false → start() is a no-op skip log.
    void configure(PlexTvDeviceIdentity identity, std::string token, bool enabled);

    // Spawns the refresh worker when enabled. Always fail-soft; never throws.
    // Logs the first attempt outcome loudly for device-log grepping.
    void start();

    // Stop refresh; best-effort unregister when a device id was captured.
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

    std::mutex mu_;
    std::condition_variable cv_;
    std::atomic<bool> running_{false};
    bool stopRequested_ = false;
    bool workerStarted_ = false;
    std::thread worker_;

    std::string deviceId_;
    int consecutiveFailures_ = 0;
};

} // namespace misterplex
