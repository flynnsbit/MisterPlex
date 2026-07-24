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

void MediaPlayer::setDecodeSize(int w, int h) {
    if (w < 160)
        w = 160;
    if (h < 120)
        h = 120;
    // Even dimensions for YUV-friendly sources
    w &= ~1;
    h &= ~1;
    if (w > 1280)
        w = 1280;
    if (h > 720)
        h = 720;
    outW_ = w;
    outH_ = h;
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
    bool wantFb = (presentMode_ == "fb0" || presentMode_ == "both" || presentMode_.empty());
    bool wantFpga = (presentMode_ == "fpga" || presentMode_ == "both");

    bool any = false;
    if (wantFb) {
        if (fb_.open("/dev/fb0")) {
            fb_.clear();
            log("media: fb " + fb_.info() + " decode=" + std::to_string(outW_) + "x" +
                std::to_string(outH_));
            any = true;
        } else {
            log("media: /dev/fb0 unavailable");
        }
    }
    if (wantFpga) {
        if (fpga_.open()) {
            log("media: FPGA SPI frame_tx OK (PRESENT=fpga → ioctl frame_store)");
            any = true;
        } else {
            log("media: FPGA SPI unavailable: " + fpga_.lastError());
        }
    }
    if (audioEnabled_) {
        int fd = ::open(audioDev_.c_str(), O_WRONLY | O_NONBLOCK);
        if (fd >= 0) {
            ::close(fd);
            log("media: audio device " + audioDev_ + " OK (s16le stereo @ 48k → FPGA)");
        } else {
            log("media: audio device " + audioDev_ + " unavailable (video-only)");
        }
    }
    if (!any) {
        std::lock_guard<std::mutex> lock(mu_);
        lastError_ = "no present path (fb0/fpga)";
        return false;
    }
    return true;
}

void MediaPlayer::signalChildren(int sig) {
    pid_t p = childPid_.load();
    if (p > 0)
        kill(-p, sig);
}

void MediaPlayer::killChildren() {
    signalChildren(SIGTERM);
    for (int i = 0; i < 20; ++i) {
        pid_t p = childPid_.load();
        if (p <= 0)
            break;
        int st = 0;
        if (waitpid(p, &st, WNOHANG) == p) {
            childPid_.store(-1);
            break;
        }
        std::this_thread::sleep_for(std::chrono::milliseconds(25));
    }
    signalChildren(SIGKILL);
    pid_t p = childPid_.exchange(-1);
    if (p > 0) {
        int st = 0;
        waitpid(p, &st, 0);
    }
    audioActive_.store(false);
}

void MediaPlayer::stop() {
    stop_.store(true);
    killChildren();
    if (audioThr_.joinable())
        audioThr_.join();
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
    if (audioThr_.joinable())
        audioThr_.join();
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

pid_t MediaPlayer::spawnFfmpeg(const std::vector<std::string>& args, int vWriteFd, int aWriteFd) {
    pid_t pid = fork();
    if (pid < 0)
        return -1;
    if (pid == 0) {
        setpgid(0, 0);
        // Video → stdout (pipe:1)
        if (vWriteFd >= 0) {
            dup2(vWriteFd, STDOUT_FILENO);
        }
        // Audio → fd 3 (pipe:3) when enabled
        if (aWriteFd >= 0) {
            if (aWriteFd != 3) {
                dup2(aWriteFd, 3);
                if (aWriteFd != STDOUT_FILENO)
                    ::close(aWriteFd);
            }
        }
        if (vWriteFd >= 0 && vWriteFd != STDOUT_FILENO && vWriteFd != 3)
            ::close(vWriteFd);

        int devnull = ::open("/dev/null", O_WRONLY);
        if (devnull >= 0) {
            dup2(devnull, STDERR_FILENO);
            if (devnull > 3)
                ::close(devnull);
        }
        // Close inherited companion sockets etc.
        for (int fd = 4; fd < 256; ++fd)
            ::close(fd);

        std::vector<char*> argv;
        argv.reserve(args.size() + 1);
        for (const auto& s : args)
            argv.push_back(const_cast<char*>(s.c_str()));
        argv.push_back(nullptr);
        execv(args[0].c_str(), argv.data());
        _exit(127);
    }
    setpgid(pid, pid);
    return pid;
}

void MediaPlayer::audioPump(int afd) {
    // Drain PCM to MrAudio (continuous) and optionally F2 audio_fifo chunks.
    const bool wantMr = audioEnabled_ && (::access(audioDev_.c_str(), W_OK) == 0);
    const bool wantF2 = fpga_.ok() && (presentMode_ == "fpga" || presentMode_ == "both");

    int out = -1;
    if (wantMr) {
        out = ::open(audioDev_.c_str(), O_WRONLY);
        if (out < 0)
            log("media: open " + audioDev_ + " failed errno=" + std::to_string(errno));
    }
    if (out < 0 && !wantF2) {
        char buf[4096];
        while (!stop_.load()) {
            ssize_t n = ::read(afd, buf, sizeof(buf));
            if (n <= 0)
                break;
        }
        ::close(afd);
        return;
    }

    if (wantF2) {
        fpga_.flushAudioFifo();
        log("media: F2 audio_fifo streaming enabled");
    }

    audioActive_.store(true);
    char buf[8192];
    std::vector<uint8_t> f2acc;
    f2acc.reserve(32768);
    size_t total = 0;
    size_t f2total = 0;
    // Match audio_fifo DEPTH=2048 stereo samples (~42 ms @ 48 kHz).
    // Larger chunks overflow and drop on wr_full (half-rate FPGA audio).
    constexpr size_t kF2Chunk = 8192;

    while (!stop_.load()) {
        if (paused_.load()) {
            std::this_thread::sleep_for(std::chrono::milliseconds(20));
            continue;
        }
        ssize_t n = ::read(afd, buf, sizeof(buf));
        if (n < 0) {
            if (errno == EINTR)
                continue;
            break;
        }
        if (n == 0)
            break;

        if (out >= 0) {
            size_t off = 0;
            while (off < static_cast<size_t>(n) && !stop_.load()) {
                ssize_t w = ::write(out, buf + off, static_cast<size_t>(n) - off);
                if (w < 0) {
                    if (errno == EINTR)
                        continue;
                    log("media: MrAudio write err errno=" + std::to_string(errno));
                    break;
                }
                off += static_cast<size_t>(w);
            }
        }

        if (wantF2) {
            f2acc.insert(f2acc.end(), buf, buf + n);
            while (f2acc.size() >= kF2Chunk && !stop_.load()) {
                if (fpga_.sendPcmChunk(f2acc.data(), kF2Chunk, /*F2*/ 2)) {
                    f2total += kF2Chunk;
                } else if ((f2total % (kF2Chunk * 8)) == 0) {
                    log("media: F2 pcm: " + fpga_.lastError());
                }
                f2acc.erase(f2acc.begin(), f2acc.begin() + static_cast<std::ptrdiff_t>(kF2Chunk));
            }
        }
        total += static_cast<size_t>(n);
    }

    // Flush remainder to F2
    if (wantF2 && f2acc.size() >= 4) {
        size_t n = f2acc.size() & ~size_t(3);
        if (n && fpga_.sendPcmChunk(f2acc.data(), n, 2))
            f2total += n;
    }

    if (out >= 0)
        ::close(out);
    ::close(afd);
    audioActive_.store(false);
    log("media: audio pump end bytes=" + std::to_string(total) +
        " f2=" + std::to_string(f2total));
}

void MediaPlayer::threadMain(std::string url, int64_t startMs, std::string headers,
                             int64_t durationMs) {
    playing_.store(true);
    positionMs_.store(startMs);
    if (onProgress_)
        onProgress_("buffering", startMs, durationMs);

    char scale[64];
    std::snprintf(scale, sizeof(scale), "%d:%d", outW_, outH_);
    std::string vf = std::string("scale=") + scale +
                     ":force_original_aspect_ratio=decrease,pad=" + scale + ":(ow-iw)/2:(oh-ih)/2";

    const bool testPattern = (url == "testsrc" || url.rfind("lavfi", 0) == 0);
    const bool wantMr = audioEnabled_ && (::access(audioDev_.c_str(), W_OK) == 0);
    const bool wantF2 = fpga_.ok() && (presentMode_ == "fpga" || presentMode_ == "both");
    const bool wantAudio = audioEnabled_ && (wantMr || wantF2);

    std::vector<std::string> args;
    args.push_back(ffmpeg_);
    args.push_back("-hide_banner");
    args.push_back("-loglevel");
    args.push_back("error");
    args.push_back("-nostdin");

    if (testPattern) {
        char lavfi[128];
        std::snprintf(lavfi, sizeof(lavfi), "testsrc2=size=%dx%d:rate=30", outW_, outH_);
        args.push_back("-f");
        args.push_back("lavfi");
        args.push_back("-i");
        args.push_back(lavfi);
        if (wantAudio) {
            args.push_back("-f");
            args.push_back("lavfi");
            args.push_back("-i");
            args.push_back("sine=f=440:r=48000:d=120");
        }
        args.push_back("-t");
        args.push_back("120");
        args.push_back("-map");
        args.push_back("0:v:0");
        args.push_back("-an");
        args.push_back("-f");
        args.push_back("rawvideo");
        args.push_back("-pix_fmt");
        args.push_back("rgb24");
        args.push_back("pipe:1");
        if (wantAudio) {
            args.push_back("-map");
            args.push_back("1:a:0");
            args.push_back("-vn");
            args.push_back("-f");
            args.push_back("s16le");
            args.push_back("-ac");
            args.push_back("2");
            args.push_back("-ar");
            args.push_back("48000");
            args.push_back("pipe:3");
        }
    } else {
        if (startMs > 0) {
            char ss[32];
            std::snprintf(ss, sizeof(ss), "%.3f", startMs / 1000.0);
            args.push_back("-ss");
            args.push_back(ss);
        }
        // Prefer native HTTP with headers (single demux for A+V — dual-A9 critical)
        if (!headers.empty()) {
            // FFmpeg requires trailing CRLF on -headers block
            std::string h = headers;
            if (h.size() < 2 || h[h.size() - 1] != '\n')
                h += "\r\n";
            args.push_back("-headers");
            args.push_back(h);
            args.push_back("-reconnect");
            args.push_back("1");
            args.push_back("-reconnect_streamed");
            args.push_back("1");
            args.push_back("-reconnect_delay_max");
            args.push_back("5");
        }
        args.push_back("-i");
        args.push_back(url);

        args.push_back("-map");
        args.push_back("0:v:0");
        args.push_back("-an");
        args.push_back("-f");
        args.push_back("rawvideo");
        args.push_back("-pix_fmt");
        args.push_back("rgb24");
        args.push_back("-vf");
        args.push_back(vf);
        args.push_back("pipe:1");

        if (wantAudio) {
            // Optional audio map: missing track → no audio pipe traffic
            args.push_back("-map");
            args.push_back("0:a:0?");
            args.push_back("-vn");
            args.push_back("-f");
            args.push_back("s16le");
            args.push_back("-ac");
            args.push_back("2");
            args.push_back("-ar");
            args.push_back("48000");
            args.push_back("pipe:3");
        }
    }

    int vpipe[2] = {-1, -1};
    int apipe[2] = {-1, -1};
    if (pipe(vpipe) != 0) {
        log("media: video pipe failed");
        playing_.store(false);
        return;
    }
    if (wantAudio && pipe(apipe) != 0) {
        log("media: audio pipe failed — video only");
        apipe[0] = apipe[1] = -1;
    }

    {
        std::string joined = "media: spawn single-process";
        for (const auto& a : args) {
            joined += ' ';
            if (a.find(' ') != std::string::npos || a.find('\r') != std::string::npos)
                joined += "[...]";
            else
                joined += a;
        }
        log(joined);
    }

    pid_t pid = spawnFfmpeg(args, vpipe[1], apipe[1] >= 0 ? apipe[1] : -1);
    ::close(vpipe[1]);
    if (apipe[1] >= 0)
        ::close(apipe[1]);
    if (pid < 0) {
        ::close(vpipe[0]);
        if (apipe[0] >= 0)
            ::close(apipe[0]);
        log("media: fork failed");
        playing_.store(false);
        return;
    }
    childPid_.store(pid);
    int rfd = vpipe[0];

    if (apipe[0] >= 0) {
        audioThr_ = std::thread([this, afd = apipe[0]] { audioPump(afd); });
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

        if (fb_.ok()) {
            if (!fb_.blitRgb24(frame.data(), outW_, outH_))
                log("media: blit failed");
        }
        // FPGA frame_store: SPI ioctl is ~100–150ms/frame — push every 4th unique
        // when dual present (keep fb0 smooth); every frame if PRESENT=fpga only.
        if (fpga_.ok() && outW_ == 320 && outH_ == 240) {
            const bool every = (presentMode_ == "fpga");
            if (every || (frameIndex % 4) == 0) {
                if (!fpga_.sendRgb24Frame(frame.data(), outW_, outH_, /*F1*/ 1)) {
                    if ((frameIndex % 30) == 0)
                        log("media: fpga frame_tx: " + fpga_.lastError());
                } else if ((frameIndex % 30) == 0) {
                    log("media: fpga frame_tx ok frames=" + std::to_string(frameIndex));
                }
            }
        }
        ++frameIndex;

        auto now = std::chrono::steady_clock::now();
        if (now - lastLog > std::chrono::seconds(1)) {
            lastLog = now;
            log("media: frames=" + std::to_string(frameIndex) +
                " bytes=" + std::to_string(totalBytes) +
                " audio=" + (audioActive_.load() ? "on" : "off") +
                " decode=" + std::to_string(outW_) + "x" + std::to_string(outH_));
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
    if (audioThr_.joinable())
        audioThr_.join();

    playing_.store(false);
    if (!stop_.load() && onProgress_)
        onProgress_("stopped", 0, durationMs);
    log("media: session end frames=" + std::to_string(frameIndex));
}

} // namespace misterplex
