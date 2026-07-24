#include "media_player.hpp"

#include <cerrno>
#include <cstdio>
#include <cstring>
#include <chrono>
#include <signal.h>
#include <vector>

#include <fcntl.h>
#include <sys/stat.h>
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
    // Probe audio device
    if (audioEnabled_) {
        int fd = ::open(audioDev_.c_str(), O_WRONLY | O_NONBLOCK);
        if (fd >= 0) {
            ::close(fd);
            log("media: audio device " + audioDev_ + " OK (s16le stereo @ 48k → FPGA)");
        } else {
            log("media: audio device " + audioDev_ + " unavailable (video-only)");
        }
    }
    return true;
}

void MediaPlayer::signalChildren(int sig) {
    pid_t v = videoPid_.load();
    pid_t a = audioPid_.load();
    if (v > 0)
        kill(-v, sig);
    if (a > 0)
        kill(-a, sig);
}

void MediaPlayer::killChildren() {
    signalChildren(SIGTERM);
    // Also reaping via process group; orphaned ffmpeg from prior sessions
    // must not keep companion port (see CLOEXEC / close-on-spawn).
    for (int i = 0; i < 20; ++i) {
        pid_t v = videoPid_.load();
        pid_t a = audioPid_.load();
        bool done = true;
        if (v > 0) {
            int st = 0;
            if (waitpid(v, &st, WNOHANG) == v)
                videoPid_.store(-1);
            else
                done = false;
        }
        if (a > 0) {
            int st = 0;
            if (waitpid(a, &st, WNOHANG) == a)
                audioPid_.store(-1);
            else
                done = false;
        }
        if (done)
            break;
        std::this_thread::sleep_for(std::chrono::milliseconds(25));
    }
    signalChildren(SIGKILL);
    pid_t v = videoPid_.exchange(-1);
    pid_t a = audioPid_.exchange(-1);
    if (v > 0) {
        int st = 0;
        waitpid(v, &st, 0);
    }
    if (a > 0) {
        int st = 0;
        waitpid(a, &st, 0);
    }
    audioActive_.store(false);
}

void MediaPlayer::stop() {
    stop_.store(true);
    killChildren();
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
    signalChildren(SIGSTOP);
    if (onProgress_)
        onProgress_("paused", positionMs_.load(), durationMs_);
}

void MediaPlayer::resume() {
    paused_.store(false);
    signalChildren(SIGCONT);
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
    play(url, ms, headers, dur);
}

bool MediaPlayer::play(const std::string& urlOrPath, int64_t startOffsetMs,
                       const std::string& httpHeaders, int64_t durationMs) {
    stop_.store(true);
    killChildren();
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

std::string MediaPlayer::buildCurlHeaderArgs(const std::string& headers) const {
    std::string args;
    size_t i = 0;
    while (i < headers.size()) {
        size_t j = headers.find('\n', i);
        if (j == std::string::npos)
            j = headers.size();
        std::string line = headers.substr(i, j - i);
        i = j + 1;
        while (!line.empty() && (line.back() == '\r' || line.back() == '\n'))
            line.pop_back();
        if (line.empty())
            continue;
        args += "-H '";
        for (char c : line) {
            if (c == '\'')
                args += "'\\''";
            else
                args += c;
        }
        args += "' ";
    }
    return args;
}

pid_t MediaPlayer::spawnShell(const std::string& cmd, int stdoutFd) {
    pid_t pid = fork();
    if (pid < 0)
        return -1;
    if (pid == 0) {
        setpgid(0, 0);
        if (stdoutFd >= 0) {
            dup2(stdoutFd, STDOUT_FILENO);
            if (stdoutFd != STDOUT_FILENO)
                ::close(stdoutFd);
        } else {
            int dn = ::open("/dev/null", O_WRONLY);
            if (dn >= 0) {
                dup2(dn, STDOUT_FILENO);
                ::close(dn);
            }
        }
        int devnull = ::open("/dev/null", O_WRONLY);
        if (devnull >= 0) {
            dup2(devnull, STDERR_FILENO);
            ::close(devnull);
        }
        // Drop inherited companion/listen fds so orphans cannot hold :3005
        for (int fd = 3; fd < 256; ++fd) {
            if (fd == stdoutFd)
                continue;
            ::close(fd);
        }
        execl("/bin/sh", "sh", "-c", cmd.c_str(), static_cast<char*>(nullptr));
        _exit(127);
    }
    setpgid(pid, pid);
    return pid;
}

void MediaPlayer::threadMain(std::string url, int64_t startMs, std::string headers,
                             int64_t durationMs) {
    playing_.store(true);
    positionMs_.store(startMs);
    if (onProgress_)
        onProgress_("buffering", startMs, durationMs);

    char scale[64];
    std::snprintf(scale, sizeof(scale), "%d:%d", outW_, outH_);

    std::string vcmd;
    std::string acmd;
    const bool testPattern = (url == "testsrc" || url.rfind("lavfi", 0) == 0);
    const bool httpUrl = (url.rfind("http://", 0) == 0 || url.rfind("https://", 0) == 0);

    auto shellQuote = [](const std::string& s) {
        std::string o = "'";
        for (char c : s) {
            if (c == '\'')
                o += "'\\''";
            else
                o += c;
        }
        o += "'";
        return o;
    };

    char ssArg[48] = {};
    if (startMs > 0 && !testPattern)
        std::snprintf(ssArg, sizeof(ssArg), " -ss %.3f", startMs / 1000.0);

    // --- Video command (stdout = raw RGB24) ---
    if (testPattern) {
        char lavfi[128];
        std::snprintf(lavfi, sizeof(lavfi), "testsrc2=size=%dx%d:rate=30", outW_, outH_);
        vcmd = ffmpeg_ + " -hide_banner -loglevel error -nostdin -f lavfi -i ";
        vcmd += lavfi;
        vcmd += " -t 120 -an -f rawvideo -pix_fmt rgb24 -";
        // Audio: sine tone for pattern
        if (audioEnabled_) {
            acmd = ffmpeg_ + " -hide_banner -loglevel error -nostdin -f lavfi -i sine=f=440:r=48000:d=120";
            acmd += " -f s16le -ac 2 -ar 48000 - >";
            acmd += shellQuote(audioDev_);
        }
    } else if (httpUrl && !headers.empty()) {
        const std::string hargs = buildCurlHeaderArgs(headers);
        const std::string qurl = shellQuote(url);
        vcmd = "curl -sS -g -L --http1.1 --connect-timeout 15 ";
        vcmd += hargs;
        vcmd += qurl;
        vcmd += " | ";
        vcmd += ffmpeg_;
        vcmd += " -hide_banner -loglevel error -nostdin -i pipe:0 -an -f rawvideo -pix_fmt rgb24 -vf 'scale=";
        vcmd += scale;
        vcmd += ":force_original_aspect_ratio=decrease,pad=";
        vcmd += scale;
        vcmd += ":(ow-iw)/2:(oh-ih)/2' -";
        if (audioEnabled_) {
            // Second fetch for audio (PMS universal is multi-client OK for weak ladder)
            acmd = "curl -sS -g -L --http1.1 --connect-timeout 15 ";
            acmd += hargs;
            acmd += qurl;
            acmd += " | ";
            acmd += ffmpeg_;
            acmd += " -hide_banner -loglevel error -nostdin -i pipe:0 -vn -f s16le -ac 2 -ar 48000 - >";
            acmd += shellQuote(audioDev_);
        }
    } else {
        std::string qpath;
        qpath.reserve(url.size() + 8);
        qpath.push_back('"');
        for (char c : url) {
            if (c == '"' || c == '$' || c == '`' || c == '\\')
                qpath += '\\';
            qpath += c;
        }
        qpath.push_back('"');
        vcmd = ffmpeg_ + " -hide_banner -loglevel error -nostdin";
        vcmd += ssArg;
        vcmd += " -i ";
        vcmd += qpath;
        vcmd += " -an -f rawvideo -pix_fmt rgb24 -vf 'scale=";
        vcmd += scale;
        vcmd += ":force_original_aspect_ratio=decrease,pad=";
        vcmd += scale;
        vcmd += ":(ow-iw)/2:(oh-ih)/2' -";
        if (audioEnabled_) {
            acmd = ffmpeg_ + " -hide_banner -loglevel error -nostdin";
            acmd += ssArg;
            acmd += " -i ";
            acmd += qpath;
            acmd += " -vn -f s16le -ac 2 -ar 48000 - >";
            acmd += shellQuote(audioDev_);
        }
    }

    // Spawn video
    int vfds[2];
    if (pipe(vfds) != 0) {
        log("media: video pipe failed");
        playing_.store(false);
        return;
    }
    log("media: spawn video " + vcmd);
    pid_t vpid = spawnShell(vcmd, vfds[1]);
    ::close(vfds[1]);
    if (vpid < 0) {
        ::close(vfds[0]);
        log("media: video fork failed");
        playing_.store(false);
        return;
    }
    videoPid_.store(vpid);
    int rfd = vfds[0];

    // Spawn audio (best-effort)
    if (!acmd.empty()) {
        // Only if device exists
        if (::access(audioDev_.c_str(), W_OK) == 0) {
            log("media: spawn audio " + acmd);
            pid_t apid = spawnShell(acmd, -1);
            if (apid > 0) {
                audioPid_.store(apid);
                audioActive_.store(true);
            } else {
                log("media: audio fork failed");
            }
        } else {
            log("media: skip audio (no " + audioDev_ + ")");
        }
    }

    const size_t frameBytes = static_cast<size_t>(outW_) * static_cast<size_t>(outH_) * 3;
    std::vector<uint8_t> frame(frameBytes);
    int64_t frameIndex = 0;
    auto t0 = std::chrono::steady_clock::now();
    auto lastLog = t0;
    size_t totalBytes = 0;
    const int fps = 30;

    if (onProgress_)
        onProgress_("playing", startMs, durationMs);

    while (!stop_.load()) {
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
            log("media: frames=" + std::to_string(frameIndex) +
                " bytes=" + std::to_string(totalBytes) +
                " audio=" + (audioActive_.load() ? "on" : "off"));
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
    killChildren();

    playing_.store(false);
    if (!stop_.load() && onProgress_)
        onProgress_("stopped", 0, durationMs);
    log("media: session end frames=" + std::to_string(frameIndex));
}

} // namespace misterplex
