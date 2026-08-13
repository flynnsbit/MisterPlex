#include "companion.hpp"

#include <arpa/inet.h>
#include <sys/select.h>
#include <sys/socket.h>
#include <unistd.h>

#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstdlib>
#include <cstring>
#include <iostream>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

namespace {

void require(bool ok, const std::string& message) {
    if (!ok) {
        std::cerr << "FAIL: " << message << "\n";
        std::exit(1);
    }
}

uint16_t reservePort() {
    const int fd = socket(AF_INET, SOCK_STREAM, 0);
    require(fd >= 0, "socket");
    sockaddr_in address{};
    address.sin_family = AF_INET;
    address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    address.sin_port = 0;
    require(bind(fd, reinterpret_cast<sockaddr*>(&address), sizeof(address)) == 0,
            "bind ephemeral port");
    socklen_t length = sizeof(address);
    require(getsockname(fd, reinterpret_cast<sockaddr*>(&address), &length) == 0,
            "getsockname");
    const uint16_t port = ntohs(address.sin_port);
    close(fd);
    return port;
}

std::string httpGet(uint16_t port, const std::string& path,
                    const std::string& clientId = {}) {
    const int fd = socket(AF_INET, SOCK_STREAM, 0);
    require(fd >= 0, "client socket");
    sockaddr_in address{};
    address.sin_family = AF_INET;
    address.sin_port = htons(port);
    inet_pton(AF_INET, "127.0.0.1", &address.sin_addr);
    if (connect(fd, reinterpret_cast<sockaddr*>(&address), sizeof(address)) != 0) {
        close(fd);
        return {};
    }
    std::string request = "GET " + path + " HTTP/1.1\r\nHost: 127.0.0.1\r\n";
    if (!clientId.empty())
        request += "X-Plex-Client-Identifier: " + clientId + "\r\n";
    request += "Connection: close\r\n\r\n";
    require(send(fd, request.data(), request.size(), 0) ==
                static_cast<ssize_t>(request.size()),
            "client send");
    std::string response;
    char chunk[4096];
    for (;;) {
        const ssize_t got = recv(fd, chunk, sizeof(chunk), 0);
        if (got <= 0)
            break;
        response.append(chunk, static_cast<size_t>(got));
    }
    close(fd);
    return response;
}

std::string fragmentedGet(uint16_t port, const std::string& path) {
    const int fd = socket(AF_INET, SOCK_STREAM, 0);
    require(fd >= 0, "fragmented client socket");
    sockaddr_in address{};
    address.sin_family = AF_INET;
    address.sin_port = htons(port);
    inet_pton(AF_INET, "127.0.0.1", &address.sin_addr);
    require(connect(fd, reinterpret_cast<sockaddr*>(&address), sizeof(address)) == 0,
            "fragmented client connect");
    const std::string first =
        "GET " + path +
        " HTTP/1.1\r\nHost: 127.0.0.1\r\nx-plex-client-identifier: controller-";
    const std::string second = "test\r\nConnection: close\r\n\r\n";
    require(send(fd, first.data(), first.size(), 0) == static_cast<ssize_t>(first.size()),
            "fragmented first send");
    std::this_thread::sleep_for(std::chrono::milliseconds(75));
    require(send(fd, second.data(), second.size(), 0) ==
                static_cast<ssize_t>(second.size()),
            "fragmented second send");
    std::string response;
    char chunk[4096];
    for (;;) {
        const ssize_t got = recv(fd, chunk, sizeof(chunk), 0);
        if (got <= 0)
            break;
        response.append(chunk, static_cast<size_t>(got));
    }
    close(fd);
    return response;
}

class CallbackServer {
public:
    CallbackServer() : port_(reservePort()) {}

    void start() {
        fd_ = socket(AF_INET, SOCK_STREAM, 0);
        require(fd_ >= 0, "callback socket");
        int reuse = 1;
        setsockopt(fd_, SOL_SOCKET, SO_REUSEADDR, &reuse, sizeof(reuse));
        sockaddr_in address{};
        address.sin_family = AF_INET;
        address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
        address.sin_port = htons(port_);
        require(bind(fd_, reinterpret_cast<sockaddr*>(&address), sizeof(address)) == 0,
                "callback bind");
        require(listen(fd_, 8) == 0, "callback listen");
        running_.store(true);
        thread_ = std::thread([this] { run(); });
    }

    void stop() {
        if (!running_.exchange(false))
            return;
        const int wake = socket(AF_INET, SOCK_STREAM, 0);
        if (wake >= 0) {
            sockaddr_in address{};
            address.sin_family = AF_INET;
            address.sin_port = htons(port_);
            inet_pton(AF_INET, "127.0.0.1", &address.sin_addr);
            connect(wake, reinterpret_cast<sockaddr*>(&address), sizeof(address));
            close(wake);
        }
        if (thread_.joinable())
            thread_.join();
        close(fd_);
        fd_ = -1;
    }

    ~CallbackServer() { stop(); }

    uint16_t port() const { return port_; }

    bool waitFor(const std::string& first, const std::string& second = {},
                 std::chrono::milliseconds timeout = std::chrono::milliseconds(2500)) {
        std::unique_lock<std::mutex> lock(mu_);
        return cv_.wait_for(lock, timeout, [&] {
            for (const auto& request : requests_) {
                if (request.find(first) != std::string::npos &&
                    (second.empty() || request.find(second) != std::string::npos)) {
                    return true;
                }
            }
            return false;
        });
    }

    size_t count() const {
        std::lock_guard<std::mutex> lock(mu_);
        return requests_.size();
    }

private:
    void run() {
        while (running_.load()) {
            fd_set readSet;
            FD_ZERO(&readSet);
            FD_SET(fd_, &readSet);
            timeval timeout{0, 100000};
            if (select(fd_ + 1, &readSet, nullptr, nullptr, &timeout) <= 0)
                continue;
            const int client = accept(fd_, nullptr, nullptr);
            if (client < 0)
                continue;
            std::string request;
            char chunk[4096];
            size_t wanted = 0;
            for (;;) {
                const ssize_t got = recv(client, chunk, sizeof(chunk), 0);
                if (got <= 0)
                    break;
                request.append(chunk, static_cast<size_t>(got));
                const auto headerEnd = request.find("\r\n\r\n");
                if (headerEnd != std::string::npos && wanted == 0) {
                    const std::string marker = "Content-Length:";
                    const auto lengthAt = request.find(marker);
                    if (lengthAt != std::string::npos) {
                        wanted = headerEnd + 4 +
                                 static_cast<size_t>(
                                     std::strtoul(request.c_str() + lengthAt + marker.size(),
                                                 nullptr, 10));
                    }
                }
                if (wanted > 0 && request.size() >= wanted)
                    break;
            }
            if (!request.empty()) {
                {
                    std::lock_guard<std::mutex> lock(mu_);
                    requests_.push_back(request);
                }
                cv_.notify_all();
                const char first[] = "HTTP/1.1 ";
                const char second[] =
                    "200 OK\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";
                send(client, first, std::strlen(first), MSG_NOSIGNAL);
                std::this_thread::sleep_for(std::chrono::milliseconds(20));
                send(client, second, std::strlen(second), MSG_NOSIGNAL);
            }
            close(client);
        }
    }

    uint16_t port_;
    int fd_ = -1;
    std::atomic<bool> running_{false};
    std::thread thread_;
    mutable std::mutex mu_;
    std::condition_variable cv_;
    std::vector<std::string> requests_;
};

} // namespace

int main() {
    CallbackServer callback;
    callback.start();

    misterplex::Companion companion;
    const uint16_t companionPort = reservePort();
    companion.setName("MiSTerPlexSubscriptionTest");
    companion.setMachineId("misterplex-dev");
    companion.setPort(companionPort);
    std::atomic<int> tokenUpdates{0};
    std::atomic<int> playQueued{0};
    std::atomic<uint64_t> playedGeneration{0};
    companion.setTokenUpdate([&](const misterplex::TokenUpdate&) { ++tokenUpdates; });
    companion.setPlayQueued([&](const misterplex::PlayRequest&) {
        ++playQueued;
        return uint64_t{7};
    });
    companion.setPlay(
        [&](const misterplex::PlayRequest& request) {
            playedGeneration.store(request.dispatchGeneration);
        });
    require(companion.start(), "companion start");

    bool ready = false;
    for (int attempt = 0; attempt < 50; ++attempt) {
        const std::string response = httpGet(companionPort, "/resources");
        if (response.find("200 OK") != std::string::npos) {
            ready = true;
            break;
        }
        std::this_thread::sleep_for(std::chrono::milliseconds(20));
    }
    require(ready, "companion HTTP ready");

    require(httpGet(companionPort,
                    "/player/playback/playMedia?key=%2Flibrary%2Fmetadata%2F1"
                    "&address=next-pms.local&port=32400&protocol=http"
                    "&token=next-token&commandID=10",
                    "controller-test")
                    .find("200 OK") != std::string::npos,
            "playMedia response");
    require(playQueued.load() == 1,
            "playMedia ACK returned before synchronous pending-session publication");
    for (int attempt = 0; attempt < 50 && playedGeneration.load() == 0; ++attempt)
        std::this_thread::sleep_for(std::chrono::milliseconds(10));
    require(playedGeneration.load() == 7,
            "async play handler lost the synchronously assigned generation");
    require(tokenUpdates.load() == 0,
            "new playMedia token mutated the previous PMS timeline session");
    require(httpGet(companionPort,
                    "/player/playback/pause?X-Plex-Token=active-token&commandID=11",
                    "controller-test")
                    .find("200 OK") != std::string::npos,
            "token refresh control response");
    require(tokenUpdates.load() == 0,
            "identity-less control forwarded an ambiguous PMS token");
    require(httpGet(companionPort,
                    "/player/playback/pause?X-Plex-Token=active-token"
                    "&address=next-pms.local&port=32400&protocol=http&commandID=9",
                    "controller-test")
                    .find("200 OK") != std::string::npos,
            "stale token refresh control response");
    require(tokenUpdates.load() == 0,
            "stale same-PMS control crossed the playMedia command boundary");
    require(httpGet(companionPort,
                    "/player/playback/pause?X-Plex-Token=active-token"
                    "&address=next-pms.local&port=32400&protocol=http&commandID=12",
                    "older-controller")
                    .find("200 OK") != std::string::npos,
            "foreign-controller token refresh response");
    require(tokenUpdates.load() == 0,
            "foreign controller token crossed the playMedia command boundary");
    require(httpGet(companionPort,
                    "/player/playback/pause?X-Plex-Token=active-token"
                    "&address=next-pms.local&port=32400&protocol=http&commandID=13",
                    "controller-test")
                    .find("200 OK") != std::string::npos,
            "identity-qualified token refresh response");
    require(tokenUpdates.load() == 1,
            "identity-qualified control token was not forwarded");

    const std::string subscribe =
        "/player/timeline/subscribe?protocol=http&port=" +
        std::to_string(callback.port()) + "&commandID=101";
    require(fragmentedGet(companionPort, subscribe).find("200 OK") != std::string::npos,
            "subscribe response");
    require(callback.waitFor("POST /:/timeline", "commandID=\"101\""),
            "immediate timeline callback");

    misterplex::PlayRequest play;
    play.key = "/library/metadata/40870";
    play.ratingKey = "40870";
    play.playQueueId = "145155";
    play.playQueueItemId = "40870";
    play.serverMachineId = "plex-server";
    play.address = "pms.local";
    play.port = "32400";
    play.protocol = "https";
    play.dispatchGeneration = 8;
    require(companion.stagePlay(play), "stage current generation");
    misterplex::PlayRequest stalePlay = play;
    stalePlay.dispatchGeneration = 6;
    require(!companion.stagePlay(stalePlay),
            "stale generated play overwrote newer Companion generation");
    require(companion.bindMedia(play, 2762760), "bind media");
    companion.setState("playing", 1000, 2762760);
    require(callback.waitFor("state=\"playing\"", "time=\"1000\""),
            "playing timeline callback");

    require(httpGet(companionPort, "/player/playback/pause?commandID=205",
                    "controller-test")
                    .find("200 OK") != std::string::npos,
            "pause response");
    require(callback.waitFor("state=\"paused\"", "commandID=\"205\""),
            "callback did not echo latest commandID");
    const std::string inheritedCommand =
        httpGet(companionPort, "/player/timeline/poll?wait=0", "controller-test");
    require(inheritedCommand.find("commandID=\"205\"") != std::string::npos,
            "poll without commandID forgot controller high-water mark");
    const std::string staleCommand =
        httpGet(companionPort, "/player/timeline/poll?wait=0&commandID=100",
                "controller-test");
    require(staleCommand.find("commandID=\"205\"") != std::string::npos,
            "older commandID regressed controller high-water mark");

    std::this_thread::sleep_for(std::chrono::milliseconds(1100));
    companion.setState("playing", 2500, 2762760);
    require(callback.waitFor("state=\"playing\"", "time=\"2500\""),
            "advancing timeline callback");

    const auto pollStart = std::chrono::steady_clock::now();
    const std::string poll =
        httpGet(companionPort, "/player/timeline/poll?wait=1&commandID=333",
                "controller-test");
    const auto pollElapsed = std::chrono::duration_cast<std::chrono::milliseconds>(
        std::chrono::steady_clock::now() - pollStart);
    require(pollElapsed.count() >= 300, "wait=1 poll returned without hold");
    require(poll.find("commandID=\"333\"") != std::string::npos,
            "poll did not echo commandID");
    require(poll.find("time=\"2500\"") != std::string::npos,
            "poll did not return current time");
    require(poll.find("\r\nX-Plex-Client-Identifier: misterplex-dev\r\n") !=
                std::string::npos,
            "poll response omitted player identity required by PMS proxy");

    const std::string unsubscribe = "/player/timeline/unsubscribe?commandID=102";
    require(httpGet(companionPort, unsubscribe, "controller-test").find("200 OK") !=
                std::string::npos,
            "unsubscribe response");
    std::this_thread::sleep_for(std::chrono::milliseconds(200));
    const size_t callbacksAfterUnsubscribe = callback.count();
    companion.setState("playing", 4000, 2762760);
    std::this_thread::sleep_for(std::chrono::milliseconds(1200));
    require(callback.count() == callbacksAfterUnsubscribe,
            "callback delivered after unsubscribe");

    companion.stop();
    callback.stop();
    std::cout << "test_companion_subscription: OK\n";
    return 0;
}
