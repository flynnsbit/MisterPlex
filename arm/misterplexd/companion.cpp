#include "companion.hpp"

#include <arpa/inet.h>
#include <cstring>
#include <netinet/in.h>
#include <sys/socket.h>
#include <unistd.h>

#include <chrono>
#include <cstdio>
#include <sstream>
#include <vector>

namespace misterplex {
namespace {

bool setReuse(int fd) {
    int on = 1;
    return setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &on, sizeof(on)) == 0;
}

std::string queryParam(const std::string& req, const char* key) {
    const std::string k = std::string(key) + "=";
    auto pos = req.find(k);
    if (pos == std::string::npos)
        return {};
    pos += k.size();
    auto end = req.find_first_of(" &\r\n", pos);
    return req.substr(pos, end == std::string::npos ? std::string::npos : end - pos);
}

void sendHttp(int fd, int code, const char* ctype, const std::string& body) {
    char hdr[256];
    std::snprintf(hdr, sizeof(hdr),
                  "HTTP/1.1 %d OK\r\nContent-Type: %s\r\nContent-Length: %zu\r\n"
                  "Connection: close\r\nAccess-Control-Allow-Origin: *\r\n\r\n",
                  code, ctype, body.size());
    (void)::send(fd, hdr, std::strlen(hdr), 0);
    if (!body.empty())
        (void)::send(fd, body.data(), body.size(), 0);
}

} // namespace

void Companion::log(const std::string& s) const {
    if (log_)
        log_(s);
    else
        std::fprintf(stderr, "%s\n", s.c_str());
}

std::string Companion::lanIp() const {
    // Best-effort: UDP connect trick to a public DNS (no packets required for local bind)
    int fd = ::socket(AF_INET, SOCK_DGRAM, 0);
    if (fd < 0)
        return "127.0.0.1";
    sockaddr_in a{};
    a.sin_family = AF_INET;
    a.sin_port = htons(53);
    inet_pton(AF_INET, "1.1.1.1", &a.sin_addr);
    if (connect(fd, reinterpret_cast<sockaddr*>(&a), sizeof(a)) != 0) {
        close(fd);
        return "127.0.0.1";
    }
    sockaddr_in local{};
    socklen_t len = sizeof(local);
    getsockname(fd, reinterpret_cast<sockaddr*>(&local), &len);
    close(fd);
    char buf[64];
    inet_ntop(AF_INET, &local.sin_addr, buf, sizeof(buf));
    return buf;
}

std::string Companion::gdmPayload() const {
    std::ostringstream o;
    o << "HTTP/1.0 200 OK\r\n"
      << "Content-Type: plex/media-player\r\n"
      << "Name: " << name_ << "\r\n"
      << "Port: " << port_ << "\r\n"
      << "Product: MiSTerPlex\r\n"
      << "Version: 0.1.0\r\n"
      << "Protocol: plex\r\n"
      << "Protocol-Version: 1\r\n"
      << "Protocol-Capabilities: timeline,playback,navigation,mirror,playqueues\r\n"
      << "Device-Class: stb\r\n"
      << "Resource-Identifier: " << machineId_ << "\r\n"
      << "\r\n";
    return o.str();
}

std::string Companion::resourcesXml() const {
    std::ostringstream o;
    o << "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
      << "<MediaContainer>"
      << "<Player title=\"" << name_ << "\" product=\"MiSTerPlex\" "
      << "protocol=\"plex\" protocolVersion=\"1\" "
      << "protocolCapabilities=\"timeline,playback,navigation,mirror,playqueues\" "
      << "deviceClass=\"stb\" machineIdentifier=\"" << machineId_ << "\" "
      << "version=\"0.1.0\"/>"
      << "</MediaContainer>";
    return o.str();
}

std::string Companion::timelineXml(const std::string& commandId) const {
    std::lock_guard<std::mutex> lock(mu_);
    std::ostringstream o;
    o << "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
      << "<MediaContainer commandID=\"" << commandId << "\">"
      << "<Timeline state=\"" << state_ << "\" time=\"" << timeMs_ << "\" duration=\""
      << durationMs_ << "\" type=\"video\" itemType=\"video\" controllable=\"playPause,stop,seekTo\" "
      << "machineIdentifier=\"" << machineId_ << "\" protocol=\"plex\"/>"
      << "</MediaContainer>";
    return o.str();
}

void Companion::setState(const std::string& state, int64_t timeMs, int64_t durationMs) {
    std::lock_guard<std::mutex> lock(mu_);
    state_ = state;
    timeMs_ = timeMs;
    durationMs_ = durationMs;
}

bool Companion::start() {
    if (running_.exchange(true))
        return true;
    gdmThr_ = std::thread([this] { gdmLoop(); });
    httpThr_ = std::thread([this] { httpLoop(); });
    log("companion: GDM + HTTP :" + std::to_string(port_) + " name=" + name_);
    return true;
}

void Companion::stop() {
    if (!running_.exchange(false))
        return;
    // Wake accepts via connecting to self
    int fd = ::socket(AF_INET, SOCK_STREAM, 0);
    if (fd >= 0) {
        sockaddr_in a{};
        a.sin_family = AF_INET;
        a.sin_port = htons(port_);
        inet_pton(AF_INET, "127.0.0.1", &a.sin_addr);
        connect(fd, reinterpret_cast<sockaddr*>(&a), sizeof(a));
        close(fd);
    }
    if (gdmThr_.joinable())
        gdmThr_.join();
    if (httpThr_.joinable())
        httpThr_.join();
    log("companion: stopped");
}

void Companion::gdmLoop() {
    int fd = ::socket(AF_INET, SOCK_DGRAM, 0);
    if (fd < 0) {
        log("GDM: socket failed");
        return;
    }
    setReuse(fd);
    sockaddr_in addr{};
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = INADDR_ANY;
    addr.sin_port = htons(32412);
    if (bind(fd, reinterpret_cast<sockaddr*>(&addr), sizeof(addr)) != 0) {
        log("GDM: bind 32412 failed (PMS may own it) — still advertising via presence later");
        // Continue without exclusive bind; some setups use SO_REUSEPORT
    } else {
        log("GDM: listening UDP 32412");
    }

    // Optional periodic advertise
    auto lastAdv = std::chrono::steady_clock::now();
    while (running_.load()) {
        fd_set rfds;
        FD_ZERO(&rfds);
        FD_SET(fd, &rfds);
        timeval tv{0, 200000};
        int r = select(fd + 1, &rfds, nullptr, nullptr, &tv);
        if (r > 0 && FD_ISSET(fd, &rfds)) {
            char buf[2048];
            sockaddr_in peer{};
            socklen_t plen = sizeof(peer);
            ssize_t n = recvfrom(fd, buf, sizeof(buf) - 1, 0, reinterpret_cast<sockaddr*>(&peer), &plen);
            if (n > 0) {
                buf[n] = 0;
                if (std::strstr(buf, "M-SEARCH") || std::strstr(buf, "M-SEARCH *") ||
                    std::strstr(buf, "plex")) {
                    auto payload = gdmPayload();
                    sendto(fd, payload.data(), payload.size(), 0, reinterpret_cast<sockaddr*>(&peer),
                           plen);
                }
            }
        }
        auto now = std::chrono::steady_clock::now();
        if (now - lastAdv > std::chrono::seconds(5)) {
            lastAdv = now;
            // broadcast hello
            int on = 1;
            setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &on, sizeof(on));
            sockaddr_in bcast{};
            bcast.sin_family = AF_INET;
            bcast.sin_port = htons(32412);
            bcast.sin_addr.s_addr = INADDR_BROADCAST;
            auto payload = gdmPayload();
            sendto(fd, payload.data(), payload.size(), 0, reinterpret_cast<sockaddr*>(&bcast),
                   sizeof(bcast));
        }
    }
    close(fd);
}

void Companion::httpLoop() {
    int fd = ::socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) {
        log("HTTP: socket failed");
        return;
    }
    setReuse(fd);
    sockaddr_in addr{};
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = INADDR_ANY;
    addr.sin_port = htons(port_);
    if (bind(fd, reinterpret_cast<sockaddr*>(&addr), sizeof(addr)) != 0) {
        log("HTTP: bind :" + std::to_string(port_) + " failed");
        close(fd);
        return;
    }
    listen(fd, 16);
    log("HTTP: companion on :" + std::to_string(port_) + " ip≈" + lanIp());

    while (running_.load()) {
        fd_set rfds;
        FD_ZERO(&rfds);
        FD_SET(fd, &rfds);
        timeval tv{0, 200000};
        if (select(fd + 1, &rfds, nullptr, nullptr, &tv) <= 0)
            continue;
        int c = accept(fd, nullptr, nullptr);
        if (c < 0)
            continue;
        char buf[8192];
        ssize_t n = recv(c, buf, sizeof(buf) - 1, 0);
        if (n <= 0) {
            close(c);
            continue;
        }
        buf[n] = 0;
        std::string req(buf, static_cast<size_t>(n));

        if (req.find("GET /resources") != std::string::npos ||
            req.find("GET /identity") != std::string::npos) {
            sendHttp(c, 200, "application/xml", resourcesXml());
        } else if (req.find("GET /player/timeline/poll") != std::string::npos ||
                   req.find("/timeline") != std::string::npos) {
            auto cid = queryParam(req, "commandID");
            if (cid.empty())
                cid = "0";
            sendHttp(c, 200, "application/xml", timelineXml(cid));
        } else if (req.find("playMedia") != std::string::npos || req.find("/player/playback/") != std::string::npos) {
            auto key = queryParam(req, "key");
            auto offset = queryParam(req, "offset");
            int64_t offMs = 0;
            if (!offset.empty())
                offMs = std::atoll(offset.c_str()) * 1000; // PMS often seconds
            // Also support viewOffset ms
            auto vo = queryParam(req, "viewOffset");
            if (!vo.empty())
                offMs = std::atoll(vo.c_str());

            if (req.find("playMedia") != std::string::npos || req.find("/play") != std::string::npos) {
                setState("buffering", offMs, 0);
                sendHttp(c, 200, "application/xml", timelineXml(queryParam(req, "commandID")));
                if (onPlay_)
                    onPlay_(key.empty() ? std::string("(no-key)") : key, offMs);
                setState("playing", offMs, durationMs_);
                log("playMedia key=" + key + " offMs=" + std::to_string(offMs));
            } else if (req.find("pause") != std::string::npos) {
                setState("paused", timeMs_, durationMs_);
                sendHttp(c, 200, "application/xml", timelineXml(queryParam(req, "commandID")));
            } else if (req.find("stop") != std::string::npos) {
                setState("stopped", 0, 0);
                sendHttp(c, 200, "application/xml", timelineXml(queryParam(req, "commandID")));
            } else if (req.find("seekTo") != std::string::npos || req.find("seek") != std::string::npos) {
                auto t = queryParam(req, "offset");
                if (t.empty())
                    t = queryParam(req, "time");
                int64_t ms = t.empty() ? 0 : std::atoll(t.c_str());
                setState(state_, ms, durationMs_);
                sendHttp(c, 200, "application/xml", timelineXml(queryParam(req, "commandID")));
            } else {
                sendHttp(c, 200, "application/xml", timelineXml(queryParam(req, "commandID")));
            }
        } else if (req.find("OPTIONS") == 0) {
            sendHttp(c, 200, "text/plain", "");
        } else {
            sendHttp(c, 404, "text/plain", "not found");
        }
        close(c);
    }
    close(fd);
}

} // namespace misterplex
