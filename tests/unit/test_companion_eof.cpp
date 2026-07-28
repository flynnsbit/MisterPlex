#include <cstdlib>
#include <arpa/inet.h>
#include <chrono>
#include <iostream>
#include <mutex>
#include <netinet/in.h>
#include <sys/socket.h>
#include <string>
#include <thread>
#include <unistd.h>
#include <vector>

#define private public
#include "companion.hpp"
#undef private

namespace {

void require(bool ok, const std::string& msg) {
    if (!ok) {
        std::cerr << "FAIL: " << msg << "\n";
        std::exit(1);
    }
}

bool has(const std::string& s, const std::string& needle) {
    return s.find(needle) != std::string::npos;
}

uint16_t freeTcpPort() {
    int fd = ::socket(AF_INET, SOCK_STREAM, 0);
    require(fd >= 0, "socket failed while finding free port");
    sockaddr_in addr{};
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    addr.sin_port = 0;
    require(::bind(fd, reinterpret_cast<sockaddr*>(&addr), sizeof(addr)) == 0,
            "bind failed while finding free port");
    socklen_t len = sizeof(addr);
    require(::getsockname(fd, reinterpret_cast<sockaddr*>(&addr), &len) == 0,
            "getsockname failed while finding free port");
    const uint16_t port = ntohs(addr.sin_port);
    ::close(fd);
    return port;
}

std::string httpRequest(uint16_t port, const std::string& request) {
    int fd = ::socket(AF_INET, SOCK_STREAM, 0);
    require(fd >= 0, "HTTP test socket failed");
    sockaddr_in addr{};
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    addr.sin_port = htons(port);
    for (int i = 0; i < 50; ++i) {
        if (::connect(fd, reinterpret_cast<sockaddr*>(&addr), sizeof(addr)) == 0)
            break;
        if (i == 49)
            require(false, "HTTP test connect failed");
        std::this_thread::sleep_for(std::chrono::milliseconds(20));
    }
    require(::send(fd, request.data(), request.size(), 0) == static_cast<ssize_t>(request.size()),
            "HTTP test send failed");
    std::string out;
    char buf[1024];
    for (;;) {
        ssize_t n = ::recv(fd, buf, sizeof(buf), 0);
        if (n <= 0)
            break;
        out.append(buf, static_cast<size_t>(n));
    }
    ::close(fd);
    return out;
}

misterplex::PlayRequest episodeRequest() {
    misterplex::PlayRequest req;
    req.key = "/library/metadata/3";
    req.ratingKey = "3";
    req.playQueueItemId = "3";
    req.address = "192.168.1.41";
    req.protocol = "http";
    req.port = "32400";
    req.serverMachineId = "plex-server";
    req.offsetMs = 0;
    req.offsetPresent = true;
    return req;
}

} // namespace

int main() {
    misterplex::Companion comp;
    comp.setMachineId("misterplex-dev");

    misterplex::PlayRequest req = episodeRequest();

    comp.stagePlay(req);
    require(comp.bindMedia(req, 1286942), "bindMedia rejected staged play");
    comp.setState("playing", 1285862, 1286942);
    const std::string live = comp.timelineXml("live");
    require(has(live, "location=\"fullScreenVideo\""), "live playback not fullScreenVideo: " + live);
    require(has(live, "key=\"/library/metadata/3\""), "live playback lost key: " + live);

    // Regression contract: natural EOF with no auto-next must converge to the same
    // local/companion state as explicit stop. MediaPlayer already paints idle at EOF;
    // the companion must clear the media bind so timeline polls are navigation,
    // duration=0, and contain no stale media key. The old path did
    // buffering@duration while deciding auto-next, then a plain stopped progress
    // update without clearMedia(), leaving fullScreenVideo/buffering forever.
    comp.setState("buffering", 1286942, 1286942);
    comp.endMediaSession(1286942, 1286942);
    const std::string eof = comp.timelineXml("eof");
    require(has(eof, "location=\"navigation\""), "EOF did not return to navigation: " + eof);
    require(has(eof, "state=\"buffering\""), "EOF stop hold should be buffering@navigation: " + eof);
    require(has(eof, "duration=\"0\""), "EOF retained stale duration: " + eof);
    require(!has(eof, "key=\"/library/metadata/3\""), "EOF retained stale media key: " + eof);
    require(!has(eof, "fullScreenVideo"), "EOF retained fullScreenVideo: " + eof);

    misterplex::Companion disconnect;
    disconnect.setMachineId("misterplex-dev");
    req = episodeRequest();
    disconnect.stagePlay(req);
    require(disconnect.bindMedia(req, 1286942), "bindMedia rejected disconnect play");
    disconnect.setState("playing", 42000, 1286942);
    // Same terminal mechanism, but not at EOF: if the source disconnects after
    // real playback, main must drive an explicit terminal transition. It must also
    // clear the local bind; only non-terminal stopped@0 is reserved for
    // empty/failed demux preserving scrubber plants.
    disconnect.endMediaSession(42000, 1286942);
    const std::string disc = disconnect.timelineXml("disconnect");
    require(has(disc, "location=\"navigation\""),
            "source disconnect did not return to navigation: " + disc);
    require(!has(disc, "key=\"/library/metadata/3\""),
            "source disconnect retained stale media key: " + disc);

    misterplex::Companion emptyFail;
    emptyFail.setMachineId("misterplex-dev");
    req = episodeRequest();
    emptyFail.stagePlay(req);
    require(emptyFail.bindMedia(req, 1286942), "bindMedia rejected empty-fail play");
    // Empty/failed demux is not a terminal-content transition. It arrives as
    // stopped@0 while a planted seek may still be live; a plain stopped progress
    // update must preserve media identity and planted time.
    emptyFail.setState("stopped", 0, 1286942);
    const std::string empty = emptyFail.timelineXml("empty-fail");
    require(has(empty, "location=\"fullScreenVideo\""),
            "empty stopped@0 should preserve scrubber bind: " + empty);
    require(has(empty, "key=\"/library/metadata/3\""),
            "empty stopped@0 lost scrubber key: " + empty);

    misterplex::Companion http;
    http.setMachineId("misterplex-dev");
    http.setPort(freeTcpPort());
    std::mutex captureMu;
    std::vector<misterplex::PlayRequest> captured;
    std::mutex logMu;
    std::vector<std::string> logs;
    http.setLog([&](const std::string& line) {
        std::lock_guard<std::mutex> lock(logMu);
        logs.push_back(line);
    });
    http.setPlay([&](const misterplex::PlayRequest& parsed) {
        std::lock_guard<std::mutex> lock(captureMu);
        captured.push_back(parsed);
    });
    require(http.start(), "HTTP companion failed to start");

    const uint16_t httpPort = http.port_;
    const std::string identityResp = httpRequest(
        httpPort, "GET /identity HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n");
    require(has(identityResp, "X-Plex-Client-Identifier: misterplex-dev\r\n"),
            "identity response missing client identifier: " + identityResp);

    const std::string pathResp = httpRequest(
        httpPort,
        "GET /player/playback/playMedia?commandID=path-only&path=%2Flibrary%2Fmetadata%2F4&"
        "machineIdentifier=server-path&address=192.168.1.41&port=32400&protocol=http HTTP/1.1\r\n"
        "Host: 127.0.0.1\r\n\r\n");
    require(has(pathResp, "HTTP/1.1 200 OK"), "path-only playMedia did not return 200");
    require(has(pathResp, "X-Plex-Client-Identifier: misterplex-dev\r\n"),
            "missing response client identifier: " + pathResp);
    require(has(pathResp, "Access-Control-Expose-Headers: X-Plex-Client-Identifier\r\n"),
            "missing exposed client identifier header: " + pathResp);
    require(has(pathResp, "Access-Control-Allow-Methods: GET, POST, PUT, OPTIONS\r\n"),
            "wildcard/invalid allow-methods survived: " + pathResp);
    require(has(pathResp, "key=\"/library/metadata/4\""),
            "path-only playMedia did not bind metadata key: " + pathResp);

    const std::string uriResp = httpRequest(
        httpPort,
        "GET /player/playback/playMedia?commandID=uri-only&"
        "uri=server%3A%2F%2Fserver-uri%2Fcom.plexapp.plugins.library%2Flibrary%2Fmetadata%2F3&"
        "address=192.168.1.41&port=32400&protocol=http HTTP/1.1\r\n"
        "Host: 127.0.0.1\r\n\r\n");
    require(has(uriResp, "key=\"/library/metadata/3\""),
            "uri-only playMedia did not bind metadata key: " + uriResp);
    require(has(uriResp, "machineIdentifier=\"server-uri\""),
            "uri-only playMedia did not bind server machine id: " + uriResp);

    for (int i = 0; i < 50; ++i) {
        {
            std::lock_guard<std::mutex> lock(captureMu);
            if (captured.size() >= 2)
                break;
        }
        std::this_thread::sleep_for(std::chrono::milliseconds(20));
    }
    http.stop();
    {
        std::lock_guard<std::mutex> lock(captureMu);
        require(captured.size() == 2, "did not capture both playMedia callbacks");
        // The two playMedia requests are served on separate HTTP worker threads,
        // so the order in which their callbacks append is not defined. Indexing
        // by arrival made this test fail about one run in three with
        // "path callback key mismatch: /library/metadata/3" -- the inverted
        // order, not a product defect: pathResp and uriResp are already asserted
        // synchronously above. Match on the key instead; every field assertion
        // below is unchanged, and requiring exactly one of each is strictly
        // stronger than the old positional check.
        const auto* pathCb = static_cast<const decltype(captured)::value_type*>(nullptr);
        const auto* uriCb = pathCb;
        for (const auto& c : captured) {
            if (c.key == "/library/metadata/4")
                pathCb = &c;
            else if (c.key == "/library/metadata/3")
                uriCb = &c;
        }
        require(pathCb != nullptr,
                "path callback key mismatch: no callback bound /library/metadata/4");
        require(uriCb != nullptr,
                "uri callback key mismatch: no callback bound /library/metadata/3");
        require(pathCb->ratingKey == "4", "path callback ratingKey mismatch");
        require(pathCb->playQueueItemId == "4", "path callback queue item fallback missing");
        require(uriCb->ratingKey == "3", "uri callback ratingKey mismatch");
        require(uriCb->serverMachineId == "server-uri",
                "uri callback server machine id mismatch: " + uriCb->serverMachineId);
    }
    {
        std::lock_guard<std::mutex> lock(logMu);
        bool sawIdentity = false;
        bool sawUri = false;
        for (const auto& line : logs) {
            sawIdentity = sawIdentity ||
                          has(line, "HTTP IN peer=127.0.0.1 GET /identity HTTP/1.1");
            sawUri = sawUri || (has(line, "HTTP IN peer=127.0.0.1 GET /player/playback/playMedia") &&
                                has(line, "commandID=uri-only"));
        }
        require(sawIdentity, "missing peer/request-line log for /identity");
        require(sawUri, "missing peer/request-line log for uri playMedia");
    }

    std::cout << "test_companion_eof: OK\n";
    return 0;
}
