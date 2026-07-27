#include "media_player.hpp"

#include "libmisterplex/av_clock.hpp"
#include "libmisterplex/idle_screen.hpp"
#include "libmisterplex/osd_menu.hpp"
#include "libmisterplex/h264_recon.hpp"
#include "libmisterplex/pixel_format.hpp"

#include <algorithm>
#include <cctype>
#include <cerrno>
#include <cstdio>
#include <cstring>
#include <chrono>
#include <exception>
#include <signal.h>
#include <time.h>
#include <vector>

#include <fcntl.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <unistd.h>

namespace misterplex {
namespace {

// PMS universal already bakes offset= (seconds). Applying FFmpeg -ss again double-seeks
// and breaks resume / mid-play scrub on STREAM=0 cast. Timeline still uses startMs.
inline bool isUniversalTranscodeUrl(const std::string& url) {
    return url.find("transcode/universal") != std::string::npos ||
           url.find("/video/:/transcode/") != std::string::npos;
}

inline bool urlHasUniversalOffset(const std::string& url) {
    if (!isUniversalTranscodeUrl(url))
        return false;
    // offset=N in query (N may be 0; still "baked" path when present after ?)
    auto q = url.find('?');
    if (q == std::string::npos)
        return false;
    const std::string qs = url.substr(q + 1);
    return qs.find("offset=") != std::string::npos;
}

inline std::string withUniversalOffset(const std::string& url, int64_t offsetMs) {
    if (!isUniversalTranscodeUrl(url))
        return url;
    const int64_t offSec = offsetMs <= 0 ? 0 : (offsetMs + 500) / 1000;
    const std::string value = "offset=" + std::to_string(offSec);
    const auto q = url.find('?');
    const auto hash = url.find('#');
    const auto end = (hash == std::string::npos) ? url.size() : hash;
    if (q == std::string::npos || q > end) {
        return url.substr(0, end) + "?" + value +
               (hash == std::string::npos ? std::string() : url.substr(hash));
    }
    auto pos = q + 1;
    while ((pos = url.find("offset=", pos)) != std::string::npos && pos < end) {
        const bool atKey = pos == q + 1 || url[pos - 1] == '&';
        if (atKey) {
            auto valEnd = url.find('&', pos);
            if (valEnd == std::string::npos || valEnd > end)
                valEnd = end;
            return url.substr(0, pos) + value + url.substr(valEnd);
        }
        pos += 7;
    }
    return url.substr(0, end) + "&" + value +
           (hash == std::string::npos ? std::string() : url.substr(hash));
}

// Annex-B start-code length at `i`, or 0 if none.
inline size_t annexBStartLen(const uint8_t* p, size_t n, size_t i) {
    if (i + 3 < n && p[i] == 0 && p[i + 1] == 0 && p[i + 2] == 0 && p[i + 3] == 1)
        return 4;
    if (i + 2 < n && p[i] == 0 && p[i + 1] == 0 && p[i + 2] == 1)
        return 3;
    return 0;
}

// Nearest-neighbor scale RGB565 → fixed frame_store size (default 320×240).
inline void scaleRgb565(const uint16_t* src, int sw, int sh, uint16_t* dst, int dw, int dh) {
    if (sw == dw && sh == dh) {
        std::memcpy(dst, src, static_cast<size_t>(dw) * static_cast<size_t>(dh) * sizeof(uint16_t));
        return;
    }
    for (int y = 0; y < dh; ++y) {
        const int sy = (sh > 0) ? (y * sh) / dh : 0;
        for (int x = 0; x < dw; ++x) {
            const int sx = (sw > 0) ? (x * sw) / dw : 0;
            dst[y * dw + x] = src[sy * sw + sx];
        }
    }
}

// RGB565 host words → packed RGB24 for fb0 blit.
inline void rgb565ToRgb24(const uint16_t* src, int w, int h, std::vector<uint8_t>& out) {
    out.resize(static_cast<size_t>(w) * static_cast<size_t>(h) * 3);
    for (int i = 0; i < w * h; ++i) {
        uint8_t r = 0, g = 0, b = 0;
        pixel::expandRgb565(src[i], r, g, b);
        out[static_cast<size_t>(i) * 3 + 0] = r;
        out[static_cast<size_t>(i) * 3 + 1] = g;
        out[static_cast<size_t>(i) * 3 + 2] = b;
    }
}

// Local annex-B elementary H.264 (skip remux BSF when possible).
inline bool looksElementaryH264(const std::string& url) {
    if (url.empty() || url.rfind("http", 0) == 0 || url.rfind("lavfi", 0) == 0)
        return false;
    auto lower = url;
    for (char& c : lower)
        c = static_cast<char>(std::tolower(static_cast<unsigned char>(c)));
    auto q = lower.find('?');
    if (q != std::string::npos)
        lower = lower.substr(0, q);
    return lower.size() >= 5 &&
           (lower.compare(lower.size() - 5, 5, ".h264") == 0 ||
            lower.compare(lower.size() - 4, 4, ".264") == 0 ||
            lower.compare(lower.size() - 4, 4, ".avc") == 0);
}

inline bool confTruthyMode(const std::string& v) {
    return v == "1" || v == "true" || v == "yes" || v == "on";
}

inline int64_t steadyMs() {
    return std::chrono::duration_cast<std::chrono::milliseconds>(
               std::chrono::steady_clock::now().time_since_epoch())
        .count();
}

enum class RawVideoFormat {
    Rgb24,
    Rgb565Le,
    Bgra32,
    Yuv420p,
};

inline const char* ffmpegPixFmt(RawVideoFormat f) {
    switch (f) {
    case RawVideoFormat::Rgb565Le:
        return "rgb565le";
    case RawVideoFormat::Bgra32:
        return "bgra";
    case RawVideoFormat::Yuv420p:
        return "yuv420p";
    case RawVideoFormat::Rgb24:
    default:
        return "rgb24";
    }
}

inline size_t rawVideoFrameBytes(RawVideoFormat f, int width, int height) {
    const size_t pixels = static_cast<size_t>(width) * static_cast<size_t>(height);
    switch (f) {
    case RawVideoFormat::Rgb565Le:
        return pixels * 2;
    case RawVideoFormat::Bgra32:
        return pixels * 4;
    case RawVideoFormat::Yuv420p:
        return yuv420pFrameBytes(width, height);
    case RawVideoFormat::Rgb24:
    default:
        return pixels * 3;
    }
}

inline size_t rawVideoPackedBytesPerPixel(RawVideoFormat f) {
    switch (f) {
    case RawVideoFormat::Rgb565Le:
        return 2;
    case RawVideoFormat::Bgra32:
        return 4;
    case RawVideoFormat::Rgb24:
        return 3;
    case RawVideoFormat::Yuv420p:
    default:
        return 0;
    }
}

inline void clearYuv420pCropPadding(uint8_t* yuv, const DdrFrameGeometry& g) {
    if (!yuv || (g.crop_left == 0 && g.crop_right == 0 && g.crop_top == 0 && g.crop_bottom == 0))
        return;
    const int w = g.coded_width;
    const int h = g.coded_height;
    if (w <= 0 || h <= 0 || (w & 1) || (h & 1))
        return;

    auto clearPlane = [](uint8_t* plane, int stride, int width, int height, int cropLeft,
                         int cropRight, int cropTop, int cropBottom, uint8_t value) {
        const int topRows = std::max(0, std::min(cropTop, height));
        const int bottomRows = std::max(0, std::min(cropBottom, height - topRows));
        for (int y = 0; y < topRows; ++y)
            std::memset(plane + static_cast<size_t>(y) * stride, value, width);
        for (int y = height - bottomRows; y < height; ++y)
            std::memset(plane + static_cast<size_t>(y) * stride, value, width);
        const int first = topRows;
        const int last = height - bottomRows;
        const int left = std::max(0, std::min(cropLeft, width));
        const int right = std::max(0, std::min(cropRight, width - left));
        for (int y = first; y < last; ++y) {
            uint8_t* row = plane + static_cast<size_t>(y) * stride;
            if (left)
                std::memset(row, value, left);
            if (right)
                std::memset(row + width - right, value, right);
        }
    };

    const int yBytes = w * h;
    const int cW = w / 2;
    const int cH = h / 2;
    clearPlane(yuv, w, w, h, g.crop_left, g.crop_right, g.crop_top, g.crop_bottom,
               kYuv420BlackY);
    clearPlane(yuv + yBytes, cW, cW, cH, g.crop_left / 2, g.crop_right / 2, g.crop_top / 2,
               g.crop_bottom / 2, kYuv420BlackU);
    clearPlane(yuv + yBytes + cW * cH, cW, cW, cH, g.crop_left / 2, g.crop_right / 2,
               g.crop_top / 2, g.crop_bottom / 2, kYuv420BlackV);
}

inline int64_t microsBetween(std::chrono::steady_clock::time_point a,
                             std::chrono::steady_clock::time_point b) {
    return std::chrono::duration_cast<std::chrono::microseconds>(b - a).count();
}

inline int64_t threadCpuMicros() {
    timespec ts{};
    if (clock_gettime(CLOCK_THREAD_CPUTIME_ID, &ts) != 0)
        return 0;
    return static_cast<int64_t>(ts.tv_sec) * 1000000 + static_cast<int64_t>(ts.tv_nsec) / 1000;
}

} // namespace

void MediaPlayer::log(const std::string& s) const {
    if (log_)
        log_(s);
    else
        std::fprintf(stderr, "%s\n", s.c_str());
}

void MediaPlayer::setContentFpsRational(int num, int den) {
    if (num <= 0 || den <= 0) {
        fpsNum_ = 0;
        fpsDen_ = 0;
        return;
    }
    // Sanity clamp: 1..240 fps. Keeps a bogus PMS value from wedging the schedule.
    const double v = static_cast<double>(num) / static_cast<double>(den);
    if (v < 1.0 || v > 240.0) {
        fpsNum_ = 0;
        fpsDen_ = 0;
        return;
    }
    fpsNum_ = num;
    fpsDen_ = den;
}

std::string MediaPlayer::hex16(uint16_t v) {
    static const char* d = "0123456789abcdef";
    std::string out(4, '0');
    for (int i = 3; i >= 0; --i) {
        out[static_cast<size_t>(i)] = d[v & 0xF];
        v >>= 4;
    }
    return out;
}

void MediaPlayer::startOsdPoll() {
    std::lock_guard<std::mutex> lk(osdMu_);
    if (shuttingDown_.load() || !osdControl_ || osdRun_.exchange(true))
        return;
    if (osdThr_.joinable())
        osdThr_.join();
    osdThr_ = std::thread([this] {
        bool mailboxLogged = false;
        while (osdRun_.load()) {
            uint16_t word = 0;
            bool got = false;
            bool viaMailbox = false;
            {
                std::lock_guard<std::mutex> lk(presentMu_);
                // Preferred path: the core publishes the OSD word into HPS DDR,
                // so reading it is a plain memory load that Main never sees.
                if (fpga_.readOsdMailbox(word)) {
                    got = true;
                    viaMailbox = true;
                } else if (fpga_.ok()) {
                    // Pre-mailbox RBF: fall back to UIO_GET_STATUS over SPI.
                    // status[15:0] is the only slice the core echoes back;
                    // everything above it is telemetry that Main overwrites.
                    uint8_t raw[16]{};
                    if (fpga_.getCoreStatus(raw)) {
                        word = static_cast<uint16_t>(raw[0] | (raw[1] << 8));
                        got = true;
                    }
                }
            }
            if (got && viaMailbox && !mailboxLogged) {
                mailboxLogged = true;
                log("media: OSD via DDR mailbox (no SPI)");
            }
            if (got) {
                const uint16_t prev = lastOsd_.load();
                if (!osdSeen_.exchange(true) || osdChanged(prev, word)) {
                    lastOsd_.store(word);
                    applyOsd(word);
                }
            }
            // The mailbox is free to poll. The SPI fallback is not: it has to
            // park Main for the critical section, so keep that path slow.
            const int quietMs = viaMailbox ? 100 : (playing_.load() ? 250 : 1000);
            for (int slept = 0; slept < quietMs && osdRun_.load(); slept += 50)
                std::this_thread::sleep_for(std::chrono::milliseconds(50));
        }
    });
}

void MediaPlayer::stopOsdPoll() {
    std::lock_guard<std::mutex> lk(osdMu_);
    osdRun_.store(false);
    if (osdThr_.joinable())
        osdThr_.join();
}

void MediaPlayer::setSkipDeltasMs(int64_t forwardMs, int64_t backMs) {
    if (forwardMs < 0)
        forwardMs = 0;
    if (backMs < 0)
        backMs = 0;
    skipForwardMs_ = forwardMs;
    skipBackMs_ = backMs;
}

void MediaPlayer::startInputPoll() {
    std::lock_guard<std::mutex> lk(inputMu_);
    if (shuttingDown_.load() || inputRun_.exchange(true))
        return;
    if (inputThr_.joinable())
        inputThr_.join();
    inputThr_ = std::thread([this] {
        bool logged = false;
        while (inputRun_.load()) {
            PlaybackCommand command = PlaybackCommand::None;
            bool got = false;
            {
                std::lock_guard<std::mutex> lk(presentMu_);
                got = fpga_.readInputMailbox(command);
            }
            if (got) {
                if (!logged) {
                    logged = true;
                    log("media: playback input via DDR mailbox (no SPI)");
                }
                dispatchPlaybackInput(command);
            }
            for (int slept = 0; slept < 50 && inputRun_.load(); slept += 10)
                std::this_thread::sleep_for(std::chrono::milliseconds(10));
        }
    });
}

void MediaPlayer::stopInputPoll() {
    std::lock_guard<std::mutex> lk(inputMu_);
    inputRun_.store(false);
    if (inputThr_.joinable())
        inputThr_.join();
}

void MediaPlayer::dispatchPlaybackInput(PlaybackCommand command) {
    const PlaybackTransportState state{playing_.load(), paused_.load(), positionMs_.load(),
                                       durationMs()};
    (void)dispatchPlaybackCommand(command, state, skipForwardMs_, skipBackMs_, steadyMs(),
                                  ignoreInputUntilMs_.load(), *this);
}

void MediaPlayer::applyOsd(uint16_t word) {
    ignoreInputUntilMs_.store(steadyMs() + 300);
    const OsdSettings s = decodeOsdWord(word);
    setAvOffsetMs(s.avOffsetMs);
    // Takes effect on the next session: the feed rate is captured when audioPump
    // opens MrAudio, and re-timing it mid-stream would step the audio clock.
    setAudioClockTrimEnabled(s.audioClockTrimEnabled);
    setResyncDropMs(s.resyncEnabled ? kDefaultResyncDropMs : 0);
    const IdleMode im = idleModeFromBits(static_cast<unsigned>(s.idleMode));
    const bool idleChanged = im != idleMode();
    setIdleMode(im);
    if (idleChanged)
        idleLogged_.store(false);
    if (idleChanged && !playing_.load())
        paintIdle();
    log("media: OSD word=0x" + hex16(word) + " av_offset_ms=" + std::to_string(s.avOffsetMs) +
        " clock_ppm=" + std::to_string(audioClockPpm_) +
        " resync=" + (s.resyncEnabled ? "on" : "off") +
        " idle=" + std::to_string(s.idleMode));
}

void MediaPlayer::paintIdle() {
    const IdleMode m = idleMode();
    if (m == IdleMode::LastFrame)
        return;
    const int w = 320;
    const int h = 240;
    std::vector<uint8_t> buf(static_cast<size_t>(w) * h * 3);
    renderIdleRgb24(buf.data(), w, h, m, idlePhase_.load());

    std::lock_guard<std::mutex> lk(presentMu_);
    if (fb_.ok())
        fb_.blitRgb24(buf.data(), w, h);
    // F1 latches the last frame written, so the frame store must be repainted too.
    // C3 frame-store DDR is YUV-only; use a deterministic black I420 frame for
    // the FPGA idle clear rather than ringing the doorbell with an RGB payload.
    if (fpga_.ok()) {
        bool ok = false;
        if (useDdrF1_) {
            const DdrFrameGeometry g = plex480pDdrFrameGeometry();
            std::vector<uint8_t> yuv(makeDdrFrameLayout(g, kDdrFramePhysBase,
                                                        kDdrFrameStrideAlign,
                                                        DdrFrameFormat::Yuv420p)
                                         .frame_bytes);
            const size_t yBytes = static_cast<size_t>(g.coded_width) * g.coded_height;
            const size_t cBytes = yBytes / 4u;
            std::memset(yuv.data(), kYuv420BlackY, yBytes);
            std::memset(yuv.data() + yBytes, kYuv420BlackU, cBytes);
            std::memset(yuv.data() + yBytes + cBytes, kYuv420BlackV, cBytes);
            ok = fpga_.sendYuv420pFrameDdr(yuv.data(), yuv.size(), g, ddrBank_);
            ddrBank_ ^= 1;
        }
        if (!ok)
            ok = fpga_.sendRgb24Frame(buf.data(), w, h, /*F1*/ 1);
        if (!ok) {
            if (!idleWarned_.exchange(true))
                log("media: idle paint failed (will retry): " + fpga_.lastError());
        } else {
            // Arm the warning again so a later failure is not swallowed — the core
            // is briefly out of user mode right after a heal/reload and the first
            // paint legitimately fails.
            idleWarned_.store(false);
            if (!idleLogged_.exchange(true))
                log("media: idle screen painted (mode=" + std::to_string(static_cast<int>(m)) + ")");
        }
    }
}

// startIdle() is called from the play thread at session end while stopIdle() is
// called from the companion thread at the next play(); without this mutex the two
// can move-assign and join the same std::thread object and std::terminate.
void MediaPlayer::startIdle() {
    std::lock_guard<std::mutex> lk(idleMu_);
    if (shuttingDown_.load() || idleRun_.exchange(true))
        return;
    if (idleThr_.joinable())
        idleThr_.join();
    idleThr_ = std::thread([this] {
        while (idleRun_.load()) {
            if (playing_.load() || idleMode() == IdleMode::LastFrame) {
                std::this_thread::sleep_for(std::chrono::milliseconds(200));
                continue;
            }
            paintIdle();
            const bool moving = idleMode() == IdleMode::Screensaver;
            if (moving)
                idlePhase_.fetch_add(1);
            // A static idle screen is already latched in the frame store, so
            // repainting it buys nothing except another SIGSTOP of Main every
            // couple of seconds — forever, with no heal to follow. applyOsd()
            // and the session-end path repaint on the transitions that matter;
            // this slow sweep is only a safety net for a core reload underneath
            // us. The screensaver still moves at ~10 fps because the user asked
            // for motion.
            const int stepMs = moving ? 100 : 30000;
            for (int slept = 0; slept < stepMs && idleRun_.load(); slept += 50)
                std::this_thread::sleep_for(std::chrono::milliseconds(50));
        }
    });
}

void MediaPlayer::stopIdle() {
    std::lock_guard<std::mutex> lk(idleMu_);
    idleRun_.store(false);
    if (idleThr_.joinable())
        idleThr_.join();
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

bool MediaPlayer::wantSkipRgbVideo() const {
    if (!streamEnabled_)
        return false;
    // Continuous fb0 needs RGB; skip only frees dual-A9 when FPGA alone owns present.
    if (presentMode_ == "both" || presentMode_ == "fb0" || presentMode_.empty())
        return false;
    // presentMode_ == "fpga": auto/on skip RGB from start (host recon owns F1).
    if (streamSkipRgb_ == "0" || streamSkipRgb_ == "off" || streamSkipRgb_ == "false" ||
        streamSkipRgb_ == "no")
        return false;
    // auto | on | 1 | true | yes | empty(default auto)
    return streamSkipRgb_ == "auto" || confTruthyMode(streamSkipRgb_) || streamSkipRgb_.empty();
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
            useDdrF1_ = true; // try DDR bulk first; falls back to SPI on first fail
            ddrBank_ = 0;
            log("media: FPGA frame path OK (PRESENT=fpga → DDR bulk 3.1b, SPI F1 fallback)");
            // Legacy (pre-v3) core only: park the debug bits so a stale saved OSD
            // cannot steal cast frames. On a v3 core those same bits ARE the A/V
            // offset menu item, so zeroing them would silently reset the user's
            // setting on every startup.
            if (!osdControl_) {
                const int park[] = {6, 0, 7, 0, 8, 0, 9, 0};
                if (!fpga_.setStatusBits(park, 4))
                    log("media: park OSD (None/tone-off): " + fpga_.lastError());
                else
                    log("media: park OSD — Pattern=None, audio tone Off, force bars No");
            }
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
    // Pause/resume both RGB/audio FFmpeg and STREAM demux process groups.
    pid_t p = childPid_.load();
    if (p > 0)
        kill(-p, sig);
    pid_t sp = streamPid_.load();
    if (sp > 0)
        kill(-sp, sig);
}

void MediaPlayer::killChildren() {
    signalChildren(SIGTERM);
    for (int i = 0; i < 20; ++i) {
        pid_t p = childPid_.load();
        pid_t sp = streamPid_.load();
        if (p <= 0 && sp <= 0)
            break;
        int st = 0;
        if (p > 0 && waitpid(p, &st, WNOHANG) == p)
            childPid_.store(-1);
        if (sp > 0 && waitpid(sp, &st, WNOHANG) == sp)
            streamPid_.store(-1);
        std::this_thread::sleep_for(std::chrono::milliseconds(25));
    }
    signalChildren(SIGKILL);
    pid_t p = childPid_.exchange(-1);
    if (p > 0) {
        int st = 0;
        waitpid(p, &st, 0);
    }
    pid_t sp = streamPid_.exchange(-1);
    if (sp > 0) {
        int st = 0;
        waitpid(sp, &st, 0);
    }
    audioActive_.store(false);
    streamActive_.store(false);
}

void MediaPlayer::shutdown() {
    // Order matters: retire the play thread FIRST. threadMain calls startIdle()
    // at session end, so stopping the idle painter before joining thr_ leaves a
    // window where a brand new idle thread is spawned after we joined the old
    // one — it is then still joinable in ~MediaPlayer and aborts the process.
    shuttingDown_.store(true);
    {
        std::lock_guard<std::mutex> life(lifeMu_);
        stop_.store(true);
        killChildren();
        if (thr_.joinable())
            thr_.join();
        // threadMain normally joins these at session end, but it may never have
        // run (or may have been torn down mid-session), so sweep them here too.
        if (audioThr_.joinable())
            audioThr_.join();
        if (streamThr_.joinable())
            streamThr_.join();
        playing_.store(false);
        paused_.store(false);
    }
    stopInputPoll();
    stopOsdPoll();
    stopIdle();
}

void MediaPlayer::stop() {
    // Only join thr_ here. threadMain owns audioThr_/streamThr_ joins at session end.
    // Joining helpers from both thr_ and stop() races and can hang the companion HTTP thread.
    std::lock_guard<std::mutex> life(lifeMu_);
    stop_.store(true);
    killChildren();
    if (thr_.joinable())
        thr_.join();
    const int64_t finalPos = positionMs_.load();
    int64_t finalDur = 0;
    {
        std::lock_guard<std::mutex> lock(mu_);
        finalDur = durationMs_;
    }
    playing_.store(false);
    paused_.store(false);
    if (onProgress_)
        onProgress_("stopped", finalPos, finalDur);
    {
        // Drop session URL so post-stop seekMs cannot restart without a new playMedia.
        std::lock_guard<std::mutex> lock(mu_);
        currentUrl_.clear();
        currentHeaders_.clear();
        durationMs_ = 0;
    }
    seekReqMs_.store(-1);
    positionMs_.store(0);
    showPlaybackOverlay(PlaybackOverlayState::Stopped, 0, 0);
    // Retire the background FPGA users BEFORE tearing the SPI/mmap state down.
    // stop() closes FpgaSpi and reloads the core; an OSD poll or idle paint in
    // flight would then ioctl through an unmapped handle and take the daemon down.
    stopOsdPoll();
    stopIdle();
    if (fb_.ok())
        fb_.clear();
    // Nothing to heal: SPI transactions hand GPO back to Main exactly as they
    // found it, and the frame path never touches SPI at all, so Main is still
    // servicing F12/OSD/MiSTer_cmd. Do NOT unlink /tmp/misterplex_spi.lock here —
    // recreating that inode would put concurrent tools on a different lock.
    paintIdle();
    startIdle();
    startOsdPoll();
}

void MediaPlayer::pause() {
    paused_.store(true);
    signalChildren(SIGSTOP);
    showPlaybackOverlay(PlaybackOverlayState::Paused, positionMs_.load(), durationMs());
    if (onProgress_)
        onProgress_("paused", positionMs_.load(), durationMs_);
}

void MediaPlayer::resume() {
    paused_.store(false);
    signalChildren(SIGCONT);
    showPlaybackOverlay(PlaybackOverlayState::Playing, positionMs_.load(), durationMs());
    if (onProgress_)
        onProgress_("playing", positionMs_.load(), durationMs_);
}

void MediaPlayer::showPlaybackOverlay(PlaybackOverlayState state, int64_t positionMs,
                                      int64_t durationMs) {
    overlay_.show(state, positionMs, durationMs);
}

void MediaPlayer::flashPlaybackSkip(int64_t deltaMs) {
    overlay_.flashSkip(deltaMs, positionMs_.load(), durationMs());
}

void MediaPlayer::seekMs(int64_t ms) {
    if (ms < 0)
        ms = 0;
    const int64_t fromMs = positionMs_.load();
    std::string url, headers;
    int64_t dur = 0;
    {
        std::lock_guard<std::mutex> lock(mu_);
        url = currentUrl_;
        headers = currentHeaders_;
        dur = durationMs_;
    }
    // Clamp into known duration so scrubber/step edges cannot overshoot EOF.
    if (dur > 0 && ms > dur)
        ms = dur;
    if (url.empty()) {
        // No active session — drop seek (do not leave a phantom seekReq for next play).
        return;
    }
    flashPlaybackSkip(ms - fromMs);
    // Same scrubber position while session is live: skip demux restart thrash
    // (companion already ACK-only gates; belt-and-suspenders for step/skip paths).
    if (playing_.load() && !stop_.load() && positionMs_.load() == ms) {
        log("media: seek same-pos " + std::to_string(ms) + " (no-op)");
        return;
    }
    if (onProgress_)
        onProgress_("buffering", ms, dur);
    // Full restart: both RGB/audio and STREAM demux re-spawn at new offset (multi-IDR clean).
    play(withUniversalOffset(url, ms), ms, headers, dur);
}

bool MediaPlayer::play(const std::string& urlOrPath, int64_t startOffsetMs,
                       const std::string& httpHeaders, int64_t durationMs) {
    // Idle painter owns fb0/F1 between sessions — retire it before we present.
    stopIdle();
    {
        std::lock_guard<std::mutex> life(lifeMu_);
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
        reconFrames_.store(0);
        reconPresentOk_.store(false);
        cabacSkip_.store(false);
        // Mark playing before thr_ starts so callers (e.g. lab --play-file) that
        // poll playing() cannot race stop() before threadMain runs and wipe the
        // session at frames=0 / audio_s=0.
        playing_.store(true);
        showPlaybackOverlay(PlaybackOverlayState::Playing, startOffsetMs, durationMs);
        thr_ = std::thread([this, urlOrPath, startOffsetMs, httpHeaders, durationMs] {
            try {
                threadMain(urlOrPath, startOffsetMs, httpHeaders, durationMs);
            } catch (const std::exception& ex) {
                log(std::string("media: threadMain exception: ") + ex.what());
                playing_.store(false);
            } catch (...) {
                log("media: threadMain unknown exception");
                playing_.store(false);
            }
        });
    }
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
        // Audio → fd 3 (pipe:3) when enabled. Keep write end open across the
        // mass close below (fd 3 must survive).
        if (aWriteFd >= 0) {
            if (aWriteFd != 3) {
                dup2(aWriteFd, 3);
                if (aWriteFd != STDOUT_FILENO && aWriteFd != 3)
                    ::close(aWriteFd);
            }
        }
        if (vWriteFd >= 0 && vWriteFd != STDOUT_FILENO && vWriteFd != 3)
            ::close(vWriteFd);

        // Lab: capture FFmpeg errors on USB (tmpfs /tmp is tiny). Product: /dev/null.
        int errfd = ::open("/media/usb0/misterplex-lab/logs/ffmpeg.err",
                           O_WRONLY | O_CREAT | O_TRUNC, 0644);
        if (errfd < 0)
            errfd = ::open("/dev/null", O_WRONLY);
        if (errfd >= 0) {
            dup2(errfd, STDERR_FILENO);
            if (errfd != STDERR_FILENO && errfd != 3 && errfd != STDOUT_FILENO)
                ::close(errfd);
        }
        // Close inherited fds but KEEP 0,1,2,3 (stdin/out/err + audio pipe:3).
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

pid_t MediaPlayer::spawnStreamDemux(const std::string& url, const std::string& headers,
                                    int64_t startMs, int writeFd) {
    // Lightweight copy-demux: annex-B elementary for host recon + F3 (no re-encode).
    // Prefer direct elementary when already annex-B (.264); otherwise remux via BSF.
    const bool elementary = looksElementaryH264(url);
    std::vector<std::string> args;
    args.push_back(ffmpeg_);
    args.push_back("-hide_banner");
    args.push_back("-loglevel");
    args.push_back("error");
    args.push_back("-nostdin");
    // Skip -ss when PMS universal already baked offset= (seconds) into the URL.
    if (startMs > 0 && !urlHasUniversalOffset(url)) {
        char ss[32];
        std::snprintf(ss, sizeof(ss), "%.3f", startMs / 1000.0);
        args.push_back("-ss");
        args.push_back(ss);
    }
    if (!headers.empty()) {
        std::string h = headers;
        if (h.size() < 2 || h[h.size() - 1] != '\n')
            h += "\r\n";
        args.push_back("-headers");
        args.push_back(h);
        args.push_back("-reconnect");
        args.push_back("1");
        args.push_back("-reconnect_streamed");
        args.push_back("1");
    }
    if (elementary) {
        // Raw annex-B: declare format so FFmpeg does not probe as MP4.
        args.push_back("-f");
        args.push_back("h264");
    }
    args.push_back("-i");
    args.push_back(url);
    args.push_back("-map");
    args.push_back("0:v:0");
    args.push_back("-an");
    args.push_back("-c:v");
    args.push_back("copy");
    if (!elementary) {
        args.push_back("-bsf:v");
        args.push_back("h264_mp4toannexb");
    }
    args.push_back("-f");
    args.push_back("h264");
    args.push_back("pipe:1");
    return spawnFfmpeg(args, writeFd, -1);
}

pid_t MediaPlayer::spawnAudioOnly(const std::string& url, const std::string& headers, int64_t startMs,
                                  int aWriteFd) {
    // Audio-only FFmpeg — frees dual-A9 when host recon owns F1 (no RGB scale/decode).
    std::vector<std::string> args;
    args.push_back(ffmpeg_);
    args.push_back("-hide_banner");
    args.push_back("-loglevel");
    args.push_back("error");
    args.push_back("-nostdin");
    if (startMs > 0 && !urlHasUniversalOffset(url)) {
        char ss[32];
        std::snprintf(ss, sizeof(ss), "%.3f", startMs / 1000.0);
        args.push_back("-ss");
        args.push_back(ss);
    }
    if (!headers.empty()) {
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
    args.push_back("-vn");
    args.push_back("-map");
    args.push_back("0:a:0?");
    args.push_back("-af");
    if (audioDelayMs_ > 0)
        args.push_back("aresample=48000,adelay=" + std::to_string(audioDelayMs_) + ":all=1");
    else
        args.push_back("aresample=48000");
    args.push_back("-f");
    args.push_back("s16le");
    args.push_back("-ac");
    args.push_back("2");
    args.push_back("-ar");
    args.push_back("48000");
    args.push_back("pipe:3");
    return spawnFfmpeg(args, /*vWriteFd*/ -1, aWriteFd);
}

void MediaPlayer::streamPump(int sfd) {
    // Phase 3.3i/product: demux annex-B → host I-slice recon → YUV420 F1 (+ optional fb0).
    // Also feed the FPGA decoder through the continuous HPS-DDR bitstream ring.
    // Robust multi-IDR: retain last SPS/PPS, recon every I/IDR, sticky CABAC skip.
    const bool wantF3 = fpga_.ok();
    const bool wantF1 = fpga_.ok() && (presentMode_ == "fpga" || presentMode_ == "both");
    // PRESENT=both: FFmpeg owns continuous fb0; recon owns F1 only.
    // PRESENT=fb0 + STREAM: recon I-frames may blit fb0 (sparse keyframe present).
    const bool reconToFb =
        fb_.ok() && (presentMode_ == "fb0" || presentMode_.empty());

    if (wantF3)
        fpga_.flushBitstreamDdr();
    streamActive_.store(true);
    reconFrames_.store(0);
    reconPresentOk_.store(false);
    // cabacSkip_ is session-level (cleared in play()); do not clear here on mid-session re-entry.
    log(std::string("media: STREAM=1 host I-slice recon") +
        (wantF1 ? " →F1" : "") + (wantF3 ? " +DDR-bitstream" : "") +
        (reconToFb ? " +fb0" : ""));

    constexpr size_t kF3Chunk = 8192;
    // Bound NAL scan buffer (SPS+PPS+IDR can be large at 720p; cap for dual-A9)
    constexpr size_t kMaxAcc = 2 * 1024 * 1024;
    std::vector<uint8_t> acc;
    acc.reserve(64 * 1024);
    // Unsent F3 tail offset into acc (bytes [f3Off, acc.size()) not yet pushed)
    size_t f3Off = 0;
    // Last complete NAL start (start-code index) still in acc; incomplete NAL retained
    size_t parseFrom = 0;

    std::vector<uint8_t> spsNal; // includes start code
    std::vector<uint8_t> ppsNal;
    std::vector<uint8_t> yuv420p;
    char buf[4096];
    size_t f3Total = 0;
    size_t f3Pushes = 0;
    size_t reconOk = 0;
    size_t reconFail = 0;
    size_t idrSeen = 0;
    size_t iSliceSeen = 0;
    bool cabacLogged = cabacSkip_.load();
    // Throttle sparse host recon F1 publishing; product rawvideo owns continuous playback.
    constexpr size_t kReconPresentEvery = 1;
    bool reconDdrMismatchLogged = false;

    auto pushF3UpTo = [&](size_t end) {
        if (!wantF3 || end <= f3Off)
            return;
        while (f3Off + kF3Chunk <= end && !stop_.load()) {
            if (fpga_.sendBitstreamChunkDdr(acc.data() + f3Off, kF3Chunk)) {
                f3Total += kF3Chunk;
                ++f3Pushes;
                if ((f3Pushes % 64) == 0)
                    log("media: DDR bitstream bytes=" + std::to_string(f3Total));
            } else if ((f3Pushes % 16) == 0) {
                log("media: DDR bitstream backpressure: " + fpga_.lastError());
                break;
            }
            f3Off += kF3Chunk;
        }
    };

    auto presentRecon = [&](const recon::ReconResult& rec) {
        if (rec.y.empty() || rec.u.empty() || rec.v.empty() || rec.width <= 0 ||
            rec.height <= 0 || (rec.width & 1) || (rec.height & 1))
            return false;
        const size_t yBytes = static_cast<size_t>(rec.width) * static_cast<size_t>(rec.height);
        const size_t cBytes = yBytes / 4u;
        if (rec.y.size() < yBytes || rec.u.size() < cBytes || rec.v.size() < cBytes)
            return false;
        auto ensureYuv420p = [&]() -> const uint8_t* {
            if (yuv420p.empty()) {
                yuv420p.resize(yBytes + 2u * cBytes);
                std::memcpy(yuv420p.data(), rec.y.data(), yBytes);
                std::memcpy(yuv420p.data() + yBytes, rec.u.data(), cBytes);
                std::memcpy(yuv420p.data() + yBytes + cBytes, rec.v.data(), cBytes);
            }
            return yuv420p.data();
        };
        yuv420p.clear();
        bool any = false;
        if (wantF1) {
            // C3 frame-store RTL is YUV-only. Never send RGB565 to the DDR doorbell.
            bool ok = false;
            if (useDdrF1_) {
                const DdrFrameGeometry g = plex480pDdrFrameGeometry();
                if (rec.width == g.coded_width && rec.height == g.coded_height) {
                    ensureYuv420p();
                    clearYuv420pCropPadding(yuv420p.data(), g);
                    ok = fpga_.sendYuv420pFrameDdr(yuv420p.data(), yuv420p.size(), g, ddrBank_);
                    ddrBank_ ^= 1;
                    if (!ok) {
                        useDdrF1_ = false;
                        log("media: recon YUV420 DDR F1 unavailable: " + fpga_.lastError());
                    } else if ((reconOk % 30) == 0) {
                        log("media: recon F1 via YUV420 DDR " +
                            std::to_string(static_cast<int>(fpga_.lastPushMs())) + "ms");
                    }
                } else if (!reconDdrMismatchLogged) {
                    reconDdrMismatchLogged = true;
                    log("media: recon F1 skipped: YUV DDR frame-store requires coded 624x480, got " +
                        std::to_string(rec.width) + "x" + std::to_string(rec.height));
                }
            }
            if (ok)
                any = true;
        }
        if (reconToFb && fb_.ok()) {
            ensureYuv420p();
            if (fb_.blitYuv420p(yuv420p.data(), rec.width, rec.height))
                any = true;
        }
        if (any) {
            reconPresentOk_.store(true);
            reconFrames_.fetch_add(1);
        }
        return any;
    };

    // Lightweight slice_type probe (first_mb ue + slice_type ue) — skip P/B walks.
    auto isISliceNal = [](const uint8_t* nalSc, size_t nalLen) -> bool {
        size_t sc = annexBStartLen(nalSc, nalLen, 0);
        if (!sc || sc >= nalLen)
            return false;
        const uint8_t ntype = nalSc[sc] & 0x1f;
        if (ntype == 5)
            return true; // IDR is always I
        if (ntype != 1)
            return false;
        const uint8_t* pay = nalSc + sc + 1;
        const size_t plen = nalLen - sc - 1;
        if (plen < 1)
            return false;
        auto rbsp = misterplex::detail::removeEpb(pay, plen);
        misterplex::detail::BitReader br(rbsp.data(), rbsp.size());
        br.ue(); // first_mb_in_slice
        uint32_t st = br.ue(); // slice_type
        if (!br.ok)
            return false;
        // 2 or 7 = I (spec allows slice_type % 5)
        return (st % 5) == 2;
    };

    // PPS entropy_coding_mode_flag drives sticky CABAC. In-band SPS/PPS before every
    // IDR used to clear skip → dual-A9 residual walk failed every keyframe on High.
    // Policy: CABAC PPS sets sticky immediately; CAVLC PPS clears for re-probe; SPS no-op.
    auto applyPpsEntropy = [&](const uint8_t* nalSc, size_t nalLen) {
        size_t sc = annexBStartLen(nalSc, nalLen, 0);
        if (!sc || sc + 1 >= nalLen)
            return;
        const uint8_t* pay = nalSc + sc + 1;
        const size_t plen = nalLen - sc - 1;
        if (plen < 1)
            return;
        auto rbsp = misterplex::detail::removeEpb(pay, plen);
        misterplex::detail::BitReader br(rbsp.data(), rbsp.size());
        br.ue(); // pic_parameter_set_id
        br.ue(); // seq_parameter_set_id
        const bool cabac = br.u(1) != 0;
        if (!br.ok)
            return;
        if (cabac) {
            cabacSkip_.store(true);
            if (!cabacLogged) {
                cabacLogged = true;
                log("media: recon CABAC/High — PPS entropy_coding_mode=1; host CAVLC skip "
                    "(sticky). Stream is High/CABAC; MiSTerPlex.xml profile may be missing "
                    "or inactive on PMS. FFmpeg RGB F1 fallback if enabled.");
            }
        } else {
            // CAVLC PPS: allow I-slice recon (seek/segment may flip profile).
            if (cabacSkip_.load() && cabacLogged) {
                log("media: recon CAVLC PPS — sticky CABAC cleared; host I-slice recon re-enabled");
            }
            cabacSkip_.store(false);
            cabacLogged = false;
        }
    };

    auto tryReconNal = [&](const uint8_t* nalSc, size_t nalLen, uint8_t ntype) {
        if (spsNal.empty() || ppsNal.empty())
            return;
        if (ntype != 5 && ntype != 1)
            return;
        if (!isISliceNal(nalSc, nalLen))
            return;
        ++iSliceSeen;
        if (ntype == 5)
            ++idrSeen;

        // Sticky CABAC: do not burn dual-A9 walking High-profile every keyframe.
        if (cabacSkip_.load()) {
            if (ntype == 5 && (idrSeen % 16) == 1)
                log("media: recon skip CABAC/High (sticky) idr=" + std::to_string(idrSeen) +
                    " — FFmpeg RGB F1 fallback if enabled");
            return;
        }

        std::vector<uint8_t> au;
        au.reserve(spsNal.size() + ppsNal.size() + nalLen);
        au.insert(au.end(), spsNal.begin(), spsNal.end());
        au.insert(au.end(), ppsNal.begin(), ppsNal.end());
        au.insert(au.end(), nalSc, nalSc + nalLen);

        auto rec = recon::reconISlice(au.data(), au.size());
        if (rec.mb_decoded <= 0 || rec.mb_decoded != rec.mb_total || rec.y.empty()) {
            ++reconFail;
            // Backup path: CABAC detected late in recon chain (PPS probe missed).
            if (rec.fail_reason && std::strcmp(rec.fail_reason, "cabac") == 0) {
                cabacSkip_.store(true);
                if (!cabacLogged) {
                    cabacLogged = true;
                    log("media: recon CABAC/High — host CAVLC cannot decode this stream; "
                        "stream is High/CABAC; MiSTerPlex.xml profile may be missing or "
                        "inactive on PMS. FFmpeg RGB F1 fallback (STREAM still feeds F3).");
                }
                return;
            }
            if (ntype == 5 || (reconFail % 8) == 1) {
                log("media: recon fail ntype=" + std::to_string(ntype) +
                    " mb=" + std::to_string(rec.mb_decoded) + "/" +
                    std::to_string(rec.mb_total) +
                    " reason=" + (rec.fail_reason ? rec.fail_reason : "?") +
                    " idr=" + std::to_string(idrSeen));
            }
            return;
        }
        ++reconOk;
        // Present every kReconPresentEvery successful I-slice
        if ((reconOk % kReconPresentEvery) != 0)
            return;
        if (presentRecon(rec)) {
            if (reconOk == 1 || ntype == 5 || (reconOk % 8) == 0) {
                log("media: recon frame ok #" + std::to_string(reconOk) + " " +
                    std::to_string(rec.width) + "x" + std::to_string(rec.height) +
                    " mb=" + std::to_string(rec.mb_decoded) + " idr=" + std::to_string(idrSeen) +
                    " i=" + std::to_string(iSliceSeen) +
                    " f1ms=" + std::to_string(static_cast<int>(fpga_.lastPushMs())));
            }
        }
    };

    auto consumeCompleteNals = [&]() {
        // Parse complete NALs from parseFrom; leave trailing incomplete NAL in acc.
        size_t i = parseFrom;
        // Ensure we start at a start code if possible
        while (i + 3 < acc.size()) {
            size_t sc = annexBStartLen(acc.data(), acc.size(), i);
            if (sc)
                break;
            ++i;
        }
        parseFrom = i;

        while (i + 3 < acc.size() && !stop_.load()) {
            size_t sc = annexBStartLen(acc.data(), acc.size(), i);
            if (!sc) {
                ++i;
                parseFrom = i;
                continue;
            }
            // Find next start code (end of this NAL)
            size_t j = i + sc;
            bool foundNext = false;
            while (j + 2 < acc.size()) {
                size_t nsc = annexBStartLen(acc.data(), acc.size(), j);
                if (nsc) {
                    foundNext = true;
                    break;
                }
                ++j;
            }
            if (!foundNext) {
                // Incomplete NAL — wait for more bytes
                parseFrom = i;
                return;
            }
            // Complete NAL: [i, j)
            const size_t nalLen = j - i;
            if (i + sc < j) {
                const uint8_t ntype = acc[i + sc] & 0x1f;
                if (ntype == 7) {
                    // SPS alone does not change entropy mode — keep sticky CABAC.
                    spsNal.assign(acc.begin() + static_cast<std::ptrdiff_t>(i),
                                  acc.begin() + static_cast<std::ptrdiff_t>(j));
                } else if (ntype == 8) {
                    ppsNal.assign(acc.begin() + static_cast<std::ptrdiff_t>(i),
                                  acc.begin() + static_cast<std::ptrdiff_t>(j));
                    applyPpsEntropy(acc.data() + i, nalLen);
                } else if (ntype == 5 || ntype == 1) {
                    tryReconNal(acc.data() + i, nalLen, ntype);
                }
            }
            i = j;
            parseFrom = i;
        }
    };

    auto compactAcc = [&]() {
        // Drop bytes already pushed to F3 and fully parsed; keep incomplete NAL + unsent F3.
        size_t drop = std::min(f3Off, parseFrom);
        if (drop == 0)
            return;
        // Never drop past incomplete NAL start
        drop = std::min(drop, parseFrom);
        if (drop > 0 && drop <= acc.size()) {
            acc.erase(acc.begin(), acc.begin() + static_cast<std::ptrdiff_t>(drop));
            f3Off -= drop;
            parseFrom -= drop;
        }
        // Hard cap
        if (acc.size() > kMaxAcc) {
            log("media: STREAM acc overflow — reset NAL state");
            acc.clear();
            f3Off = 0;
            parseFrom = 0;
            // Keep last SPS/PPS so multi-IDR can recover after overflow gap
        }
    };

    while (!stop_.load()) {
        if (paused_.load()) {
            std::this_thread::sleep_for(std::chrono::milliseconds(20));
            continue;
        }
        ssize_t n = ::read(sfd, buf, sizeof(buf));
        if (n < 0) {
            if (errno == EINTR)
                continue;
            break;
        }
        if (n == 0)
            break; // demux EOF or killed (seek/stop closes pipe)
        acc.insert(acc.end(), buf, buf + n);
        consumeCompleteNals();
        // Feed F3 up through fully parsed bytes (safe: complete NALs only)
        pushF3UpTo(parseFrom);
        compactAcc();
    }

    // EOF: process trailing NAL that has no following start code (short files / last IDR).
    // Without this, single-AU Baseline vectors never recon (IDR is last NAL).
    if (!stop_.load() && parseFrom + 3 < acc.size()) {
        size_t sc = annexBStartLen(acc.data(), acc.size(), parseFrom);
        if (sc && parseFrom + sc < acc.size()) {
            const size_t nalLen = acc.size() - parseFrom;
            const uint8_t ntype = acc[parseFrom + sc] & 0x1f;
            if (ntype == 7) {
                spsNal.assign(acc.begin() + static_cast<std::ptrdiff_t>(parseFrom),
                              acc.end());
            } else if (ntype == 8) {
                ppsNal.assign(acc.begin() + static_cast<std::ptrdiff_t>(parseFrom),
                              acc.end());
                applyPpsEntropy(acc.data() + parseFrom, nalLen);
            } else if (ntype == 5 || ntype == 1) {
                tryReconNal(acc.data() + parseFrom, nalLen, ntype);
            }
            parseFrom = acc.size();
        }
    }

    // Flush remaining complete NALs and F3 tail (only if not mid-stop)
    if (!stop_.load()) {
        consumeCompleteNals();
        pushF3UpTo(parseFrom);
        if (wantF3 && f3Off < acc.size()) {
            size_t rem = acc.size() - f3Off;
            if (rem && fpga_.sendBitstreamChunkDdr(acc.data() + f3Off, rem))
                f3Total += rem;
        }
    }

    ::close(sfd);
    streamActive_.store(false);
    log("media: STREAM end f3_bytes=" + std::to_string(f3Total) +
        " recon_ok=" + std::to_string(reconOk) + " recon_fail=" + std::to_string(reconFail) +
        " idr=" + std::to_string(idrSeen) + " i_slices=" + std::to_string(iSliceSeen) +
        " cabac=" + (cabacSkip_.load() ? "1" : "0") +
        " present=" + std::to_string(reconFrames_.load()));
}

int64_t MediaPlayer::readMrAudioQueuedBytes() {
    const int fd = ::open(audioDev_.c_str(), O_RDONLY);
    if (fd < 0)
        return -1;
    char buf[128];
    const ssize_t n = ::read(fd, buf, sizeof(buf));
    ::close(fd);
    if (n <= 0)
        return -1;
    return misterplex::parseMrAudioQueuedBytes(buf, n);
}

void MediaPlayer::audioPump(int afd) {
    // Drain PCM to MrAudio. Lab evidence: MrAudio write() does NOT pace realtime
    // (audio_s grew ~3× wall → jumpy audio). Pace ourselves to exact 48 kHz wall
    // clock; that back-pressures FFmpeg and thus video.
    // F2 SPI skipped when MrAudio works (SPI thrash + no heard benefit).
    // AUDIO_DELAY_MS is applied in FFmpeg (adelay) on the product RGB path so A+V
    // stay on one clock. Pump is pure wall-48k MrAudio (no second delay line).
    const bool wantMr = audioEnabled_ && (::access(audioDev_.c_str(), W_OK) == 0);
    bool wantF2 = fpga_.ok() && presentMode_ == "fpga" && !wantMr;

    int out = -1;
    if (wantMr) {
        out = ::open(audioDev_.c_str(), O_WRONLY);
        if (out < 0)
            log("media: open " + audioDev_ + " failed errno=" + std::to_string(errno));
        else
            log("media: MrAudio open — software-paced 48kHz delay_ms=" +
                std::to_string(audioDelayMs_) +
                " clock_ppm=" + std::to_string(audioClockPpm_) + " (adelay in ffmpeg if >0)");
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
    audioBytes_.store(0);
    audioQueuedBytes_.store(-1);
    // 20ms chunks @ 48k stereo s16le
    char buf[3840];
    std::vector<uint8_t> f2acc;
    f2acc.reserve(32768);
    size_t total = 0;
    size_t f2total = 0;
    int f2Fail = 0;
    constexpr size_t kF2Chunk = 8192;
    // Nominal 48 kHz stereo s16le, seeded by AUDIO_CLOCK_PPM. This used to be
    // the whole story: an open-loop trim for the FPGA's not-quite-48 kHz audio
    // clock. It cannot be, because the ring has no backpressure, so any residual
    // error integrates into ring depth forever (measured: +255 B/s at the old
    // +685 ppm, ~80 ms/min, overrunning the ring mid-episode). The servo in
    // feedRateBytesPerSec() now closes the loop on the measured depth and this
    // value is only a starting point — and the fallback if the depth is
    // unreadable.
    const double kBytesPerSec = 48000.0 * 4.0 * (1.0 + audioClockPpm_ / 1000000.0);
    // Deadline for the next chunk. Started on the FIRST chunk actually read, not
    // here: FFmpeg needs a variable, sometimes multi-hundred-ms warm-up before it
    // emits anything, and anchoring the clock before that made the pump write
    // flat out to "catch up", dumping the entire warm-up into the ring where it
    // stayed for the session (feed and drain are both ~48 kHz, so nothing ever
    // drained it). That is what made ring depth — and therefore lipsync —
    // session-dependent.
    std::chrono::steady_clock::time_point audioDue{};
    bool audioClockStarted = false;
    int64_t chunkIndex = 0;
    int64_t queuedEma = -1;
    int64_t lastLatLog = -1;
    bool latencyLogged = false;
    bool overrunLogged = false;

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
            audioBytes_.fetch_add(static_cast<size_t>(n));

            // Anchor on the first chunk, biased one target-depth into the past so
            // the pump runs flat out just long enough to prefill the ring to the
            // servo's set point, then falls into paced mode. This is the ordinary
            // audio prefill, and it is bounded — unlike the old warm-up burst.
            if (!audioClockStarted) {
                audioClockStarted = true;
                audioDue = std::chrono::steady_clock::now() -
                           std::chrono::duration_cast<std::chrono::steady_clock::duration>(
                               std::chrono::duration<double>(
                                   static_cast<double>(misterplex::kFeedTargetBytes) /
                                   kBytesPerSec));
            }

            // Advance the deadline by this chunk's duration at the servo-corrected
            // rate. Accumulating the deadline (rather than recomputing it from a
            // fixed origin) is what lets the rate change mid-stream without the
            // schedule jumping.
            const double rate = misterplex::feedRateBytesPerSec(
                kBytesPerSec, audioQueuedBytes_.load(std::memory_order_relaxed));
            audioDue += std::chrono::duration_cast<std::chrono::steady_clock::duration>(
                std::chrono::duration<double>(n / rate));
            const auto now = std::chrono::steady_clock::now();
            if (audioDue > now)
                std::this_thread::sleep_until(audioDue);
            else if (now - audioDue > std::chrono::seconds(1)) {
                // We fell more than a second behind (decoder stall, CPU spike).
                // Do not try to make it up in one burst — that is precisely the
                // ring-stuffing behaviour we just removed. Re-anchor and let the
                // servo refill the target depth at its own pace.
                audioDue = now;
            }

            // Turn the submitted-byte counter into a real playback position by
            // subtracting what is still sitting in the driver's DMA ring. This
            // reading is also the servo's error signal, so it feeds both the
            // video clock and the feed rate.
            // Sampled every 4th chunk (~80 ms), which is far faster than the
            // servo's 8 s time constant; polling harder buys nothing but
            // syscalls.
            if ((chunkIndex++ % 4) == 0) {
                const int64_t q = readMrAudioQueuedBytes();
                if (q < 0) {
                    audioQueuedBytes_.store(-1);
                } else {
                    // Low-pass the depth. The servo holds the true depth
                    // constant, so sample-to-sample movement is mostly noise;
                    // feeding it raw into the video clock would jitter every
                    // frame's release time, and into the servo would make it
                    // chase that jitter. Seed on the first sample so startup is
                    // not slewed in from zero.
                    queuedEma = (queuedEma < 0) ? q : (queuedEma * 3 + q) / 4;
                    audioQueuedBytes_.store(queuedEma);
                    const int64_t latMs =
                        (queuedEma * 1000LL) / misterplex::kMrAudioBytesPerSec;
                    if (!latencyLogged) {
                        latencyLogged = true;
                        log("media: MrAudio playback position available — video now paces "
                            "off what is HEARD, not what is sent");
                    }
                    const int64_t nowMs = audioClockMs(audioBytes_.load());
                    if (lastLatLog < 0 || nowMs - lastLatLog >= 5000) {
                        lastLatLog = nowMs;
                        log("media: audio latency " + std::to_string(latMs) + "ms queued=" +
                            std::to_string(queuedEma) + "B");
                    }
                    // The ring has no backpressure: writing past the read pointer
                    // silently destroys unplayed audio. Nothing else reports this.
                    if (!overrunLogged && queuedEma > (misterplex::kMrAudioRingBytes * 3) / 4) {
                        overrunLogged = true;
                        log("media: WARNING MrAudio ring " + std::to_string(latMs) +
                            "ms deep — approaching overwrite of unplayed audio");
                    }
                }
            }
        }

        if (wantF2) {
            f2acc.insert(f2acc.end(), buf, buf + n);
            while (f2acc.size() >= kF2Chunk && !stop_.load()) {
                if (fpga_.sendPcmChunk(f2acc.data(), kF2Chunk, /*F2*/ 2)) {
                    f2total += kF2Chunk;
                    f2Fail = 0;
                } else {
                    ++f2Fail;
                    // Rate-limit: was logging every chunk when f2total==0 (0 % N == 0).
                    if (f2Fail == 1 || f2Fail == 8 || (f2Fail % 64) == 0)
                        log("media: F2 pcm: " + fpga_.lastError() +
                            " (fail#" + std::to_string(f2Fail) + ")");
                    // Core reconfig / menu: stop hammering SPI; MrAudio still plays.
                    if (fpga_.lastError().find("user mode") != std::string::npos && f2Fail >= 4) {
                        log("media: F2 disabled for session (FPGA left user mode)");
                        wantF2 = false;
                        f2acc.clear();
                        break;
                    }
                    if (f2Fail >= 32) {
                        log("media: F2 disabled for session (too many SPI errors)");
                        wantF2 = false;
                        f2acc.clear();
                        break;
                    }
                }
                if (wantF2)
                    f2acc.erase(f2acc.begin(),
                                f2acc.begin() + static_cast<std::ptrdiff_t>(kF2Chunk));
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

    const bool fpgaOnlyPresent = (presentMode_ == "fpga");
    const DdrFrameGeometry ddrGeometry =
        fpgaOnlyPresent ? ddrFrameGeometryForPresentedSize(outW_, outH_)
                        : makeDdrFrameGeometry(outW_, outH_);
    const int rawW = ddrGeometry.coded_width;
    const int rawH = ddrGeometry.coded_height;
    const int rawDisplayW = ddrGeometry.display_width;
    const int rawDisplayH = ddrGeometry.display_height;

    char scale[64];
    std::snprintf(scale, sizeof(scale), "%d:%d", rawW, rawH);
    std::string vf;
    // Force CFR at the exact content rate FIRST in the chain: frameIndex ↔ content
    // time then holds by construction (even if PMS emits a different rate than its
    // metadata claims), and frames dropped by the fps filter are never scaled.
    if (fpsNum_ > 0 && fpsDen_ > 0) {
        vf = "fps=" + std::to_string(fpsNum_) + "/" + std::to_string(fpsDen_) + ",";
    }
    if (rawDisplayW != rawW || rawDisplayH != rawH) {
        char displayScale[64];
        std::snprintf(displayScale, sizeof(displayScale), "%d:%d", rawDisplayW, rawDisplayH);
        vf += std::string("scale=") + displayScale +
              ":force_original_aspect_ratio=decrease,pad=" + scale + ":" +
              std::to_string(ddrGeometry.crop_left) + ":" +
              std::to_string(ddrGeometry.crop_top) + ":color=black";
    } else {
        vf += std::string("scale=") + scale +
              ":force_original_aspect_ratio=decrease,pad=" + scale + ":(ow-iw)/2:(oh-ih)/2";
    }

    const bool testPattern = (url == "testsrc" || url.rfind("lavfi", 0) == 0);
    // STREAM=0 + local file: optional FFmpeg subtitles filter (burn-in). Network/PMS
    // prefer WeakLadder::burnSubtitles so dual-A9 avoids libass on HTTP streams.
    const bool localFile =
        !testPattern && !url.empty() && url[0] == '/' && url.rfind("http", 0) != 0;
    if (!streamEnabled_ && subtitleMode_ == "ffmpeg" && localFile) {
        // Escape special chars for filtergraph path arg.
        std::string esc;
        for (char c : url) {
            if (c == '\\' || c == ':' || c == '\'' || c == '[' || c == ']')
                esc.push_back('\\');
            esc.push_back(c);
        }
        vf += ",subtitles=" + esc + ":si=" + std::to_string(std::max(0, subtitleStreamIndex_));
        log("media: FFmpeg subtitles burn-in si=" + std::to_string(subtitleStreamIndex_));
    }
    const bool wantMr = audioEnabled_ && (::access(audioDev_.c_str(), W_OK) == 0);
    // Match audioPump: F2 only when PRESENT=fpga and MrAudio unavailable.
    const bool wantF2 = fpga_.ok() && presentMode_ == "fpga" && !wantMr;
    const bool wantAudio = audioEnabled_ && (wantMr || wantF2);

    // Product path: STREAM + PRESENT=fpga may skip heavy RGB (keep audio + demux).
    // STREAM=0 and PRESENT=both/fb0 always keep the proven FFmpeg RGB path.
    const bool skipRgb = !testPattern && wantSkipRgbVideo();
    if (streamEnabled_ && !testPattern) {
        if (skipRgb) {
            log("media: STREAM skip RGB decode (audio + host recon F1; PRESENT=fpga "
                "STREAM_SKIP_RGB=" +
                streamSkipRgb_ + ")");
        } else {
            // Make preferDirect / skip-RGB product path inspectable in logs.
            log("media: STREAM keep FFmpeg RGB (PRESENT=" + presentMode_ +
                " STREAM_SKIP_RGB=" + streamSkipRgb_ +
                (presentMode_ == "fpga" ? " — RGB forced on for CABAC/fallback)"
                                        : " — continuous fb0 needs RGB)"));
        }
    }

    // Optional continuous annex-B → host recon F1 + F3
    const bool wantStream = streamEnabled_ && fpga_.ok() && !testPattern;
    if (wantStream) {
        int spipe[2] = {-1, -1};
        if (pipe(spipe) == 0) {
            pid_t spid = spawnStreamDemux(url, headers, startMs, spipe[1]);
            ::close(spipe[1]);
            if (spid > 0) {
                streamPid_.store(spid);
                streamThr_ = std::thread([this, sfd = spipe[0]] { streamPump(sfd); });
                if (looksElementaryH264(url))
                    log("media: STREAM demux elementary H.264 (no mp4toannexb)");
                else
                    log("media: STREAM demux via h264_mp4toannexb (Part/container → annex-B)");
            } else {
                ::close(spipe[0]);
                log("media: STREAM demux fork failed");
            }
        } else {
            log("media: STREAM demux pipe failed errno=" + std::to_string(errno));
        }
    } else if (streamEnabled_ && !testPattern && !fpga_.ok()) {
        log("media: STREAM=1 but FPGA SPI unavailable — host recon F1/F3 disabled");
    }

    int rfd = -1;
    int64_t frameIndex = 0;
    auto t0 = std::chrono::steady_clock::now();
    auto lastLog = t0;
    size_t totalBytes = 0;

    bool usedRgb = false;

    // A/V pacing state. The exact rational rate is load-bearing: pacing 23.976 fps
    // content at a hardcoded 24 leaks ~1 ms/s of video lead.
    const int fpsNum = fpsNum_ > 0 ? fpsNum_ : kDefaultFpsNum;
    const int fpsDen = fpsNum_ > 0 && fpsDen_ > 0 ? fpsDen_ : kDefaultFpsDen;
    const int64_t leadMs = presentLeadMs_;
    const int64_t dropMs = resyncDropMs_;
    int dropRun = 0;
    avDriftMs_.store(0);
    droppedFrames_.store(0);
    if (fpsNum_ <= 0)
        log("media: content fps UNKNOWN — pacing at " + std::to_string(kDefaultFpsNum) + "/" +
            std::to_string(kDefaultFpsDen) + " and relying on drift correction");
    else
        log("media: content fps=" + std::to_string(fpsNum) + "/" + std::to_string(fpsDen) +
            " lead_ms=" + std::to_string(leadMs) + " resync_drop_ms=" + std::to_string(dropMs));

    if (skipRgb) {
        // Audio-only FFmpeg + wall-clock position. Host recon owns F1.
        int apipe[2] = {-1, -1};
        if (wantAudio && pipe(apipe) == 0) {
            pid_t pid = spawnAudioOnly(url, headers, startMs, apipe[1]);
            ::close(apipe[1]);
            if (pid > 0) {
                childPid_.store(pid);
                audioThr_ = std::thread([this, afd = apipe[0]] { audioPump(afd); });
            } else {
                ::close(apipe[0]);
                log("media: audio-only fork failed");
            }
        } else if (wantAudio) {
            log("media: audio pipe failed — STREAM recon video only");
        }

        if (onProgress_)
            onProgress_("playing", startMs, durationMs);
        auto lastProgress = t0;

        // Wait for session end: stop/seek, or both pumps exit.
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
            // Wall-clock position (no RGB frame cadence)
            auto now = std::chrono::steady_clock::now();
            int64_t elapsed =
                std::chrono::duration_cast<std::chrono::milliseconds>(now - t0).count();
            int64_t tms = startMs + elapsed;
            positionMs_.store(tms);
            if (onProgress_ && now - lastProgress >= std::chrono::seconds(1)) {
                lastProgress = now;
                onProgress_("playing", tms, durationMs);
            }
            if (durationMs > 0 && tms >= durationMs) {
                log("media: STREAM audio-only reached duration");
                break;
            }
            // Exit when demux and audio both finished (EOF)
            if (!streamActive_.load() && streamThr_.joinable() && !audioActive_.load() &&
                childPid_.load() > 0) {
                // Give stream thr a moment; if stream ended and no audio, done
                pid_t cp = childPid_.load();
                if (cp > 0) {
                    int st = 0;
                    if (waitpid(cp, &st, WNOHANG) == cp)
                        childPid_.store(-1);
                }
                if (childPid_.load() <= 0 && !streamActive_.load())
                    break;
            }
            if (now - lastLog > std::chrono::seconds(1)) {
                lastLog = now;
                log("media: STREAM no-RGB t_ms=" + std::to_string(tms) +
                    " recon=" + std::to_string(reconFrames_.load()) +
                    " cabac=" + (cabacSkip_.load() ? "1" : "0") +
                    " audio=" + (audioActive_.load() ? "on" : "off") +
                    " stream=" + (streamActive_.load() ? "on" : "off"));
            }
            // CABAC with no recon: optional soft note (RGB was skipped — nothing to fall back)
            if (cabacSkip_.load() && reconFrames_.load() == 0 && elapsed > 3000 &&
                (elapsed / 1000) % 10 == 3) {
                static thread_local int64_t lastCabacWarn = -1;
                if (elapsed - lastCabacWarn > 9000) {
                    lastCabacWarn = elapsed;
                    log("media: STREAM no-RGB + CABAC — stream is High/CABAC; MiSTerPlex.xml "
                        "profile may be missing or inactive on PMS. Set STREAM_SKIP_RGB=0 or "
                        "PRESENT=both for FFmpeg RGB fallback.");
                }
            }
            std::this_thread::sleep_for(std::chrono::milliseconds(50));
        }
    } else {
        // Full FFmpeg rawvideo path (STREAM=0 default; STREAM=1 with PRESENT=both/fb0; skip off).
        // STREAM=0 + PRESENT=fpga: every decoded frame → F1 (DDR preferred) — not IDR recon.
        // STREAM=1 recon is ~1 fps (keyframe only) and is the wrong interactive cast path.
        const bool wantFpgaFrameStore =
            fpga_.ok() && (presentMode_ == "fpga" || presentMode_ == "both");
        const bool wantYuvDdr = wantFpgaFrameStore && ddrFrameFormat_ == DdrFrameFormat::Yuv420p;
        RawVideoFormat videoFmt = RawVideoFormat::Rgb24;
        if (wantYuvDdr) {
            videoFmt = RawVideoFormat::Yuv420p;
        } else if (wantFpgaFrameStore || (fb_.ok() && fb_.bpp() == 16)) {
            videoFmt = RawVideoFormat::Rgb565Le;
        } else if (fb_.ok() && (fb_.bpp() == 32 || fb_.bpp() == 24)) {
            videoFmt = RawVideoFormat::Bgra32;
        }
        if (!streamEnabled_ && (presentMode_ == "fpga" || presentMode_ == "both"))
            log("media: STREAM=0 rawvideo(" + std::string(ffmpegPixFmt(videoFmt)) +
                ")→F1 PRESENT=" + presentMode_ +
                " decode=" + std::to_string(outW_) + "x" + std::to_string(outH_) +
                " coded=" + std::to_string(rawW) + "x" + std::to_string(rawH) +
                " display=" + std::to_string(rawDisplayW) + "x" +
                std::to_string(rawDisplayH) +
                " clock=wall-48k-audio+every-frame-present");
        if (wantYuvDdr && presentMode_ == "both" && fb_.ok())
            log("media: PRESENT=both uses yuv420p DDR frame-store path; fb0 blit converts the "
                "same frame");
        usedRgb = true;
        presentCount_ = 0;
        audioBytes_.store(0);
        std::vector<std::string> args;
        args.push_back(ffmpeg_);
        args.push_back("-hide_banner");
        args.push_back("-loglevel");
        args.push_back("error");
        args.push_back("-nostdin");

        if (testPattern) {
            std::string lavfi;
            if (url.rfind("lavfi:", 0) == 0 && url.size() > 6) {
                lavfi = url.substr(6);
            } else {
                const std::string rate =
                    fpsNum_ > 0 ? (std::to_string(fpsNum_) +
                                   (fpsDen_ > 1 ? ("/" + std::to_string(fpsDen_)) : ""))
                                : "30";
                lavfi = "testsrc2=size=" + std::to_string(outW_) + "x" +
                        std::to_string(outH_) + ":rate=" + rate;
            }
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
            args.push_back(ffmpegPixFmt(videoFmt));
            args.push_back("-vf");
            args.push_back(vf);
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
            // Local/direct Part: FFmpeg -ss. Universal: offset already in URL (no double-seek).
            if (startMs > 0 && !urlHasUniversalOffset(url)) {
                char ss[32];
                std::snprintf(ss, sizeof(ss), "%.3f", startMs / 1000.0);
                args.push_back("-ss");
                args.push_back(ss);
            } else if (startMs > 0 && urlHasUniversalOffset(url)) {
                log("media: skip -ss (universal offset baked) startMs=" +
                    std::to_string(startMs));
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
            args.push_back(ffmpegPixFmt(videoFmt));
            args.push_back("-vf");
            args.push_back(vf);
            args.push_back("pipe:1");

            if (wantAudio) {
                // Plain 48k stereo — no async stretch. MrAudio wall-pace is the
                // master clock; FFmpeg back-pressures A+V together (see present loop).
                // AUDIO_DELAY_MS>0: adelay shifts audio content later (ms) so lipsync
                // can be corrected from measure evidence. adelay is content-aligned
                // (unlike a pure wall hold that races during network burst fill).
                args.push_back("-map");
                args.push_back("0:a:0?");
                args.push_back("-vn");
                args.push_back("-af");
                if (audioDelayMs_ > 0) {
                    // adelay unit is ms per channel; all=1 applies to every channel.
                    args.push_back("aresample=48000,adelay=" + std::to_string(audioDelayMs_) +
                                   ":all=1");
                    log("media: ffmpeg adelay_ms=" + std::to_string(audioDelayMs_));
                } else {
                    args.push_back("aresample=48000");
                }
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
            killChildren();
            if (streamThr_.joinable())
                streamThr_.join();
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
            killChildren();
            if (streamThr_.joinable())
                streamThr_.join();
            return;
        }
        childPid_.store(pid);
        rfd = vpipe[0];
        const int rflags = fcntl(rfd, F_GETFL, 0);
        if (rflags >= 0)
            fcntl(rfd, F_SETFL, rflags | O_NONBLOCK);

        if (apipe[0] >= 0) {
            audioThr_ = std::thread([this, afd = apipe[0]] { audioPump(afd); });
        }

        const size_t frameBytes = rawVideoFrameBytes(videoFmt, rawW, rawH);
        std::vector<uint8_t> frame(frameBytes);
        std::vector<uint8_t> fbOverlayBackup;

        struct PresentProfileAccum {
            int64_t frames = 0;
            int64_t presented = 0;
            int64_t readCalls = 0;
            int64_t readOkCalls = 0;
            int64_t readEagain = 0;
            int64_t readEintr = 0;
            int64_t readZero = 0;
            int64_t readBytes = 0;
            int64_t readMaxBytes = 0;
            int64_t readWallUs = 0;
            int64_t readCpuUs = 0;
            int64_t readSyscallUs = 0;
            int64_t readSleepUs = 0;
            int64_t pacingWaitUs = 0;
            int64_t pacingWaitCpuUs = 0;
            int64_t overlayUs = 0;
            int64_t overlayCpuUs = 0;
            int64_t fbUs = 0;
            int64_t fbCpuUs = 0;
            int64_t pixelUs = 0;
            int64_t pixelCpuUs = 0;
            int64_t ddrPrepWaitUs = 0;
            int64_t ddrCopyUs = 0;
            int64_t ddrFlushUs = 0;
            int64_t ddrDoorbellUs = 0;
            int64_t ddrPostWaitUs = 0;
            int64_t ddrTotalUs = 0;
            int64_t ddrCpuUs = 0;
            int64_t ddrUnaccountedUs = 0;
            int64_t spiFallbackUs = 0;
            int64_t spiFallbackCpuUs = 0;
            int64_t drops = 0;
        } prof;
        const bool profilePresent = presentProfile_;
        auto logProfile = [&]() {
            if (!profilePresent || prof.frames <= 0)
                return;
            const int64_t presented = prof.presented > 0 ? prof.presented : 1;
            const int64_t readOk = prof.readOkCalls > 0 ? prof.readOkCalls : 1;
            auto avgFrame = [&](int64_t us) { return us / prof.frames; };
            auto avgFrameX100 = [&](int64_t v) { return (v * 100) / prof.frames; };
            auto avgPresented = [&](int64_t us) { return us / presented; };
            auto avgRead = [&](int64_t v) { return v / readOk; };
            const int64_t readLoopUs =
                std::max<int64_t>(0, prof.readWallUs - prof.readSyscallUs - prof.readSleepUs);
            const int64_t ddrWaitUs = prof.ddrPrepWaitUs + prof.ddrPostWaitUs;
            const int64_t ddrAccountedUs =
                ddrWaitUs + prof.ddrCopyUs + prof.ddrFlushUs + prof.ddrDoorbellUs;
            log("media: present_profile frames=" + std::to_string(prof.frames) +
                " presented=" + std::to_string(prof.presented) +
                " drops=" + std::to_string(prof.drops) +
                " read_us_f=" + std::to_string(avgFrame(prof.readWallUs)) +
                " read_cpu_us_f=" + std::to_string(avgFrame(prof.readCpuUs)) +
                " read_syscall_us_f=" + std::to_string(avgFrame(prof.readSyscallUs)) +
                " read_eagain_sleep_us_f=" + std::to_string(avgFrame(prof.readSleepUs)) +
                " read_loop_overhead_us_f=" + std::to_string(avgFrame(readLoopUs)) +
                " read_calls_f=" + std::to_string(prof.readCalls / prof.frames) +
                " read_calls_x100_f=" + std::to_string(avgFrameX100(prof.readCalls)) +
                " read_ok_calls_f=" + std::to_string(prof.readOkCalls / prof.frames) +
                " read_ok_calls_x100_f=" + std::to_string(avgFrameX100(prof.readOkCalls)) +
                " read_eagain_f=" + std::to_string(prof.readEagain / prof.frames) +
                " read_eagain_x100_f=" + std::to_string(avgFrameX100(prof.readEagain)) +
                " read_eintr_f=" + std::to_string(prof.readEintr / prof.frames) +
                " read_zero=" + std::to_string(prof.readZero) +
                " read_bytes_f=" + std::to_string(prof.readBytes / prof.frames) +
                " read_avg_bytes_call=" + std::to_string(avgRead(prof.readBytes)) +
                " read_max_bytes_call=" + std::to_string(prof.readMaxBytes) +
                " pacing_wait_us_f=" + std::to_string(avgFrame(prof.pacingWaitUs)) +
                " pacing_wait_cpu_us_f=" + std::to_string(avgFrame(prof.pacingWaitCpuUs)) +
                " overlay_us_p=" + std::to_string(avgPresented(prof.overlayUs)) +
                " overlay_cpu_us_p=" + std::to_string(avgPresented(prof.overlayCpuUs)) +
                " fb_us_p=" + std::to_string(avgPresented(prof.fbUs)) +
                " fb_cpu_us_p=" + std::to_string(avgPresented(prof.fbCpuUs)) +
                " pixel_us_p=" + std::to_string(avgPresented(prof.pixelUs)) +
                " pixel_cpu_us_p=" + std::to_string(avgPresented(prof.pixelCpuUs)) +
                " ddr_wait_us_p=" + std::to_string(avgPresented(ddrWaitUs)) +
                " ddr_prep_wait_us_p=" + std::to_string(avgPresented(prof.ddrPrepWaitUs)) +
                " ddr_copy_us_p=" + std::to_string(avgPresented(prof.ddrCopyUs)) +
                " ddr_flush_us_p=" + std::to_string(avgPresented(prof.ddrFlushUs)) +
                " ddr_doorbell_us_p=" + std::to_string(avgPresented(prof.ddrDoorbellUs)) +
                " ddr_post_wait_us_p=" + std::to_string(avgPresented(prof.ddrPostWaitUs)) +
                " ddr_accounted_us_p=" + std::to_string(avgPresented(ddrAccountedUs)) +
                " ddr_unaccounted_us_p=" +
                    std::to_string(avgPresented(prof.ddrUnaccountedUs)) +
                " ddr_total_us_p=" + std::to_string(avgPresented(prof.ddrTotalUs)) +
                " ddr_cpu_us_p=" + std::to_string(avgPresented(prof.ddrCpuUs)) +
                " spi_fallback_us_p=" + std::to_string(avgPresented(prof.spiFallbackUs)) +
                " spi_fallback_cpu_us_p=" +
                    std::to_string(avgPresented(prof.spiFallbackCpuUs)) +
                " frame_bytes=" + std::to_string(frameBytes) +
                " fmt=" + ffmpegPixFmt(videoFmt));
            prof = PresentProfileAccum{};
        };

        auto blitFrame = [&](const uint8_t* data) {
            if (!fb_.ok())
                return;
            bool fbOk = false;
            switch (videoFmt) {
            case RawVideoFormat::Rgb565Le:
                fbOk = fb_.blitRgb565Le(data, rawW, rawH);
                break;
            case RawVideoFormat::Bgra32:
                fbOk = fb_.blitBgra32(data, rawW, rawH);
                break;
            case RawVideoFormat::Yuv420p:
                fbOk = fb_.blitYuv420p(data, rawW, rawH);
                break;
            case RawVideoFormat::Rgb24:
            default:
                fbOk = fb_.blitRgb24(data, rawW, rawH);
                break;
            }
            if (!fbOk)
                log("media: blit failed fmt=" + std::string(ffmpegPixFmt(videoFmt)));
        };

        auto renderOverlay = [&](uint8_t* data) {
            switch (videoFmt) {
            case RawVideoFormat::Rgb565Le:
                overlay_.renderRgb565Le(data, rawW, rawH);
                break;
            case RawVideoFormat::Bgra32:
                overlay_.renderBgra32(data, rawW, rawH);
                break;
            case RawVideoFormat::Yuv420p:
                break;
            case RawVideoFormat::Rgb24:
            default:
                overlay_.renderRgb24(data, rawW, rawH);
                break;
            }
        };

        auto backupOverlayDirty = [&](uint8_t* cleanFrame, const OverlayRect& dirty) {
            fbOverlayBackup.clear();
            if (dirty.empty())
                return;
            const size_t bpp = rawVideoPackedBytesPerPixel(videoFmt);
            if (bpp == 0)
                return;
            const size_t rowBytes = static_cast<size_t>(dirty.w) * bpp;
            fbOverlayBackup.resize(rowBytes * static_cast<size_t>(dirty.h));
            for (int yy = 0; yy < dirty.h; ++yy) {
                const size_t src =
                    (static_cast<size_t>(dirty.y + yy) * rawW + dirty.x) * bpp;
                std::memcpy(fbOverlayBackup.data() + rowBytes * static_cast<size_t>(yy),
                            cleanFrame + src, rowBytes);
            }
        };

        auto restoreOverlayDirty = [&](uint8_t* cleanFrame, const OverlayRect& dirty) {
            if (dirty.empty() || fbOverlayBackup.empty())
                return;
            const size_t bpp = rawVideoPackedBytesPerPixel(videoFmt);
            if (bpp == 0)
                return;
            const size_t rowBytes = static_cast<size_t>(dirty.w) * bpp;
            for (int yy = 0; yy < dirty.h; ++yy) {
                const size_t dst =
                    (static_cast<size_t>(dirty.y + yy) * rawW + dirty.x) * bpp;
                std::memcpy(cleanFrame + dst,
                            fbOverlayBackup.data() + rowBytes * static_cast<size_t>(yy),
                            rowBytes);
            }
        };

        auto presentCleanFrame = [&](uint8_t* cleanFrame, bool countPresent) {
            const OverlayRect dirty = overlay_.dirtyBounds(rawW, rawH);
            backupOverlayDirty(cleanFrame, dirty);
            if (!dirty.empty()) {
                if (profilePresent) {
                    const auto overlay0 = std::chrono::steady_clock::now();
                    const int64_t overlayCpu0 = threadCpuMicros();
                    renderOverlay(cleanFrame);
                    const int64_t overlayCpu1 = threadCpuMicros();
                    const auto overlay1 = std::chrono::steady_clock::now();
                    prof.overlayUs += microsBetween(overlay0, overlay1);
                    prof.overlayCpuUs += overlayCpu1 - overlayCpu0;
                } else {
                    renderOverlay(cleanFrame);
                }
            }

            if (fb_.ok()) {
                if (profilePresent) {
                    const auto fb0 = std::chrono::steady_clock::now();
                    const int64_t fbCpu0 = threadCpuMicros();
                    blitFrame(cleanFrame);
                    const int64_t fbCpu1 = threadCpuMicros();
                    const auto fb1 = std::chrono::steady_clock::now();
                    prof.fbUs += microsBetween(fb0, fb1);
                    prof.fbCpuUs += fbCpu1 - fbCpu0;
                } else {
                    blitFrame(cleanFrame);
                }
            }

            const bool reconOwnsF1 = streamEnabled_ && reconPresentOk_.load();
            if (!reconOwnsF1 && wantFpgaFrameStore) {
                const uint8_t* txFrame = cleanFrame;
                size_t txBytes = frameBytes;

                // Serialise with the OSD poller / idle painter: FpgaSpi keeps
                // transaction state, so overlapping ioctls corrupt each other.
                std::lock_guard<std::mutex> lk(presentMu_);
                bool ok = false;
                if (useDdrF1_) {
                    const int64_t ddrCpu0 = profilePresent ? threadCpuMicros() : 0;
                    if (videoFmt == RawVideoFormat::Yuv420p) {
                        ok = fpga_.sendYuv420pFrameDdr(txFrame, txBytes, ddrGeometry, ddrBank_);
                    } else {
                        ok = false;
                    }
                    if (profilePresent && ok) {
                        const int64_t ddrCpu1 = threadCpuMicros();
                        const auto dt = fpga_.lastDdrTiming();
                        const int64_t accounted = dt.prep_wait_us + dt.copy_us + dt.flush_us +
                                                  dt.doorbell_us + dt.post_wait_us;
                        prof.ddrPrepWaitUs += dt.prep_wait_us;
                        prof.ddrCopyUs += dt.copy_us;
                        prof.ddrFlushUs += dt.flush_us;
                        prof.ddrDoorbellUs += dt.doorbell_us;
                        prof.ddrPostWaitUs += dt.post_wait_us;
                        prof.ddrTotalUs += dt.total_us;
                        prof.ddrCpuUs += ddrCpu1 - ddrCpu0;
                        if (dt.total_us > accounted)
                            prof.ddrUnaccountedUs += dt.total_us - accounted;
                    }
                    ddrBank_ ^= 1;
                    if (!ok) {
                        useDdrF1_ = false;
                        if (videoFmt == RawVideoFormat::Yuv420p)
                            log("media: DDR YUV420p F1 unavailable: " + fpga_.lastError());
                        else
                            log("media: DDR F1 unavailable, SPI fallback: " + fpga_.lastError());
                    }
                }
                if (!ok && videoFmt != RawVideoFormat::Yuv420p) {
                    if (profilePresent) {
                        const auto spi0 = std::chrono::steady_clock::now();
                        const int64_t spiCpu0 = threadCpuMicros();
                        ok = fpga_.sendRgb565Bytes(txFrame, txBytes, /*F1*/ 1);
                        const int64_t spiCpu1 = threadCpuMicros();
                        const auto spi1 = std::chrono::steady_clock::now();
                        prof.spiFallbackUs += microsBetween(spi0, spi1);
                        prof.spiFallbackCpuUs += spiCpu1 - spiCpu0;
                    } else {
                        ok = fpga_.sendRgb565Bytes(txFrame, txBytes, /*F1*/ 1);
                    }
                }
                if (!ok) {
                    if (countPresent && (frameIndex % 30) == 0)
                        log("media: fpga frame_tx: " + fpga_.lastError());
                } else if (countPresent) {
                    ++presentCount_;
                    if (profilePresent)
                        ++prof.presented;
                    if ((presentCount_ % 48) == 0) {
                        log(std::string("media: fpga frame_tx ok via ") +
                            (useDdrF1_ ? "DDR" : "SPI") +
                            " presents=" + std::to_string(presentCount_) +
                            " frames=" + std::to_string(frameIndex) +
                            " ms=" + std::to_string(static_cast<int>(fpga_.lastPushMs())));
                    }
                }
            }

            restoreOverlayDirty(cleanFrame, dirty);
        };

        if (onProgress_)
            onProgress_("playing", startMs, durationMs);

        // Deterministic A/V origin: never start the schedule on the wall clock and then
        // switch to the audio clock mid-stream — that step discontinuity randomises the
        // lipsync offset by tens of ms on every play (measured spread ~67 ms across
        // identical runs). Wait for the audio master clock to exist first.
        if (wantAudio && apipe[0] >= 0) {
            const auto waitStart = std::chrono::steady_clock::now();
            while (!stop_.load() && !audioActive_.load() &&
                   std::chrono::steady_clock::now() - waitStart < std::chrono::seconds(5)) {
                std::this_thread::sleep_for(std::chrono::milliseconds(2));
            }
            const int64_t waited = std::chrono::duration_cast<std::chrono::milliseconds>(
                                       std::chrono::steady_clock::now() - waitStart)
                                       .count();
            log("media: A/V origin armed audio_active=" +
                std::string(audioActive_.load() ? "1" : "0") +
                " waited_ms=" + std::to_string(waited));
        }
        t0 = std::chrono::steady_clock::now();
        bool pauseClockHeld = false;
        bool pausedOverlayWasVisible = false;
        std::chrono::steady_clock::time_point pauseStarted{};
        size_t got = 0;
        bool videoEof = false;

        while (!stop_.load()) {
            int64_t seekTo = seekReqMs_.exchange(-1);
            if (seekTo >= 0) {
                log("media: seek requested " + std::to_string(seekTo));
                break;
            }

            if (paused_.load()) {
                if (!pauseClockHeld) {
                    pauseClockHeld = true;
                    pauseStarted = std::chrono::steady_clock::now();
                }
                const bool overlayNow = overlay_.visible();
                if ((overlayNow || pausedOverlayWasVisible) && frameIndex > 0) {
                    presentCleanFrame(frame.data(), /*countPresent*/ false);
                    pausedOverlayWasVisible = overlayNow;
                }
                std::this_thread::sleep_for(std::chrono::milliseconds(50));
                continue;
            } else if (pauseClockHeld) {
                t0 += std::chrono::steady_clock::now() - pauseStarted;
                pauseClockHeld = false;
            }

            int64_t frameReadCalls = 0;
            int64_t frameReadOkCalls = 0;
            int64_t frameReadEagain = 0;
            int64_t frameReadEintr = 0;
            int64_t frameReadZero = 0;
            int64_t frameReadBytes = 0;
            int64_t frameReadMaxBytes = 0;
            int64_t frameReadSyscallUs = 0;
            int64_t frameReadSleepUs = 0;
            std::chrono::steady_clock::time_point readStart;
            std::chrono::steady_clock::time_point readEnd;
            int64_t readCpuStart = 0;
            int64_t readCpuEnd = 0;
            if (profilePresent)
                readStart = std::chrono::steady_clock::now();
            if (profilePresent)
                readCpuStart = threadCpuMicros();
            while (got < frameBytes && !stop_.load() && !paused_.load()) {
                ++frameReadCalls;
                ssize_t n = 0;
                if (profilePresent) {
                    const auto syscall0 = std::chrono::steady_clock::now();
                    n = ::read(rfd, frame.data() + got, frameBytes - got);
                    const auto syscall1 = std::chrono::steady_clock::now();
                    frameReadSyscallUs += microsBetween(syscall0, syscall1);
                } else {
                    n = ::read(rfd, frame.data() + got, frameBytes - got);
                }
                if (n < 0) {
                    if (errno == EINTR) {
                        ++frameReadEintr;
                        continue;
                    }
                    if (errno == EAGAIN || errno == EWOULDBLOCK) {
                        ++frameReadEagain;
                        if (profilePresent) {
                            const auto sleep0 = std::chrono::steady_clock::now();
                            std::this_thread::sleep_for(std::chrono::milliseconds(2));
                            const auto sleep1 = std::chrono::steady_clock::now();
                            frameReadSleepUs += microsBetween(sleep0, sleep1);
                        } else {
                            std::this_thread::sleep_for(std::chrono::milliseconds(2));
                        }
                        continue;
                    }
                    log("media: read err errno=" + std::to_string(errno));
                    break;
                }
                if (n == 0) {
                    ++frameReadZero;
                    videoEof = true;
                    break;
                }
                got += static_cast<size_t>(n);
                ++frameReadOkCalls;
                frameReadBytes += n;
                if (n > frameReadMaxBytes)
                    frameReadMaxBytes = n;
                totalBytes += static_cast<size_t>(n);
            }
            if (profilePresent) {
                readCpuEnd = threadCpuMicros();
                readEnd = std::chrono::steady_clock::now();
            }
            if (paused_.load())
                continue;
            if (got < frameBytes) {
                log("media: short read got=" + std::to_string(got) + "/" +
                    std::to_string(frameBytes) + " totalBytes=" + std::to_string(totalBytes) +
                    (videoEof ? " eof=1" : ""));
                break;
            }
            got = 0;

            if (videoFmt == RawVideoFormat::Yuv420p) {
                if (profilePresent) {
                    const auto pix0 = std::chrono::steady_clock::now();
                    const int64_t pixCpu0 = threadCpuMicros();
                    clearYuv420pCropPadding(frame.data(), ddrGeometry);
                    const int64_t pixCpu1 = threadCpuMicros();
                    const auto pix1 = std::chrono::steady_clock::now();
                    prof.pixelUs += microsBetween(pix0, pix1);
                    prof.pixelCpuUs += pixCpu1 - pixCpu0;
                } else {
                    clearYuv420pCropPadding(frame.data(), ddrGeometry);
                }
            }

            ++frameIndex;
            if (profilePresent) {
                ++prof.frames;
                prof.readCalls += frameReadCalls;
                prof.readOkCalls += frameReadOkCalls;
                prof.readEagain += frameReadEagain;
                prof.readEintr += frameReadEintr;
                prof.readZero += frameReadZero;
                prof.readBytes += frameReadBytes;
                if (frameReadMaxBytes > prof.readMaxBytes)
                    prof.readMaxBytes = frameReadMaxBytes;
                prof.readWallUs += microsBetween(readStart, readEnd);
                prof.readCpuUs += readCpuEnd - readCpuStart;
                prof.readSyscallUs += frameReadSyscallUs;
                prof.readSleepUs += frameReadSleepUs;
            }

            // A/V lock: wait until the master clock reaches this frame's content time,
            // or drop the frame when we are too far behind to catch up by waiting.
            // Content time comes from the EXACT rational rate — a bucketed integer fps
            // (23.976 → 24) leaks ~1 ms/s, invisible in a 12 s clip but ~234 ms by 3:54.
            bool present = true;
            int64_t framePacingWaitUs = 0;
            int64_t framePacingWaitCpuUs = 0;
            {
                // Live OSD trim is read every frame so the menu takes effect at once.
                const int64_t frameMs =
                    frameContentMs(frameIndex, fpsNum, fpsDen) + avOffsetMs_.load();
                for (;;) {
                    if (stop_.load() || paused_.load())
                        break;
                    int64_t clockMs = 0;
                    if (wantAudio && audioActive_.load()) {
                        // What has actually been HEARD, not what has been handed
                        // to the driver. Falls back to the submitted-byte clock
                        // when the ring depth is unavailable.
                        clockMs = misterplex::audibleClockMs(audioBytes_.load(),
                                                             audioQueuedBytes_.load());
                    } else {
                        clockMs = std::chrono::duration_cast<std::chrono::milliseconds>(
                                      std::chrono::steady_clock::now() - t0)
                                      .count();
                    }
                    const int64_t drift = misterplex::avDriftMs(clockMs, frameMs);
                    avDriftMs_.store(drift);
                    const AvAction act = avDecide(drift, leadMs, dropMs, dropRun);
                    if (act == AvAction::Hold) {
                        if (profilePresent) {
                            const auto hold0 = std::chrono::steady_clock::now();
                            const int64_t holdCpu0 = threadCpuMicros();
                            std::this_thread::sleep_for(std::chrono::milliseconds(2));
                            const int64_t holdCpu1 = threadCpuMicros();
                            const auto hold1 = std::chrono::steady_clock::now();
                            framePacingWaitUs += microsBetween(hold0, hold1);
                            framePacingWaitCpuUs += holdCpu1 - holdCpu0;
                        } else {
                            std::this_thread::sleep_for(std::chrono::milliseconds(2));
                        }
                        continue;
                    }
                    present = (act != AvAction::Drop);
                    break;
                }
            }
            if (profilePresent) {
                prof.pacingWaitUs += framePacingWaitUs;
                prof.pacingWaitCpuUs += framePacingWaitCpuUs;
            }

            if (!present) {
                ++dropRun;
                droppedFrames_.fetch_add(1);
                if (profilePresent)
                    ++prof.drops;
                if ((droppedFrames_.load() % 24) == 1)
                    log("media: A/V resync drop drift_ms=" + std::to_string(avDriftMs_.load()) +
                        " drops=" + std::to_string(droppedFrames_.load()));
            } else {
                dropRun = 0;
                presentCleanFrame(frame.data(), /*countPresent*/ true);
            }

            auto now = std::chrono::steady_clock::now();
            const int64_t wall2 = std::chrono::duration_cast<std::chrono::milliseconds>(
                                      now - t0)
                                      .count();
            if (now - lastLog > std::chrono::seconds(1)) {
                lastLog = now;
                const double vfps =
                    wall2 > 0 ? (1000.0 * static_cast<double>(frameIndex) /
                                 static_cast<double>(wall2))
                              : 0.0;
                const double pfps =
                    wall2 > 0 ? (1000.0 * static_cast<double>(presentCount_) /
                                 static_cast<double>(wall2))
                              : 0.0;
                const int64_t abytes = audioBytes_.load();
                const double a_sec = static_cast<double>(abytes) / (48000.0 * 4.0);
                log("media: frames=" + std::to_string(frameIndex) +
                    " vfps=" + std::to_string(vfps).substr(0, 4) +
                    " pfps=" + std::to_string(pfps).substr(0, 4) +
                    " audio_s=" + std::to_string(a_sec).substr(0, 5) +
                    " wall_s=" + std::to_string(wall2 / 1000.0).substr(0, 5) +
                    " audio=" + (audioActive_.load() ? "on" : "off") +
                    " clock=av-lock" +
                    " av_drift_ms=" + std::to_string(avDriftMs_.load()) +
                    " drops=" + std::to_string(droppedFrames_.load()) +
                    " fps=" + std::to_string(fpsNum) + "/" + std::to_string(fpsDen) +
                    " decode=" + std::to_string(outW_) + "x" + std::to_string(outH_));
            }

            {
                int64_t tms = startMs + wall2;
                positionMs_.store(tms);
                overlay_.setProgress(tms, durationMs);
                if ((frameIndex % 15) == 0 && onProgress_)
                    onProgress_("playing", tms, durationMs);
            }
            if (profilePresent && prof.frames >= 300)
                logProfile();
        }

        if (profilePresent)
            logProfile();
        if (rfd >= 0)
            ::close(rfd);
    }

    killChildren();
    if (audioThr_.joinable())
        audioThr_.join();
    if (streamThr_.joinable())
        streamThr_.join();

    playing_.store(false);
    // Natural EOF (not user stop / seek restart) → "ended" so main can auto-next.
    if (!stop_.load() && onProgress_) {
        const bool hadContent = usedRgb ? (frameIndex > 0) : (reconFrames_.load() > 0 ||
                                                              positionMs_.load() > startMs + 500);
        if (hadContent)
            onProgress_("ended", positionMs_.load(), durationMs);
        else
            onProgress_("stopped", 0, durationMs);
    }
    // The frame store latches the last frame written; without this the final frame
    // of the video stays on screen until something else paints over it.
    paintIdle();
    startIdle();

    log("media: session end frames=" + std::to_string(frameIndex) +
        " recon=" + std::to_string(reconFrames_.load()) +
        " cabac=" + (cabacSkip_.load() ? "1" : "0") +
        " stream=" + (streamEnabled_ ? "on" : "off") +
        " rgb=" + (usedRgb ? "on" : "off") +
        " present=" + presentMode_ +
        " skip_rgb=" + (skipRgb ? "1" : "0"));
}

} // namespace misterplex
