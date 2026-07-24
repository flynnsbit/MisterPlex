#pragma once
// Phase 2 media player: FFmpeg decode → /dev/fb0 present + /dev/MrAudio PCM.
// Transitional: ARM decode, FPGA scanout via MiSTer_fb/ascal + SPI audio buffer.
// Phase 3 moves decode onto the fabric.

#include "fb_present.hpp"

#include <atomic>
#include <cstdint>
#include <functional>
#include <mutex>
#include <string>
#include <thread>

#include <sys/types.h>

namespace misterplex {

class MediaPlayer {
public:
    using LogFn = std::function<void(const std::string&)>;
    using ProgressFn = std::function<void(const std::string& state, int64_t timeMs, int64_t durMs)>;

    void setLog(LogFn f) { log_ = std::move(f); }
    void setProgress(ProgressFn f) { onProgress_ = std::move(f); }
    void setFfmpegPath(std::string p) { ffmpeg_ = std::move(p); }
    void setAudioPath(std::string p) { audioDev_ = std::move(p); }
    void setAudioEnabled(bool on) { audioEnabled_ = on; }

    bool initPresent();

    // Start playing a local path, lavfi testsrc, or http(s) URL.
    // httpHeaders: optional FFmpeg -headers block (CRLF-terminated lines).
    bool play(const std::string& urlOrPath, int64_t startOffsetMs = 0,
              const std::string& httpHeaders = {}, int64_t durationMs = 0);
    void pause();
    void resume();
    void stop();
    void seekMs(int64_t ms);

    bool playing() const { return playing_.load(); }
    bool audioActive() const { return audioActive_.load(); }
    std::string lastError() const;
    std::string currentUrl() const;

private:
    void threadMain(std::string url, int64_t startMs, std::string headers, int64_t durationMs);
    void killChildren();
    void signalChildren(int sig);
    pid_t spawnShell(const std::string& cmd, int stdoutFd /* -1 = inherit/devnull */);
    std::string buildCurlHeaderArgs(const std::string& headers) const;
    void log(const std::string& s) const;

    LogFn log_;
    ProgressFn onProgress_;
    std::string ffmpeg_ = "/media/fat/mistercast/bin/ffmpeg";
    std::string audioDev_ = "/dev/MrAudio";
    bool audioEnabled_ = true;

    FbPresent fb_;
    mutable std::mutex mu_;
    std::thread thr_;
    std::atomic<bool> stop_{false};
    std::atomic<bool> playing_{false};
    std::atomic<bool> paused_{false};
    std::atomic<bool> audioActive_{false};
    std::atomic<int64_t> seekReqMs_{-1};
    std::atomic<int64_t> positionMs_{0};
    std::atomic<pid_t> videoPid_{-1};
    std::atomic<pid_t> audioPid_{-1};
    std::string lastError_;
    std::string currentUrl_;
    std::string currentHeaders_;
    int64_t durationMs_ = 0;
    int outW_ = 320;
    int outH_ = 240;
};

} // namespace misterplex
