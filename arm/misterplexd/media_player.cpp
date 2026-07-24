#include "media_player.hpp"

#include <cerrno>
#include <cstdio>
#include <cstring>
#include <chrono>
#include <signal.h>
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

std::string MediaPlayer::currentUrl() const {
    std::lock_guard<std::mutex> lock(mu_);
    return currentUrl_;
}

bool MediaPlayer::initPresent() {
    if (!fb_.open("/dev/fb0")) {
        std::lock_guard<std::mutex> lock(mu_);
        lastError_ = "open /dev/fb0 failed";
        log("media: " + lastError_);
        return false;
    }
    outW_ = 320;
    outH_ = 240;
    fb_.clear();
    log("media: fb " + fb_.info() + " decode=" + std::to_string(outW_) + "x" + std::to_string(outH_));
    return true;
}

void MediaPlayer::killChild() {
    pid_t pid = childPid_.exchange(-1);
    if (pid > 0) {
        kill(pid, SIGTERM);
        // brief wait then SIGKILL
        for (int i = 0; i < 20; ++i) {
            int st = 0;
            pid_t r = waitpid(pid, &st, WNOHANG);
            if (r == pid || r < 0)
                return;
            std::this_thread::sleep_for(std::chrono::milliseconds(25));
        }
        kill(pid, SIGKILL);
        int st = 0;
        waitpid(pid, &st, 0);
    }
}

void MediaPlayer::stop() {
    stop_.store(true);
    killChild();
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
    pid_t pid = childPid_.load();
    if (pid > 0)
        kill(pid, SIGSTOP);
    if (onProgress_)
        onProgress_("paused", positionMs_.load(), durationMs_);
}

void MediaPlayer::resume() {
    paused_.store(false);
    pid_t pid = childPid_.load();
    if (pid > 0)
        kill(pid, SIGCONT);
    if (onProgress_)
        onProgress_("playing", positionMs_.load(), durationMs_);
}

void MediaPlayer::seekMs(int64_t ms) {
    if (ms < 0)
        ms = 0;
    std::string url, headers;
    int64_t dur = 0;
    {
        std::lock_guard<std::mutex> lock(mu_);
        url = currentUrl_;
        headers = currentHeaders_;
        dur = durationMs_;
    }
    if (url.empty()) {
        seekReqMs_.store(ms);
        return;
    }
    // Restart stream at new offset
    play(url, ms, headers, dur);
}

bool MediaPlayer::play(const std::string& urlOrPath, int64_t startOffsetMs,
                       const std::string& httpHeaders, int64_t durationMs) {
    stop_.store(true);
    killChild();
    if (thr_.joinable())
        thr_.join();

    if (!fb_.ok() && !initPresent())
        return false;

    {
        std::lock_guard<std::mutex> lock(mu_);
        currentUrl_ = urlOrPath;
        currentHeaders_ = httpHeaders;
        durationMs_ = durationMs;
    }

    stop_.store(false);
    paused_.store(false);
    seekReqMs_.store(-1);
    thr_ = std::thread([this, urlOrPath, startOffsetMs, httpHeaders, durationMs] {
        threadMain(urlOrPath, startOffsetMs, httpHeaders, durationMs);
    });
    return true;
}

void MediaPlayer::threadMain(std::string url, int64_t startMs, std::string headers,
                             int64_t durationMs) {
    playing_.store(true);
    positionMs_.store(startMs);
    if (onProgress_)
        onProgress_("buffering", startMs, durationMs);

    char scale[64];
    std::snprintf(scale, sizeof(scale), "%d:%d", outW_, outH_);

    std::string cmd;
    const bool testPattern = (url == "testsrc" || url.rfind("lavfi", 0) == 0);
    const bool httpUrl = (url.rfind("http://", 0) == 0 || url.rfind("https://", 0) == 0);

    if (testPattern) {
        char lavfi[128];
        std::snprintf(lavfi, sizeof(lavfi), "testsrc2=size=%dx%d:rate=30", outW_, outH_);
        cmd = ffmpeg_ + " -hide_banner -loglevel error -nostdin -f lavfi -i ";
        cmd += lavfi;
        cmd += " -t 120 -an -f rawvideo -pix_fmt rgb24 -";
    } else if (httpUrl && !headers.empty()) {
        // PMS universal: curl with one -H per header line (quoted), pipe to ffmpeg.
        cmd = "curl -sS -g -L --http1.1 --connect-timeout 15 ";
        {
            std::string hblock = headers;
            size_t i = 0;
            while (i < hblock.size()) {
                size_t j = hblock.find('\n', i);
                if (j == std::string::npos)
                    j = hblock.size();
                std::string line = hblock.substr(i, j - i);
                i = j + 1;
                while (!line.empty() && (line.back() == '\r' || line.back() == '\n'))
                    line.pop_back();
                if (line.empty())
                    continue;
                cmd += "-H '";
                for (char c : line) {
                    if (c == '\'')
                        cmd += "'\\''";
                    else
                        cmd += c;
                }
                cmd += "' ";
            }
        }
        cmd += "'";
        for (char c : url) {
            if (c == '\'')
                cmd += "'\\''";
            else
                cmd += c;
        }
        cmd += "' | ";
        cmd += ffmpeg_;
        cmd += " -hide_banner -loglevel error -nostdin -i pipe:0 -an -f rawvideo -pix_fmt rgb24 -vf 'scale=";
        cmd += scale;
        cmd += ":force_original_aspect_ratio=decrease,pad=";
        cmd += scale;
        cmd += ":(ow-iw)/2:(oh-ih)/2' -";
    } else {
        cmd = ffmpeg_ + " -hide_banner -loglevel error -nostdin";
        if (startMs > 0) {
            char ss[32];
            std::snprintf(ss, sizeof(ss), "%.3f", startMs / 1000.0);
            cmd += " -ss ";
            cmd += ss;
        }
        cmd += " -i \"";
        for (char c : url) {
            if (c == '"' || c == '$' || c == '`' || c == '\\')
                cmd += '\\';
            cmd += c;
        }
        cmd += "\"";
        cmd += " -an -f rawvideo -pix_fmt rgb24 -vf 'scale=";
        cmd += scale;
        cmd += ":force_original_aspect_ratio=decrease,pad=";
        cmd += scale;
        cmd += ":(ow-iw)/2:(oh-ih)/2' -";
    }

    log("media: spawn " + cmd);
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
        int devnull = ::open("/dev/null", O_WRONLY);
        if (devnull >= 0) {
            dup2(devnull, STDERR_FILENO);
            ::close(devnull);
        }
        // New process group so we can signal the whole tree (sh + ffmpeg)
        setpgid(0, 0);
        execl("/bin/sh", "sh", "-c", cmd.c_str(), static_cast<char*>(nullptr));
        _exit(127);
    }
    ::close(fds[1]);
    childPid_.store(pid);
    int rfd = fds[0];

    const size_t frameBytes = static_cast<size_t>(outW_) * static_cast<size_t>(outH_) * 3;
    std::vector<uint8_t> frame(frameBytes);
    int64_t frameIndex = 0;
    auto t0 = std::chrono::steady_clock::now();
    auto lastLog = t0;
    size_t totalBytes = 0;
    // Assume 30 fps presentation pace (testsrc and weak ladder)
    const int fps = 30;

    if (onProgress_)
        onProgress_("playing", startMs, durationMs);

    while (!stop_.load()) {
        // Handle seek request mid-stream: break and restart outer play()
        int64_t seekTo = seekReqMs_.exchange(-1);
        if (seekTo >= 0) {
            log("media: seek requested " + std::to_string(seekTo));
            break;
        }

        if (paused_.load()) {
            std::this_thread::sleep_for(std::chrono::milliseconds(20));
            continue;
        }

        size_t got = 0;
        while (got < frameBytes && !stop_.load() && !paused_.load()) {
            ssize_t n = ::read(rfd, frame.data() + got, frameBytes - got);
            if (n < 0) {
                if (errno == EINTR)
                    continue;
                log("media: read err errno=" + std::to_string(errno));
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

        auto target = t0 + std::chrono::milliseconds(frameIndex * 1000 / fps);
        if (target > now)
            std::this_thread::sleep_until(target);

        {
            int64_t tms = startMs + frameIndex * 1000 / fps;
            positionMs_.store(tms);
            if ((frameIndex % 15) == 0 && onProgress_)
                onProgress_("playing", tms, durationMs);
        }
    }

    ::close(rfd);
    // Kill process group
    pid_t p = childPid_.exchange(-1);
    if (p > 0) {
        kill(-p, SIGTERM);
        int st = 0;
        for (int i = 0; i < 20; ++i) {
            if (waitpid(p, &st, WNOHANG) == p)
                break;
            std::this_thread::sleep_for(std::chrono::milliseconds(25));
        }
        kill(-p, SIGKILL);
        waitpid(p, &st, 0);
    }

    playing_.store(false);
    if (!stop_.load() && onProgress_)
        onProgress_("stopped", 0, durationMs);
    log("media: session end frames=" + std::to_string(frameIndex));
}

} // namespace misterplex
