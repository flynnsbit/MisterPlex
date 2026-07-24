#pragma once
// Phase 2 media player: FFmpeg decode → /dev/fb0 present.
// Transitional: ARM decode, FPGA scanout via MiSTer_fb/ascal.
// Phase 3 moves decode onto the fabric.

#include "fb_present.hpp"

#include <atomic>
#include <cstdint>
#include <functional>
#include <mutex>
#include <string>
#include <thread>

namespace misterplex {

class MediaPlayer {
public:
    using LogFn = std::function<void(const std::string&)>;
    using ProgressFn = std::function<void(const std::string& state, int64_t timeMs, int64_t durMs)>;

    void setLog(LogFn f) { log_ = std::move(f); }
    void setProgress(ProgressFn f) { onProgress_ = std::move(f); }
    void setFfmpegPath(std::string p) { ffmpeg_ = std::move(p); }

    // Open fb once (call at daemon start).
    bool initPresent();

    // Start playing a local path or http(s) URL. Stops any previous session.
    bool play(const std::string& urlOrPath, int64_t startOffsetMs = 0);
    void pause();
    void resume();
    void stop();
    void seekMs(int64_t ms);

    bool playing() const { return playing_.load(); }
    std::string lastError() const;

private:
    void threadMain(std::string url, int64_t startMs);
    void log(const std::string& s) const;

    LogFn log_;
    ProgressFn onProgress_;
    std::string ffmpeg_ = "/media/fat/mistercast/bin/ffmpeg";

    FbPresent fb_;
    mutable std::mutex mu_;
    std::thread thr_;
    std::atomic<bool> stop_{false};
    std::atomic<bool> playing_{false};
    std::atomic<bool> paused_{false};
    std::atomic<int64_t> seekReqMs_{-1};
    std::string lastError_;
    int outW_ = 640;
    int outH_ = 480;
};

} // namespace misterplex
