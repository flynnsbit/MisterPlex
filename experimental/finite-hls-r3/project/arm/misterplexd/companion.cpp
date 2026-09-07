#include "companion.hpp"

#include "libmisterplex/gdm_filter.hpp"

#include <arpa/inet.h>
#include <cerrno>
#include <cctype>
#include <cstdlib>
#include <cstring>
#include <fcntl.h>
#include <netinet/in.h>
#include <sys/socket.h>
#include <unistd.h>

#include <chrono>
#include <cstdio>
#include <algorithm>
#include <sstream>
#include <pthread.h>
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

std::string asciiLower(std::string value) {
    std::transform(value.begin(), value.end(), value.begin(), [](unsigned char ch) {
        return static_cast<char>(std::tolower(ch));
    });
    return value;
}

std::string trimOws(const std::string& value) {
    size_t begin = 0;
    while (begin < value.size() && (value[begin] == ' ' || value[begin] == '\t'))
        ++begin;
    size_t end = value.size();
    while (end > begin && (value[end - 1] == ' ' || value[end - 1] == '\t'))
        --end;
    return value.substr(begin, end - begin);
}

std::string headerValue(const std::string& req, const char* name) {
    const std::string wanted = asciiLower(name);
    auto line = req.find("\r\n");
    if (line == std::string::npos)
        return {};
    line += 2;
    while (line < req.size()) {
        const auto end = req.find("\r\n", line);
        if (end == std::string::npos || end == line)
            return {};
        const auto colon = req.find(':', line);
        if (colon != std::string::npos && colon < end &&
            asciiLower(req.substr(line, colon - line)) == wanted) {
            return trimOws(req.substr(colon + 1, end - colon - 1));
        }
        line = end + 2;
    }
    return {};
}

std::string controllerId(const std::string& req) {
    std::string id = pctDecode(queryParam(req, "X-Plex-Client-Identifier"));
    if (id.empty())
        id = pctDecode(queryParam(req, "clientIdentifier"));
    if (id.empty())
        id = pctDecode(headerValue(req, "X-Plex-Client-Identifier"));
    return id;
}

uint16_t callbackPort(const std::string& req) {
    const std::string raw = queryParam(req, "port");
    if (raw.empty())
        return 0;
    char* end = nullptr;
    const unsigned long value = std::strtoul(raw.c_str(), &end, 10);
    if (!end || *end != '\0' || value == 0 || value > 65535)
        return 0;
    return static_cast<uint16_t>(value);
}

bool sendAll(int fd, const std::string& bytes) {
    size_t sent = 0;
    while (sent < bytes.size()) {
        const ssize_t n =
            ::send(fd, bytes.data() + sent, bytes.size() - sent, MSG_NOSIGNAL);
        if (n > 0) {
            sent += static_cast<size_t>(n);
            continue;
        }
        if (n < 0 && errno == EINTR)
            continue;
        return false;
    }
    return true;
}

bool decimalCommandId(const std::string& value) {
    return !value.empty() &&
           std::all_of(value.begin(), value.end(), [](unsigned char ch) {
               return std::isdigit(ch) != 0;
           });
}

std::string normalizedDecimal(const std::string& value) {
    const auto first = value.find_first_not_of('0');
    return first == std::string::npos ? "0" : value.substr(first);
}

bool commandIsNewerOrEqual(const std::string& candidate, const std::string& current) {
    if (current.empty())
        return true;
    if (!decimalCommandId(candidate) || !decimalCommandId(current))
        return true;
    const std::string left = normalizedDecimal(candidate);
    const std::string right = normalizedDecimal(current);
    if (left.size() != right.size())
        return left.size() > right.size();
    return left >= right;
}

void sendHttp(int fd, const std::string& clientIdentifier, int code, const char* ctype,
              const std::string& body,
              const std::string& allowHeaders = std::string()) {
    const char* status = "Error";
    switch (code) {
    case 200:
        status = "OK";
        break;
    case 400:
        status = "Bad Request";
        break;
    case 404:
        status = "Not Found";
        break;
    case 408:
        status = "Request Timeout";
        break;
    case 413:
        status = "Payload Too Large";
        break;
    }
    std::ostringstream response;
    response << "HTTP/1.1 " << code << " " << status << "\r\n"
             << "Content-Type: " << ctype << "\r\n"
             << "Content-Length: " << body.size() << "\r\n"
             << "Connection: close\r\n"
             << "X-Plex-Client-Identifier: " << clientIdentifier << "\r\n"
             << "Access-Control-Allow-Origin: *\r\n"
             << "Access-Control-Allow-Headers: "
             << (allowHeaders.empty()
                     ? "X-Plex-Token, X-Plex-Client-Identifier, "
                       "X-Plex-Target-Client-Identifier, X-Plex-Session-Identifier, "
                       "X-Plex-Product, X-Plex-Version, X-Plex-Device, "
                       "X-Plex-Device-Name, X-Plex-Platform, "
                       "X-Plex-Platform-Version, X-Plex-Model, "
                       "X-Plex-Provider-Version, X-Plex-Text-Format, "
                       "X-Plex-Language, X-Plex-Features, X-Plex-Drm, "
                       "Content-Type, Accept"
                     : allowHeaders)
             << "\r\n"
             << "Access-Control-Allow-Methods: GET, POST, PUT, OPTIONS\r\n"
             << "Access-Control-Expose-Headers: X-Plex-Client-Identifier\r\n"
             << "Access-Control-Max-Age: 600\r\n\r\n"
             << body;
    (void)sendAll(fd, response.str());
}

enum class HttpHeaderRead { Ok, Timeout, TooLarge, Closed, Error };

HttpHeaderRead recvHttpHeaders(int fd, std::string& out, size_t maxBytes = 16384,
                               int timeoutMs = 5000) {
    out.clear();
    char chunk[2048];
    const auto deadline =
        std::chrono::steady_clock::now() + std::chrono::milliseconds(timeoutMs);
    while (out.find("\r\n\r\n") == std::string::npos) {
        if (out.size() >= maxBytes)
            return HttpHeaderRead::TooLarge;
        const auto now = std::chrono::steady_clock::now();
        if (now >= deadline)
            return HttpHeaderRead::Timeout;
        const auto remaining =
            std::chrono::duration_cast<std::chrono::microseconds>(deadline - now);
        fd_set rfds;
        FD_ZERO(&rfds);
        FD_SET(fd, &rfds);
        timeval timeout{};
        timeout.tv_sec = static_cast<time_t>(remaining.count() / 1000000);
        timeout.tv_usec = static_cast<suseconds_t>(remaining.count() % 1000000);
        const int selected = select(fd + 1, &rfds, nullptr, nullptr, &timeout);
        if (selected == 0)
            return HttpHeaderRead::Timeout;
        if (selected < 0) {
            if (errno == EINTR)
                continue;
            return HttpHeaderRead::Error;
        }
        const size_t available = maxBytes - out.size();
        const ssize_t n = recv(fd, chunk, std::min(available, sizeof(chunk)), 0);
        if (n < 0) {
            if (errno == EINTR)
                continue;
            return HttpHeaderRead::Error;
        }
        if (n == 0)
            return HttpHeaderRead::Closed;
        out.append(chunk, static_cast<size_t>(n));
    }
    return HttpHeaderRead::Ok;
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
    pr.address = pctDecode(queryParam(req, "address"));
    pr.protocol = queryParam(req, "protocol");
    pr.port = queryParam(req, "port");
    // Prefer lowercase token= (Plex Web cast). Do not substring-match inside
    // other keys. Always percent-decode — cast tokens may be URL-encoded.
    pr.token = pctDecode(queryParam(req, "token"));
    if (pr.token.empty())
        pr.token = pctDecode(queryParam(req, "X-Plex-Token"));
    if (pr.token.empty())
        pr.token = pctDecode(headerValue(req, "X-Plex-Token"));
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
      << "Version: 0.4.1\r\n"
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
      << "version=\"0.4.1\"/>"
      << "</MediaContainer>";
    return o.str();
}

std::string Companion::timelineXml(const std::string& commandId) const {
    std::lock_guard<std::mutex> lock(mu_);
    const std::string effectiveCommandId = commandId.empty() ? "0" : commandId;

    std::string videoState = state_ == "ended" ? "stopped" : state_;
    const bool holdIdle =
        !terminalStop_ && !wantPlay_ && (prePlayHold_ || castBound_) &&
        (videoState == "stopped" || videoState.empty() || videoState == "buffering");
    if (!terminalStop_ && wantPlay_ && (videoState == "stopped" || videoState.empty()))
        videoState = "buffering";
    else if (holdIdle)
        videoState = "buffering";

    const bool mediaActive =
        wantPlay_ && (videoState == "playing" || videoState == "paused" ||
                      videoState == "buffering" || !pendingKey_.empty());
    if (!terminalStop_ && mediaActive && videoState == "stopped")
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
      << xmlEsc(effectiveCommandId) << "\" location=\"" << videoLoc << "\">";

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

void Companion::setState(const std::string& state, int64_t timeMs, int64_t durationMs,
                         bool terminal, const CurrentFn& current) {
    std::lock_guard<std::mutex> lock(mu_);
    if (current && !current())
        return;
    if (terminalStop_ &&
        (state == "playing" || state == "paused" || state == "buffering"))
        return;
    const std::string previousState = state_;
    const bool previousTerminal = terminalStop_;
    // After stop clearMedia(), prePlayHold_ is set while wantPlay_ is false. Ignore
    // late media-thread progress so async teardown cannot re-arm fullScreenVideo.
    if (!wantPlay_ && prePlayHold_ &&
        (state == "playing" || state == "paused" || state == "buffering" || state == "ended")) {
        return;
    }
    // A final decoder rejection is not a pending seek. Keep the bind/position,
    // but expose stopped until a new play or progress event starts another run.
    terminalStop_ = state == "ended" ||
                    (state == "stopped" && (terminal || terminalStop_));
    // Empty/failed session end (no frames): player reports stopped@0. Keep scrubber
    // time so a plant seek + step is not clobbered by demux short-read teardown.
    // Natural EOF uses "ended" and retains the actual final presentation time.
    if (state == "stopped" && wantPlay_) {
        state_ = state;
        if (durationMs > 0)
            durationMs_ = durationMs;
        requestTimelinePush(previousState != state_ || previousTerminal != terminalStop_);
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
    //  - playing/paused far *behind* plant (seek demux restart@0): keep plant time
    //    and transport state so the Web thumb does not rewind.
    //  - playing/paused far *ahead* of plant (stale plant 0 + viewOffset start, or
    //    first progress jump): release hold and adopt live time. The old symmetric
    //    "far = pin forever" rule froze Plex Web at 0:00 while PMS /:/timeline still
    //    advanced from the media thread (fix 0abee0b6).
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
            requestTimelinePush(previousState != state_ || previousTerminal != terminalStop_);
            return;
        }
        if (delta > kScrubCatchupMs) {
            // Only suppress rewinds. Demux well ahead of plant is live truth.
            if (timeMs + kScrubCatchupMs < scrubTargetMs_) {
                if (durationMs > 0)
                    durationMs_ = durationMs;
                if (state == "playing" || state == "paused")
                    state_ = state;
                wantPlay_ = true;
                requestTimelinePush(previousState != state_);
                return;
            }
            scrubTargetMs_ = -1;
            // fall through: adopt live timeMs
        } else if (state == "ended" ||
                   ((state == "playing" || state == "paused") &&
                    timeMs >= scrubTargetMs_ + kScrubAdvanceMs)) {
            // Near plant: release only after demux advances past plant, or on ended.
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
    requestTimelinePush(previousState != state_ || previousTerminal != terminalStop_);
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
    pendingToken_ = req.token;
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
    requestTimelinePush(true);
    return true;
}

void Companion::seedPlaybackPosition(int64_t timeMs, int64_t durationMs) {
    std::lock_guard<std::mutex> lock(mu_);
    if (timeMs < 0)
        timeMs = 0;
    if (durationMs > 0) {
        durationMs_ = durationMs;
        if (timeMs > durationMs_)
            timeMs = durationMs_;
    } else if (durationMs_ > 0 && timeMs > durationMs_) {
        timeMs = durationMs_;
    }
    timeMs_ = timeMs;
    // Re-base hold on the real start. Without this, playMedia plant@0 + PMS
    // viewOffset demux start left Web polls frozen at 0 while media ran ahead.
    scrubTargetMs_ = timeMs;
    if (wantPlay_ && (state_ == "stopped" || state_.empty())) {
        state_ = "buffering";
        terminalStop_ = false;
    }
    requestTimelinePush(true);
}

bool Companion::stagePlay(const PlayRequest& req, const CurrentFn& current) {
    // Plant scrubber identity for skipNext/auto-next before async resolve so
    // bindMedia key-match accepts this title and Web sees the advance early.
    std::lock_guard<std::mutex> lock(mu_);
    if (current && !current())
        return false;
    wantPlay_ = true;
    prePlayHold_ = false;
    castBound_ = true;
    state_ = "buffering";
    terminalStop_ = false;
    durationMs_ = 0;
    timeMs_ = req.offsetMs < 0 ? 0 : req.offsetMs;
    scrubTargetMs_ = timeMs_; // hold until demux/bind catches up
    pendingKey_ = req.key;
    pendingToken_ = req.token;
    pendingGeneration_ = req.dispatchGeneration;
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
    requestTimelinePush(true);
    return true;
}

TransportRequest Companion::transportRequestLocked(TransportCommand command) {
    TransportRequest request = onTransportQueued_ ? onTransportQueued_(command)
                                                 : TransportRequest{};
    request.positionMs = timeMs_;
    request.originGeneration = pendingGeneration_;
    auto& media = request.media;
    media.key = pendingKey_;
    media.ratingKey = pendingRatingKey_;
    media.containerKey = pendingContainerKey_;
    media.playQueueId = pendingPlayQueueId_;
    media.playQueueItemId = pendingPlayQueueItemId_;
    media.playQueueVersion = pendingPlayQueueVersion_;
    media.address = serverHost_;
    media.protocol = serverProto_;
    media.port = serverPort_;
    media.serverMachineId = serverMachineId_;
    media.token = pendingToken_;
    media.offsetMs = timeMs_;
    media.offsetPresent = true;
    media.dispatchGeneration = request.generation;
    return request;
}

bool Companion::acceptSeekLocked(int64_t ms, TransportRequest& request) {
    ms = std::max<int64_t>(0, ms);
    if (durationMs_ > 0)
        ms = std::min(ms, durationMs_);
    if (!wantPlay_ || ms == timeMs_)
        return false;
    request = transportRequestLocked(TransportCommand::Seek);
    request.media.offsetMs = ms;
    pendingGeneration_ = request.generation;
    scrubTargetMs_ = timeMs_ = ms;
    state_ = "buffering";
    terminalStop_ = false;
    return true;
}

bool Companion::seekTo(int64_t ms, const CurrentFn& current) {
    TransportRequest request;
    {
        std::lock_guard<std::mutex> lock(mu_);
        if ((current && !current()) || !acceptSeekLocked(ms, request))
            return false;
    }
    requestTimelinePush(true);
    if (onSeek_)
        onSeek_(request);
    return true;
}

bool Companion::acceptPauseResumeLocked(bool pause, TransportRequest& request) {
    if (!wantPlay_ || terminalStop_)
        return false;
    request = transportRequestLocked(pause ? TransportCommand::Pause : TransportCommand::Resume);
    state_ = pause ? "paused" : "playing";
    return true;
}

TransportRequest Companion::clearMedia() {
    std::lock_guard<std::mutex> lock(mu_);
    auto request = transportRequestLocked(TransportCommand::Stop);
    // Drop media binding so polls are a clean idle (no key/container).
    // Web: video state=stopped WITH key still idles the cast player and freezes scrubber.
    pendingKey_.clear();
    pendingContainerKey_.clear();
    pendingPlayQueueId_.clear();
    pendingPlayQueueItemId_.clear();
    pendingPlayQueueVersion_.clear();
    pendingRatingKey_.clear();
    pendingToken_.clear();
    pendingGeneration_ = 0;
    wantPlay_ = false;
    state_ = "stopped";
    // A browser Stop after terminal EOF must not reopen the buffering hold.
    timeMs_ = 0;
    durationMs_ = 0;
    scrubTargetMs_ = -1;
    // Sticky hold: after stop while cast-bound, Web often reopens Resume without a
    // fresh mirror. Pure stopped polls idle the dialog — keep buffering@navigation.
    if (castBound_)
        prePlayHold_ = true;
    requestTimelinePush(true);
    return request;
}

void Companion::requestTimelinePush(bool immediate) {
    {
        std::lock_guard<std::mutex> lock(timelinePushMu_);
        timelinePushPending_ = true;
        timelinePushImmediate_ = timelinePushImmediate_ || immediate;
    }
    timelinePushCv_.notify_one();
}

void Companion::subscribeTimeline(const std::string& id, const std::string& host,
                                  const std::string& protocol, uint16_t port,
                                  const std::string& commandId) {
    TimelineSubscriber subscriber;
    subscriber.id = id.empty() ? host + ":" + std::to_string(port) : id;
    subscriber.host = host;
    subscriber.protocol = protocol;
    subscriber.port = port;
    subscriber.commandId = commandId.empty() ? "0" : commandId;

    size_t count = 0;
    {
        std::lock_guard<std::mutex> lock(subscriberMu_);
        auto it = std::find_if(
            subscribers_.begin(), subscribers_.end(),
            [&](const TimelineSubscriber& current) { return current.id == subscriber.id; });
        if (it != subscribers_.end()) {
            *it = subscriber;
        } else {
            constexpr size_t kMaxSubscribers = 8;
            if (subscribers_.size() >= kMaxSubscribers)
                subscribers_.erase(subscribers_.begin());
            subscribers_.push_back(std::move(subscriber));
        }
        count = subscribers_.size();
    }
    log("timeline: subscriber registered peer=" + host + ":" + std::to_string(port) +
        " count=" + std::to_string(count));
    requestTimelinePush(true);
}

void Companion::updateTimelineCommand(const std::string& id, const std::string& host,
                                      const std::string& commandId) {
    if (commandId.empty())
        return;
    std::lock_guard<std::mutex> lock(subscriberMu_);
    auto controller = std::find_if(
        controllerCommands_.begin(), controllerCommands_.end(),
        [&](const ControllerCommand& current) {
            return !id.empty() ? current.id == id
                               : current.id.empty() && current.host == host;
        });
    std::string effectiveCommandId = commandId;
    if (controller != controllerCommands_.end()) {
        if (commandIsNewerOrEqual(commandId, controller->commandId))
            controller->commandId = commandId;
        effectiveCommandId = controller->commandId;
    } else {
        constexpr size_t kMaxControllers = 16;
        if (controllerCommands_.size() >= kMaxControllers)
            controllerCommands_.erase(controllerCommands_.begin());
        controllerCommands_.push_back(ControllerCommand{id, host, commandId});
    }
    for (auto& subscriber : subscribers_) {
        if ((!id.empty() && subscriber.id == id) || (id.empty() && subscriber.host == host))
            subscriber.commandId = effectiveCommandId;
    }
}

std::string Companion::timelineCommandFor(const std::string& id, const std::string& host,
                                          const std::string& commandId) {
    updateTimelineCommand(id, host, commandId);
    std::lock_guard<std::mutex> lock(subscriberMu_);
    const auto controller = std::find_if(
        controllerCommands_.begin(), controllerCommands_.end(),
        [&](const ControllerCommand& current) {
            return !id.empty() ? current.id == id
                               : current.id.empty() && current.host == host;
        });
    return controller == controllerCommands_.end() ? "0" : controller->commandId;
}

bool Companion::unsubscribeTimeline(const std::string& id, const std::string& host) {
    size_t removed = 0;
    size_t remaining = 0;
    {
        std::lock_guard<std::mutex> lock(subscriberMu_);
        const auto before = subscribers_.size();
        subscribers_.erase(
            std::remove_if(subscribers_.begin(), subscribers_.end(),
                           [&](const TimelineSubscriber& subscriber) {
                               return !id.empty() ? subscriber.id == id
                                                  : subscriber.host == host;
                           }),
            subscribers_.end());
        removed = before - subscribers_.size();
        remaining = subscribers_.size();
    }
    if (removed > 0) {
        log("timeline: subscriber removed peer=" + host +
            " remaining=" + std::to_string(remaining));
    }
    return remaining == 0;
}

bool Companion::postTimeline(const TimelineSubscriber& subscriber,
                             const std::string& xml) const {
    if (subscriber.protocol != "http")
        return false;

    sockaddr_in peer{};
    peer.sin_family = AF_INET;
    peer.sin_port = htons(subscriber.port);
    if (inet_pton(AF_INET, subscriber.host.c_str(), &peer.sin_addr) != 1)
        return false;

    const int fd = ::socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0)
        return false;
    setCloexec(fd);

    const int oldFlags = fcntl(fd, F_GETFL, 0);
    if (oldFlags >= 0)
        fcntl(fd, F_SETFL, oldFlags | O_NONBLOCK);
    int rc = connect(fd, reinterpret_cast<sockaddr*>(&peer), sizeof(peer));
    if (rc != 0 && errno == EINPROGRESS) {
        fd_set wfds;
        FD_ZERO(&wfds);
        FD_SET(fd, &wfds);
        timeval timeout{1, 0};
        rc = select(fd + 1, nullptr, &wfds, nullptr, &timeout);
        if (rc > 0) {
            int socketError = 0;
            socklen_t errorLen = sizeof(socketError);
            if (getsockopt(fd, SOL_SOCKET, SO_ERROR, &socketError, &errorLen) != 0 ||
                socketError != 0) {
                rc = -1;
            } else {
                rc = 0;
            }
        } else {
            rc = -1;
        }
    }
    if (rc != 0) {
        close(fd);
        return false;
    }
    if (oldFlags >= 0)
        fcntl(fd, F_SETFL, oldFlags);

    timeval ioTimeout{1, 0};
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &ioTimeout, sizeof(ioTimeout));
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &ioTimeout, sizeof(ioTimeout));

    std::ostringstream request;
    request << "POST /:/timeline HTTP/1.1\r\n"
            << "Host: " << subscriber.host << ":" << subscriber.port << "\r\n"
            << "Content-Type: application/xml\r\n"
            << "Content-Length: " << xml.size() << "\r\n"
            << "X-Plex-Client-Identifier: " << machineId_ << "\r\n"
            << "Connection: close\r\n\r\n"
            << xml;
    if (!sendAll(fd, request.str())) {
        close(fd);
        return false;
    }

    std::string response;
    const auto readResult = recvHttpHeaders(fd, response, 4096, 1000);
    close(fd);
    if (readResult != HttpHeaderRead::Ok)
        return false;
    const auto lineEnd = response.find("\r\n");
    const auto space = response.find(' ');
    if (space == std::string::npos ||
        (lineEnd != std::string::npos && space >= lineEnd) ||
        response.size() - space < 4)
        return false;
    const int status = std::atoi(response.c_str() + space + 1);
    return status >= 200 && status < 300;
}

void Companion::timelinePushLoop() {
    auto nextPeriodic = std::chrono::steady_clock::now();
    while (running_.load()) {
        {
            std::unique_lock<std::mutex> lock(timelinePushMu_);
            timelinePushCv_.wait(lock, [&] {
                return !running_.load() || timelinePushPending_;
            });
            if (!running_.load())
                break;

            while (!timelinePushImmediate_ &&
                   std::chrono::steady_clock::now() < nextPeriodic) {
                timelinePushCv_.wait_until(lock, nextPeriodic, [&] {
                    return !running_.load() || timelinePushImmediate_;
                });
                if (!running_.load())
                    return;
            }
            timelinePushPending_ = false;
            timelinePushImmediate_ = false;
        }

        std::vector<TimelineSubscriber> subscribers;
        {
            std::lock_guard<std::mutex> lock(subscriberMu_);
            subscribers = subscribers_;
        }
        for (const auto& subscriber : subscribers) {
            const bool ok = postTimeline(subscriber, timelineXml(subscriber.commandId));
            bool removed = false;
            {
                std::lock_guard<std::mutex> lock(subscriberMu_);
                auto it = std::find_if(
                    subscribers_.begin(), subscribers_.end(),
                    [&](const TimelineSubscriber& current) {
                        return current.id == subscriber.id && current.host == subscriber.host &&
                               current.port == subscriber.port;
                    });
                if (it == subscribers_.end())
                    continue;
                if (ok) {
                    it->failures = 0;
                } else if (++it->failures >= 3) {
                    subscribers_.erase(it);
                    removed = true;
                }
            }
            if (removed) {
                log("timeline: subscriber dropped after callback failures peer=" +
                    subscriber.host + ":" + std::to_string(subscriber.port));
            }
        }
        nextPeriodic = std::chrono::steady_clock::now() + std::chrono::seconds(1);
    }
}

bool Companion::openHttpListen() {
    for (int attempt = 1; attempt <= 8; ++attempt) {
        int fd = ::socket(AF_INET, SOCK_STREAM, 0);
        if (fd < 0) {
            log("HTTP: socket failed");
            return false;
        }
        setReuse(fd);
        setCloexec(fd);
        sockaddr_in addr{};
        addr.sin_family = AF_INET;
        addr.sin_addr.s_addr = INADDR_ANY;
        addr.sin_port = htons(port_);
        if (bind(fd, reinterpret_cast<sockaddr*>(&addr), sizeof(addr)) == 0 && listen(fd, 16) == 0) {
            httpListenFd_ = fd;
            httpReady_.store(true);
            log("HTTP: companion on :" + std::to_string(port_) + " ip≈" + lanIp());
            return true;
        }
        log("HTTP: bind :" + std::to_string(port_) + " failed attempt=" + std::to_string(attempt));
        close(fd);
        std::this_thread::sleep_for(std::chrono::milliseconds(200));
    }
    return false;
}

bool Companion::start() {
    if (running_.exchange(true))
        return true;
    httpReady_.store(false);
    if (!openHttpListen()) {
        running_.store(false);
        log("companion: HTTP listen failed — not advertising GDM");
        return false;
    }
    gdmThr_ = std::thread([this] {
#if defined(__linux__)
        pthread_setname_np(pthread_self(), "mpx-gdm");
#endif
        gdmLoop();
    });
    httpThr_ = std::thread([this] {
#if defined(__linux__)
        pthread_setname_np(pthread_self(), "mpx-http");
#endif
        httpLoop();
    });
    timelinePushThr_ = std::thread([this] {
#if defined(__linux__)
        pthread_setname_np(pthread_self(), "mpx-comp-push");
#endif
        timelinePushLoop();
    });
    log("companion: GDM + HTTP :" + std::to_string(port_) + " name=" + name_);
    return true;
}

void Companion::stop() {
    if (!running_.exchange(false))
        return;
    httpReady_.store(false);
    timelinePushCv_.notify_all();
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
    if (timelinePushThr_.joinable())
        timelinePushThr_.join();
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
    // Do not answer M-SEARCH or broadcast until HTTP :port is listening.
    // Otherwise Plex Web lists MiSTerPlex and the picker vanishes (bind :3005 failed).

    auto lastAdv = std::chrono::steady_clock::now();
    while (running_.load()) {
        fd_set rfds;
        FD_ZERO(&rfds);
        FD_SET(fd, &rfds);
        timeval tv{0, 200000};
        int r = select(fd + 1, &rfds, nullptr, nullptr, &tv);
        if (r < 0) {
            // Avoid tight spin on repeated select errors.
            std::this_thread::sleep_for(std::chrono::milliseconds(200));
            continue;
        }
        if (r > 0 && FD_ISSET(fd, &rfds)) {
            char buf[2048];
            sockaddr_in peer{};
            socklen_t plen = sizeof(peer);
            ssize_t n = recvfrom(fd, buf, sizeof(buf) - 1, 0, reinterpret_cast<sockaddr*>(&peer), &plen);
            if (n > 0) {
                buf[n] = 0;
                // M-SEARCH-only (gdm_filter.hpp). Bare "plex" self-advertise loop
                // was the Sweep 114 108% core spin (mpx-gdm / unnamed tid).
                if (misterplex::gdmMayReply(httpReady_.load(), buf, static_cast<size_t>(n))) {
                    auto payload = gdmPayload();
                    sendto(fd, payload.data(), payload.size(), 0, reinterpret_cast<sockaddr*>(&peer),
                           plen);
                }
            }
        }
        auto now = std::chrono::steady_clock::now();
        if (misterplex::gdmMayAdvertise(httpReady_.load()) &&
            now - lastAdv > std::chrono::seconds(5)) {
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
    int fd = httpListenFd_;
    if (fd < 0) {
        log("HTTP: listen fd missing");
        return;
    }

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
        char peerAddressBuf[INET_ADDRSTRLEN]{};
        const char* peerAddressText =
            inet_ntop(AF_INET, &peer.sin_addr, peerAddressBuf, sizeof(peerAddressBuf));
        const std::string peerAddress = peerAddressText ? peerAddressText : "";
        std::string req;
        const HttpHeaderRead headerRead = recvHttpHeaders(c, req);
        if (headerRead != HttpHeaderRead::Ok) {
            if (headerRead == HttpHeaderRead::Timeout) {
                log("HTTP: header read timeout");
                sendHttp(c, machineId_, 408, "text/plain", "header timeout\n");
            } else if (headerRead == HttpHeaderRead::TooLarge) {
                log("HTTP: header block exceeds cap");
                sendHttp(c, machineId_, 413, "text/plain", "headers too large\n");
            } else if (headerRead == HttpHeaderRead::Error) {
                log("HTTP: header read error");
            }
            close(c);
            continue;
        }

        const std::string requestControllerId = controllerId(req);
        const std::string requestCommandId =
            timelineCommandFor(requestControllerId, peerAddress,
                               queryParam(req, "commandID"));

        // Refresh PMS timeline auth only from cast *control* requests that carry the
        // playing server's token (playMedia/seek/playback/*). Do NOT take tokens from
        // timeline poll/subscribe: Plex Web long-polls with the *controller* PMS token
        // (often local 192.168.x) while playMedia used a remote plex.direct transient
        // token — overwriting it yields /:/timeline HTTP 401 and Web scrubber stuck
        // at 0:00 (L41 follow-up; user rk 154219/154269 on machine 1cdd…).
        if (onTokenUpdate_ && req.find("/player/") != std::string::npos) {
            const bool castControl =
                req.find("playMedia") != std::string::npos ||
                req.find("/player/playback/") != std::string::npos ||
                req.find("/player/timeline/seekTo") != std::string::npos ||
                req.find("seekTo") != std::string::npos ||
                req.find("/player/command") != std::string::npos;
            const bool isPoll =
                req.find("/player/timeline/poll") != std::string::npos ||
                req.find("/player/timeline/subscribe") != std::string::npos ||
                req.find("/player/timeline/unsubscribe") != std::string::npos ||
                req.find("/player/proxy/timeline") != std::string::npos;
            if (castControl && !isPoll) {
                std::string tok = pctDecode(queryParam(req, "token"));
                if (tok.empty())
                    tok = pctDecode(queryParam(req, "X-Plex-Token"));
                if (tok.empty())
                    tok = pctDecode(headerValue(req, "X-Plex-Token"));
                if (!tok.empty()) {
                    {
                        std::lock_guard<std::mutex> lock(mu_);
                        pendingToken_ = tok;
                    }
                    try {
                        onTokenUpdate_(tok);
                    } catch (...) {
                        log("token update handler exception");
                    }
                }
            }
        }

        {
            std::lock_guard<std::mutex> lock(mu_);
            if (req.find("/player/") != std::string::npos || req.find("/resources") != std::string::npos)
                castBound_ = true;
        }

        if (req.find("OPTIONS") == 0) {
            sendHttp(c, machineId_, 200, "text/plain", "",
                     headerValue(req, "Access-Control-Request-Headers"));
            close(c);
            continue;
        }

        if (req.find("GET /resources") != std::string::npos ||
            req.find("GET /identity") != std::string::npos) {
            sendHttp(c, machineId_, 200, "application/xml", resourcesXml());
            close(c);
            continue;
        }

        if (req.find("/player/timeline/subscribe") != std::string::npos) {
            std::string protocol = queryParam(req, "protocol");
            if (protocol.empty())
                protocol = "http";
            std::transform(protocol.begin(), protocol.end(), protocol.begin(),
                           [](unsigned char ch) { return static_cast<char>(std::tolower(ch)); });
            const uint16_t subscriberPort = callbackPort(req);
            if (protocol == "http" && subscriberPort != 0 && !peerAddress.empty()) {
                subscribeTimeline(requestControllerId, peerAddress, protocol, subscriberPort,
                                  requestCommandId);
            } else {
                log("timeline: rejected invalid subscriber endpoint");
            }
            sendHttp(c, machineId_, 200, "application/xml",
                     timelineXml(requestCommandId));
            close(c);
            continue;
        }

        // Unsubscribe: drop cast-bound hold so idle polls can go pure stopped.
        if (req.find("/player/timeline/unsubscribe") != std::string::npos) {
            const bool noSubscribers =
                unsubscribeTimeline(requestControllerId, peerAddress);
            {
                std::lock_guard<std::mutex> lock(mu_);
                if (noSubscribers)
                    castBound_ = false;
                if (noSubscribers && !wantPlay_)
                    prePlayHold_ = false;
            }
            sendHttp(c, machineId_, 200, "application/xml",
                     timelineXml(requestCommandId));
            close(c);
            continue;
        }

        // Timeline poll / proxy alias — never auto-start media from poll.
        if (req.find("/player/timeline/poll") != std::string::npos ||
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
            if (queryParam(req, "wait") == "1")
                std::this_thread::sleep_for(std::chrono::milliseconds(400));
            sendHttp(c, machineId_, 200, "application/xml",
                     timelineXml(requestCommandId));
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
                if (!keepActive && !terminalStop_) {
                    // Remember key for following playMedia; wire omits media bind
                    // while wantPlay_ is false (buffering@navigation hold).
                    if (!pr.key.empty())
                        pendingKey_ = pr.key;
                    if (!pr.token.empty())
                        pendingToken_ = pr.token;
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
                    pendingGeneration_ = 0;
                    prePlayHold_ = true;
                    wantPlay_ = false;
                    state_ = "stopped"; // wire shows buffering via prePlayHold_
                    terminalStop_ = false;
                    castBound_ = true;
                }
                // else: leave live timeline alone (Web mirror after playMedia must not idle)
            }
            requestTimelinePush(true);
            sendHttp(c, machineId_, 200, "application/xml",
                     timelineXml(requestCommandId));
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
                // Serialize generation assignment before publishing this request
                // as pending. The callback shares the player's handoff mutex, so
                // an older handler either finishes first or sees this generation;
                // it can never publish stale DAR after the new request is staged.
                if (onPlayQueued_) {
                    try {
                        pr.dispatchGeneration = onPlayQueued_();
                    } catch (...) {
                        log("playQueued handler exception");
                    }
                }
                {
                    std::lock_guard<std::mutex> lock(mu_);
                    wantPlay_ = true;
                    prePlayHold_ = false;
                    castBound_ = true;
                    state_ = "buffering";
                    terminalStop_ = false;
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
                    pendingToken_ = pr.token;
                    pendingGeneration_ = pr.dispatchGeneration;
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
                requestTimelinePush(true);
                int64_t ackOff = 0;
                {
                    std::lock_guard<std::mutex> lock(mu_);
                    ackOff = timeMs_;
                }
                sendHttp(c, machineId_, 200, "application/xml",
                         timelineXml(requestCommandId));
                close(c);
                log("playMedia ACK key=" + pr.key + " offMs=" + std::to_string(ackOff));
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

            if (isPause || isResumePlay) {
                TransportRequest request;
                bool accepted = false;
                {
                    std::lock_guard<std::mutex> lock(mu_);
                    accepted = acceptPauseResumeLocked(isPause, request);
                }
                if (accepted)
                    requestTimelinePush(true);
                sendHttp(c, machineId_, 200, "application/xml",
                         timelineXml(requestCommandId));
                const auto& handler = isPause ? onPause_ : onResume_;
                if (accepted && handler)
                    handler(request);
                close(c);
                continue;
            }
            if (isStop) {
                // Drop bind first so stop ACK is buffering@navigation without keys
                // (video/stopped+key idles Web and freezes scrubber / Resume dialog).
                // clearMedia before player.stop so late progress cannot re-arm wantPlay
                // (setState ignores progress while prePlayHold && !wantPlay).
                const auto request = clearMedia();
                if (onStop_)
                    onStop_(request);
                sendHttp(c, machineId_, 200, "application/xml",
                         timelineXml(requestCommandId));
                close(c);
                continue;
            }
            if (isSeek) {
                bool present = false;
                int64_t ms = parseOffsetMs(req, &present);
                TransportRequest request;
                bool accepted = false;
                {
                    std::lock_guard<std::mutex> lock(mu_);
                    if (present)
                        accepted = acceptSeekLocked(ms, request);
                }
                if (accepted)
                    requestTimelinePush(true);
                sendHttp(c, machineId_, 200, "application/xml",
                         timelineXml(requestCommandId));
                if (accepted && onSeek_)
                    onSeek_(request);
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
                TransportRequest request;
                bool accepted = false;
                int64_t target = 0;
                int64_t applied = 0;
                {
                    std::lock_guard<std::mutex> lock(mu_);
                    t = timeMs_;
                    d = durationMs_;
                    target = t + step;
                    if (target < 0)
                        target = 0;
                    if (d > 0 && target > d)
                        target = d;
                    applied = target - t;
                    accepted = acceptSeekLocked(target, request);
                }
                if (accepted)
                    requestTimelinePush(true);
                sendHttp(c, machineId_, 200, "application/xml",
                         timelineXml(requestCommandId));
                // Prefer absolute seek when available so player lands on clamped target
                // even if positionMs lags companion timeMs_ (progress race).
                if (accepted) {
                    if (onSeek_)
                        onSeek_(request);
                    else if (onStep_)
                        onStep_(applied, request);
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
                sendHttp(c, machineId_, 200, "application/xml",
                         timelineXml(requestCommandId));
                // Empty session / unbound queue: ACK only (tryAutoNext no-ops).
                if (active && onSkipNext_)
                    onSkipNext_();
                close(c);
                continue;
            }
            if (isSkipPrevious) {
                int64_t t = 0;
                bool active = false;
                bool seekAccepted = false;
                TransportRequest request;
                {
                    std::lock_guard<std::mutex> lock(mu_);
                    t = timeMs_;
                    active = wantPlay_;
                    if (active && onSkipPrevious_)
                        request = transportRequestLocked(TransportCommand::Previous);
                    else if (active && onSeek_ && t != 0)
                        seekAccepted = acceptSeekLocked(0, request);
                }
                // Preserve the accepted position/identity for the restart-or-queue
                // decision; never apply an old optimistic plant after its callback.
                if (active) {
                    if (onSkipPrevious_)
                        onSkipPrevious_(request);
                    else if (seekAccepted)
                        onSeek_(request);
                }
                sendHttp(c, machineId_, 200, "application/xml",
                         timelineXml(requestCommandId));
                close(c);
                continue;
            }

            sendHttp(c, machineId_, 200, "application/xml",
                     timelineXml(requestCommandId));
            close(c);
            continue;
        }

        sendHttp(c, machineId_, 404, "text/plain", "not found");
        close(c);
    }
    httpReady_.store(false);
    close(fd);
    httpListenFd_ = -1;
}

} // namespace misterplex
