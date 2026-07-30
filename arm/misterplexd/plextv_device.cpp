#include "plextv_device.hpp"

#include "log_redact.hpp"
#include "plex_resolve.hpp"

#include <arpa/inet.h>
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
    headers.push_back({"X-Plex-Client-Identifier", id.clientIdentifier});
    headers.push_back({"X-Plex-Product", id.product});
    headers.push_back({"X-Plex-Version", id.version});
    headers.push_back({"X-Plex-Platform", id.platform});
    headers.push_back({"X-Plex-Device", id.device});
    headers.push_back({"X-Plex-Device-Name", id.deviceName});
    headers.push_back({"X-Plex-Provides", id.provides});
    headers.push_back({"X-Plex-Token", token});
    headers.push_back({"Accept", "application/xml"});
}

std::string connectionFormBody(const std::string& lanAddress, uint16_t port) {
    const std::string uri = "http://" + lanAddress + ":" + std::to_string(port);
    std::ostringstream body;
    body << "Connection[][protocol]=http"
         << "&Connection[][address]=" << urlEncodeQuery(lanAddress)
         << "&Connection[][port]=" << port
         << "&Connection[][uri]=" << urlEncodeQuery(uri)
         << "&Connection[][local]=1";
    return body.str();
}

} // namespace

bool buildPlexTvRegisterRequest(const PlexTvDeviceIdentity& id, const std::string& token,
                                const std::string& lanAddress, PlexTvHttpRequest& out) {
    out = {};
    if (token.empty() || id.clientIdentifier.empty() || lanAddress.empty() || id.port == 0)
        return false;

    out.method = "POST";
    out.url = "https://plex.tv/devices.xml";
    appendIdentityHeaders(out.headers, id, token);
    out.headers.push_back({"Content-Type", "application/x-www-form-urlencoded"});
    out.body = connectionFormBody(lanAddress, id.port);
    return true;
}

bool buildPlexTvUnregisterRequest(const std::string& token, const std::string& clientIdentifier,
                                  const std::string& deviceId, PlexTvHttpRequest& out) {
    out = {};
    if (token.empty() || deviceId.empty())
        return false;

    out.method = "DELETE";
    out.url = "https://plex.tv/devices/" + urlEncodeQuery(deviceId) + ".xml";
    // Minimal identity so plex.tv can attribute the delete.
    out.headers = {
        {"X-Plex-Token", token},
        {"X-Plex-Client-Identifier",
         clientIdentifier.empty() ? std::string("misterplex") : clientIdentifier},
        {"Accept", "application/xml"},
    };
    return true;
}

std::string parsePlexTvDeviceId(const std::string& xml) {
    // Prefer <Device ... id="N" ...>. First match is enough.
    const std::string key = "id=\"";
    // Prefer an id attribute on a Device tag when present.
    auto dev = xml.find("<Device");
    size_t searchFrom = (dev == std::string::npos) ? 0 : dev;
    auto pos = xml.find(key, searchFrom);
    if (pos == std::string::npos)
        return {};
    pos += key.size();
    auto end = xml.find('"', pos);
    if (end == std::string::npos || end == pos)
        return {};
    return xml.substr(pos, end - pos);
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
    // curl -w appends the status after the body on stdout.
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
        // No marker — treat entire output as body; status unknown.
        body = out;
    } else {
        body = out.substr(0, m);
        const std::string codeStr = out.substr(m + marker.size());
        // Trim trailing whitespace/newlines.
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
                                      bool enabled) {
    std::lock_guard<std::mutex> lock(mu_);
    identity_ = std::move(identity);
    token_ = std::move(token);
    enabled_ = enabled;
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
        if (identity_.clientIdentifier.empty()) {
            logLine("plextv: registration skipped (client identifier empty)");
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
    {
        std::lock_guard<std::mutex> lock(mu_);
        id = identity_;
        token = token_;
    }

    const std::string lan = detectLanIpv4();
    if (lan.empty()) {
        logLine(std::string("plextv: registration ") +
                (startup ? "startup " : "") +
                "failed — could not detect LAN IPv4 (http_status=0)");
        std::lock_guard<std::mutex> lock(mu_);
        ++consecutiveFailures_;
        return;
    }

    PlexTvHttpRequest req;
    if (!buildPlexTvRegisterRequest(id, token, lan, req)) {
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

    const bool ok = (status >= 200 && status < 300);
    if (ok) {
        const std::string devId = parsePlexTvDeviceId(body);
        {
            std::lock_guard<std::mutex> lock(mu_);
            consecutiveFailures_ = 0;
            if (!devId.empty())
                deviceId_ = devId;
        }
        std::ostringstream msg;
        msg << "plextv: registration succeeded http_status=" << status
            << " clientIdentifier=" << id.clientIdentifier
            << " deviceName=" << id.deviceName
            << " port=" << id.port
            << " uri=http://" << lan << ":" << id.port;
        if (!devId.empty())
            msg << " deviceId=" << devId;
        if (startup)
            msg << " (startup)";
        logLine(msg.str());
        return;
    }

    {
        std::lock_guard<std::mutex> lock(mu_);
        ++consecutiveFailures_;
    }
    std::ostringstream msg;
    msg << "plextv: registration failed http_status=" << status
        << " clientIdentifier=" << id.clientIdentifier;
    if (startup)
        msg << " (startup)";
    logLine(msg.str());
}

void PlexTvDeviceAnnouncer::workerLoop() {
    for (;;) {
        std::chrono::seconds wait = kRefreshInterval;
        {
            std::lock_guard<std::mutex> lock(mu_);
            if (consecutiveFailures_ > 0) {
                // Exponential backoff: 30, 60, 120, ... capped.
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

    // Best-effort teardown — never block shutdown on plex.tv.
    PlexTvHttpRequest unreg;
    std::string token;
    std::string clientId;
    std::string deviceId;
    {
        std::lock_guard<std::mutex> lock(mu_);
        token = token_;
        clientId = identity_.clientIdentifier;
        deviceId = deviceId_;
    }
    if (buildPlexTvUnregisterRequest(token, clientId, deviceId, unreg)) {
        std::string body;
        int status = 0;
        try {
            status = http_(unreg, &body);
        } catch (...) {
            status = 0;
        }
        std::ostringstream msg;
        msg << "plextv: unregister http_status=" << status << " deviceId=" << deviceId;
        logLine(msg.str());
    }

    running_.store(false);
}

} // namespace misterplex
