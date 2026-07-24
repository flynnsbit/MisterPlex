#include "companion.hpp"

#include <arpa/inet.h>
#include <cctype>
#include <cstdlib>
#include <cstring>
#include <fcntl.h>
#include <netinet/in.h>
#include <sys/socket.h>
#include <unistd.h>

#include <chrono>
#include <cstdio>
#include <sstream>
#include <thread>
#include <vector>

namespace misterplex {
namespace {

bool setReuse(int fd) {
    int on = 1;
    return setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &on, sizeof(on)) == 0;
}

// Prevent forked ffmpeg/sh from inheriting companion sockets (would hold :3005).
void setCloexec(int fd) {
    int fl = fcntl(fd, F_GETFD);
    if (fl >= 0)
        fcntl(fd, F_SETFD, fl | FD_CLOEXEC);
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

std::string pctDecode(const std::string& in) {
    std::string out;
    out.reserve(in.size());
    for (size_t i = 0; i < in.size(); ++i) {
        if (in[i] == '%' && i + 2 < in.size() &&
            std::isxdigit(static_cast<unsigned char>(in[i + 1])) &&
            std::isxdigit(static_cast<unsigned char>(in[i + 2]))) {
            out.push_back(static_cast<char>(std::strtol(in.substr(i + 1, 2).c_str(), nullptr, 16)));
            i += 2;
        } else if (in[i] == '+') {
            out.push_back(' ');
        } else {
            out.push_back(in[i]);
        }
    }
    return out;
}

std::string headerValue(const std::string& req, const char* name) {
    std::string key = std::string(name) + ":";
    auto pos = req.find(key);
    if (pos == std::string::npos)
        return {};
    pos += key.size();
    while (pos < req.size() && (req[pos] == ' ' || req[pos] == '\t'))
        ++pos;
    auto end = req.find("\r\n", pos);
    return req.substr(pos, end == std::string::npos ? std::string::npos : end - pos);
}

void sendHttp(int fd, int code, const char* ctype, const std::string& body) {
    char hdr[320];
    const char* status = (code == 200) ? "OK" : "Not Found";
    std::snprintf(hdr, sizeof(hdr),
                  "HTTP/1.1 %d %s\r\nContent-Type: %s\r\nContent-Length: %zu\r\n"
                  "Connection: close\r\nAccess-Control-Allow-Origin: *\r\n"
                  "Access-Control-Allow-Headers: *\r\nAccess-Control-Allow-Methods: *\r\n\r\n",
                  code, status, ctype, body.size());
    (void)::send(fd, hdr, std::strlen(hdr), 0);
    if (!body.empty())
        (void)::send(fd, body.data(), body.size(), 0);
}

// Companion offset/viewOffset are milliseconds (PMS universal offset= is seconds).
int64_t parseOffsetMs(const std::string& req, bool* present) {
    if (present)
        *present = false;
    for (const char* name : {"offset", "viewOffset", "time", "startTimeOffset"}) {
        auto off = queryParam(req, name);
        if (!off.empty()) {
            if (present)
                *present = true;
            return std::atoll(off.c_str());
        }
    }
    return 0;
}

// /library/metadata/123 → "123" (Web often omits ratingKey= on cast URLs).
std::string ratingKeyFromKey(const std::string& key) {
    const std::string marker = "/library/metadata/";
    auto pos = key.find(marker);
    if (pos == std::string::npos)
        return {};
    pos += marker.size();
    size_t end = pos;
    while (end < key.size() && std::isdigit(static_cast<unsigned char>(key[end])))
        ++end;
    if (end == pos)
        return {};
    return key.substr(pos, end - pos);
}

PlayRequest parsePlayRequest(const std::string& req) {
    PlayRequest pr;
    pr.key = pctDecode(queryParam(req, "key"));
    pr.containerKey = pctDecode(queryParam(req, "containerKey"));
    pr.playQueueItemId = queryParam(req, "playQueueItemID");
    pr.playQueueVersion = queryParam(req, "playQueueVersion");
    pr.ratingKey = queryParam(req, "ratingKey");
    if (pr.ratingKey.empty())
        pr.ratingKey = ratingKeyFromKey(pr.key);
    // Web indexes cast queue by playQueueItemID; fall back to ratingKey so scrubber opens.
    if (pr.playQueueItemId.empty() && !pr.ratingKey.empty())
        pr.playQueueItemId = pr.ratingKey;
    pr.address = pctDecode(queryParam(req, "address"));
    pr.protocol = queryParam(req, "protocol");
    pr.port = queryParam(req, "port");
    pr.token = queryParam(req, "token");
    if (pr.token.empty())
        pr.token = queryParam(req, "X-Plex-Token");
    if (pr.token.empty())
        pr.token = headerValue(req, "X-Plex-Token");
    pr.serverMachineId = queryParam(req, "machineIdentifier");
    pr.offsetMs = parseOffsetMs(req, &pr.offsetPresent);
    if (pr.containerKey.find("/playQueues/") != std::string::npos) {
        auto rest = pr.containerKey.substr(std::string("/playQueues/").size());
        auto q = rest.find('?');
        pr.playQueueId = (q == std::string::npos) ? rest : rest.substr(0, q);
    } else {
        // Never treat containerKey=/library/metadata/N as a queue (poisons Web NY→isOpen).
        auto pq = queryParam(req, "playQueueID");
        if (!pq.empty())
            pr.playQueueId = pq;
        if (pr.containerKey.find("/playQueues/") == std::string::npos &&
            pr.containerKey.find("/library/") != std::string::npos)
            pr.containerKey.clear();
    }
    return pr;
}

} // namespace

void Companion::log(const std::string& s) const {
    if (log_)
        log_(s);
    else
        std::fprintf(stderr, "%s\n", s.c_str());
}

std::string Companion::xmlEsc(const std::string& s) {
    std::string o;
    o.reserve(s.size());
    for (char c : s) {
        switch (c) {
        case '&':
            o += "&amp;";
            break;
        case '<':
            o += "&lt;";
            break;
        case '>':
            o += "&gt;";
            break;
        case '"':
            o += "&quot;";
            break;
        default:
            o += c;
        }
    }
    return o;
}

std::string Companion::lanIp() const {
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
      << "Version: 0.2.0\r\n"
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
    o << "<?xml version=\"1.0\" encoding=\"UTF-8\"?>"
      << "<MediaContainer>"
      << "<Player title=\"" << xmlEsc(name_) << "\" product=\"MiSTerPlex\" "
      << "protocol=\"plex\" protocolVersion=\"1\" "
      << "protocolCapabilities=\"timeline,playback,navigation,mirror,playqueues\" "
      << "deviceClass=\"stb\" machineIdentifier=\"" << xmlEsc(machineId_) << "\" "
      << "version=\"0.2.0\"/>"
      << "</MediaContainer>";
    return o.str();
}

std::string Companion::timelineXml(const std::string& commandId) const {
    std::lock_guard<std::mutex> lock(mu_);

    std::string videoState = state_;
    const bool holdIdle =
        !wantPlay_ && (prePlayHold_ || castBound_) &&
        (videoState == "stopped" || videoState.empty() || videoState == "buffering");
    if (wantPlay_ && (videoState == "stopped" || videoState.empty()))
        videoState = "buffering";
    else if (holdIdle)
        videoState = "buffering";

    const bool mediaActive =
        wantPlay_ && (videoState == "playing" || videoState == "paused" ||
                      videoState == "buffering" || !pendingKey_.empty());
    if (mediaActive && videoState == "stopped")
        videoState = "buffering";

    const std::string videoLoc = mediaActive ? "fullScreenVideo" : "navigation";
    const char* videoCtrl =
        "playPause,stop,volume,audioStream,subtitleStream,seekTo,skipPrevious,skipNext,"
        "stepBack,stepForward";

    std::string container;
    if (!pendingPlayQueueId_.empty()) {
        container = "/playQueues/" + pendingPlayQueueId_ + "?own=1";
    } else if (!pendingContainerKey_.empty() &&
               pendingContainerKey_.find("/playQueues/") != std::string::npos) {
        container = pendingContainerKey_;
        const auto q = container.find('?');
        if (q != std::string::npos)
            container = container.substr(0, q);
        if (container.find("own=") == std::string::npos)
            container += "?own=1";
    }

    const int64_t reportMs = mediaActive ? std::max<int64_t>(0, timeMs_) : 0;
    const int64_t dur = (mediaActive && durationMs_ > 0) ? durationMs_ : 0;

    std::ostringstream b;
    b << "<?xml version=\"1.0\" encoding=\"UTF-8\"?>"
      << "<MediaContainer machineIdentifier=\"" << xmlEsc(machineId_) << "\" size=\"1\" commandID=\""
      << xmlEsc(commandId) << "\" location=\"" << videoLoc << "\">";

    b << "<Timeline type=\"video\" state=\"" << videoState << "\" time=\"" << reportMs
      << "\" duration=\"" << dur << "\" ";
    if (dur > 0)
        b << "seekRange=\"0-" << dur << "\" ";
    b << "volume=\"100\" mute=\"0\" controllable=\"" << videoCtrl << "\" location=\""
      << videoLoc << "\" mediaIndex=\"0\" partIndex=\"0\" ";

    if (mediaActive && !pendingKey_.empty()) {
        const std::string srvId = !serverMachineId_.empty() ? serverMachineId_ : machineId_;
        b << "machineIdentifier=\"" << xmlEsc(srvId) << "\" ";
        if (!serverHost_.empty()) {
            b << "protocol=\"" << xmlEsc(serverProto_) << "\" address=\"" << xmlEsc(serverHost_)
              << "\" port=\"" << xmlEsc(serverPort_) << "\" ";
        }
        b << "providerIdentifier=\"com.plexapp.plugins.library\" ";
        b << "key=\"" << xmlEsc(pendingKey_) << "\" ";
        if (!container.empty())
            b << "containerKey=\"" << xmlEsc(container) << "\" ";
        if (!pendingRatingKey_.empty())
            b << "ratingKey=\"" << xmlEsc(pendingRatingKey_) << "\" ";
        if (!pendingPlayQueueId_.empty()) {
            b << "playQueueID=\"" << xmlEsc(pendingPlayQueueId_) << "\" ";
            b << "playQueueVersion=\""
              << xmlEsc(pendingPlayQueueVersion_.empty() ? "1" : pendingPlayQueueVersion_)
              << "\" ";
        }
        if (!pendingPlayQueueItemId_.empty())
            b << "playQueueItemID=\"" << xmlEsc(pendingPlayQueueItemId_) << "\" ";
    } else {
        b << "machineIdentifier=\"" << xmlEsc(machineId_) << "\" ";
    }
    b << "/>";
    b << "</MediaContainer>";
    return b.str();
}

void Companion::setState(const std::string& state, int64_t timeMs, int64_t durationMs) {
    std::lock_guard<std::mutex> lock(mu_);
    // After stop clearMedia(), prePlayHold_ is set while wantPlay_ is false. Ignore
    // late media-thread progress so async teardown cannot re-arm fullScreenVideo.
    if (!wantPlay_ && prePlayHold_ &&
        (state == "playing" || state == "paused" || state == "buffering" || state == "ended")) {
        return;
    }
    state_ = state;
    timeMs_ = timeMs;
    if (durationMs > 0)
        durationMs_ = durationMs;
    // Keep wantPlay_ latched after playMedia until clearMedia()/stop.
    // Player progress "stopped" (EOF) must not drop scrubber bind fields.
    if (state == "playing" || state == "paused" || state == "buffering")
        wantPlay_ = true;
}

void Companion::bindMedia(const PlayRequest& req, int64_t durationMs) {
    std::lock_guard<std::mutex> lock(mu_);
    pendingKey_ = req.key;
    pendingContainerKey_ = req.containerKey;
    pendingPlayQueueId_ = req.playQueueId;
    pendingPlayQueueItemId_ = req.playQueueItemId;
    pendingPlayQueueVersion_ = req.playQueueVersion.empty() ? "1" : req.playQueueVersion;
    pendingRatingKey_ = req.ratingKey;
    serverMachineId_ = req.serverMachineId;
    serverProto_ = req.protocol.empty() ? "http" : req.protocol;
    serverHost_ = req.address;
    serverPort_ = req.port.empty() ? "32400" : req.port;
    // Always take resolve duration (0 = unknown / local file without probe)
    durationMs_ = durationMs > 0 ? durationMs : 0;
    wantPlay_ = true;
    prePlayHold_ = false;
}

void Companion::clearMedia() {
    std::lock_guard<std::mutex> lock(mu_);
    // Drop media binding so polls are a clean idle (no key/container).
    // Web: video state=stopped WITH key still idles the cast player and freezes scrubber.
    pendingKey_.clear();
    pendingContainerKey_.clear();
    pendingPlayQueueId_.clear();
    pendingPlayQueueItemId_.clear();
    pendingPlayQueueVersion_.clear();
    pendingRatingKey_.clear();
    wantPlay_ = false;
    state_ = "stopped";
    timeMs_ = 0;
    durationMs_ = 0;
    // Sticky hold: after stop while cast-bound, Web often reopens Resume without a
    // fresh mirror. Pure stopped polls idle the dialog — keep buffering@navigation.
    if (castBound_)
        prePlayHold_ = true;
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
    setCloexec(fd);
    sockaddr_in addr{};
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = INADDR_ANY;
    addr.sin_port = htons(32412);
    if (bind(fd, reinterpret_cast<sockaddr*>(&addr), sizeof(addr)) != 0)
        log("GDM: bind 32412 failed — broadcast-only advertise");
    else
        log("GDM: listening UDP 32412");

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
                if (std::strstr(buf, "M-SEARCH") || std::strstr(buf, "plex")) {
                    auto payload = gdmPayload();
                    sendto(fd, payload.data(), payload.size(), 0, reinterpret_cast<sockaddr*>(&peer),
                           plen);
                }
            }
        }
        auto now = std::chrono::steady_clock::now();
        if (now - lastAdv > std::chrono::seconds(5)) {
            lastAdv = now;
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
    setCloexec(fd);
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
        char buf[16384];
        ssize_t n = recv(c, buf, sizeof(buf) - 1, 0);
        if (n <= 0) {
            close(c);
            continue;
        }
        buf[n] = 0;
        std::string req(buf, static_cast<size_t>(n));

        {
            std::lock_guard<std::mutex> lock(mu_);
            if (req.find("/player/") != std::string::npos || req.find("/resources") != std::string::npos)
                castBound_ = true;
        }

        if (req.find("OPTIONS") == 0) {
            sendHttp(c, 200, "text/plain", "");
            close(c);
            continue;
        }

        if (req.find("GET /resources") != std::string::npos ||
            req.find("GET /identity") != std::string::npos) {
            sendHttp(c, 200, "application/xml", resourcesXml());
            close(c);
            continue;
        }

        // Unsubscribe: drop cast-bound hold so idle polls can go pure stopped.
        if (req.find("/player/timeline/unsubscribe") != std::string::npos) {
            {
                std::lock_guard<std::mutex> lock(mu_);
                castBound_ = false;
                if (!wantPlay_)
                    prePlayHold_ = false;
            }
            auto cid = queryParam(req, "commandID");
            if (cid.empty())
                cid = "0";
            sendHttp(c, 200, "application/xml", timelineXml(cid));
            close(c);
            continue;
        }

        // Timeline poll / subscribe / proxy alias — never auto-start media from poll.
        if (req.find("/player/timeline/poll") != std::string::npos ||
            req.find("/player/timeline/subscribe") != std::string::npos ||
            req.find("/player/proxy/timeline") != std::string::npos ||
            (req.find("/timeline") != std::string::npos && req.find("playMedia") == std::string::npos &&
             req.find("mirror") == std::string::npos && req.find("unsubscribe") == std::string::npos)) {
            {
                std::lock_guard<std::mutex> lock(mu_);
                castBound_ = true;
                // Live poller ⇒ Web still has us as cast target; hold for Resume dialog.
                if (!wantPlay_ && !prePlayHold_)
                    prePlayHold_ = true;
            }
            auto cid = queryParam(req, "commandID");
            if (cid.empty())
                cid = "0";
            if (queryParam(req, "wait") == "1")
                std::this_thread::sleep_for(std::chrono::milliseconds(400));
            sendHttp(c, 200, "application/xml", timelineXml(cid));
            close(c);
            continue;
        }

        // Mirror: stage identity + prePlayHold (no media start). Do not demote live cast.
        if (req.find("mirror") != std::string::npos && req.find("playMedia") == std::string::npos) {
            PlayRequest pr = parsePlayRequest(req);
            {
                std::lock_guard<std::mutex> lock(mu_);
                const bool keepActive =
                    wantPlay_ && (state_ == "playing" || state_ == "buffering" || state_ == "paused");
                if (!keepActive) {
                    // Remember key for following playMedia; wire omits media bind
                    // while wantPlay_ is false (buffering@navigation hold).
                    if (!pr.key.empty())
                        pendingKey_ = pr.key;
                    if (!pr.ratingKey.empty())
                        pendingRatingKey_ = pr.ratingKey;
                    if (!pr.address.empty())
                        serverHost_ = pr.address;
                    if (!pr.protocol.empty())
                        serverProto_ = pr.protocol;
                    if (!pr.port.empty())
                        serverPort_ = pr.port;
                    if (!pr.serverMachineId.empty())
                        serverMachineId_ = pr.serverMachineId;
                    // Drop stale queue so hold never looks like a live session if
                    // wantPlay latches incorrectly; restage only valid play-queue.
                    pendingPlayQueueId_.clear();
                    pendingPlayQueueItemId_.clear();
                    pendingContainerKey_.clear();
                    if (!pr.playQueueId.empty())
                        pendingPlayQueueId_ = pr.playQueueId;
                    if (!pr.playQueueItemId.empty())
                        pendingPlayQueueItemId_ = pr.playQueueItemId;
                    if (!pr.containerKey.empty() &&
                        pr.containerKey.find("/playQueues/") != std::string::npos)
                        pendingContainerKey_ = pr.containerKey;
                    durationMs_ = 0;
                    prePlayHold_ = true;
                    wantPlay_ = false;
                    state_ = "stopped"; // wire shows buffering via prePlayHold_
                    castBound_ = true;
                }
                // else: leave live timeline alone (Web mirror after playMedia must not idle)
            }
            sendHttp(c, 200, "application/xml", timelineXml(queryParam(req, "commandID")));
            log("mirror staged key=" + pr.key);
            close(c);
            continue;
        }

        if (req.find("playMedia") != std::string::npos ||
            req.find("/player/playback/") != std::string::npos) {
            const bool isPlayMedia = req.find("playMedia") != std::string::npos;
            const bool isPause = req.find("/pause") != std::string::npos ||
                                 req.find("playback/pause") != std::string::npos;
            const bool isStop = req.find("/stop") != std::string::npos ||
                                req.find("playback/stop") != std::string::npos;
            const bool isSeek = req.find("seekTo") != std::string::npos ||
                                (req.find("/seek") != std::string::npos &&
                                 req.find("seekTo") == std::string::npos &&
                                 req.find("step") == std::string::npos);
            // Relative scrubber steps (Web remote / keyboard)
            const bool isStepForward = req.find("stepForward") != std::string::npos;
            const bool isStepBack = req.find("stepBack") != std::string::npos;
            const bool isSkipNext = req.find("skipNext") != std::string::npos;
            const bool isSkipPrevious = req.find("skipPrevious") != std::string::npos;
            const bool isResumePlay =
                !isPlayMedia && !isPause && !isStop && !isSeek && !isStepForward &&
                !isStepBack && !isSkipNext && !isSkipPrevious &&
                (req.find("/player/playback/play") != std::string::npos ||
                 req.find("playback/play?") != std::string::npos ||
                 req.find("playback/play ") != std::string::npos);

            if (isPlayMedia) {
                PlayRequest pr = parsePlayRequest(req);
                if (pr.key.empty())
                    pr.key = "(no-key)";
                {
                    std::lock_guard<std::mutex> lock(mu_);
                    wantPlay_ = true;
                    prePlayHold_ = false;
                    castBound_ = true;
                    state_ = "buffering";
                    timeMs_ = pr.offsetMs;
                    pendingKey_ = pr.key;
                    pendingContainerKey_ = pr.containerKey;
                    pendingPlayQueueId_ = pr.playQueueId;
                    pendingPlayQueueItemId_ = pr.playQueueItemId;
                    pendingPlayQueueVersion_ =
                        pr.playQueueVersion.empty() ? "1" : pr.playQueueVersion;
                    if (!pr.ratingKey.empty())
                        pendingRatingKey_ = pr.ratingKey;
                    if (!pr.address.empty())
                        serverHost_ = pr.address;
                    if (!pr.protocol.empty())
                        serverProto_ = pr.protocol;
                    if (!pr.port.empty())
                        serverPort_ = pr.port;
                    if (!pr.serverMachineId.empty())
                        serverMachineId_ = pr.serverMachineId;
                }
                auto cid = queryParam(req, "commandID");
                sendHttp(c, 200, "application/xml", timelineXml(cid));
                close(c);
                log("playMedia ACK key=" + pr.key + " offMs=" + std::to_string(pr.offsetMs));
                if (onPlay_) {
                    std::thread([this, pr]() {
                        try {
                            onPlay_(pr);
                        } catch (...) {
                            log("playMedia handler exception");
                        }
                    }).detach();
                }
                continue;
            }

            if (isPause) {
                int64_t t = 0, d = 0;
                {
                    std::lock_guard<std::mutex> lock(mu_);
                    t = timeMs_;
                    d = durationMs_;
                }
                setState("paused", t, d);
                sendHttp(c, 200, "application/xml", timelineXml(queryParam(req, "commandID")));
                if (onPause_)
                    onPause_();
                close(c);
                continue;
            }
            if (isResumePlay) {
                int64_t t = 0, d = 0;
                {
                    std::lock_guard<std::mutex> lock(mu_);
                    t = timeMs_;
                    d = durationMs_;
                }
                setState("playing", t, d);
                sendHttp(c, 200, "application/xml", timelineXml(queryParam(req, "commandID")));
                if (onResume_)
                    onResume_();
                close(c);
                continue;
            }
            if (isStop) {
                // Drop bind first so stop ACK is buffering@navigation without keys
                // (video/stopped+key idles Web and freezes scrubber / Resume dialog).
                // clearMedia before player.stop so late progress cannot re-arm wantPlay
                // (setState ignores progress while prePlayHold && !wantPlay).
                clearMedia();
                if (onStop_)
                    onStop_();
                sendHttp(c, 200, "application/xml", timelineXml(queryParam(req, "commandID")));
                close(c);
                continue;
            }
            if (isSeek) {
                bool present = false;
                int64_t ms = parseOffsetMs(req, &present);
                int64_t d = 0;
                {
                    std::lock_guard<std::mutex> lock(mu_);
                    d = durationMs_;
                    // Clamp seek into known duration so scrubber cannot overshoot.
                    if (d > 0 && ms > d)
                        ms = d;
                }
                setState("buffering", ms, d);
                sendHttp(c, 200, "application/xml", timelineXml(queryParam(req, "commandID")));
                if (onSeek_)
                    onSeek_(ms);
                close(c);
                continue;
            }
            if (isStepForward || isStepBack) {
                // Default ±10s; optional offset= overrides absolute (rare) or type= for ms step.
                int64_t step = 10000;
                auto off = queryParam(req, "offset");
                if (!off.empty()) {
                    // Some clients send step size in offset; treat small values as relative ms.
                    int64_t v = std::atoll(off.c_str());
                    if (v > 0 && v < 120000)
                        step = v;
                }
                if (isStepBack)
                    step = -step;
                int64_t t = 0, d = 0;
                {
                    std::lock_guard<std::mutex> lock(mu_);
                    t = timeMs_;
                    d = durationMs_;
                }
                int64_t target = t + step;
                if (target < 0)
                    target = 0;
                if (d > 0 && target > d)
                    target = d;
                setState("buffering", target, d);
                sendHttp(c, 200, "application/xml", timelineXml(queryParam(req, "commandID")));
                if (onStep_)
                    onStep_(step);
                else if (onSeek_)
                    onSeek_(target);
                close(c);
                continue;
            }
            if (isSkipNext) {
                sendHttp(c, 200, "application/xml", timelineXml(queryParam(req, "commandID")));
                if (onSkipNext_)
                    onSkipNext_();
                close(c);
                continue;
            }
            if (isSkipPrevious) {
                int64_t d = 0;
                {
                    std::lock_guard<std::mutex> lock(mu_);
                    d = durationMs_;
                }
                setState("buffering", 0, d);
                sendHttp(c, 200, "application/xml", timelineXml(queryParam(req, "commandID")));
                if (onSkipPrevious_)
                    onSkipPrevious_();
                else if (onSeek_)
                    onSeek_(0);
                close(c);
                continue;
            }

            sendHttp(c, 200, "application/xml", timelineXml(queryParam(req, "commandID")));
            close(c);
            continue;
        }

        sendHttp(c, 404, "text/plain", "not found");
        close(c);
    }
    close(fd);
}

} // namespace misterplex
