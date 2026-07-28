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

std::string requestLine(const std::string& req) {
    auto end = req.find("\r\n");
    return req.substr(0, end == std::string::npos ? std::string::npos : end);
}

std::string redactSensitive(std::string s) {
    for (const char* key : {"X-Plex-Token", "token"}) {
        size_t pos = 0;
        const std::string pfx = std::string(key) + "=";
        while ((pos = s.find(pfx, pos)) != std::string::npos) {
            pos += pfx.size();
            auto end = s.find_first_of("& \r\n", pos);
            s.replace(pos, end == std::string::npos ? std::string::npos : end - pos,
                      "<redacted>");
            if (end == std::string::npos)
                break;
        }
    }
    return s;
}

std::string timelineBrief(const std::string& xml) {
    auto p = xml.find("<Timeline ");
    if (p == std::string::npos)
        return xml.substr(0, 160);
    auto e = xml.find("/>", p);
    return xml.substr(p, e == std::string::npos ? 240 : std::min<size_t>(e + 2 - p, 240));
}

void sendHttp(int fd, const std::string& clientIdentifier, int code, const char* ctype,
              const std::string& body) {
    char hdr[640];
    const char* status = (code == 200) ? "OK" : "Not Found";
    std::snprintf(hdr, sizeof(hdr),
                  "HTTP/1.1 %d %s\r\nContent-Type: %s\r\nContent-Length: %zu\r\n"
                  "Connection: close\r\nX-Plex-Client-Identifier: %s\r\n"
                  "Access-Control-Allow-Origin: *\r\n"
                  "Access-Control-Allow-Headers: X-Plex-Token, X-Plex-Client-Identifier, "
                  "X-Plex-Product, X-Plex-Version, X-Plex-Device, X-Plex-Device-Name, "
                  "X-Plex-Platform, Content-Type, Accept\r\n"
                  "Access-Control-Allow-Methods: GET, POST, PUT, OPTIONS\r\n"
                  "Access-Control-Expose-Headers: X-Plex-Client-Identifier\r\n\r\n",
                  code, status, ctype, body.size(), clientIdentifier.c_str());
    // MSG_NOSIGNAL: a client that hangs up before we flush (Plex's long-poll
    // timeline, or any timed-out request) would otherwise raise SIGPIPE, whose
    // default action kills the daemon silently — no log line, no dmesg entry.
    (void)::send(fd, hdr, std::strlen(hdr), MSG_NOSIGNAL);
    if (!body.empty())
        (void)::send(fd, body.data(), body.size(), MSG_NOSIGNAL);
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

std::string libraryMetadataKeyFromString(const std::string& value) {
    const std::string marker = "/library/metadata/";
    auto pos = value.find(marker);
    if (pos == std::string::npos)
        return {};
    const size_t digits = pos + marker.size();
    size_t end = digits;
    while (end < value.size() && std::isdigit(static_cast<unsigned char>(value[end])))
        ++end;
    if (end == digits)
        return {};
    return value.substr(pos, end - pos);
}

std::string serverMachineIdFromUri(const std::string& value) {
    const std::string prefix = "server://";
    if (value.rfind(prefix, 0) != 0)
        return {};
    const size_t start = prefix.size();
    const auto end = value.find('/', start);
    if (end == std::string::npos || end == start)
        return {};
    return value.substr(start, end - start);
}

void fillPlayKeyFromFallback(PlayRequest& pr, const std::string& value) {
    if (value.empty())
        return;
    if (pr.key.empty())
        pr.key = libraryMetadataKeyFromString(value);
    if (pr.serverMachineId.empty())
        pr.serverMachineId = serverMachineIdFromUri(value);
}

PlayRequest parsePlayRequest(const std::string& req) {
    PlayRequest pr;
    pr.key = pctDecode(queryParam(req, "key"));
    pr.containerKey = pctDecode(queryParam(req, "containerKey"));
    pr.playQueueItemId = queryParam(req, "playQueueItemID");
    pr.playQueueVersion = queryParam(req, "playQueueVersion");
    pr.ratingKey = queryParam(req, "ratingKey");
    pr.address = pctDecode(queryParam(req, "address"));
    pr.protocol = queryParam(req, "protocol");
    pr.port = queryParam(req, "port");
    pr.token = queryParam(req, "token");
    if (pr.token.empty())
        pr.token = queryParam(req, "X-Plex-Token");
    if (pr.token.empty())
        pr.token = headerValue(req, "X-Plex-Token");
    pr.serverMachineId = queryParam(req, "machineIdentifier");
    if (pr.key.empty())
        fillPlayKeyFromFallback(pr, pctDecode(queryParam(req, "path")));
    if (pr.key.empty())
        fillPlayKeyFromFallback(pr, pctDecode(queryParam(req, "uri")));
    if (pr.ratingKey.empty())
        pr.ratingKey = ratingKeyFromKey(pr.key);
    // Web indexes cast queue by playQueueItemID; fall back to ratingKey so scrubber opens.
    if (pr.playQueueItemId.empty() && !pr.ratingKey.empty())
        pr.playQueueItemId = pr.ratingKey;
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
    setStateLocked(state, timeMs, durationMs, false);
}

void Companion::endMediaSession(int64_t timeMs, int64_t durationMs) {
    std::lock_guard<std::mutex> lock(mu_);
    setStateLocked("stopped", timeMs, durationMs, true);
}

void Companion::setStateLocked(const std::string& state, int64_t timeMs, int64_t durationMs,
                               bool terminalSession) {
    // After stop clearMedia(), prePlayHold_ is set while wantPlay_ is false. Ignore
    // late media-thread progress so async teardown cannot re-arm fullScreenVideo.
    if (!wantPlay_ && prePlayHold_ &&
        (state == "playing" || state == "paused" || state == "buffering" || state == "ended")) {
        return;
    }
    // Stopped has two distinct meanings:
    //  1. endMediaSession(): main already observed a real terminal transition
    //     ("ended" after content) and flushed PMS. Clear the local bind.
    //  2. setState("stopped"): explicit-stop teardown after clearMedia(), or an
    //     empty/failed demux stopped@0 while a seek plant may still be visible.
    // Do not infer terminal state from timeMs; planted seek safety depends on
    // stopped@0 preserving media identity until a real terminal transition exists.
    if (state == "stopped" && wantPlay_) {
        if (terminalSession) {
            clearMediaLocked();
            return;
        }
        // Empty/failed session end (no frames): player reports stopped@0. Keep scrubber
        // time so a plant seek + step is not clobbered by demux short-read teardown.
        state_ = state;
        if (durationMs > 0)
            durationMs_ = durationMs;
        return;
    }
    // Scrubber bounds on incoming time before plant-hold compare.
    if (timeMs < 0)
        timeMs = 0;
    if (durationMs > 0 && timeMs > durationMs)
        timeMs = durationMs;
    else if (durationMs_ > 0 && timeMs > durationMs_)
        timeMs = durationMs_;

    // Async seek/step plant hold (P4-SCRUB / C-unit6):
    // Demux restart often reports buffering/playing@0 (or the plant pulse) before
    // real catch-up. Companion plant is scrubber source of truth until live
    // progress is near *and past* the target (or natural EOF at plant).
    //
    // Rules while scrubTargetMs_ >= 0:
    //  - buffering: pin time to the plant (companion plants via buffering@target);
    //    never release — plant call itself must not clear the hold.
    //  - playing/paused/ended far from plant: reflect transport state only.
    //  - playing/paused at plant pulse (near, not advanced): apply time, keep hold
    //    so late restart@0 / short-read cannot free-run after the pulse.
    //  - playing/paused advanced past plant by kScrubAdvanceMs: release + apply.
    //  - ended near plant: release + apply.
    constexpr int64_t kScrubCatchupMs = 2000;
    constexpr int64_t kScrubAdvanceMs = 400;
    if (wantPlay_ && scrubTargetMs_ >= 0 &&
        (state == "playing" || state == "paused" || state == "buffering" || state == "ended")) {
        const int64_t delta =
            timeMs > scrubTargetMs_ ? timeMs - scrubTargetMs_ : scrubTargetMs_ - timeMs;
        if (state == "buffering") {
            if (durationMs > 0)
                durationMs_ = durationMs;
            state_ = "buffering";
            // Pin thumb to plant (not demux startMs of a superseded seek).
            timeMs_ = scrubTargetMs_;
            wantPlay_ = true;
            return;
        }
        if (delta > kScrubCatchupMs) {
            if (durationMs > 0)
                durationMs_ = durationMs;
            // Reflect live transport but keep the planted scrubber time.
            if (state == "playing" || state == "paused")
                state_ = state;
            wantPlay_ = true;
            return;
        }
        // Near plant: release only after demux advances past plant, or on ended.
        if (state == "ended" ||
            ((state == "playing" || state == "paused") &&
             timeMs >= scrubTargetMs_ + kScrubAdvanceMs)) {
            scrubTargetMs_ = -1;
        }
        // else playing@plant pulse: fall through apply time, keep hold
    }


    state_ = state;
    if (durationMs > 0)
        durationMs_ = durationMs;
    // Scrubber bounds: never report negative time or time past known duration.
    if (durationMs_ > 0 && timeMs > durationMs_)
        timeMs = durationMs_;
    timeMs_ = timeMs;
    // Keep wantPlay_ latched after playMedia until clearMedia()/stop.
    // Player progress "stopped" (EOF) must not drop scrubber bind fields.
    if (state == "playing" || state == "paused" || state == "buffering")
        wantPlay_ = true;
}

bool Companion::bindMedia(const PlayRequest& req, int64_t durationMs) {
    std::lock_guard<std::mutex> lock(mu_);
    // Drop late async playMedia (resolve/network) that finishes after stop/clearMedia
    // so scrubber cannot re-arm fullScreenVideo without a fresh cast command.
    if (!wantPlay_) {
        log("bindMedia ignored — session stopped (stale playMedia)");
        return false;
    }
    // Newer playMedia/stagePlay already planted a different key — stale resolve.
    if (!pendingKey_.empty() && !req.key.empty() && pendingKey_ != req.key) {
        log("bindMedia ignored — key mismatch (stale) pending=" + pendingKey_ + " got=" +
            req.key);
        return false;
    }
    pendingKey_ = req.key;
    pendingContainerKey_ = req.containerKey;
    pendingPlayQueueId_ = req.playQueueId;
    pendingPlayQueueItemId_ = req.playQueueItemId;
    pendingPlayQueueVersion_ = req.playQueueVersion.empty() ? "1" : req.playQueueVersion;
    if (pendingContainerKey_.empty() && !pendingPlayQueueId_.empty())
        pendingContainerKey_ = "/playQueues/" + pendingPlayQueueId_ + "?own=1";
    pendingRatingKey_ = req.ratingKey;
    serverMachineId_ = req.serverMachineId;
    serverProto_ = req.protocol.empty() ? "http" : req.protocol;
    serverHost_ = req.address;
    serverPort_ = req.port.empty() ? "32400" : req.port;
    // Always take resolve duration (0 = unknown / local file without probe)
    durationMs_ = durationMs > 0 ? durationMs : 0;
    // If playMedia planted a huge offset before duration was known, clamp now.
    if (timeMs_ < 0)
        timeMs_ = 0;
    if (durationMs_ > 0 && timeMs_ > durationMs_)
        timeMs_ = durationMs_;
    // Keep plant hold across resolve: demux may still report playing@0 after bind.
    // Only playing/paused near-target in setState releases scrubTargetMs_.
    if (scrubTargetMs_ >= 0) {
        if (durationMs_ > 0 && scrubTargetMs_ > durationMs_)
            scrubTargetMs_ = durationMs_;
        // Thumb follows clamped plant (continue-watching past shorter stale duration).
        timeMs_ = scrubTargetMs_;
    }
    wantPlay_ = true;
    prePlayHold_ = false;
    return true;
}

void Companion::stagePlay(const PlayRequest& req) {
    // Plant scrubber identity for skipNext/auto-next before async resolve so
    // bindMedia key-match accepts this title and Web sees the advance early.
    std::lock_guard<std::mutex> lock(mu_);
    wantPlay_ = true;
    prePlayHold_ = false;
    castBound_ = true;
    state_ = "buffering";
    durationMs_ = 0;
    timeMs_ = req.offsetMs < 0 ? 0 : req.offsetMs;
    scrubTargetMs_ = timeMs_; // hold until demux/bind catches up
    pendingKey_ = req.key;
    pendingContainerKey_ = req.containerKey;
    pendingPlayQueueId_ = req.playQueueId;
    pendingPlayQueueItemId_ = req.playQueueItemId;
    pendingPlayQueueVersion_ = req.playQueueVersion.empty() ? "1" : req.playQueueVersion;
    if (pendingContainerKey_.empty() && !pendingPlayQueueId_.empty())
        pendingContainerKey_ = "/playQueues/" + pendingPlayQueueId_ + "?own=1";
    if (!req.ratingKey.empty())
        pendingRatingKey_ = req.ratingKey;
    if (!req.address.empty())
        serverHost_ = req.address;
    if (!req.protocol.empty())
        serverProto_ = req.protocol;
    if (!req.port.empty())
        serverPort_ = req.port;
    if (!req.serverMachineId.empty())
        serverMachineId_ = req.serverMachineId;
}

void Companion::clearMediaLocked() {
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
    scrubTargetMs_ = -1;
    // Sticky hold: after stop while cast-bound, Web often reopens Resume without a
    // fresh mirror. Pure stopped polls idle the dialog — keep buffering@navigation.
    if (castBound_)
        prePlayHold_ = true;
}

void Companion::clearMedia() {
    std::lock_guard<std::mutex> lock(mu_);
    clearMediaLocked();
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
        sockaddr_in peer{};
        socklen_t peerLen = sizeof(peer);
        int c = accept(fd, reinterpret_cast<sockaddr*>(&peer), &peerLen);
        if (c < 0)
            continue;
        char peerIp[64] = "?";
        inet_ntop(AF_INET, &peer.sin_addr, peerIp, sizeof(peerIp));
        char buf[16384];
        ssize_t n = recv(c, buf, sizeof(buf) - 1, 0);
        if (n <= 0) {
            close(c);
            continue;
        }
        buf[n] = 0;
        std::string req(buf, static_cast<size_t>(n));
        if (req.find("/player/") != std::string::npos || req.find("/resources") != std::string::npos ||
            req.find("/identity") != std::string::npos)
            log(std::string("HTTP IN peer=") + peerIp + " " + redactSensitive(requestLine(req)));

        {
            std::lock_guard<std::mutex> lock(mu_);
            if (req.find("/player/") != std::string::npos || req.find("/resources") != std::string::npos ||
                req.find("/identity") != std::string::npos)
                castBound_ = true;
        }

        if (req.find("OPTIONS") == 0) {
            sendHttp(c, machineId_, 200, "text/plain", "");
            close(c);
            continue;
        }

        if (req.find("GET /resources") != std::string::npos ||
            req.find("GET /identity") != std::string::npos) {
            sendHttp(c, machineId_, 200, "application/xml", resourcesXml());
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
            sendHttp(c, machineId_, 200, "application/xml", timelineXml(cid));
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
            auto body = timelineXml(cid);
            sendHttp(c, machineId_, 200, "application/xml", body);
            log("HTTP OUT 200 timeline " + timelineBrief(body));
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
            sendHttp(c, machineId_, 200, "application/xml", timelineXml(queryParam(req, "commandID")));
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
                    // Never plant negative scrubber time (Web/browse edge).
                    int64_t off = pr.offsetMs < 0 ? 0 : pr.offsetMs;
                    // Drop prior title duration on every fresh cast. A shorter leftover
                    // duration (e.g. testsrc 120s) must not clamp a legitimate continue-
                    // watching offset on a longer next title. bindMedia re-supplies
                    // duration after resolve and clamps timeMs_ then.
                    durationMs_ = 0;
                    timeMs_ = off;
                    scrubTargetMs_ = off; // hold until bind/demux
                    pendingKey_ = pr.key;
                    pendingContainerKey_ = pr.containerKey;
                    pendingPlayQueueId_ = pr.playQueueId;
                    pendingPlayQueueItemId_ = pr.playQueueItemId;
                    pendingPlayQueueVersion_ =
                        pr.playQueueVersion.empty() ? "1" : pr.playQueueVersion;
                    // Synthetic containerKey when only playQueueID was supplied so
                    // auto-next / skipNext lastPlay.containerKey paths stay queue-shaped.
                    if (pendingContainerKey_.empty() && !pendingPlayQueueId_.empty())
                        pendingContainerKey_ = "/playQueues/" + pendingPlayQueueId_ + "?own=1";
                    // Mirror onto PlayRequest so async onPlay_/lastPlay see the queue bind
                    // (pending* alone is display-only until bindMedia).
                    if (pr.containerKey.empty() && !pr.playQueueId.empty())
                        pr.containerKey = "/playQueues/" + pr.playQueueId + "?own=1";
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
                int64_t ackOff = 0;
                {
                    std::lock_guard<std::mutex> lock(mu_);
                    ackOff = timeMs_;
                }
                auto body = timelineXml(cid);
                sendHttp(c, machineId_, 200, "application/xml", body);
                close(c);
                log("HTTP OUT 200 playMedia " + timelineBrief(body));
                log("playMedia ACK key=" + pr.key + " offMs=" + std::to_string(ackOff));
                // Invalidate in-flight resolve *before* spawning onPlay_ so a
                // concurrent doPlay cannot bind/setState over this plant while
                // the new play thread is still scheduling (P4-SCRUB cast race).
                if (onPlayQueued_) {
                    try {
                        onPlayQueued_();
                    } catch (...) {
                        log("playQueued handler exception");
                    }
                }
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
                bool active = false;
                {
                    std::lock_guard<std::mutex> lock(mu_);
                    t = timeMs_;
                    d = durationMs_;
                    active = wantPlay_;
                }
                // Idle/stopped: ACK only — setState("paused") would re-arm wantPlay_
                // and fullScreenVideo without a media key (scrubber ghost after stop).
                if (active)
                    setState("paused", t, d);
                sendHttp(c, machineId_, 200, "application/xml", timelineXml(queryParam(req, "commandID")));
                if (active && onPause_)
                    onPause_();
                close(c);
                continue;
            }
            if (isResumePlay) {
                int64_t t = 0, d = 0;
                bool active = false;
                {
                    std::lock_guard<std::mutex> lock(mu_);
                    t = timeMs_;
                    d = durationMs_;
                    active = wantPlay_;
                }
                // Idle: ACK only — do not re-arm wantPlay via setState("playing").
                if (active)
                    setState("playing", t, d);
                sendHttp(c, machineId_, 200, "application/xml", timelineXml(queryParam(req, "commandID")));
                if (active && onResume_)
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
                sendHttp(c, machineId_, 200, "application/xml", timelineXml(queryParam(req, "commandID")));
                close(c);
                continue;
            }
            if (isSeek) {
                bool present = false;
                int64_t ms = parseOffsetMs(req, &present);
                if (ms < 0)
                    ms = 0;
                int64_t d = 0;
                int64_t curT = 0;
                bool active = false;
                {
                    std::lock_guard<std::mutex> lock(mu_);
                    d = durationMs_;
                    curT = timeMs_;
                    active = wantPlay_;
                    // Clamp seek into known duration so scrubber cannot overshoot.
                    if (d > 0 && ms > d)
                        ms = d;
                }
                // No offset=/viewOffset=/time=: ACK only (do not jump to 0 unintentionally).
                // Idle after stop: ACK only — do not re-arm player via onSeek
                // (stop leaves last URL; seekMs would restart without scrubber bind).
                // Same position after clamp: ACK only — avoid demux restart thrash
                // (Web sometimes re-sends the current scrubber thumb position).
                const bool moved = present && (ms != curT);
                if (active && moved) {
                    // Atomic plant: scrub target + time under one lock so demux
                    // progress cannot interleave a stale pin between assign/setState.
                    {
                        std::lock_guard<std::mutex> lock(mu_);
                        scrubTargetMs_ = ms;
                        timeMs_ = ms;
                        if (d > 0)
                            durationMs_ = d;
                        state_ = "buffering";
                        wantPlay_ = true;
                    }
                }
                sendHttp(c, machineId_, 200, "application/xml", timelineXml(queryParam(req, "commandID")));
                if (active && moved && onSeek_)
                    onSeek_(ms);
                close(c);
                continue;
            }
            if (isStepForward || isStepBack) {
                // Default ±10s; optional offset= is relative step size in ms (cap 120s).
                // offset=0 → keep default (not a zero-step no-op). Negative sizes use abs.
                int64_t step = 10000;
                auto off = queryParam(req, "offset");
                if (!off.empty()) {
                    int64_t v = std::atoll(off.c_str());
                    if (v < 0)
                        v = -v;
                    // Non-zero only; clamp huge values (Web may send large step sizes).
                    if (v > 0)
                        step = (v > 120000) ? 120000 : v;
                }
                if (isStepBack)
                    step = -step;
                int64_t t = 0, d = 0;
                bool active = false;
                int64_t target = 0;
                int64_t applied = 0;
                {
                    std::lock_guard<std::mutex> lock(mu_);
                    t = timeMs_;
                    d = durationMs_;
                    active = wantPlay_;
                    target = t + step;
                    if (target < 0)
                        target = 0;
                    if (d > 0 && target > d)
                        target = d;
                    applied = target - t;
                    // applied==0 at bounds: ACK only — no buffering thrash / player restart.
                    if (active && applied != 0) {
                        scrubTargetMs_ = target;
                        timeMs_ = target;
                        if (d > 0)
                            durationMs_ = d;
                        state_ = "buffering";
                        wantPlay_ = true;
                    }
                }
                sendHttp(c, machineId_, 200, "application/xml", timelineXml(queryParam(req, "commandID")));
                // Prefer absolute seek when available so player lands on clamped target
                // even if positionMs lags companion timeMs_ (progress race).
                if (active && applied != 0) {
                    if (onSeek_)
                        onSeek_(target);
                    else if (onStep_)
                        onStep_(applied);
                }
                close(c);
                continue;
            }
            if (isSkipNext) {
                bool active = false;
                {
                    std::lock_guard<std::mutex> lock(mu_);
                    active = wantPlay_;
                }
                sendHttp(c, machineId_, 200, "application/xml", timelineXml(queryParam(req, "commandID")));
                // Empty session / unbound queue: ACK only (tryAutoNext no-ops).
                if (active && onSkipNext_)
                    onSkipNext_();
                close(c);
                continue;
            }
            if (isSkipPrevious) {
                int64_t d = 0;
                int64_t t = 0;
                bool active = false;
                {
                    std::lock_guard<std::mutex> lock(mu_);
                    d = durationMs_;
                    t = timeMs_;
                    active = wantPlay_;
                }
                // Idle: ACK only (no re-arm). Active: fire handler *before* zeroing
                // timeMs_ so main can Plex-style branch on scrub position
                // (t>3s → restart@0; t≤3s → queue previous / no-op at 0).
                if (active) {
                    if (onSkipPrevious_)
                        onSkipPrevious_();
                    else if (onSeek_ && t != 0)
                        onSeek_(0);
                    // Optimistic scrubber plant after branch (queue-prev rebind overwrites).
                    if (t != 0) {
                        std::lock_guard<std::mutex> lock(mu_);
                        scrubTargetMs_ = 0;
                        timeMs_ = 0;
                        if (d > 0)
                            durationMs_ = d;
                        state_ = "buffering";
                        wantPlay_ = true;
                    }
                }
                sendHttp(c, machineId_, 200, "application/xml", timelineXml(queryParam(req, "commandID")));
                close(c);
                continue;
            }

            sendHttp(c, machineId_, 200, "application/xml", timelineXml(queryParam(req, "commandID")));
            close(c);
            continue;
        }

        sendHttp(c, machineId_, 404, "text/plain", "not found");
        close(c);
    }
    close(fd);
}

} // namespace misterplex
