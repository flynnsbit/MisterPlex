#include "media_player.hpp"

#include <cerrno>
#include <cstdio>
#include <cstring>
#include <chrono>
#include <vector>

#include <fcntl.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <unistd.h>

namespace misterplex {

void MediaPlayer::log(const std::string& s) const {
    if (log_)
        log_(s);
    else
        std::fprintf(stderr, "%s\n", s.c_str());
}

std::string MediaPlayer::lastError() const {
    std::lock_guard<std::mutex> lock(mu_);
    return lastError_;
}

bool MediaPlayer::initPresent() {
    if (!fb_.open("/dev/fb0")) {
        std::lock_guard<std::mutex> lock(mu_);
        lastError_ = "open /dev/fb0 failed";
        log("media: " + lastError_);
        return false;
    }
    // Fit decode size to fb (cap work on dual A9)
    // Cap decode work for dual A9; letterbox onto fb
    outW_ = 320;
    outH_ = 240;

    fb_.clear();
    log("media: fb " + fb_.info() + " decode=" + std::to_string(outW_) + "x" + std::to_string(outH_));
    return true;
}

void MediaPlayer::stop() {
    stop_.store(true);
    if (thr_.joinable())
        thr_.join();
    playing_.store(false);
    paused_.store(false);
    if (fb_.ok())
        fb_.clear();
    if (onProgress_)
        onProgress_("stopped", 0, 0);
}

void MediaPlayer::pause() {
    paused_.store(true);
    if (onProgress_)
        onProgress_("paused", 0, 0);
}

void MediaPlayer::resume() {
    paused_.store(false);
    if (onProgress_)
        onProgress_("playing", 0, 0);
}

void MediaPlayer::seekMs(int64_t ms) {
    if (ms < 0)
        ms = 0;
    seekReqMs_.store(ms);
}

bool MediaPlayer::play(const std::string& urlOrPath, int64_t startOffsetMs) {
    stop();
    if (!fb_.ok() && !initPresent())
        return false;
    stop_.store(false);
    paused_.store(false);
    seekReqMs_.store(-1);
    thr_ = std::thread([this, urlOrPath, startOffsetMs] { threadMain(urlOrPath, startOffsetMs); });
    return true;
}

void MediaPlayer::threadMain(std::string url, int64_t startMs) {
    playing_.store(true);
    if (onProgress_)
        onProgress_("buffering", startMs, 0);

    // Build ffmpeg command: scale to outW x outH, rgb24 raw to stdout, no audio (Phase 2 video-first)
    char scale[64];
    std::snprintf(scale, sizeof(scale), "%d:%d", outW_, outH_);

    std::string cmd = ffmpeg_ + " -hide_banner -loglevel error -nostdin";
    const bool testPattern = (url == "testsrc" || url.rfind("lavfi", 0) == 0);
    if (testPattern) {
        // Match decode size exactly — no scale filter (faster on dual A9)
        char lavfi[128];
        std::snprintf(lavfi, sizeof(lavfi), "testsrc2=size=%dx%d:rate=30", outW_, outH_);
        cmd += " -f lavfi -i ";
        cmd += lavfi;
        cmd += " -t 120 -an -f rawvideo -pix_fmt rgb24 -";
    } else {
        if (startMs > 0) {
            char ss[32];
            std::snprintf(ss, sizeof(ss), "%.3f", startMs / 1000.0);
            cmd += " -ss ";
            cmd += ss;
        }
        cmd += " -i \"";
        cmd += url;
        cmd += "\"";
        // Quote -vf: MiSTer ash treats ( ) as syntax otherwise
        cmd += " -an -f rawvideo -pix_fmt rgb24 -vf 'scale=";
        cmd += scale;
        cmd += ":force_original_aspect_ratio=decrease,pad=";
        cmd += scale;
        cmd += ":(ow-iw)/2:(oh-ih)/2' -";
    }

    log("media: spawn " + cmd);
    // Use direct pipe+fork so we control fds (popen + huge frames was hanging on device).
    int fds[2];
    if (pipe(fds) != 0) {
        log("media: pipe() failed");
        playing_.store(false);
        return;
    }
    pid_t pid = fork();
    if (pid < 0) {
        log("media: fork failed");
        ::close(fds[0]);
        ::close(fds[1]);
        playing_.store(false);
        return;
    }
    if (pid == 0) {
        ::close(fds[0]);
        dup2(fds[1], STDOUT_FILENO);
        ::close(fds[1]);
        // stderr → /dev/null to avoid fill
        int devnull = ::open("/dev/null", O_WRONLY);
        if (devnull >= 0) {
            dup2(devnull, STDERR_FILENO);
            ::close(devnull);
        }
        execl("/bin/sh", "sh", "-c", cmd.c_str(), static_cast<char*>(nullptr));
        _exit(127);
    }
    ::close(fds[1]);
    int rfd = fds[0];

    const size_t frameBytes = static_cast<size_t>(outW_) * static_cast<size_t>(outH_) * 3;
    std::vector<uint8_t> frame(frameBytes);
    int64_t frameIndex = 0;
    auto t0 = std::chrono::steady_clock::now();
    auto lastLog = t0;
    size_t totalBytes = 0;

    if (onProgress_)
        onProgress_("playing", startMs, 0);

    while (!stop_.load()) {
        if (paused_.load()) {
            std::this_thread::sleep_for(std::chrono::milliseconds(20));
            continue;
        }

        size_t got = 0;
        while (got < frameBytes && !stop_.load()) {
            ssize_t n = ::read(rfd, frame.data() + got, frameBytes - got);
            if (n < 0) {
                if (errno == EINTR)
                    continue;
                log("media: read err");
                break;
            }
            if (n == 0)
                break;
            got += static_cast<size_t>(n);
            totalBytes += static_cast<size_t>(n);
        }
        if (got < frameBytes) {
            log("media: short read got=" + std::to_string(got) + "/" + std::to_string(frameBytes) +
                " totalBytes=" + std::to_string(totalBytes));
            break;
        }

        if (!fb_.blitRgb24(frame.data(), outW_, outH_))
            log("media: blit failed");
        ++frameIndex;

        auto now = std::chrono::steady_clock::now();
        if (now - lastLog > std::chrono::seconds(1)) {
            lastLog = now;
            log("media: frames=" + std::to_string(frameIndex) + " bytes=" + std::to_string(totalBytes));
        }

        auto target = t0 + std::chrono::milliseconds(frameIndex * 1000 / 30);
        if (target > now)
            std::this_thread::sleep_until(target);

        if ((frameIndex % 15) == 0 && onProgress_) {
            int64_t tms = startMs + frameIndex * 1000 / 30;
            onProgress_("playing", tms, 0);
        }
    }

    ::close(rfd);
    int st = 0;
    waitpid(pid, &st, 0);
    playing_.store(false);
    if (!stop_.load() && onProgress_)
        onProgress_("stopped", 0, 0);
    log("media: session end frames=" + std::to_string(frameIndex) + " status=" + std::to_string(st));
}

} // namespace misterplex
