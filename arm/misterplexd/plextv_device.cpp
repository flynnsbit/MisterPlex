#include "plextv_device.hpp"

#include "log_redact.hpp"

#include <arpa/inet.h>
#include <cctype>
#include <cstdio>
#include <cstdlib>
#include <netinet/in.h>
#include <sstream>
#include <sys/socket.h>
#include <unistd.h>

namespace misterplex {
namespace {

std::string shellQuote(const std::string& s) {
    std::string o = "'";
    for (char c : s) {
        if (c == '\'')
            o += "'\\''";
        else
            o += c;
    }
    o += "'";
    return o;
}

void appendIdentityHeaders(std::vector<std::pair<std::string, std::string>>& headers,
                           const PlexTvDeviceIdentity& id, const std::string& token) {
    // Full identity set — parent confirmed these headers cause plex.tv to upsert
    // a provides=player device record keyed by X-Plex-Client-Identifier.
    headers.push_back({"X-Plex-Client-Identifier", id.clientIdentifier});
    headers.push_back({"X-Plex-Product", id.product});
    headers.push_back({"X-Plex-Version", id.version});
    headers.push_back({"X-Plex-Platform", id.platform});
    headers.push_back({"X-Plex-Device", id.device});
    headers.push_back({"X-Plex-Device-Name", id.deviceName});
    headers.push_back({"X-Plex-Provides", id.provides});
    headers.push_back({"X-Plex-Token", token});
    headers.push_back({"Accept", "application/json"});
}

bool equalsIgnoreCase(const std::string& a, const std::string& b) {
    if (a.size() != b.size())
        return false;
    for (size_t i = 0; i < a.size(); ++i) {
        if (std::tolower(static_cast<unsigned char>(a[i])) !=
            std::tolower(static_cast<unsigned char>(b[i])))
            return false;
    }
    return true;
}

} // namespace

std::string plexTvClientIdentifierUnsafeReason(const std::string& id,
                                               const std::vector<std::string>& foreignIds) {
    // Trim is not applied — callers must pass the raw --id / Resource-Identifier.
    if (id.empty())
        return "empty";

    // Whitespace / control characters are never valid.
    for (unsigned char c : id) {
        if (c <= 0x20 || c == 0x7f)
            return "contains whitespace or control characters";
    }

    // Hard denylist: compile-time / historical defaults that are shared across
    // installs or collide with request-identity headers used against PMS.
    static const char* kBannedExact[] = {
        "misterplex-1", // main.cpp default when --id is omitted
        "misterplex",   // generic product slug, not a device id
        "misterplex-",  // prefix alone
        "chrome",
        "plex",
        "player",
        "1",
    };
    for (const char* b : kBannedExact) {
        if (equalsIgnoreCase(id, b))
            return std::string("banned default identifier '") + b + "'";
    }

    // Namespace: player IDs must use the misterplex- prefix so they cannot equal
    // typical PMS machineIdentifiers (hex UUID strings without this prefix).
    const std::string prefix = kPlexTvClientIdPrefix;
    if (id.size() < prefix.size() || id.compare(0, prefix.size(), prefix) != 0)
        return std::string("must start with '") + prefix + "'";

    // Require a non-trivial suffix after the prefix (at least 3 chars → total >= 13).
    // "misterplex-dev" (14) and "misterplex-abc" (13) pass; "misterplex-ab" (12) fails.
    if (id.size() < prefix.size() + 3)
        return "suffix after misterplex- too short (need >= 3 chars)";

    for (const auto& foreign : foreignIds) {
        if (!foreign.empty() && id == foreign)
            return "matches denylisted foreign/PMS identifier";
    }

    return {};
}

bool plexTvResourcesBodyMentionsClient(const std::string& body,
                                       const std::string& clientIdentifier) {
    if (body.empty() || clientIdentifier.empty())
        return false;
    // JSON: "clientIdentifier":"value" or "clientIdentifier": "value"
    // XML:  clientIdentifier="value"
    const std::string jsonKey = "\"clientIdentifier\"";
    const std::string xmlKey = "clientIdentifier=\"";
    size_t pos = 0;
    while (pos < body.size()) {
        auto j = body.find(jsonKey, pos);
        auto x = body.find(xmlKey, pos);
        size_t hit = std::string::npos;
        bool isJson = false;
        if (j != std::string::npos && (x == std::string::npos || j < x)) {
            hit = j;
            isJson = true;
        } else if (x != std::string::npos) {
            hit = x;
            isJson = false;
        }
        if (hit == std::string::npos)
            break;
        size_t valStart = 0;
        if (isJson) {
            auto colon = body.find(':', hit + jsonKey.size());
            if (colon == std::string::npos)
                break;
            auto q1 = body.find('"', colon + 1);
            if (q1 == std::string::npos)
                break;
            valStart = q1 + 1;
            auto q2 = body.find('"', valStart);
            if (q2 == std::string::npos)
                break;
            if (body.substr(valStart, q2 - valStart) == clientIdentifier)
                return true;
            pos = q2 + 1;
        } else {
            valStart = hit + xmlKey.size();
            auto q2 = body.find('"', valStart);
            if (q2 == std::string::npos)
                break;
            if (body.substr(valStart, q2 - valStart) == clientIdentifier)
                return true;
            pos = q2 + 1;
        }
    }
    return false;
}

bool buildPlexTvRegisterRequest(const PlexTvDeviceIdentity& id, const std::string& token,
                                PlexTvHttpRequest& out,
                                const std::vector<std::string>& foreignIds) {
    out = {};
    if (token.empty())
        return false;
    if (!isSafePlexTvClientIdentifier(id.clientIdentifier, foreignIds))
        return false;
    if (id.product.empty() || id.provides.empty())
        return false;

    out.method = "GET";
    out.url = PlexTvDeviceAnnouncer::kRegisterUrl;
    appendIdentityHeaders(out.headers, id, token);
    // No body — registration is the authenticated identity GET itself.
    return true;
}

std::string detectLanIpv4() {
    int fd = ::socket(AF_INET, SOCK_DGRAM, 0);
    if (fd < 0)
        return {};
    sockaddr_in a{};
    a.sin_family = AF_INET;
    a.sin_port = htons(53);
    // Public DNS — connect does not send packets; used only to pick a source IP.
    if (inet_pton(AF_INET, "1.1.1.1", &a.sin_addr) != 1) {
        close(fd);
        return {};
    }
    if (connect(fd, reinterpret_cast<sockaddr*>(&a), sizeof(a)) != 0) {
        close(fd);
        return {};
    }
    sockaddr_in local{};
    socklen_t len = sizeof(local);
    if (getsockname(fd, reinterpret_cast<sockaddr*>(&local), &len) != 0) {
        close(fd);
        return {};
    }
    close(fd);
    char buf[64];
    if (!inet_ntop(AF_INET, &local.sin_addr, buf, sizeof(buf)))
        return {};
    std::string ip(buf);
    if (ip.empty() || ip == "0.0.0.0")
        return {};
    return ip;
}

int defaultPlexTvHttp(const PlexTvHttpRequest& req, std::string* responseBody) {
    if (req.url.empty() || req.method.empty())
        return 0;

    // Capture body + trailing status line without writing to a temp file.
    std::ostringstream cmd;
    cmd << "curl -sS -g -k -L --http1.1 --connect-timeout 6 --max-time 12"
        << " -X " << shellQuote(req.method);
    for (const auto& h : req.headers) {
        if (h.first.empty())
            continue;
        cmd << " -H " << shellQuote(h.first + ": " + h.second);
    }
    if (!req.body.empty())
        cmd << " --data-binary " << shellQuote(req.body);
    cmd << " -w " << shellQuote("\n__MISTERPLEX_HTTP_STATUS__:%{http_code}")
        << " " << shellQuote(req.url) << " 2>/dev/null";

    FILE* p = popen(cmd.str().c_str(), "r");
    if (!p)
        return 0;
    std::string out;
    char buf[4096];
    while (fgets(buf, sizeof(buf), p))
        out += buf;
    pclose(p);

    const std::string marker = "\n__MISTERPLEX_HTTP_STATUS__:";
    auto m = out.rfind(marker);
    int status = 0;
    std::string body;
    if (m == std::string::npos) {
        body = out;
    } else {
        body = out.substr(0, m);
        const std::string codeStr = out.substr(m + marker.size());
        size_t end = codeStr.find_first_not_of("0123456789");
        const std::string digits = (end == std::string::npos) ? codeStr : codeStr.substr(0, end);
        if (!digits.empty())
            status = std::atoi(digits.c_str());
    }
    if (responseBody)
        *responseBody = std::move(body);
    return status;
}

PlexTvDeviceAnnouncer::PlexTvDeviceAnnouncer(PlexTvHttpFn http, bool async)
    : http_(std::move(http)), async_(async) {
    if (!http_)
        http_ = defaultPlexTvHttp;
}

PlexTvDeviceAnnouncer::~PlexTvDeviceAnnouncer() { stop(); }

void PlexTvDeviceAnnouncer::configure(PlexTvDeviceIdentity identity, std::string token,
                                      bool enabled, std::vector<std::string> foreignClientIds) {
    std::lock_guard<std::mutex> lock(mu_);
    identity_ = std::move(identity);
    token_ = std::move(token);
    enabled_ = enabled;
    foreignClientIds_ = std::move(foreignClientIds);
}

void PlexTvDeviceAnnouncer::logLine(const std::string& s) const {
    if (log_)
        log_(redactSensitive(s));
}

void PlexTvDeviceAnnouncer::start() {
    {
        std::lock_guard<std::mutex> lock(mu_);
        if (running_.load() || workerStarted_)
            return;
        if (!enabled_) {
            logLine("plextv: registration skipped (PLEXTV_ANNOUNCE off)");
            return;
        }
        if (token_.empty()) {
            logLine("plextv: registration skipped (PLEX_TOKEN missing)");
            return;
        }
        const std::string why =
            plexTvClientIdentifierUnsafeReason(identity_.clientIdentifier, foreignClientIds_);
        if (!why.empty()) {
            // CRITICAL: never hit plex.tv with an unsafe identifier — that is how
            // player attributes can merge onto another account device record.
            logLine("plextv: registration skipped (unsafe clientIdentifier: " + why +
                    ") id='" + identity_.clientIdentifier +
                    "' — set a unique --id starting with misterplex- "
                    "(deploy default: misterplex-dev); refusing network call");
            return;
        }
        stopRequested_ = false;
        running_.store(true);
    }

    // Synchronous first attempt so startup logs are immediate and greppable.
    attemptOnce(/*startup=*/true);

    if (!async_)
        return;

    {
        std::lock_guard<std::mutex> lock(mu_);
        if (stopRequested_) {
            running_.store(false);
            return;
        }
        workerStarted_ = true;
        worker_ = std::thread([this] { workerLoop(); });
    }
}

void PlexTvDeviceAnnouncer::attemptOnce(bool startup) {
    PlexTvDeviceIdentity id;
    std::string token;
    std::vector<std::string> foreign;
    {
        std::lock_guard<std::mutex> lock(mu_);
        id = identity_;
        token = token_;
        foreign = foreignClientIds_;
    }

    // Re-check safety every attempt (configure may race in tests).
    const std::string why = plexTvClientIdentifierUnsafeReason(id.clientIdentifier, foreign);
    if (!why.empty()) {
        logLine("plextv: registration skipped (unsafe clientIdentifier: " + why + ")");
        return;
    }

    PlexTvHttpRequest req;
    if (!buildPlexTvRegisterRequest(id, token, req, foreign)) {
        logLine("plextv: registration skipped (incomplete identity)");
        return;
    }

    std::string body;
    int status = 0;
    try {
        status = http_(req, &body);
    } catch (...) {
        status = 0;
    }

    const bool httpOk = (status >= 200 && status < 300);
    const bool seenSelf = plexTvResourcesBodyMentionsClient(body, id.clientIdentifier);

    // Measured 2026-07-30: HTTP 200 does NOT upsert a device. Only
    // clientIdentifier appearing in the resources body is success.
    if (httpOk && seenSelf) {
        {
            std::lock_guard<std::mutex> lock(mu_);
            consecutiveFailures_ = 0;
        }
        std::ostringstream msg;
        msg << "plextv: registration succeeded http_status=" << status
            << " endpoint=api/v2/resources"
            << " clientIdentifier=" << id.clientIdentifier
            << " deviceName=" << id.deviceName
            << " provides=" << id.provides
            << " self_in_body=1";
        if (startup)
            msg << " (startup)";
        logLine(msg.str());
        return;
    }

    int failures = 0;
    {
        std::lock_guard<std::mutex> lock(mu_);
        ++consecutiveFailures_;
        failures = consecutiveFailures_;
    }
    // Rate-limit failure logs: always emit startup + first fail, then every 10th
    // or when backoff is capped. Endpoint replacement is a separate research lane;
    // do not spam the device log or burn journal CPU on a sticky 404/no-op.
    const bool logThis = startup || failures == 1 || (failures % 10) == 0 || failures >= 9;
    if (!logThis)
        return;
    std::ostringstream msg;
    if (httpOk && !seenSelf) {
        // No-op: GET accepted but device not in body — not a registration.
        msg << "plextv: registration no-op http_status=" << status
            << " endpoint=api/v2/resources"
            << " clientIdentifier=" << id.clientIdentifier
            << " self_in_body=0"
            << " reason=clientIdentifier_not_in_resources_body"
            << " consecutive=" << failures;
    } else {
        msg << "plextv: registration failed http_status=" << status
            << " endpoint=api/v2/resources"
            << " clientIdentifier=" << id.clientIdentifier
            << " consecutive=" << failures;
    }
    if (startup)
        msg << " (startup)";
    if (failures > 1 && (failures % 10) == 0)
        msg << " (rate-limited; endpoint research pending)";
    logLine(msg.str());
}

void PlexTvDeviceAnnouncer::workerLoop() {
    for (;;) {
        std::chrono::seconds wait = kRefreshInterval;
        {
            std::lock_guard<std::mutex> lock(mu_);
            if (consecutiveFailures_ > 0) {
                int shift = consecutiveFailures_ - 1;
                if (shift > 8)
                    shift = 8;
                auto back = kInitialBackoff * (1 << shift);
                if (back > kMaxBackoff)
                    back = kMaxBackoff;
                wait = back;
            }
        }

        {
            std::unique_lock<std::mutex> lock(mu_);
            if (cv_.wait_for(lock, wait, [this] { return stopRequested_; }))
                break;
        }

        if (stopRequested_)
            break;
        attemptOnce(/*startup=*/false);
    }
}

void PlexTvDeviceAnnouncer::stop() {
    {
        std::lock_guard<std::mutex> lock(mu_);
        stopRequested_ = true;
    }
    cv_.notify_all();
    if (worker_.joinable())
        worker_.join();
    workerStarted_ = false;

    // No DELETE teardown: legacy devices.xml is 404. Device lastSeenAt ages out
    // when we stop refreshing. Never issue a network call with a weak id here.
    if (enabled_)
        logLine("plextv: announcer stopped (no unregister; record ages out on plex.tv)");

    running_.store(false);
}

} // namespace misterplex
