#pragma once
// Phase 2 media player: single-process FFmpeg → /dev/fb0 + /dev/MrAudio.
// Transitional ARM decode; FPGA owns scanout (MiSTer_fb) + SPI audio (MrAudio).

#include "fb_present.hpp"

#include <atomic>
#include <cstdint>
#include <functional>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

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
    void setDecodeSize(int w, int h);

    bool initPresent();

    bool play(const std::string& urlOrPath, int64_t startOffsetMs = 0,
              const std::string& httpHeaders = {}, int64_t durationMs = 0);
    void pause();
    void resume();
    void stop();
    void seekMs(int64_t ms);

    bool playing() const { return playing_.load(); }
    bool audioActive() const { return audioActive_.load(); }
    int decodeW() const { return outW_; }
    int decodeH() const { return outH_; }
    std::string lastError() const;
    std::string currentUrl() const;

private:
    void threadMain(std::string url, int64_t startMs, std::string headers, int64_t durationMs);
    void audioPump(int afd);
    void killChildren();
    void signalChildren(int sig);
    pid_t spawnFfmpeg(const std::vector<std::string>& args, int vWriteFd, int aWriteFd);
    void log(const std::string& s) const;

    LogFn log_;
    ProgressFn onProgress_;
    std::string ffmpeg_ = "/media/fat/mistercast/bin/ffmpeg";
    std::string audioDev_ = "/dev/MrAudio";
    bool audioEnabled_ = true;

    FbPresent fb_;
    mutable std::mutex mu_;
    std::thread thr_;
    std::thread audioThr_;
    std::atomic<bool> stop_{false};
    std::atomic<bool> playing_{false};
    std::atomic<bool> paused_{false};
    std::atomic<bool> audioActive_{false};
    std::atomic<int64_t> seekReqMs_{-1};
    std::atomic<int64_t> positionMs_{0};
    std::atomic<pid_t> childPid_{-1};
    std::string lastError_;
    std::string currentUrl_;
    std::string currentHeaders_;
    int64_t durationMs_ = 0;
    int outW_ = 320;
    int outH_ = 240;
};

} // namespace misterplex
