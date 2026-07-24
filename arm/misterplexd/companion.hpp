#pragma once
// Minimal Plex GDM + companion HTTP for MiSTerPlex Phase 2 bootstrap.
// Full feature parity lands by porting mistercast-linux plex_cast lessons.

#include <atomic>
#include <cstdint>
#include <functional>
#include <mutex>
#include <string>
#include <thread>

namespace misterplex {

class Companion {
public:
    using LogFn = std::function<void(const std::string&)>;
    using PlayFn = std::function<void(const std::string& keyOrUrl, int64_t offsetMs)>;

    void setName(std::string n) { name_ = std::move(n); }
    void setMachineId(std::string id) { machineId_ = std::move(id); }
    void setPort(uint16_t p) { port_ = p; }
    void setLog(LogFn f) { log_ = std::move(f); }
    void setPlay(PlayFn f) { onPlay_ = std::move(f); }

    bool start();
    void stop();
    bool running() const { return running_.load(); }

    void setState(const std::string& state, int64_t timeMs, int64_t durationMs);

private:
    void gdmLoop();
    void httpLoop();
    std::string gdmPayload() const;
    std::string resourcesXml() const;
    std::string timelineXml(const std::string& commandId) const;
    std::string lanIp() const;
    void log(const std::string& s) const;

    std::string name_ = "MiSTerPlex";
    std::string machineId_ = "misterplex-1";
    uint16_t port_ = 3005;
    LogFn log_;
    PlayFn onPlay_;

    std::atomic<bool> running_{false};
    std::thread gdmThr_;
    std::thread httpThr_;

    mutable std::mutex mu_;
    std::string state_ = "stopped";
    int64_t timeMs_ = 0;
    int64_t durationMs_ = 0;
};

} // namespace misterplex
