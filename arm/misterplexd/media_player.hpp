#pragma once
// Phase 2 media player: single-process FFmpeg → /dev/fb0 + /dev/MrAudio.
// Transitional ARM decode; FPGA owns scanout (MiSTer_fb) + SPI audio (MrAudio).

#include "fb_present.hpp"
#include "fpga_spi.hpp"

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
    // present: "fb0" (default) and/or "fpga" (SPI ioctl → frame_store)
    void setPresentMode(std::string mode) { presentMode_ = std::move(mode); }
    // STREAM=1: demux annex-B H.264 → host I-slice recon (RGB565 → F1) + F3 stub feed
    void setStreamEnabled(bool on) { streamEnabled_ = on; }
    // STREAM=0 only: optional FFmpeg subtitles filter for local file paths (see docs/subtitles-burnin.md).
    // "off" | "ffmpeg" — PMS burn-in is handled in resolve (WeakLadder::burnSubtitles).
    void setSubtitleMode(std::string mode) { subtitleMode_ = std::move(mode); }
    void setSubtitleStreamIndex(int idx) { subtitleStreamIndex_ = idx; }
    void setDecodeSize(int w, int h);
    // Host recon frames presented this session (I/IDR only)
    int64_t reconFrames() const { return reconFrames_.load(); }

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
    void streamPump(int sfd);
    void killChildren();
    void signalChildren(int sig);
    pid_t spawnFfmpeg(const std::vector<std::string>& args, int vWriteFd, int aWriteFd);
    pid_t spawnStreamDemux(const std::string& url, const std::string& headers, int64_t startMs,
                           int writeFd);
    void log(const std::string& s) const;

    LogFn log_;
    ProgressFn onProgress_;
    std::string ffmpeg_ = "/media/fat/mistercast/bin/ffmpeg";
    std::string audioDev_ = "/dev/MrAudio";
    std::string presentMode_ = "fb0"; // "fb0", "fpga", "both"
    bool audioEnabled_ = true;
    bool streamEnabled_ = false; // annex-B → host recon F1 + F3 stub
    std::string subtitleMode_ = "off"; // off | ffmpeg
    int subtitleStreamIndex_ = 0;

    FbPresent fb_;
    FpgaSpi fpga_;
    mutable std::mutex mu_;
    std::thread thr_;
    std::thread audioThr_;
    std::thread streamThr_;
    std::atomic<bool> stop_{false};
    std::atomic<bool> playing_{false};
    std::atomic<bool> paused_{false};
    std::atomic<bool> audioActive_{false};
    std::atomic<bool> streamActive_{false};
    std::atomic<int64_t> reconFrames_{0};
    std::atomic<bool> reconPresentOk_{false}; // at least one recon → F1/fb0 this session
    std::atomic<int64_t> seekReqMs_{-1};
    std::atomic<int64_t> positionMs_{0};
    std::atomic<pid_t> childPid_{-1};
    std::atomic<pid_t> streamPid_{-1};
    std::string lastError_;
    std::string currentUrl_;
    std::string currentHeaders_;
    int64_t durationMs_ = 0;
    int outW_ = 320;
    int outH_ = 240;
};

} // namespace misterplex
