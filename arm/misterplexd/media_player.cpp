#include "media_player.hpp"
#include "log_redact.hpp"

#include "libmisterplex/audio_delay.hpp"
#include "libmisterplex/av_clock.hpp"
#include "libmisterplex/ffmpeg_vf.hpp"
#include "libmisterplex/frame_ledger.hpp"
#include "libmisterplex/supply_bucket.hpp"
#include "libmisterplex/idle_screen.hpp"
#include "libmisterplex/last_frame_latch.hpp"
#include "libmisterplex/osd_menu.hpp"
#include "libmisterplex/h264_nal_dispatch.hpp"
#include "libmisterplex/h264_recon.hpp"
#include "libmisterplex/raw_video_pipe.hpp"
#include "libmisterplex/yuv420p_chroma_health.hpp"
#include "libmisterplex/publish_interval_ledger.hpp"
#include "libmisterplex/publish_swap_delta_ledger.hpp"
#include <algorithm>
#include <atomic>
#include <cctype>
#include <cerrno>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <chrono>
#include <exception>
#include <signal.h>
#include <time.h>
#include <vector>

#include <fcntl.h>
#include <poll.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <unistd.h>

namespace misterplex {
namespace {

// Telemetry rates must be evidence-grade. NEVER truncate with string.substr(0,4):
// std::to_string(23.9694) and std::to_string(23.9111) both become "23.9", which over
// a 360 s soak is a ±36 frame ambiguity (parent DEFECT 1). Prefer exact counters
// (frames=/presents=/wall_ms=) and print rates with enough decimals to resolve
// single-frame deficits (1/360 s ≈ 0.0028 fps → %.4f).
inline std::string fmtFpsRate(double v) {
    char buf[32];
    std::snprintf(buf, sizeof(buf), "%.4f", v);
    return std::string(buf);
}
inline std::string fmtSec3(double v) {
    char buf[32];
    std::snprintf(buf, sizeof(buf), "%.3f", v);
    return std::string(buf);
}

// Steady-clock ms since epoch — shared axis for startup cluster instrumentation.
// wall_s is session-relative (only after sessionOriginMonoMs_ is armed). mono_ms
// is always available so first_audio_pcm (pre-origin) and first_video share one axis.
inline int64_t steadyMonoMs() {
    return std::chrono::duration_cast<std::chrono::milliseconds>(
               std::chrono::steady_clock::now().time_since_epoch())
        .count();
}

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
    const int w = g.coded_width.get();
    const int h = g.coded_height.get();
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

bool ffmpegHasAudioStream(const std::string& ffmpeg, const std::string& url,
                          const std::string& headers, int64_t startMs) {
    std::vector<std::string> args;
    args.push_back(ffmpeg);
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
    args.push_back("-map");
    args.push_back("0:a:0");
    args.push_back("-frames:a");
    args.push_back("1");
    args.push_back("-f");
    args.push_back("null");
    args.push_back("-");

    pid_t pid = fork();
    if (pid < 0)
        return true; // fail open: do not suppress product audio just because probe fork failed
    if (pid == 0) {
        int devnull = ::open("/dev/null", O_WRONLY);
        if (devnull >= 0) {
            dup2(devnull, STDOUT_FILENO);
            dup2(devnull, STDERR_FILENO);
            if (devnull != STDOUT_FILENO && devnull != STDERR_FILENO)
                ::close(devnull);
        }
        for (int fd = 3; fd < 256; ++fd)
            ::close(fd);
        std::vector<char*> argv;
        argv.reserve(args.size() + 1);
        for (const auto& s : args)
            argv.push_back(const_cast<char*>(s.c_str()));
        argv.push_back(nullptr);
        execv(args[0].c_str(), argv.data());
        _exit(127);
    }
    int st = 0;
    while (waitpid(pid, &st, 0) < 0) {
        if (errno == EINTR)
            continue;
        return true;
    }
    return WIFEXITED(st) && WEXITSTATUS(st) == 0;
}
class FpgaBitstreamProducer final : public h264stream::IBitstreamProducer {
public:
    explicit FpgaBitstreamProducer(FpgaSpi& fpga) : fpga_(fpga) {}

    h264stream::ControlResult begin(uint64_t session_id) override {
        if (active_)
            return h264stream::ControlResult::ActiveSession;
        if (!fpga_.ok() || !fpga_.beginBitstreamSession(session_id, 250))
            return h264stream::ControlResult::Fatal;
        session_id_ = session_id;
        producer_seq_ = 0;
        consumer_seq_ = 0;
        bytes_accepted_ = 0;
        nal_accepted_ = 0;
        desync_count_ = 0;
        last_bad_seq_ = 0;
        active_ = true;
        paused_ = false;
        return h264stream::ControlResult::Ok;
    }

    h264stream::PushResult pushNal(const h264stream::NalView& nal) override {
        if (!active_ || nal.session_id != session_id_ || !nal.annexb || nal.len == 0)
            return h264stream::PushResult::Fatal;
        if (nal.seq != producer_seq_) {
            ++desync_count_;
            last_bad_seq_ = nal.seq;
            return h264stream::PushResult::Desync;
        }
        // Contract: copy-on-push. The caller may reuse the demux accumulator as
        // soon as this function returns, even if a future transport is DMA-backed.
        std::vector<uint8_t> copy(nal.annexb, nal.annexb + nal.len);
        FpgaSpi::BitstreamNal fpgaNal;
        fpgaNal.session_id = nal.session_id;
        fpgaNal.seq = nal.seq;
        fpgaNal.nal_type = nal.nal_type;
        fpgaNal.annexb = copy.data();
        fpgaNal.len = copy.size();
        const auto r = fpga_.pushBitstreamNal(fpgaNal, 0);
        if (r == FpgaSpi::BitstreamPushResult::Full)
            return h264stream::PushResult::Full;
        if (r == FpgaSpi::BitstreamPushResult::Desync) {
            syncStatus();
            return h264stream::PushResult::Desync;
        }
        if (r != FpgaSpi::BitstreamPushResult::Ok)
            return h264stream::PushResult::Fatal;
        ++producer_seq_;
        bytes_accepted_ += copy.size();
        ++nal_accepted_;
        return h264stream::PushResult::Ok;
    }

    h264stream::ControlResult flush(uint64_t session_id) override {
        if (!active_ || session_id != session_id_)
            return h264stream::ControlResult::NoSession;
        if (!fpga_.flushBitstreamSession(session_id, 250))
            return h264stream::ControlResult::Fatal;
        consumer_seq_ = producer_seq_;
        return h264stream::ControlResult::Ok;
    }

    h264stream::ControlResult end(uint64_t session_id) override {
        if (!active_ || session_id != session_id_)
            return h264stream::ControlResult::NoSession;
        if (!fpga_.endBitstreamSession(session_id, 250))
            return h264stream::ControlResult::Fatal;
        active_ = false;
        paused_ = false;
        return h264stream::ControlResult::Ok;
    }

    h264stream::ControlResult pause(uint64_t session_id) override {
        if (!active_ || session_id != session_id_)
            return h264stream::ControlResult::NoSession;
        if (!fpga_.pauseBitstreamSession(session_id, 250))
            return h264stream::ControlResult::Fatal;
        paused_ = true;
        return h264stream::ControlResult::Ok;
    }

    h264stream::ControlResult resume(uint64_t session_id) override {
        if (!active_ || session_id != session_id_)
            return h264stream::ControlResult::NoSession;
        if (!fpga_.resumeBitstreamSession(session_id, 250))
            return h264stream::ControlResult::Fatal;
        paused_ = false;
        return h264stream::ControlResult::Ok;
    }

    h264stream::Telemetry status() const override {
        h264stream::Telemetry t;
        t.session_id = session_id_;
        t.bytes_accepted = bytes_accepted_;
        t.nal_accepted = nal_accepted_;
        t.producer_seq = producer_seq_;
        t.consumer_seq = consumer_seq_;
        t.desync_count = desync_count_;
        t.last_bad_seq = last_bad_seq_;
        t.active = active_;
        t.paused = paused_;
        FpgaSpi::BitstreamStatus s;
        if (fpga_.readBitstreamStatus(s)) {
            t.session_id = s.session_id ? s.session_id : t.session_id;
            t.ring_level_bytes = s.ring_level;
            t.ring_capacity_bytes = s.ring_capacity;
            t.consumer_seq = s.consumer_seq;
            t.underrun_count = s.underrun_count;
            t.overrun_count = s.overrun_count;
            t.desync_count = s.desync_count;
            t.last_bad_seq = s.last_bad_seq;
            t.active = s.active;
            t.paused = s.paused;
        }
        return t;
    }

private:
    void syncStatus() {
        FpgaSpi::BitstreamStatus s;
        if (!fpga_.readBitstreamStatus(s))
            return;
        consumer_seq_ = s.consumer_seq;
        desync_count_ = s.desync_count;
        last_bad_seq_ = s.last_bad_seq;
        paused_ = s.paused;
        active_ = s.active;
    }

    FpgaSpi& fpga_;
    uint64_t session_id_ = 0;
    uint32_t producer_seq_ = 0;
    uint32_t consumer_seq_ = 0;
    uint64_t bytes_accepted_ = 0;
    uint64_t nal_accepted_ = 0;
    uint64_t desync_count_ = 0;
    uint32_t last_bad_seq_ = 0;
    bool active_ = false;
    bool paused_ = false;
};

} // namespace

void MediaPlayer::log(const std::string& s) const {
    // Central sink redaction: spawn argv is logged here; real argv passed to
    // spawnFfmpeg must remain unredacted (playback needs the true token).
    const std::string safe = redactSensitive(s);
    if (log_)
        log_(safe);
    else
        std::fprintf(stderr, "%s\n", safe.c_str());
}

PlaybackSummary MediaPlayer::lastPlaybackSummary() const {
    std::lock_guard<std::mutex> lock(summaryMu_);
    return lastSummary_;
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

void MediaPlayer::setFfmpegScaleMode(std::string mode) {
    // Unknown tokens collapse to "always" inside parseFfmpegScaleMode — keep raw for logs.
    if (mode.empty())
        mode = "always";
    ffmpegScaleMode_ = std::move(mode);
}

void MediaPlayer::setFfmpegSwsFlags(std::string flags) {
    if (!flags.empty() && !swsFlagsTokenOk(flags)) {
        log("media: FFMPEG_SWS_FLAGS rejected (charset); keeping empty/default");
        ffmpegSwsFlags_.clear();
        return;
    }
    ffmpegSwsFlags_ = std::move(flags);
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

void MediaPlayer::setOsdControlMode(OsdControlMode mode) { osdMode_ = mode; }

bool MediaPlayer::osdApplyActive() const {
    return osdApplyWanted(osdMode_,
                          static_cast<OsdCapability>(osdCapability_.load()));
}

void MediaPlayer::startOsdPoll() {
    std::lock_guard<std::mutex> lk(osdMu_);
    if (shuttingDown_.load())
        return;
    // ForcedOff: never probe, but still surface the inert state on HDMI once.
    if (!osdPollWanted(osdMode_)) {
        osdCapability_.store(static_cast<int>(OsdCapability::Absent));
        if (!osdInertNotified_.exchange(true)) {
            log("media: OSD F12 inert mode=off capability=absent — Idle Screen menu "
                "does nothing; use IDLE_SCREEN conf");
            overlay_.flashNotice(osdInertUserNotice());
            if (!playing_.load())
                paintIdle();
        }
        return;
    }
    // Auto/On: probe live CONF_STR (generation) then poll status word.
    if (osdRun_.exchange(true))
        return;
    if (osdThr_.joinable())
        osdThr_.join();
    osdCapability_.store(static_cast<int>(OsdCapability::Unknown));
    osdInertNotified_.store(false);
    osdThr_ = std::thread([this] {
        bool confstrLogged = false;
        bool transportLogged = false;
        bool applyLogged = false;
        const auto t0 = std::chrono::steady_clock::now();
        const double startMs =
            std::chrono::duration<double, std::milli>(t0.time_since_epoch()).count();
        while (osdRun_.load()) {
            // 1) Generation proof: UIO_GET_STRING CONF_STR (once classified, stick).
            //    Auto apply is gated on V3Idle only — never on PLXS alone.
            {
                const auto cur = static_cast<OsdCapability>(osdCapability_.load());
                if (cur == OsdCapability::Unknown) {
                    std::string confstr;
                    bool gotStr = false;
                    {
                        std::lock_guard<std::mutex> lk(presentMu_);
                        if (fpga_.ok())
                            gotStr = fpga_.getConfigString(confstr);
                    }
                    if (gotStr) {
                        const auto gen = classifyOsdConfStr(confstr);
                        osdCapability_.store(static_cast<int>(gen));
                        if (!confstrLogged) {
                            confstrLogged = true;
                            std::string detail;
                            if (gen == OsdCapability::V3Idle) {
                                detail = std::string("marker=") + kOsdIdleScreenConfMarker;
                            } else if (confStrHasPreV3Markers(confstr)) {
                                detail = "pre_v3_markers=Pattern|ContentFPS";
                            } else {
                                detail = "no_idle_screen_marker";
                            }
                            log(std::string("media: OSD confstr gen=") + osdCapabilityName(gen) +
                                " " + detail);
                        }
                    }
                }
            }

            const auto cap = static_cast<OsdCapability>(osdCapability_.load());

            // 2) Status word transport: mailbox preferred; SPI only when allowed.
            uint16_t word = 0;
            bool got = false;
            bool viaMailbox = false;
            {
                std::lock_guard<std::mutex> lk(presentMu_);
                if (fpga_.readOsdMailbox(word)) {
                    got = true;
                    viaMailbox = true;
                } else if (osdSpiStatusWanted(osdMode_, cap) && fpga_.ok()) {
                    // SPI status is safe once CONF_STR proved V3Idle, or ForcedOn.
                    // Auto+PreV3 must never read/apply these bits via SPI.
                    uint8_t raw[16]{};
                    if (fpga_.getCoreStatus(raw)) {
                        word = static_cast<uint16_t>(raw[0] | (raw[1] << 8));
                        got = true;
                    }
                }
            }

            // Auto: fail closed when probe window elapses without confstr class.
            if (osdMode_ == OsdControlMode::Auto) {
                const double nowMs = std::chrono::duration<double, std::milli>(
                                         std::chrono::steady_clock::now().time_since_epoch())
                                         .count();
                const auto cur = static_cast<OsdCapability>(osdCapability_.load());
                const auto settled = osdAutoSettle(cur, startMs, nowMs);
                if (settled != cur) {
                    osdCapability_.store(static_cast<int>(settled));
                    if (settled == OsdCapability::Absent && !confstrLogged) {
                        confstrLogged = true;
                        log("media: OSD confstr gen=absent — UIO_GET_STRING not readable "
                            "within probe window; F12 Idle stays disabled (fail closed)");
                    }
                }
            }

            if (got && !transportLogged) {
                transportLogged = true;
                log(std::string("media: OSD status via=") + (viaMailbox ? "mailbox" : "spi") +
                    " capability=" +
                    osdCapabilityName(static_cast<OsdCapability>(osdCapability_.load())));
            }

            // One-shot user-visible notice when F12 cannot drive the daemon.
            {
                const auto c = static_cast<OsdCapability>(osdCapability_.load());
                const bool settledInert =
                    !osdApplyActive() &&
                    (osdMode_ == OsdControlMode::ForcedOff || c == OsdCapability::Absent ||
                     c == OsdCapability::PreV3);
                if (settledInert && !osdInertNotified_.exchange(true)) {
                    log(std::string("media: OSD F12 inert mode=") + osdControlModeName(osdMode_) +
                        " capability=" + osdCapabilityName(c) +
                        " — Idle Screen menu does nothing; use IDLE_SCREEN conf");
                    overlay_.flashNotice(osdInertUserNotice());
                    if (!playing_.load())
                        paintIdle();
                }
            }

            if (got && osdApplyActive()) {
                if (!applyLogged) {
                    applyLogged = true;
                    log(std::string("media: OSD apply enabled mode=") +
                        osdControlModeName(osdMode_) + " capability=" +
                        osdCapabilityName(static_cast<OsdCapability>(osdCapability_.load())) +
                        " via=" + (viaMailbox ? "mailbox" : "spi"));
                }
                const uint16_t prev = lastOsd_.load();
                const bool seenBefore = osdSeen_.exchange(true);
                if (!seenBefore || osdChanged(prev, word)) {
                    lastOsd_.store(word);
                    // First word: apply persisted F12 Idle Screen (Main CFG).
                    // Later: idle only when [15:14] change. See shouldApplyOsdIdle.
                    applyOsd(word, shouldApplyOsdIdle(seenBefore, prev, word));
                }
            }
            // Mailbox is free to poll. SPI parks Main — keep that path slow.
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

void MediaPlayer::applyOsd(uint16_t word, bool applyIdle) {
    ignoreInputUntilMs_.store(steadyMs() + 300);
    const OsdSettings s = decodeOsdWord(word);
    setAvOffsetMs(s.avOffsetMs);
    // Takes effect on the next session: the feed rate is captured when audioPump
    // opens MrAudio, and re-timing it mid-stream would step the audio clock.
    setAudioClockTrimEnabled(s.audioClockTrimEnabled);
    setResyncDropMs(s.resyncEnabled ? kDefaultResyncDropMs : 0);
    if (applyIdle) {
        const IdleMode im = idleModeFromBits(static_cast<unsigned>(s.idleMode));
        const bool idleChanged = im != idleMode();
        setIdleMode(im);
        if (idleChanged)
            idleLogged_.store(false);
        if (idleChanged && !playing_.load())
            paintIdle();
    }
    log("media: OSD word=0x" + hex16(word) + " av_offset_ms=" + std::to_string(s.avOffsetMs) +
        " clock_ppm=" + std::to_string(audioClockPpm_) +
        " resync=" + (s.resyncEnabled ? "on" : "off") +
        " idle=" + std::to_string(s.idleMode) + (applyIdle ? "" : " (idle unchanged)"));
}

bool MediaPlayer::publishDdrFrame(const DdrPublishFrame& frame, const char* context,
                                  std::string* err) {
    DdrPublishPlan plan{};
    std::string localErr;
    if (!makeDdrPublishPlan(frame, ddrBank_, plan, &localErr)) {
        if (err)
            *err = std::string(context ? context : "DDR") + ": " + localErr;
        return false;
    }
    // Late-arrival vs late-observation: stamp immediately BEFORE the DDR/SPI
    // write and immediately AFTER it returns. Intervals use pre-to-pre (arrival);
    // write_us=post-pre discriminates blocking inside the write (parent 2026-08-01).
    const auto tPre = std::chrono::steady_clock::now();
    const bool ok = fpga_.publishDdrFrame(frame, ddrBank_);
    const auto tPost = std::chrono::steady_clock::now();
    // Advance from the bank actually written (PLXD may override the hint).
    if (ok) {
        ddrBank_ = nextDdrPresentBank(fpga_.lastPublishedBank(), true);
        const int64_t preUs = std::chrono::duration_cast<std::chrono::microseconds>(
                                  tPre.time_since_epoch())
                                  .count();
        const int64_t postUs = std::chrono::duration_cast<std::chrono::microseconds>(
                                   tPost.time_since_epoch())
                                   .count();
        pubInterval_.note(preUs, postUs);
        // PLXD frames_done from bank-select read already done inside sendDdrFrame.
        BankReleaseStatus brs{};
        if (fpga_.lastPublishBankRelease(brs)) {
            pubSwapDelta_.note(preUs, brs.frames_done,
                               static_cast<uint8_t>(brs.swap_pending ? 1 : 0),
                               brs.free_bank_mask, brs.disp_bank);
        }
        // Optional mid-session sample (env): every 240 successful pubs (~10s @24).
        static const bool kLogMid = [] {
            const char* e = std::getenv("MISTERPLEX_PUBLISH_INTERVAL_LOG");
            return e && e[0] && e[0] != '0';
        }();
        if (kLogMid && (pubInterval_.count % 240) == 0) {
            log(std::string("media: ") + pubInterval_.formatSummaryLine("measured") +
                " phase=mid");
            log(std::string("media: ") + pubInterval_.formatDiscLine() + " phase=mid");
            log(std::string("media: ") + pubSwapDelta_.formatSummaryLine("measured") +
                " phase=mid");
            log(std::string("media: ") + pubSwapDelta_.formatCompatAliasLine() +
                " phase=mid");
        }
    }
    if (!ok && err)
        *err = fpga_.lastError();
    return ok;
}

void MediaPlayer::paintIdle() {
    const IdleMode m = idleMode();
    if (m == IdleMode::LastFrame)
        return;
    const int w = 320;
    const int h = 240;
    std::vector<uint8_t> buf(static_cast<size_t>(w) * h * 3);
    renderIdleRgb24(buf.data(), w, h, m, idlePhase_.load());
    // Composite F12-inert / transport notice onto idle RGB (HDMI-visible without logs).
    overlay_.renderRgb24(buf.data(), w, h);

    std::lock_guard<std::mutex> lk(presentMu_);
    if (fb_.ok() && !fb_.blitRgb24(buf.data(), w, h))
        log("media: idle fb0 blit failed");
    // F1 latches the last frame written, so the frame store must be repainted too.
    // C3 frame-store DDR is YUV-only, so encode the same idle renderer as I420
    // instead of ringing the doorbell with an RGB payload.
    if (!fpga_.ok() && presentMode_ != "none") {
        if (fpga_.open()) {
            useDdrF1_ = true;
            ddrBank_ = 0;
            log("media: idle FPGA frame path OK (painting core frame store)");
        } else if (!idleWarned_.exchange(true)) {
            log("media: ERROR idle cannot open FPGA (PRESENT=" + presentMode_ + "): " +
                fpga_.lastError() +
                " — menu Idle Screen changes will not appear on HDMI");
        }
    }
    if (fpga_.ok()) {
        bool ok = false;
        std::string ddrErr;
        if (useDdrF1_) {
            const DdrFrameGeometry g = plex480pDdrFrameGeometry();
            const int cw = g.coded_width.get();
            const int ch = g.coded_height.get();
            const DdrFrameLayout layout =
                makeDdrFrameLayout(g, kDdrFramePhysBase, kDdrFrameStrideAlign,
                                   DdrFrameFormat::Yuv420p);
            std::vector<uint8_t> yuv(layout.frame_bytes);
            bool haveYuv = false;
            // When a notice banner is up, render idle+overlay at coded size in RGB
            // then convert so HDMI (DDR path) shows the same banner as fb0.
            if (overlay_.visible()) {
                std::vector<uint8_t> rgb(static_cast<size_t>(cw) * ch * 3);
                renderIdleRgb24(rgb.data(), cw, ch, m, idlePhase_.load());
                overlay_.renderRgb24(rgb.data(), cw, ch);
                // RGB24 → planar YUV420 using the same coeffs as idle_screen.
                uint8_t* yPlane = yuv.data();
                uint8_t* uPlane = yPlane + static_cast<size_t>(cw) * ch;
                uint8_t* vPlane = uPlane + static_cast<size_t>(cw / 2) * (ch / 2);
                for (int y = 0; y < ch; ++y) {
                    for (int x = 0; x < cw; ++x) {
                        const size_t i = (static_cast<size_t>(y) * cw + x) * 3;
                        yPlane[static_cast<size_t>(y) * cw + x] =
                            idleRgbToY(rgb[i], rgb[i + 1], rgb[i + 2]);
                    }
                }
                for (int cy = 0; cy < ch / 2; ++cy) {
                    for (int cx = 0; cx < cw / 2; ++cx) {
                        int rSum = 0, gSum = 0, bSum = 0;
                        for (int dy = 0; dy < 2; ++dy) {
                            for (int dx = 0; dx < 2; ++dx) {
                                const size_t i =
                                    (static_cast<size_t>(cy * 2 + dy) * cw + (cx * 2 + dx)) * 3;
                                rSum += rgb[i];
                                gSum += rgb[i + 1];
                                bSum += rgb[i + 2];
                            }
                        }
                        const int r = (rSum + 2) / 4;
                        const int g = (gSum + 2) / 4;
                        const int b = (bSum + 2) / 4;
                        const size_t ci = static_cast<size_t>(cy) * (cw / 2) + cx;
                        uPlane[ci] = idleRgbToU(r, g, b);
                        vPlane[ci] = idleRgbToV(r, g, b);
                    }
                }
                haveYuv = true;
            } else {
                haveYuv = renderIdleYuv420p(yuv.data(), cw, ch, m, idlePhase_.load());
            }
            if (haveYuv) {
                DdrPublishFrame frame{yuv.data(), yuv.size(), g, DdrFrameFormat::Yuv420p};
                ok = publishDdrFrame(frame, "idle DDR", &ddrErr);
            }
        }
        if (!ok) {
            if (!idleWarned_.exchange(true))
                log("media: idle paint DDR failed (will retry on re-probe): " +
                    (ddrErr.empty() ? fpga_.lastError() : ddrErr));
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

void MediaPlayer::setDecodeSize(CodedWidth cw, CodedHeight ch) {
    int w = cw.get();
    int h = ch.get();
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

void MediaPlayer::setDecodeSizeSource(const std::string& src) {
    if (src.empty())
        decodeSizeSource_ = "default";
    else if (src.rfind("cli:", 0) == 0 || src == "cli:--decode" || src == "argv")
        decodeSizeSource_ = "caller_supplied";
    else if (src.rfind("conf:", 0) == 0)
        decodeSizeSource_ = src; // keep conf path for audit
    else
        decodeSizeSource_ = src;
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
    if (presentMode_ == "none") {
        log("media: PRESENT=none decode-only path (test/lab; no fb0 or FPGA writes)");
        return true;
    }
    if (presentMode_.empty())
        presentMode_ = "fpga";

    // fb0/both still open Linux fb0. The Plex *core* HDMI path always needs the
    // FPGA DDR frame store for idle/OSD paint — PRESENT=fb0 used to skip
    // fpga_.open() and left the last latched image forever (user-reported twice).
    const bool wantFb = (presentMode_ == "fb0" || presentMode_ == "both");
    const bool wantFpga = true; // every non-none PRESENT must open FPGA for core scanout

    if (presentMode_ == "fb0") {
        log("media: PRESENT=fb0 — also opening FPGA frame path (core HDMI idle/OSD need "
            "DDR; fb0 blit alone does not update Plex core scanout)");
    }

    bool any = false;
    bool fpgaOk = false;
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
            useDdrF1_ = true;
            ddrBank_ = 0;
            fpgaOk = true;
            log("media: FPGA frame path OK (PRESENT=" + presentMode_ + " → DDR YUV420p)");
            // Write PLXD (dormant) to the bitstream ring CTRL so that a DDR probe
            // can distinguish "producer disabled by config" from uninitialised DDR
            // residue. The FPGA reader ignores PLXD; this is diagnostic only.
            if (!streamEnabled_) {
                if (fpga_.publishBitstreamDormant())
                    log("media: DDR bitstream CTRL=PLXD (STREAM=0, producer dormant)");
                else
                    log("media: DDR bitstream dormant publish failed: " + fpga_.lastError());
            }
            // Legacy (pre-v3) core only: park the debug bits so a stale saved OSD
            // cannot steal cast frames. On a v3 core those same bits ARE the A/V
            // offset menu item, so zeroing them would silently reset the user's
            // setting on every startup. Only park when OSD apply is forced off —
            // Auto still probing must not touch A/V offset bits on a live v3 core.
            if (osdMode_ == OsdControlMode::ForcedOff) {
                const int park[] = {6, 0, 7, 0, 8, 0, 9, 0};
                if (!fpga_.setStatusBits(park, 4))
                    log("media: park OSD (None/tone-off): " + fpga_.lastError());
                else
                    log("media: park OSD — Pattern=None, audio tone Off, force bars No");
            }
            any = true;
        } else {
            log("media: ERROR FPGA SPI unavailable (PRESENT=" + presentMode_ + "): " +
                fpga_.lastError() +
                " — core HDMI idle screen and F12 Idle Screen menu cannot repaint "
                "the DDR frame store. Load Plex.rbf, check SPI/uio, or set "
                "PRESENT=none for decode-only lab.");
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
    // Product PRESENT=fpga|both: FPGA is mandatory (HDMI is the core, not fb0).
    if (!fpgaOk && (presentMode_ == "fpga" || presentMode_ == "both")) {
        std::lock_guard<std::mutex> lock(mu_);
        lastError_ = "FPGA present path required for PRESENT=" + presentMode_;
        return false;
    }
    if (!any) {
        std::lock_guard<std::mutex> lock(mu_);
        lastError_ = "no present path (fb0/fpga)";
        return false;
    }
    if (!fpgaOk) {
        // PRESENT=fb0 with no FPGA: companion/fb0 may work; core idle stays frozen.
        log("media: ERROR PRESENT=" + presentMode_ +
            " without FPGA — idle-mode rotation on the Plex core will stay stuck on "
            "the last latched frame. Fix PRESENT/SPI or expect a frozen logo.");
    }
    return true;
}

void MediaPlayer::signalChildren(int sig) {
    // Pause/resume RGB/audio FFmpeg. STREAM demux stays alive on pause.
    pid_t p = childPid_.load();
    if (p > 0)
        kill(-p, sig);
    pid_t sp = streamPid_.load();
    // Do not SIGSTOP the H.264 source demux on pause: PMS can tear down an HTTP
    // transcode session that stops being consumed. streamPump keeps reading and
    // drops NALs while paused; the FPGA freezes on the last decoded frame.
    if (sp > 0 && sig != SIGSTOP && sig != SIGCONT)
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
    audioStartGate_.store(false);
    sessionOriginMonoMs_.store(-1, std::memory_order_release);
    firstAudioPcmMonoMs_.store(-1, std::memory_order_release);
    avAudioReleaseMonoMs_.store(-1, std::memory_order_release);
    pumpAudioReleaseMonoMs_.store(-1, std::memory_order_release);
    holdBytesAtRelease_.store(-1, std::memory_order_release);
    firstAudioQueuedGe0MonoMs_.store(-1, std::memory_order_release);
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

void MediaPlayer::armProcessEpoch(uint64_t epochMonoMs) {
    // Once per process. 0 is reserved as "unarmed".
    uint64_t expected = 0;
    if (processEpoch_.compare_exchange_strong(expected, epochMonoMs == 0 ? 1 : epochMonoMs,
                                              std::memory_order_acq_rel)) {
        log("media: process_epoch=" + std::to_string(processEpoch_.load()) +
            " tag=measured — soak windows must not span a different process_epoch");
    }
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
        // Stream generation: bump at START so telemetry session_epoch is stable
        // for the whole stream and changes on every play/seek restart.
        const uint64_t sseq = streamSeq_.fetch_add(1, std::memory_order_acq_rel) + 1;
        const uint64_t pep = processEpoch_.load(std::memory_order_acquire);
        log("media: stream_start stream_seq=" + std::to_string(sseq) +
            " process_epoch=" + std::to_string(pep) +
            " session_epoch=" + sessionEpochString(pep, sseq) +
            " tag=measured");
        // Cadence instrument (w-instr DEFECT 2/3): T_vsync / src_fps provenance.
        // Prefer host tools/measure_refresh_hz.py → MISTERPLEX_VSYNC_HZ=...
        // Without env: DEFAULT_ASSUMED 60 Hz — every hold_d is CONDITIONAL.
        pubSwapDelta_.reset();
        pubInterval_.reset();
        if (const char* vh = std::getenv("MISTERPLEX_VSYNC_HZ")) {
            char* endp = nullptr;
            const double hz = std::strtod(vh, &endp);
            if (endp != vh && hz > 1.0 && hz < 240.0) {
                pubSwapDelta_.setVsyncHzMeasured(hz);
                log("media: cadence_vsync_hz=" + std::to_string(hz) +
                    " vsync_hz_tag=measured vsync_hz_der=env_MISTERPLEX_VSYNC_HZ "
                    "hold_d_conditional=0");
            } else {
                pubSwapDelta_.setVsyncHzDefaultAssumed(60.0);
                log("media: cadence_vsync_hz=60 vsync_hz_tag=DEFAULT_ASSUMED "
                    "vsync_hz_der=fallback_bad_env hold_d_conditional=1");
            }
        } else {
            pubSwapDelta_.setVsyncHzDefaultAssumed(60.0);
            log("media: cadence_vsync_hz=60 vsync_hz_tag=DEFAULT_ASSUMED "
                "vsync_hz_der=no_MISTERPLEX_VSYNC_HZ hold_d_conditional=1");
        }
        if (const char* sf = std::getenv("MISTERPLEX_SRC_FPS")) {
            char* endp = nullptr;
            const double fps = std::strtod(sf, &endp);
            if (endp != sf && fps > 1.0 && fps < 120.0) {
                pubSwapDelta_.setSrcFpsMeasured(fps);
                log("media: cadence_src_fps=" + std::to_string(fps) +
                    " src_fps_tag=measured src_fps_der=env_MISTERPLEX_SRC_FPS");
            } else {
                pubSwapDelta_.setSrcFpsDefaultAssumed(24.0);
                log("media: cadence_src_fps=24 src_fps_tag=DEFAULT_ASSUMED "
                    "src_fps_der=fallback_bad_env_NOT_asset_probe");
            }
        } else {
            pubSwapDelta_.setSrcFpsDefaultAssumed(24.0);
            log("media: cadence_src_fps=24 src_fps_tag=DEFAULT_ASSUMED "
                "src_fps_der=no_MISTERPLEX_SRC_FPS_NOT_asset_probe");
        }
        {
            std::lock_guard<std::mutex> lock(summaryMu_);
            lastSummary_ = PlaybackSummary{};
        }
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

pid_t MediaPlayer::spawnFfmpeg(const std::vector<std::string>& args, int vWriteFd, int aWriteFd,
                               int errWriteFd) {
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

        // Prefer caller stderr pipe (geometry banners). Else lab USB file /dev/null.
        int errfd = errWriteFd;
        if (errfd < 0) {
            errfd = ::open("/media/usb0/misterplex-lab/logs/ffmpeg.err",
                           O_WRONLY | O_CREAT | O_TRUNC, 0644);
            if (errfd < 0)
                errfd = ::open("/dev/null", O_WRONLY);
        }
        if (errfd >= 0) {
            if (errfd != STDERR_FILENO)
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

void MediaPlayer::ffmpegStderrPump(int errReadFd, size_t codedFrameBytes, bool identitySkip) {
    if (errReadFd < 0)
        return;
    std::string acc;
    char buf[512];
    int lastInW = 0, lastInH = 0;
    int lastOutW = 0, lastOutH = 0;
    for (;;) {
        const ssize_t n = ::read(errReadFd, buf, sizeof(buf));
        if (n < 0) {
            if (errno == EINTR)
                continue;
            break;
        }
        if (n == 0)
            break;
        acc.append(buf, static_cast<size_t>(n));
        for (;;) {
            // Must split on '\r' too: ffmpeg -stats uses CR progress updates.
            // Splitting only on '\n' leaves ffmpeg_out_frames=NO-DATA all soak.
            std::string line;
            if (!misterplex::takeFfmpegStderrLine(acc, &line))
                break;
            if (line.empty())
                continue;
            // Capture ffmpeg frame= into atomic; do not log every stats line (spam).
            // Parent glass-loss split needs ffmpeg_out_frames vs frameIndex.
            {
                int64_t ff = 0;
                if (misterplex::parseFfmpegFrameCountLine(line, &ff)) {
                    ffmpegOutFrames_.store(ff, std::memory_order_relaxed);
                    continue;
                }
            }
            if (line.find("fps=") != std::string::npos && line.find("Stream") == std::string::npos)
                continue;
            // Content fps from Stream banner (same line family as geometry). Prefer
            // "N fps"; tbr only if fps absent. Do not invent 24 (ERROR 17).
            {
                const auto fr = parseFfmpegStreamFpsLine(line);
                if (fr.ok && fr.num > 0 && fr.den > 0) {
                    const int prevN = measuredFpsNum_.load(std::memory_order_relaxed);
                    const int prevD = measuredFpsDen_.load(std::memory_order_relaxed);
                    if (prevN != fr.num || prevD != fr.den) {
                        measuredFpsNum_.store(fr.num, std::memory_order_relaxed);
                        measuredFpsDen_.store(fr.den, std::memory_order_relaxed);
                        log(std::string("media: MEASURED_FPS fps=") +
                            std::to_string(fr.num) + "/" + std::to_string(fr.den) +
                            " src=ffmpeg_banner token=" +
                            std::string(fr.from_tbr ? "tbr" : "fps") +
                            " tag=measured");
                        if (fpsNum_ > 0 && fpsDen_ > 0 &&
                            !misterplex::supplyFpsRationalsAgree(fpsNum_, fpsDen_, fr.num,
                                                                fr.den)) {
                            log("ERROR media: FPS_MISMATCH caller=" +
                                std::to_string(fpsNum_) + "/" + std::to_string(fpsDen_) +
                                " measured=" + std::to_string(fr.num) + "/" +
                                std::to_string(fr.den) +
                                " — supply_gap will refuse until rates agree "
                                "tag=measured");
                        }
                    }
                }
            }
            const auto g = parseFfmpegGeometryLine(line);
            if (!g.ok)
                continue;
            // Classify: lines under Output # are post-filter; Input/Stream Video
            // without Output are pre-filter delivery.
            const bool outish =
                g.is_output || line.find("Output") != std::string::npos ||
                line.find("rawvideo") != std::string::npos;
            if (outish) {
                if (g.w == lastOutW && g.h == lastOutH)
                    continue;
                lastOutW = g.w;
                lastOutH = g.h;
                log("media: MEASURED_OUTPUT " + std::to_string(g.w) + "x" +
                    std::to_string(g.h) + " (post-vf rawvideo)");
                continue;
            }
            // Input / decoded delivery geometry — the B2 permanent observable.
            if (g.w == lastInW && g.h == lastInH)
                continue;
            const bool changed = (lastInW > 0 || lastInH > 0);
            lastInW = g.w;
            lastInH = g.h;
            measuredDeliveryW_.store(g.w);
            measuredDeliveryH_.store(g.h);
            // B4: only a runtime measurement upgrades verification (not library_media).
            deliveryGeometryVerified_.store(true, std::memory_order_relaxed);
            ffmpegScaleSourceW_ = g.w;
            ffmpegScaleSourceH_ = g.h;
            const size_t prodBytes = yuv420pFrameBytesWH(g.w, g.h);
            // desync_risk is real: identity_skip && measured_input_bytes != reader.
            // Product FORCE_SCALE (Always) at play-time plan uses crop+pad for an
            // *unverified* exact claim (identity_skip=0) so OUTPUT stays coded-
            // shaped without FOAR; risk stays 0 unless a verified-identity path
            // was taken and measurement later disagrees. identity_skip=1 is only
            // for verified/assume exact (or SkipIdentity+verified). Not unwired.
            const bool risk = pipeDesyncRisk(prodBytes, codedFrameBytes, identitySkip);
            if (risk)
                pipeDesyncRisk_.store(true);
            // delivered_geom: ACTUAL input WxH from ffmpeg Stream banner (stderr).
            // Derivation: parseFfmpegGeometryLine on -loglevel info "Stream #… Video: … WxH".
            // Not library metadata, not PMS /status/sessions, not the requested
            // videoResolution= query. src=ffmpeg_banner is permanent observability (B2).
            log(std::string("media: MEASURED_DELIVERY delivered_geom=") +
                std::to_string(g.w) + "x" + std::to_string(g.h) +
                " src=ffmpeg_banner" +
                " bytes=" + std::to_string(prodBytes) +
                " coded_bytes=" + std::to_string(codedFrameBytes) +
                " identity_skip=" + (identitySkip ? "1" : "0") +
                " desync_risk=" + (risk ? "1" : "0") +
                " delivery_verified=1 delivery_basis=measured" +
                (changed ? " MID_STREAM_CHANGE=1" : " MID_STREAM_CHANGE=0") +
                " tag=measured" +
                (changed ? " — size changed after play start" : ""));
            if (risk) {
                log("ERROR media: PIPE_DESYNC_RISK measured=" + std::to_string(g.w) + "x" +
                    std::to_string(g.h) + " producer_bytes=" + std::to_string(prodBytes) +
                    " reader_bytes=" + std::to_string(codedFrameBytes) +
                    " identity_skip=1 tag=measured — raw pipe will phase-walk; force scale");
            }
            if (changed) {
                // Play-time GEOM / vf plan is fixed for the session. Unverified
                // exact under Always uses crop+pad (not identity_skip) so the
                // filter still emits coded WxH when input is large enough to crop;
                // identity_skip cannot rebuild if it was taken. Surface loudly.
                log("ERROR media: MEASURED_DELIVERY mid-stream change — play-time "
                    "geometry guard cannot rebuild vf; identity_skip=" +
                    std::string(identitySkip ? "1" : "0") +
                    " (crop+pad/scale pin OUTPUT only while those filters stay live)");
            }
        }
    }
    // EOF: final stats line may lack a trailing separator.
    if (!acc.empty()) {
        int64_t ff = 0;
        if (misterplex::parseFfmpegFrameCountLine(acc, &ff))
            ffmpegOutFrames_.store(ff, std::memory_order_relaxed);
    }
    ::close(errReadFd);
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
    // Portable adelay=N|N (see libmisterplex/audio_delay.hpp). Conf intent is
    // logged here; audioPump measures pcm_silence_head_ms on the wire.
    args.push_back(misterplex::ffmpegAudioDelayFilter(audioDelayMs_));
    if (audioDelayMs_ > 0)
        log("media: ffmpeg adelay_ms=" + std::to_string(audioDelayMs_) +
            " filter=" + misterplex::ffmpegAudioDelayFilter(audioDelayMs_));
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

    auto formatDdrBitstreamStatus = [](const FpgaSpi::BitstreamStatus& st) {
        if (st.dormant)
            return std::string("ddr_status=DORMANT (STREAM=0, PLXD)");
        return std::string("ddr_status session=") + std::to_string(st.session_id) +
               " active=" + (st.active ? "1" : "0") +
               " paused=" + (st.paused ? "1" : "0") +
               " ring=" + std::to_string(st.ring_level) + "/" +
               std::to_string(st.ring_capacity) +
               " producer_bytes=" + std::to_string(st.producer_count) +
               " consumer_bytes=" + std::to_string(st.consumer_count) +
               " consumer_seq=" + std::to_string(st.consumer_seq) +
               " underrun=" + std::to_string(st.underrun_count) +
               " overrun=" + std::to_string(st.overrun_count) +
               " desync=" + std::to_string(st.desync_count) +
               " last_bad_seq=" + std::to_string(st.last_bad_seq) +
               " flags=u" + (st.underrun ? "1" : "0") +
               "o" + (st.overrun ? "1" : "0") +
               "d" + (st.desync ? "1" : "0") +
               "f" + (st.fatal ? "1" : "0");
    };
    auto readDdrBitstreamStatusString = [&]() {
        FpgaSpi::BitstreamStatus st;
        if (!fpga_.readBitstreamStatus(st))
            return std::string("ddr_status=unreadable err=") + fpga_.lastError();
        return formatDdrBitstreamStatus(st);
    };

    streamActive_.store(true);
    reconFrames_.store(0);
    reconPresentOk_.store(false);
    // cabacSkip_ is session-level (cleared in play()); do not clear here on mid-session re-entry.
    log(std::string("media: STREAM=1 host I-slice recon") +
        (wantF1 ? " →F1" : "") + (wantF3 ? " +DDR-bitstream" : "") +
        (reconToFb ? " +fb0" : ""));

    // Bound NAL scan buffer (SPS+PPS+IDR can be large at 720p; cap for dual-A9)
    constexpr size_t kMaxAcc = 2 * 1024 * 1024;
    std::vector<uint8_t> acc;
    acc.reserve(64 * 1024);
    // Last complete NAL start (start-code index) still in acc; incomplete NAL retained
    size_t parseFrom = 0;

    FpgaBitstreamProducer f3Producer(fpga_);
    h264stream::DispatchConfig f3Cfg;
    f3Cfg.max_full_retries = 50;    // Full is transient: retry for ~100 ms.
    f3Cfg.full_retry_sleep_ms = 2;
    h264stream::NalDispatcher f3Dispatch(f3Producer, f3Cfg);
    bool f3Active = false;
    bool f3Fatal = false;
    bool f3Paused = false;
    static std::atomic<uint64_t> nextStreamSession{1};
    const uint64_t streamSession = nextStreamSession.fetch_add(1);
    if (wantF3) {
        const auto br = f3Dispatch.begin(streamSession);
        if (br == h264stream::ControlResult::Ok) {
            f3Active = true;
            log("media: F3 NAL producer begin session=" + std::to_string(streamSession) +
                " " + readDdrBitstreamStatusString());
        } else {
            f3Fatal = true;
            log("media: F3 NAL producer begin failed " +
                std::string(h264stream::toString(br)) + " — F3 disabled");
        }
    }
    const auto streamWall0 = std::chrono::steady_clock::now();
    const int64_t streamCpu0 = threadCpuMicros();

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

    auto syncF3Pause = [&]() {
        if (!f3Active || f3Fatal)
            return;
        const bool paused = paused_.load();
        if (paused && !f3Paused) {
            const auto r = f3Dispatch.pause();
            if (r == h264stream::ControlResult::Ok) {
                f3Paused = true;
                log("media: F3 NAL producer pause session=" + std::to_string(streamSession) +
                    " (HTTP demux kept alive; FPGA holds last frame)");
            } else {
                f3Fatal = true;
                log("media: F3 NAL producer pause failed " +
                    std::string(h264stream::toString(r)));
            }
        } else if (!paused && f3Paused) {
            const auto r = f3Dispatch.resume();
            if (r == h264stream::ControlResult::Ok) {
                f3Paused = false;
                log("media: F3 NAL producer resume session=" + std::to_string(streamSession) +
                    " (SPS/PPS will replay before next VCL)");
            } else {
                f3Fatal = true;
                log("media: F3 NAL producer resume failed " +
                    std::string(h264stream::toString(r)));
            }
        }
    };

    auto pushF3Nal = [&](const uint8_t* nalSc, size_t nalLen) {
        if (!f3Active || f3Fatal || !wantF3)
            return;
        const uint64_t beforeNals = f3Dispatch.stats().nal_pushed;
        const auto r = f3Dispatch.handleNal(nalSc, nalLen);
        const auto& after = f3Dispatch.stats();
        f3Total = static_cast<size_t>(after.bytes_pushed);
        f3Pushes = static_cast<size_t>(after.nal_pushed);
        if (r == h264stream::PushResult::Ok) {
            if (after.nal_pushed != beforeNals && (after.nal_pushed % 64) == 0)
                log("media: F3 NAL stream nals=" + std::to_string(after.nal_pushed) +
                    " bytes=" + std::to_string(after.bytes_pushed));
            return;
        }
        if (r == h264stream::PushResult::Full) {
            f3Fatal = true;
            log("ERROR media: F3 NAL producer Full persisted after bounded retry; resetting session " +
                readDdrBitstreamStatusString());
        } else {
            f3Fatal = true;
            log("ERROR media: F3 NAL producer " + std::string(h264stream::toString(r)) +
                " — resetting session " + readDdrBitstreamStatusString());
        }
        if (f3Active)
            f3Dispatch.end();
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
                // Silicon canvas is always productDdrFrameStoreGeometry() (624 coded).
                // Accept any MB-aligned recon size that fits, then center-pack into
                // the compile-time bank so line stride matches RTL CODED_W.
                if (ddrFrameStoreAcceptsResolution(rec.width, rec.height)) {
                    const DdrFrameGeometry g = ddrFrameGeometryForFpgaPresent(
                        CodedWidth{rec.width}, CodedHeight{rec.height});
                    const DdrFrameLayout layout = makeDdrFrameLayout(
                        g, kDdrFramePhysBase, kDdrFrameStrideAlign, DdrFrameFormat::Yuv420p);
                    ensureYuv420p();
                    std::vector<uint8_t> bank(layout.frame_bytes);
                    if (!packYuv420pCenteredIntoCodedBank(yuv420p.data(), rec.width, rec.height,
                                                          bank.data(), g)) {
                        log("media: recon YUV420 pack into silicon canvas failed " +
                            std::to_string(rec.width) + "x" + std::to_string(rec.height));
                    } else {
                        clearYuv420pCropPadding(bank.data(), g);
                        DdrPublishFrame frame{bank.data(), bank.size(), g,
                                              DdrFrameFormat::Yuv420p};
                        std::string ddrErr;
                        std::lock_guard<std::mutex> lk(presentMu_);
                        ok = publishDdrFrame(frame, "recon DDR", &ddrErr);
                        if (!ok) {
                            log("media: recon YUV420 DDR F1 unavailable: " +
                                (ddrErr.empty() ? fpga_.lastError() : ddrErr));
                        } else if ((reconOk % 30) == 0) {
                            log("media: recon F1 via YUV420 DDR " +
                                std::to_string(rec.width) + "x" + std::to_string(rec.height) +
                                "→" + std::to_string(g.coded_width.get()) + "x" +
                                std::to_string(g.coded_height.get()) + " " +
                                std::to_string(static_cast<int>(fpga_.lastPushMs())) + "ms");
                        }
                    }
                } else if (!reconDdrMismatchLogged) {
                    reconDdrMismatchLogged = true;
                    log("ERROR media: recon F1 REFUSED: frame-store requires MB-aligned "
                        "resolution <= " + std::to_string(kDdrFrameStoreMaxWidth.get()) + "x" +
                        std::to_string(kDdrFrameStoreMaxHeight.get()) +
                        ", got " + std::to_string(rec.width) + "x" + std::to_string(rec.height) +
                        " — ALL subsequent recon frames will be SKIPPED. "
                        "This produces no video on the FPGA output.");
                } else if ((reconFrames_.load() % 300) == 0) {
                    log("media: recon F1 still skipping: " +
                        std::to_string(rec.width) + "x" + std::to_string(rec.height) +
                        " exceeds frame-store capacity");
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
                    "or inactive on PMS. Use STREAM_SKIP_RGB=0/PRESENT=both for fb0 fallback.");
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
                    " — legacy RGB F1 path is disabled; use PRESENT=both for fb0 fallback");
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
                        "inactive on PMS. Legacy RGB F1 path is disabled; STREAM still feeds F3.");
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
                pushF3Nal(acc.data() + i, nalLen);
                if (ntype == 7) {
                    // SPS alone does not change entropy mode — keep sticky CABAC.
                    spsNal.assign(acc.begin() + static_cast<std::ptrdiff_t>(i),
                                  acc.begin() + static_cast<std::ptrdiff_t>(j));
                } else if (ntype == 8) {
                    ppsNal.assign(acc.begin() + static_cast<std::ptrdiff_t>(i),
                                  acc.begin() + static_cast<std::ptrdiff_t>(j));
                    applyPpsEntropy(acc.data() + i, nalLen);
                } else if ((ntype == 5 || ntype == 1) && !paused_.load()) {
                    tryReconNal(acc.data() + i, nalLen, ntype);
                }
            }
            i = j;
            parseFrom = i;
        }
    };

    auto compactAcc = [&]() {
        // Drop fully parsed bytes; keep the trailing incomplete NAL.
        size_t drop = parseFrom;
        if (drop == 0)
            return;
        // Never drop past incomplete NAL start
        drop = std::min(drop, parseFrom);
        if (drop > 0 && drop <= acc.size()) {
            acc.erase(acc.begin(), acc.begin() + static_cast<std::ptrdiff_t>(drop));
            parseFrom -= drop;
        }
        // Hard cap
        if (acc.size() > kMaxAcc) {
            log("media: STREAM acc overflow — reset NAL state");
            acc.clear();
            parseFrom = 0;
            // Keep last SPS/PPS so multi-IDR can recover after overflow gap
        }
    };

    while (!stop_.load()) {
        syncF3Pause();
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
        compactAcc();
    }

    // EOF: process trailing NAL that has no following start code (short files / last IDR).
    // Without this, single-AU Baseline vectors never recon (IDR is last NAL).
    if (!stop_.load() && parseFrom + 3 < acc.size()) {
        size_t sc = annexBStartLen(acc.data(), acc.size(), parseFrom);
        if (sc && parseFrom + sc < acc.size()) {
            const size_t nalLen = acc.size() - parseFrom;
            const uint8_t ntype = acc[parseFrom + sc] & 0x1f;
            pushF3Nal(acc.data() + parseFrom, nalLen);
            if (ntype == 7) {
                spsNal.assign(acc.begin() + static_cast<std::ptrdiff_t>(parseFrom),
                              acc.end());
            } else if (ntype == 8) {
                ppsNal.assign(acc.begin() + static_cast<std::ptrdiff_t>(parseFrom),
                              acc.end());
                applyPpsEntropy(acc.data() + parseFrom, nalLen);
            } else if ((ntype == 5 || ntype == 1) && !paused_.load()) {
                tryReconNal(acc.data() + parseFrom, nalLen, ntype);
            }
            parseFrom = acc.size();
        }
    }

    // Flush remaining complete NALs and F3 tail (only if not mid-stop)
    if (!stop_.load()) {
        consumeCompleteNals();
    }

    FpgaSpi::BitstreamStatus ddrBeforeEnd{};
    const bool haveDdrBeforeEnd = fpga_.readBitstreamStatus(ddrBeforeEnd);
    const std::string ddrStatusBeforeEnd = haveDdrBeforeEnd
                                               ? formatDdrBitstreamStatus(ddrBeforeEnd)
                                               : (std::string("ddr_status=unreadable err=") +
                                                  fpga_.lastError());
    h264stream::Telemetry f3StatusBeforeEnd = f3Producer.status();
    if (f3Active) {
        const auto endResult = f3Dispatch.end();
        if (endResult != h264stream::ControlResult::Ok)
            log("ERROR media: F3 NAL producer end failed " +
                std::string(h264stream::toString(endResult)) + " " + ddrStatusBeforeEnd);
    }
    ::close(sfd);
    streamActive_.store(false);
    const auto streamWall1 = std::chrono::steady_clock::now();
    const int64_t streamCpu1 = threadCpuMicros();
    const int64_t streamWallMs =
        std::chrono::duration_cast<std::chrono::milliseconds>(streamWall1 - streamWall0).count();
    const int64_t streamCpuUs = std::max<int64_t>(0, streamCpu1 - streamCpu0);
    const auto f3Stats = f3Dispatch.stats();
    const auto f3Status = f3StatusBeforeEnd;
    const bool effectivelyEmptyDelivery =
        wantF3 && f3Status.bytes_accepted > 4 && haveDdrBeforeEnd &&
        ddrBeforeEnd.consumer_count <= 4;
    if (wantF3 && (f3Status.nal_accepted == 0 || f3Status.bytes_accepted <= 4 ||
                   effectivelyEmptyDelivery || f3Fatal || f3Stats.full_escalations != 0 ||
                   f3Stats.desync_or_fatal != 0)) {
        log("ERROR media: DDR bitstream zero/effectively-empty delivery "
            "accepted_nals=" + std::to_string(f3Status.nal_accepted) +
            " accepted_bytes=" + std::to_string(f3Status.bytes_accepted) +
            " dispatcher_seen=" + std::to_string(f3Stats.nal_seen) +
            " full_retries=" + std::to_string(f3Stats.full_retries) +
            " full_escalations=" + std::to_string(f3Stats.full_escalations) +
            " desync_or_fatal=" + std::to_string(f3Stats.desync_or_fatal) +
            " effectively_empty=" + (effectivelyEmptyDelivery ? "1" : "0") +
            " " + ddrStatusBeforeEnd);
    }
    log("media: STREAM end f3_bytes=" + std::to_string(f3Total) +
        " f3_nals=" + std::to_string(f3Status.nal_accepted) +
        " f3_full_retries=" + std::to_string(f3Stats.full_retries) +
        " f3_full_escalations=" + std::to_string(f3Stats.full_escalations) +
        " f3_dropped_paused=" + std::to_string(f3Stats.nal_dropped_paused) +
        " f3_desync=" + std::to_string(f3Status.desync_count) +
        " f3_last_bad_seq=" + std::to_string(f3Status.last_bad_seq) +
        " " + ddrStatusBeforeEnd +
        " stream_wall_ms=" + std::to_string(streamWallMs) +
        " stream_cpu_us=" + std::to_string(streamCpuUs) +
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

// One status-line sample for handoff boundary logs. Does not claim playback phase.
misterplex::MrAudioStatusSnap MediaPlayer::readMrAudioStatusSnap(std::string* rawOut) {
    misterplex::MrAudioStatusSnap snap{};
    const int fd = ::open(audioDev_.c_str(), O_RDONLY);
    if (fd < 0)
        return snap;
    char buf[160];
    const ssize_t n = ::read(fd, buf, sizeof(buf) - 1);
    ::close(fd);
    if (n <= 0)
        return snap;
    buf[n] = '\0';
    // Trim trailing newline for log cleanliness.
    ssize_t end = n;
    while (end > 0 && (buf[end - 1] == '\n' || buf[end - 1] == '\r')) {
        buf[end - 1] = '\0';
        --end;
    }
    if (rawOut)
        *rawOut = std::string(buf, static_cast<size_t>(end > 0 ? end : 0));
    return misterplex::parseMrAudioStatusSnap(buf, end);
}

void MediaPlayer::logMrAudioHandoffAt(const char* where) {
    // Parent A/B across clusters: pair rptr/wptr/len/comp at the same `where`.
    // If identical while HDMI sep≈117 ms, ring snapshot at this point is NOT the
    // discriminator. Does not claim lipsync; tag=measured on every field we got.
    std::string raw;
    const auto snap = readMrAudioStatusSnap(&raw);
    const int64_t mono = steadyMonoMs();
    const int64_t qms =
        (snap.len >= 0) ? (snap.len * 1000LL) / misterplex::kMrAudioBytesPerSec : -1;
    std::string plxd = " frames_done=NO-DATA";
    if (fpga_.ok()) {
        BankReleaseStatus brs;
        if (fpga_.readBankRelease(brs))
            plxd = " frames_done=" + std::to_string(static_cast<unsigned>(brs.frames_done));
        else
            plxd = " frames_done=UNREADABLE";
    }
    log(std::string("media: MrAudio handoff_at=") + (where ? where : "?") +
        " mono_ms=" + std::to_string(mono) +
        " rptr=" + std::to_string(snap.rptr) + " wptr=" + std::to_string(snap.wptr) +
        " len_B=" + std::to_string(snap.len) + " len_ms=" + std::to_string(qms) +
        " comp=" + std::to_string(snap.comp) + plxd +
        " written_B=" + std::to_string(audioBytes_.load()) +
        " raw=\"" + (raw.empty() ? std::string("NO-DATA") : raw) + "\""
        " tag=measured"
        " (post-write FPGA drain phase not in this sample)");
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
        else {
            log("media: MrAudio open — software-paced 48kHz delay_ms=" +
                std::to_string(audioDelayMs_) +
                " clock_ppm=" + std::to_string(audioClockPpm_) + " (adelay in ffmpeg if >0)");
            // Handoff boundary: last daemon-controlled store is ::write into the
            // ring. Sample status BEFORE any write so leftover depth/rptr is
            // visible. Does NOT locate the 117 ms cluster (hold falsified);
            // makes post-write-unobserved phase partially greppable.
            std::string raw;
            const auto snap = readMrAudioStatusSnap(&raw);
            const int64_t mono = steadyMonoMs();
            const int64_t qms =
                (snap.len >= 0) ? (snap.len * 1000LL) / misterplex::kMrAudioBytesPerSec : -1;
            log("media: MrAudio ring_at_open mono_ms=" + std::to_string(mono) +
                " rptr=" + std::to_string(snap.rptr) + " wptr=" + std::to_string(snap.wptr) +
                " len_B=" + std::to_string(snap.len) + " len_ms=" + std::to_string(qms) +
                " comp=" + std::to_string(snap.comp) +
                " raw=\"" + (raw.empty() ? std::string("NO-DATA") : raw) + "\""
                " tag=measured"
                " (observability ends at write+len; FPGA drain phase not logged)");
        }
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
    // Measure leading PCM silence (adelay proof on the wire). conf intent alone
    // is not enough — parent A/B saw only +33 ms of a 150 ms request.
    misterplex::SilenceHeadScan silenceScan;
    silenceScan.reset(/*threshold=*/500, /*sr=*/48000, /*maxMs=*/2000);
    bool silenceLogged = false;
    auto noteSilence = [&](const void* data, size_t nbytes) {
        if (silenceLogged)
            return;
        if (silenceScan.feed(data, nbytes)) {
            silenceLogged = true;
            log("media: pcm_silence_head_ms=" + std::to_string(silenceScan.headMs) +
                " conf_adelay_ms=" + std::to_string(audioDelayMs_) +
                " predicted_shift_ms=" +
                std::to_string(misterplex::adelayContentShiftMs(audioDelayMs_)) +
                " (measured on pump input; tag=measured)");
        }
    };
    // Hold buffer while audioStartGate_ is closed. Cap kAudioHoldCapMs (2 s).
    //
    // Peer shape (CITED): arm when BOTH ready / preroll then latch base-time
    // (mpv, GStreamer). NOT-FOUND: peer keep-HEAD hold FIFO from stream t=0.
    //
    // Overflow: DropHeadKeepTail (NOT-FOUND peer consensus). keep-HEAD was a
    // measured audible jump; drop-head is still a content discontinuity at the
    // discarded head — honest, not peer-blessed.
    //
    // Timeout kAudioHoldTimeoutMs: ENGINEERING COMPROMISE (NOT "what mpv does")
    // between infinite silence and ExoPlayer-scale ~2.5 s start buffers. Logs
    // loudly; lastHoldWaitedMs_ makes it telemetry-visible.
    constexpr size_t kAudioHoldCapBytes =
        static_cast<size_t>(misterplex::kAudioHoldCapBytes);
    std::vector<uint8_t> holdBuf;
    holdBuf.reserve(static_cast<size_t>(misterplex::kMrAudioBytesPerSec)); // 1 s typical
    bool holdLogged = false;
    bool holdOverflowLogged = false;
    bool holdTimeoutLogged = false;
    bool releaseLogged = false;
    bool firstAudioPcmLogged = false;
    // Peer-aligned: no past-bias when draining a non-empty hold (see av_clock.hpp).
    bool pastBiasOnNextOrigin = true;
    auto holdSince = std::chrono::steady_clock::time_point{};
    int64_t lastHoldWaitLogMs = -1;
    lastHeldMs_.store(-1, std::memory_order_release);
    lastHoldWaitedMs_.store(-1, std::memory_order_release);
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
    // Deadline for the next chunk. Started on the FIRST chunk actually written
    // to MrAudio (after audioStartGate_), not on the first ffmpeg read: holding
    // the device closed until first video is what absorbs the ~206 ms startup
    // lead (measured audio_origin_ms) without re-basing the pacer clock.
    std::chrono::steady_clock::time_point audioDue{};
    bool audioClockStarted = false;
    int64_t chunkIndex = 0;
    int64_t queuedEma = -1;
    int64_t lastLatLog = -1;
    bool latencyLogged = false;
    bool overrunLogged = false;

    // Write one PCM chunk to MrAudio (and/or accumulate F2) with the normal
    // 48 kHz pace + ring servo. Called only after audioStartGate_ opens.
    auto writePacedChunk = [&](const uint8_t* data, size_t n) {
        if (out >= 0 && n > 0) {
            size_t off = 0;
            while (off < n && !stop_.load()) {
                ssize_t w = ::write(out, data + off, n - off);
                if (w < 0) {
                    if (errno == EINTR)
                        continue;
                    log("media: MrAudio write err errno=" + std::to_string(errno));
                    break;
                }
                off += static_cast<size_t>(w);
            }
            audioBytes_.fetch_add(static_cast<int64_t>(n));

            // Anchor on the first chunk actually written.
            // Peer-aligned hold drain: when pastBiasOnNextOrigin is false (non-
            // empty hold), start audioDue at `now` so held PCM does not burst
            // kFeedTargetMs ahead of the video origin latched at the same wall
            // instant (cluster-sep suspect). Cold/live open (empty hold) still
            // past-biases to the ring servo set-point.
            if (!audioClockStarted) {
                audioClockStarted = true;
                const auto now0 = std::chrono::steady_clock::now();
                if (pastBiasOnNextOrigin) {
                    audioDue = now0 - std::chrono::duration_cast<std::chrono::steady_clock::duration>(
                                          std::chrono::duration<double>(
                                              static_cast<double>(misterplex::kFeedTargetBytes) /
                                              kBytesPerSec));
                    log("media: audio pace origin=past_bias prefill_ms=" +
                        std::to_string(misterplex::kFeedTargetMs) +
                        " (empty-hold / live open)");
                } else {
                    audioDue = now0;
                    log("media: audio pace origin=now hold_drain_no_past_bias=1 "
                        "burst_lead_ms=0 (peer-aligned; held PCM realtime with video)");
                }
                // First MrAudio write landed — sample ring immediately (not every-4th).
                // Parent can pair ring_at_open vs ring_after_first_write across clusters.
                std::string raw;
                const auto snap = readMrAudioStatusSnap(&raw);
                const int64_t mono = steadyMonoMs();
                const int64_t qms =
                    (snap.len >= 0) ? (snap.len * 1000LL) / misterplex::kMrAudioBytesPerSec : -1;
                log("media: MrAudio ring_after_first_write mono_ms=" + std::to_string(mono) +
                    " written_B=" + std::to_string(audioBytes_.load()) +
                    " rptr=" + std::to_string(snap.rptr) + " wptr=" + std::to_string(snap.wptr) +
                    " len_B=" + std::to_string(snap.len) + " len_ms=" + std::to_string(qms) +
                    " comp=" + std::to_string(snap.comp) +
                    " raw=\"" + (raw.empty() ? std::string("NO-DATA") : raw) + "\""
                    " tag=measured"
                    " (post-write drain still FPGA-scheduled; not a lipsync claim)");
            }

            // Early ring trajectory (first ~320 ms @ 20 ms chunks). Parent: if
            // A vs B len/rptr tracks stay parallel with only a constant offset
            // that does NOT match HDMI sep (117 ms ≈ 22464 B), kill ring-phase.
            if (chunkIndex < 16) {
                std::string raw;
                const auto snap = readMrAudioStatusSnap(&raw);
                const int64_t mono = steadyMonoMs();
                const int64_t qms =
                    (snap.len >= 0) ? (snap.len * 1000LL) / misterplex::kMrAudioBytesPerSec
                                    : -1;
                log("media: MrAudio early_traj chunk=" + std::to_string(chunkIndex) +
                    " mono_ms=" + std::to_string(mono) +
                    " rptr=" + std::to_string(snap.rptr) +
                    " wptr=" + std::to_string(snap.wptr) +
                    " len_B=" + std::to_string(snap.len) +
                    " len_ms=" + std::to_string(qms) +
                    " written_B=" + std::to_string(audioBytes_.load()) +
                    " tag=measured");
            }

            const double rate = misterplex::feedRateBytesPerSec(
                kBytesPerSec, audioQueuedBytes_.load(std::memory_order_relaxed));
            audioDue += std::chrono::duration_cast<std::chrono::steady_clock::duration>(
                std::chrono::duration<double>(static_cast<double>(n) / rate));
            const auto now = std::chrono::steady_clock::now();
            if (audioDue > now)
                std::this_thread::sleep_until(audioDue);
            else if (now - audioDue > std::chrono::seconds(1)) {
                audioDue = now;
            }

            if ((chunkIndex++ % 4) == 0) {
                const int64_t q = readMrAudioQueuedBytes();
                if (q < 0) {
                    audioQueuedBytes_.store(-1);
                } else {
                    queuedEma = (queuedEma < 0) ? q : (queuedEma * 3 + q) / 4;
                    audioQueuedBytes_.store(queuedEma);
                    // Field 6: first transition audioQueuedBytes_ -1 → >=0.
                    // Ends submitted-byte-clock fallback window (H-RING length).
                    {
                        int64_t expected = -1;
                        const int64_t monoQ = steadyMonoMs();
                        if (firstAudioQueuedGe0MonoMs_.compare_exchange_strong(
                                expected, monoQ, std::memory_order_acq_rel)) {
                            const int64_t origin =
                                sessionOriginMonoMs_.load(std::memory_order_acquire);
                            const int64_t fa =
                                firstAudioPcmMonoMs_.load(std::memory_order_acquire);
                            std::string wallField = " wall_s=NO-DATA";
                            std::string sinceOrigin = " since_origin_ms=NO-DATA";
                            if (origin >= 0) {
                                const int64_t so = monoQ - origin;
                                wallField =
                                    " wall_s=" +
                                    std::to_string(static_cast<double>(so) / 1000.0)
                                        .substr(0, 8);
                                sinceOrigin =
                                    " since_origin_ms=" + std::to_string(so);
                            }
                            std::string sinceFa = " since_first_audio_pcm_ms=NO-DATA";
                            if (fa >= 0)
                                sinceFa = " since_first_audio_pcm_ms=" +
                                          std::to_string(monoQ - fa);
                            log("media: audio_queued_first_ge0 mono_ms=" +
                                std::to_string(monoQ) + wallField + sinceOrigin +
                                sinceFa + " queued_B=" + std::to_string(queuedEma) +
                                " raw_q_B=" + std::to_string(q) +
                                " tag=measured");
                        }
                    }
                    const int64_t latMs =
                        (queuedEma * 1000LL) / misterplex::kMrAudioBytesPerSec;
                    if (!latencyLogged) {
                        latencyLogged = true;
                        // One-shot: marks end of submitted-byte-clock fallback window.
                        // mono_ms required — without it the pre-availability length is
                        // unmeasurable (parent H-RING rejection still needs the window).
                        const int64_t mono = steadyMonoMs();
                        const int64_t origin =
                            sessionOriginMonoMs_.load(std::memory_order_acquire);
                        const int64_t fa =
                            firstAudioPcmMonoMs_.load(std::memory_order_acquire);
                        const int64_t ar =
                            avAudioReleaseMonoMs_.load(std::memory_order_acquire);
                        std::string wallField = " wall_s=NO-DATA";
                        std::string sinceOrigin = " since_origin_ms=NO-DATA";
                        if (origin >= 0) {
                            const int64_t so = mono - origin;
                            wallField = " wall_s=" +
                                        std::to_string(static_cast<double>(so) / 1000.0)
                                            .substr(0, 8);
                            sinceOrigin = " since_origin_ms=" + std::to_string(so);
                        }
                        std::string sinceFa = " since_first_audio_pcm_ms=NO-DATA";
                        if (fa >= 0)
                            sinceFa = " since_first_audio_pcm_ms=" + std::to_string(mono - fa);
                        std::string sinceAr = " since_audio_release_ms=NO-DATA";
                        if (ar >= 0)
                            sinceAr = " since_audio_release_ms=" + std::to_string(mono - ar);
                        log("media: MrAudio playback position available mono_ms=" +
                            std::to_string(mono) + wallField + sinceOrigin + sinceFa +
                            sinceAr + " queued_B=" + std::to_string(queuedEma) +
                            " lat_ms=" + std::to_string(latMs) +
                            " tag=measured"
                            " — video now paces off what is HEARD, not what is sent");
                    }
                    const int64_t nowMs = audioClockMs(audioBytes_.load());
                    if (lastLatLog < 0 || nowMs - lastLatLog >= 5000) {
                        lastLatLog = nowMs;
                        // Every latency sample carries mono_ms + since_origin so a
                        // "first" value cannot be misread as session-start (parent
                        // sampling-phase trap: index-9 76ms vs steady ~100ms).
                        const int64_t mono = steadyMonoMs();
                        const int64_t origin =
                            sessionOriginMonoMs_.load(std::memory_order_acquire);
                        std::string sinceOrigin = " since_origin_ms=NO-DATA";
                        std::string wallField = " wall_s=NO-DATA";
                        if (origin >= 0) {
                            const int64_t so = mono - origin;
                            sinceOrigin = " since_origin_ms=" + std::to_string(so);
                            wallField = " wall_s=" +
                                        std::to_string(static_cast<double>(so) / 1000.0)
                                            .substr(0, 8);
                        }
                        log("media: audio latency ms=" + std::to_string(latMs) +
                            " queued_B=" + std::to_string(queuedEma) +
                            " mono_ms=" + std::to_string(mono) + wallField + sinceOrigin +
                            " tag=measured");
                    }
                    if (!overrunLogged && queuedEma > (misterplex::kMrAudioRingBytes * 3) / 4) {
                        overrunLogged = true;
                        log("media: WARNING MrAudio ring " + std::to_string(latMs) +
                            "ms deep — approaching overwrite of unplayed audio");
                    }
                }
            }
        }
    };

    auto flushF2 = [&]() {
        while (wantF2 && f2acc.size() >= kF2Chunk && !stop_.load()) {
            if (fpga_.sendPcmChunk(f2acc.data(), kF2Chunk, /*F2*/ 2)) {
                f2total += kF2Chunk;
                f2Fail = 0;
            } else {
                ++f2Fail;
                if (f2Fail == 1 || f2Fail == 8 || (f2Fail % 64) == 0)
                    log("media: F2 pcm: " + fpga_.lastError() + " (fail#" +
                        std::to_string(f2Fail) + ")");
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
    };

    while (!stop_.load()) {
        if (paused_.load()) {
            std::this_thread::sleep_for(std::chrono::milliseconds(20));
            continue;
        }

        const bool gated = !audioStartGate_.load(std::memory_order_acquire);
        if (gated) {
            if (!holdLogged) {
                holdLogged = true;
                holdSince = std::chrono::steady_clock::now();
                log("media: audio hold — buffering PCM until first video frame "
                    "(no MrAudio write yet; cap_ms=" +
                    std::to_string(misterplex::kAudioHoldCapMs) +
                    " ring_drop_head; timeout_ms=" +
                    std::to_string(misterplex::kAudioHoldTimeoutMs) + ")");
            }
            const int64_t waited = std::chrono::duration_cast<std::chrono::milliseconds>(
                                       std::chrono::steady_clock::now() - holdSince)
                                       .count();
            if (waited >= misterplex::kAudioHoldTimeoutMs) {
                if (!holdTimeoutLogged) {
                    holdTimeoutLogged = true;
                    // ENGINEERING COMPROMISE — NOT peer-copied (not mpv/VLC).
                    log("media: audio hold TIMEOUT waited_ms=" + std::to_string(waited) +
                        " held_ms=" +
                        std::to_string(misterplex::heldMsFromBytes(
                            static_cast<int64_t>(holdBuf.size()))) +
                        " held_bytes=" + std::to_string(holdBuf.size()) +
                        " timeout_ms=" + std::to_string(misterplex::kAudioHoldTimeoutMs) +
                        " — escape open without video "
                        "(engineering compromise, not peer-copied; degrade to pre-hold audio)");
                    lastHoldWaitedMs_.store(waited, std::memory_order_release);
                }
                audioStartGate_.store(true, std::memory_order_release);
            } else {
                pollfd pfd{};
                pfd.fd = afd;
                pfd.events = POLLIN;
                const int pr = ::poll(&pfd, 1, 50);
                if (pr < 0) {
                    if (errno == EINTR)
                        continue;
                    break;
                }
                if (pr == 0) {
                    if (lastHoldWaitLogMs < 0 || waited - lastHoldWaitLogMs >= 1000) {
                        lastHoldWaitLogMs = waited;
                        log("media: audio hold waiting_ms=" + std::to_string(waited) +
                            " held_bytes=" + std::to_string(holdBuf.size()) +
                            " audio_bytes_written=" + std::to_string(audioBytes_.load()) +
                            " (gate closed)");
                    }
                    continue;
                }
            }
        }

        ssize_t n = ::read(afd, buf, sizeof(buf));
        if (n < 0) {
            if (errno == EINTR)
                continue;
            if (errno == EAGAIN || errno == EWOULDBLOCK)
                continue;
            break;
        }
        if (n == 0)
            break;

        // Always scan pump-input PCM (hold path and live path share this read).
        noteSilence(buf, static_cast<size_t>(n));

        // First ffmpeg PCM byte on the pump — BEFORE gate open / MrAudio write.
        // Cluster instrument: mono_ms always; wall_s only if session origin armed
        // (usually NO-DATA here because origin latches at first video).
        if (!firstAudioPcmLogged) {
            firstAudioPcmLogged = true;
            const int64_t mono = steadyMonoMs();
            firstAudioPcmMonoMs_.store(mono, std::memory_order_release);
            const int64_t origin = sessionOriginMonoMs_.load(std::memory_order_acquire);
            std::string wallField = " wall_s=NO-DATA";
            if (origin >= 0) {
                const double ws = static_cast<double>(mono - origin) / 1000.0;
                wallField = " wall_s=" + std::to_string(ws).substr(0, 8);
            }
            log("media: first_audio_pcm mono_ms=" + std::to_string(mono) + wallField +
                " nbytes=" + std::to_string(n) +
                " gate=" +
                std::string(audioStartGate_.load(std::memory_order_acquire) ? "open"
                                                                           : "closed") +
                " tag=measured"
                " (cluster axis; pre-MrAudio)");
        }

        if (!audioStartGate_.load(std::memory_order_acquire)) {
            const size_t nn = static_cast<size_t>(n);
            holdBuf.insert(holdBuf.end(), buf, buf + nn);
            if (holdBuf.size() > kAudioHoldCapBytes) {
                const size_t over = holdBuf.size() - kAudioHoldCapBytes;
                holdBuf.erase(holdBuf.begin(),
                              holdBuf.begin() + static_cast<std::ptrdiff_t>(over));
                if (!holdOverflowLogged) {
                    holdOverflowLogged = true;
                    // DropHeadKeepTail: NOT-FOUND peer consensus; measured fix vs keep-HEAD.
                    log("media: audio hold cap reached bytes=" +
                        std::to_string(holdBuf.size()) +
                        " held_ms=" +
                        std::to_string(misterplex::heldMsFromBytes(
                            static_cast<int64_t>(holdBuf.size()))) +
                        " — ring drop HEAD keep live tail "
                        "(NOT-FOUND peer FIFO policy; keep-HEAD was audible jump)");
                }
            }
            total += static_cast<size_t>(n);
            continue;
        }

        if (!releaseLogged) {
            releaseLogged = true;
            const int64_t writtenBefore = audioBytes_.load();
            const int64_t heldBytes = static_cast<int64_t>(holdBuf.size());
            const auto rel = misterplex::checkAudioReleaseOrigin(writtenBefore, heldBytes);
            const char* why = holdTimeoutLogged ? "hold_timeout" : "first_video_or_path";
            const int64_t mono = steadyMonoMs();
            pumpAudioReleaseMonoMs_.store(mono, std::memory_order_release);
            holdBytesAtRelease_.store(heldBytes, std::memory_order_release);
            const int64_t origin = sessionOriginMonoMs_.load(std::memory_order_acquire);
            const int64_t fa = firstAudioPcmMonoMs_.load(std::memory_order_acquire);
            const int64_t avr = avAudioReleaseMonoMs_.load(std::memory_order_acquire);
            std::string wallField = " wall_s=NO-DATA";
            if (origin >= 0) {
                const double ws = static_cast<double>(mono - origin) / 1000.0;
                wallField = " wall_s=" + std::to_string(ws).substr(0, 8);
            }
            // held_ms = content duration of hold buffer (bytes→ms @ 48k stereo s16).
            // hold_wall_ms = wall duration first_audio_pcm→this release (explicit;
            // parent must not hand-subtract mono_ms). Both tagged measured.
            int64_t holdWallMs = -1;
            std::string holdWall = " hold_wall_ms=NO-DATA";
            if (fa >= 0) {
                holdWallMs = mono - fa;
                holdWall = " hold_wall_ms=" + std::to_string(holdWallMs);
            } else if (holdLogged) {
                holdWallMs = std::chrono::duration_cast<std::chrono::milliseconds>(
                                 std::chrono::steady_clock::now() - holdSince)
                                 .count();
                holdWall = " hold_wall_ms=" + std::to_string(holdWallMs);
            }
            std::string sinceAv = " since_av_release_ms=NO-DATA";
            if (avr >= 0)
                sinceAv = " since_av_release_ms=" + std::to_string(mono - avr);
            // Peer-aligned drain: non-empty hold → no past-bias burst (av_clock.hpp).
            pastBiasOnNextOrigin = misterplex::holdDrainShouldPastBias(heldBytes > 0);
            const bool pastBias = pastBiasOnNextOrigin;
            const auto rep = misterplex::makeHoldSessionReport(
                writtenBefore, heldBytes, holdWallMs < 0 ? 0 : holdWallMs, pastBias,
                holdTimeoutLogged);
            lastHeldMs_.store(rep.heldMs, std::memory_order_release);
            lastHoldWaitedMs_.store(rep.holdWaitedMs, std::memory_order_release);
            const std::string axis = " mono_ms=" + std::to_string(mono) + wallField +
                                     " held_ms=" + std::to_string(rep.heldMs) + holdWall +
                                     " hold_waited_ms=" + std::to_string(rep.holdWaitedMs) +
                                     " drain_burst_lead_ms=" +
                                     std::to_string(rep.drainBurstLeadMs) +
                                     " past_bias=" + std::to_string(pastBias ? 1 : 0) + sinceAv +
                                     " tag=measured";
            if (!rel.ok || !rep.ok) {
                log("ERROR media: audio release content_origin_ms=" +
                    std::to_string(rep.contentOriginMs) +
                    " audio_bytes_at_release=" + std::to_string(rel.audioBytesAtRelease) +
                    " held_bytes=" + std::to_string(holdBuf.size()) +
                    " reason=" + why + axis +
                    " — hold report not ok (co-arm-class lead risk)");
            } else {
                log("media: audio release content_origin_ms=0"
                    " audio_bytes_at_release=0 held_bytes=" +
                    std::to_string(holdBuf.size()) + " reason=" + why + axis +
                    " (held PCM continuous with live; peer-aligned drain)");
            }
            constexpr size_t kChunk = 3840;
            size_t off = 0;
            while (off < holdBuf.size() && !stop_.load()) {
                const size_t chunk =
                    (holdBuf.size() - off) < kChunk ? (holdBuf.size() - off) : kChunk;
                writePacedChunk(holdBuf.data() + off, chunk);
                if (wantF2)
                    f2acc.insert(f2acc.end(), holdBuf.data() + off, holdBuf.data() + off + chunk);
                flushF2();
                off += chunk;
            }
            holdBuf.clear();
            holdBuf.shrink_to_fit();
            // Origin already started during drain; live path must not re-bias.
            pastBiasOnNextOrigin = true;
        }

        writePacedChunk(reinterpret_cast<const uint8_t*>(buf), static_cast<size_t>(n));
        if (wantF2) {
            f2acc.insert(f2acc.end(), buf, buf + n);
            flushF2();
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
    if (!silenceLogged) {
        log("media: pcm_silence_head_ms=UNKNOWN conf_adelay_ms=" +
            std::to_string(audioDelayMs_) +
            " (could-not-measure; too little PCM or empty stream) tag=UNSCORED");
    }
    log("media: audio pump end bytes=" + std::to_string(total) +
        " f2=" + std::to_string(f2total));
}

void MediaPlayer::threadMain(std::string url, int64_t startMs, std::string headers,
                             int64_t durationMs) {
    playing_.store(true);
    positionMs_.store(startMs);
    if (onProgress_)
        onProgress_("buffering", startMs, durationMs);

    // Product silicon CODED_W/H are compile-time (624x480). DECODE/outW_ only
    // selects the PMS source ladder; FPGA DDR publish must always use the
    // silicon canvas or line-stride shears (ARM 320 vs RTL 624).
    const bool wantFpgaDdrCanvas =
        (presentMode_ == "fpga" || presentMode_ == "both");
    const DdrFrameGeometry ddrGeometry =
        wantFpgaDdrCanvas ? ddrFrameGeometryForFpgaPresent(outW_, outH_)
                          : makeDdrFrameGeometry(outW_, outH_);
    const int rawW = ddrGeometry.coded_width.get();
    const int rawH = ddrGeometry.coded_height.get();
    const int rawDisplayW = ddrGeometry.display_width.get();
    const int rawDisplayH = ddrGeometry.display_height.get();
    LastFrameLatch lastFrameLatch;

    // Force CFR at the exact content rate FIRST in the chain: frameIndex ↔ content
    // time then holds by construction (even if PMS emits a different rate than its
    // metadata claims), and frames dropped by the fps filter are never scaled.
    FfmpegVfRequest vfReq;
    vfReq.coded_w = rawW;
    vfReq.coded_h = rawH;
    vfReq.display_w = rawDisplayW;
    vfReq.display_h = rawDisplayH;
    vfReq.crop_left = ddrGeometry.crop_left;
    vfReq.crop_top = ddrGeometry.crop_top;
    if (fpsNum_ > 0 && fpsDen_ > 0)
        vfReq.fps_filter = "fps=" + std::to_string(fpsNum_) + "/" + std::to_string(fpsDen_);
    // Defect A/B silicon: YUV DDR force-scale DEFAULT ON (pins output to coded
    // store). Escape DDR_YUV_FORCE_SCALE=0 still cannot identity-skip on an
    // unverified PMS request (delivery_geometry_verified guard).
    // Hygiene: studio-black init + dead-chroma repair always on.
    const FfmpegScaleMode confScaleMode = parseFfmpegScaleMode(ffmpegScaleMode_);
    const bool yuvDdrPresent =
        wantFpgaDdrCanvas && ddrFrameFormat_ == DdrFrameFormat::Yuv420p;
    const bool forceScale = yuvDdrPresent && ddrYuvForceScale_;
    vfReq.scale_mode = ffmpegScaleModeForDdrYuvPresent(confScaleMode, forceScale);
    vfReq.sws_flags = ffmpegSwsFlags_;
    vfReq.source_w = ffmpegScaleSourceW_;
    vfReq.source_h = ffmpegScaleSourceH_;
    vfReq.assume_source_matches_coded = ffmpegScaleAssumeMatch_;
    vfReq.delivery_geometry_verified =
        deliveryGeometryVerified_.load(std::memory_order_relaxed);
    const FfmpegVfPlan vfPlan = buildFfmpegVideoFilter(vfReq);
    std::string vf = vfPlan.vf;
    // Actual scale decision (parent greps arm_rescale= here and on misterplexd: GEOM).
    const std::string srcStr =
        (ffmpegScaleSourceW_ > 0 && ffmpegScaleSourceH_ > 0)
            ? (std::to_string(ffmpegScaleSourceW_) + "x" + std::to_string(ffmpegScaleSourceH_))
            : "unknown";
    const std::string codedStr = std::to_string(rawW) + "x" + std::to_string(rawH);
    if (vfPlan.reason.find("unverified_delivery") != std::string::npos) {
        log(std::string("media: GEOM_GUARD refused identity_skip — delivery not verified "
                        "(PMS request ≠ measured size); forcing scale. reason=") +
            vfPlan.reason + " claimed=" + srcStr + " coded=" + codedStr);
    }
    log(std::string("media: GEOM expected_delivery=") + srcStr + " decode_target=" + codedStr +
        " arm_rescale=" + (vfPlan.scale_applied ? "1" : "0") + " reason=" + vfPlan.reason +
        " identity_skip=" + (vfPlan.identity_skip ? "1" : "0") +
        " mode=" + ffmpegScaleModeName(vfReq.scale_mode) +
        " conf_mode=" + ffmpegScaleModeName(confScaleMode) +
        " yuv_ddr_force_scale=" + (forceScale ? "1" : "0") +
        " delivery_verified=" +
        (deliveryGeometryVerified_.load(std::memory_order_relaxed) ? "1" : "0") +
        " sws_flags=" + (ffmpegSwsFlags_.empty() ? "(default)" : ffmpegSwsFlags_) +
        " assume_match=" + (ffmpegScaleAssumeMatch_ ? "1" : "0") +
        " display=" + std::to_string(rawDisplayW) + "x" + std::to_string(rawDisplayH) +
        " vf=" + (vf.empty() ? "(none)" : vf));

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
        if (!vf.empty())
            vf.push_back(',');
        vf += "subtitles=" + esc + ":si=" + std::to_string(std::max(0, subtitleStreamIndex_));
        log("media: FFmpeg subtitles burn-in si=" + std::to_string(subtitleStreamIndex_));
    }
    const bool wantMr = audioEnabled_ && (::access(audioDev_.c_str(), W_OK) == 0);
    // Match audioPump: F2 only when PRESENT=fpga and MrAudio unavailable.
    const bool wantF2 = fpga_.ok() && presentMode_ == "fpga" && !wantMr;
    bool wantAudio = audioEnabled_ && (wantMr || wantF2);
    if (wantAudio && localFile && !ffmpegHasAudioStream(ffmpeg_, url, headers, startMs)) {
        wantAudio = false;
        log("media: audio disabled for session: no audio stream detected; avoiding empty "
            "audio output abort");
    }

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
                (presentMode_ == "fpga" ? " — RGB retained only for decode/audio fallback)"
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
    // Per-second supply bucket baseline (glass-loss 1/2.71s resolvable).
    misterplex::SupplyCounters supplyPrev{};
    bool supplyPrevInit = false;

    bool usedRawVideo = false;
    bool videoEof = false;
    bool shortRead = false;
    size_t shortReadGot = 0;
    size_t shortReadWant = 0;

    // A/V pacing state. The exact rational rate is load-bearing: pacing 23.976 fps
    // content at a hardcoded 24 leaks ~1 ms/s of video lead.
    const int fpsNum = fpsNum_ > 0 ? fpsNum_ : kDefaultFpsNum;
    const int fpsDen = fpsNum_ > 0 && fpsDen_ > 0 ? fpsDen_ : kDefaultFpsDen;
    const int64_t leadMs = presentLeadMs_;
    const int64_t dropMs = resyncDropMs_;
    int dropRun = 0;
    // Field 5: plain A/V Hold counters (NOT presentProfile_). Each Hold sleeps
    // ~2 ms; chrono + two integer adds are << sleep cost.
    int64_t avHoldCount = 0;
    int64_t avHoldWaitUs = 0;
    bool hold10sLogged = false;
    avDriftMs_.store(0);
    droppedFrames_.store(0);
    publishMisses_.store(0);
    ffmpegOutFrames_.store(-1, std::memory_order_relaxed);
    measuredFpsNum_.store(0, std::memory_order_relaxed);
    measuredFpsDen_.store(0, std::memory_order_relaxed);
    if (fpsNum_ <= 0)
        log("media: content fps UNKNOWN — pacing at " + std::to_string(kDefaultFpsNum) + "/" +
            std::to_string(kDefaultFpsDen) +
            " (fps_src=DEFAULT_ASSUMED) until MEASURED_FPS; supply_gap refused "
            "while unverified — relying on drift correction");
    else
        log("media: content fps=" + std::to_string(fpsNum) + "/" + std::to_string(fpsDen) +
            " fps_src=caller_supplied lead_ms=" + std::to_string(leadMs) +
            " resync_drop_ms=" + std::to_string(dropMs));

    if (skipRgb) {
        // Audio-only FFmpeg + wall-clock position. Host recon owns F1.
        int apipe[2] = {-1, -1};
        if (wantAudio && pipe(apipe) == 0) {
            pid_t pid = spawnAudioOnly(url, headers, startMs, apipe[1]);
            ::close(apipe[1]);
            if (pid > 0) {
                childPid_.store(pid);
                // No RGB frame cadence on this path — open the gate immediately.
                audioStartGate_.store(true, std::memory_order_release);
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
                if (misterplex::rawVideoTerminalSignal(/*explicitStopOrSeek=*/true,
                                                       /*readZero=*/false,
                                                       /*readError=*/false,
                                                       /*shortRead=*/false,
                                                       /*knownDurationStall=*/false))
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
                        "PRESENT=both for fb0 fallback.");
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
        usedRawVideo = true;
        presentCount_ = 0;
        audioBytes_.store(0);
        measuredDeliveryW_.store(0);
        measuredDeliveryH_.store(0);
        // Session measure starts unverified; only MEASURED_DELIVERY sets true (B4).
        deliveryGeometryVerified_.store(false, std::memory_order_relaxed);
        pipeDesyncRisk_.store(false);
        std::vector<std::string> args;
        args.push_back(ffmpeg_);
        args.push_back("-hide_banner");
        // info + stats: Stream # WxH (B2) AND frame= for supply ledger (glass-loss).
        // -loglevel error SUPPRESSES the Stream banner → delivery_verified stays 0.
        // info is required. Stderr pump parses geometry + frame=; non-matching
        // info lines are discarded (not logged) so soak logs are not flooded.
        args.push_back("-stats");
        args.push_back("-loglevel");
        args.push_back("info"); // DO NOT change to error — breaks delivered_geom
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
                // AUDIO_DELAY_MS>0: content-aligned silence via adelay=N|N (ms per
                // channel). Portable form — not :all=1 — so device FFmpeg matches
                // host unit ladders. Sample-clock pacer does NOT cancel this
                // (adelayContentShiftMs == conf). Pump logs measured silence head.
                {
                    const std::string af = misterplex::ffmpegAudioDelayFilter(audioDelayMs_);
                    args.push_back(af);
                    if (audioDelayMs_ > 0)
                        log("media: ffmpeg adelay_ms=" + std::to_string(audioDelayMs_) +
                            " filter=" + af +
                            " predicted_content_shift_ms=" +
                            std::to_string(misterplex::adelayContentShiftMs(audioDelayMs_)) +
                            " prefill_cancel_ms=" +
                            std::to_string(misterplex::adelayCancelledByPrefillMs(
                                audioDelayMs_,
                                static_cast<int>(misterplex::kFeedTargetBytes * 1000 /
                                                 misterplex::kMrAudioBytesPerSec))));
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
        int epipe[2] = {-1, -1};
        if (pipe(vpipe) != 0) {
            log("media: video pipe failed");
            playing_.store(false);
            killChildren();
            if (streamThr_.joinable())
                streamThr_.join();
            return;
        }
        // Decouple ffmpeg producer from DDR publish latency: enlarge the raw
        // video pipe beyond the kernel default (65536 ≈ 0.15 frames @ 624x480
        // I420). Read back F_GETPIPE_SZ and log THAT value — never the request
        // alone. Failure → keep default; never abort playback.
        {
            const auto pipeSz = applyRawVideoPipeSize(vpipe[0], rawVideoPipeBytes_);
            lastRawVideoPipeActual_ = pipeSz.actual;
            log(std::string("media: ") + formatRawVideoPipeLog(pipeSz));
        }
        if (wantAudio && pipe(apipe) != 0) {
            log("media: audio pipe failed — video only");
            apipe[0] = apipe[1] = -1;
        }
        if (pipe(epipe) != 0) {
            log("media: ffmpeg stderr pipe failed — measured geometry unavailable");
            epipe[0] = epipe[1] = -1;
        }

        {
            // Log-only join. `args` itself keeps the real token for execv.
            // MediaPlayer::log applies redactSensitive at the sink.
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

        // frameBytes MUST track coded bank (rawW/rawH), never display 618 or
        // DECODE tier alone — under-read would leave chroma at init value and
        // desync the pipe (parent defect A/B hypothesis). Product: 624*480*3/2.
        const size_t frameBytes = rawVideoFrameBytes(videoFmt, rawW, rawH);

        pid_t pid =
            spawnFfmpeg(args, vpipe[1], apipe[1] >= 0 ? apipe[1] : -1, epipe[1]);
        ::close(vpipe[1]);
        if (apipe[1] >= 0)
            ::close(apipe[1]);
        if (epipe[1] >= 0)
            ::close(epipe[1]);
        std::thread errThr;
        if (pid >= 0 && epipe[0] >= 0) {
            errThr = std::thread([this, efd = epipe[0], frameBytes, idSkip = vfPlan.identity_skip] {
                ffmpegStderrPump(efd, frameBytes, idSkip);
            });
        } else if (epipe[0] >= 0) {
            ::close(epipe[0]);
        }
        if (pid < 0) {
            ::close(vpipe[0]);
            if (apipe[0] >= 0)
                ::close(apipe[0]);
            if (errThr.joinable())
                errThr.join();
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
            // Closed until first complete video frame — see audioPump hold path.
            audioStartGate_.store(false, std::memory_order_release);
            sessionOriginMonoMs_.store(-1, std::memory_order_release);
            firstAudioPcmMonoMs_.store(-1, std::memory_order_release);
            avAudioReleaseMonoMs_.store(-1, std::memory_order_release);
            pumpAudioReleaseMonoMs_.store(-1, std::memory_order_release);
            holdBytesAtRelease_.store(-1, std::memory_order_release);
            firstAudioQueuedGe0MonoMs_.store(-1, std::memory_order_release);
            audioThr_ = std::thread([this, afd = apipe[0]] { audioPump(afd); });
        } else {
            audioStartGate_.store(true, std::memory_order_release);
            sessionOriginMonoMs_.store(-1, std::memory_order_release);
            firstAudioPcmMonoMs_.store(-1, std::memory_order_release);
            avAudioReleaseMonoMs_.store(-1, std::memory_order_release);
            pumpAudioReleaseMonoMs_.store(-1, std::memory_order_release);
            holdBytesAtRelease_.store(-1, std::memory_order_release);
            firstAudioQueuedGe0MonoMs_.store(-1, std::memory_order_release);
        }
        std::vector<uint8_t> frame(frameBytes);
        // Zero-init → green-cast under any underfill (U=V=0). Studio black
        // (Y=16,U=V=128) is greyscale-safe if a short frame is ever presented.
        if (videoFmt == RawVideoFormat::Yuv420p)
            fillYuv420pStudioBlack(frame.data(), rawW, rawH);
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
            int64_t ddrBankReuseWaitUs = 0;
            int64_t ddrPlxdPollUs = 0;
            int64_t ddrPlxdPollIters = 0;
            int64_t ddrPlxdUsed = 0;
            int64_t ddrTotalUs = 0;
            int64_t ddrCpuUs = 0;
            int64_t ddrUnaccountedUs = 0;
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
                " ddr_bank_reuse_wait_us_p=" +
                    std::to_string(avgPresented(prof.ddrBankReuseWaitUs)) +
                " ddr_plxd_poll_us_p=" + std::to_string(avgPresented(prof.ddrPlxdPollUs)) +
                " ddr_plxd_poll_iters_x100_p=" +
                    std::to_string((prof.ddrPlxdPollIters * 100) / presented) +
                " ddr_plxd_used_x100_p=" +
                    std::to_string((prof.ddrPlxdUsed * 100) / presented) +
                " ddr_accounted_us_p=" + std::to_string(avgPresented(ddrAccountedUs)) +
                " ddr_unaccounted_us_p=" +
                    std::to_string(avgPresented(prof.ddrUnaccountedUs)) +
                " ddr_total_us_p=" + std::to_string(avgPresented(prof.ddrTotalUs)) +
                " ddr_cpu_us_p=" + std::to_string(avgPresented(prof.ddrCpuUs)) +
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
                std::string ddrErr;
                if (useDdrF1_) {
                    const int64_t ddrCpu0 = profilePresent ? threadCpuMicros() : 0;
                    if (videoFmt == RawVideoFormat::Yuv420p) {
                        DdrPublishFrame frame{txFrame, txBytes, ddrGeometry,
                                              DdrFrameFormat::Yuv420p};
                        ok = publishDdrFrame(frame, "playback DDR", &ddrErr);
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
                        prof.ddrBankReuseWaitUs += dt.bank_reuse_wait_us;
                        prof.ddrPlxdPollUs += dt.plxa_poll_us;
                        prof.ddrPlxdPollIters += dt.plxa_poll_iters;
                        prof.ddrPlxdUsed += dt.plxa_used ? 1 : 0;
                        prof.ddrTotalUs += dt.total_us;
                        prof.ddrCpuUs += ddrCpu1 - ddrCpu0;
                        if (dt.total_us > accounted)
                            prof.ddrUnaccountedUs += dt.total_us - accounted;
                    }
                    if (!ok)
                        log("media: DDR YUV420p F1 unavailable: " +
                            (ddrErr.empty() ? fpga_.lastError() : ddrErr));
                    else if (idleMode() == IdleMode::LastFrame)
                        lastFrameLatch.remember(txFrame, txBytes, ddrGeometry);
                }
                if (!ok && videoFmt != RawVideoFormat::Yuv420p) {
                    log("media: non-YUV F1 frame refused before send; frame store requires DDR "
                        "YUV420p");
                }
                if (!ok) {
                    if (countPresent) {
                        const int64_t missNow =
                            publishMisses_.fetch_add(1, std::memory_order_relaxed) + 1;
                        // Exact form required by rtl_invariants present-path degradation
                        // contract (whitespace-stripped needle includes frame_status).
                        if ((frameIndex % 30) == 0)
                            log("media: fpga frame_tx: " +
                                (ddrErr.empty() ? fpga_.lastError() : ddrErr));
                        // Every miss (glass-loss instrument): drops stays flat while
                        // residual/unaccounted rises. Parent pairs wall_s with HDMI
                        // missing indices. err= carries bank-select / STALL reason.
                        {
                            const auto missTp = std::chrono::steady_clock::now();
                            const double missWall =
                                std::chrono::duration<double>(missTp - t0).count();
                            const int64_t residual = frameLedgerResidual(
                                frameIndex, presentCount_, droppedFrames_.load());
                            log("media: publish_miss wall_s=" +
                                std::to_string(missWall).substr(0, 6) +
                                " mono_ms=" + std::to_string(steadyMonoMs()) +
                                " publish_misses=" + std::to_string(missNow) +
                                " publish_misses_src=arm_publish_fail" +
                                " frames=" + std::to_string(frameIndex) +
                                " frames_src=pipe_assemble" +
                                " presents=" + std::to_string(presentCount_) +
                                " presents_src=arm_publish_ok" +
                                " drops=" + std::to_string(droppedFrames_.load()) +
                                " drops_src=av_pacer" +
                                " residual=" + std::to_string(residual) +
                                " residual_eq=frames-presents-drops" +
                                " residual_scope=supply_arm_only" +
                                " fpga_obs=none" +
                                " err=" +
                                (ddrErr.empty() ? fpga_.lastError() : ddrErr) +
                                " tag=measured");
                        }
                    }
                } else if (countPresent) {
                    ++presentCount_;
                    if (profilePresent)
                        ++prof.presented;
                    if (presentCount_ == 1) {
                        // Extract BEFORE any log clear — parent ERROR class.
                        // Explicit deltas — never require hand-subtraction of mono_ms.
                        const auto fv = std::chrono::steady_clock::now();
                        const double fvWall =
                            std::chrono::duration<double>(fv - t0).count();
                        const int64_t mono = steadyMonoMs();
                        const int64_t fa =
                            firstAudioPcmMonoMs_.load(std::memory_order_acquire);
                        const int64_t avr =
                            avAudioReleaseMonoMs_.load(std::memory_order_acquire);
                        const int64_t pr =
                            pumpAudioReleaseMonoMs_.load(std::memory_order_acquire);
                        std::string sinceFa = " since_first_audio_pcm_ms=NO-DATA";
                        if (fa >= 0)
                            sinceFa =
                                " since_first_audio_pcm_ms=" + std::to_string(mono - fa);
                        std::string sinceAv = " since_audio_release_ms=NO-DATA";
                        if (avr >= 0)
                            sinceAv =
                                " since_audio_release_ms=" + std::to_string(mono - avr);
                        std::string sincePump = " since_pump_release_ms=NO-DATA";
                        if (pr >= 0)
                            sincePump =
                                " since_pump_release_ms=" + std::to_string(mono - pr);
                        log("media: first_video_present wall_s=" +
                            std::to_string(fvWall).substr(0, 6) +
                            " mono_ms=" + std::to_string(mono) + sinceFa + sinceAv +
                            sincePump +
                            " av_drift_ms=" + std::to_string(avDriftMs_.load()) +
                            " frames=" + std::to_string(frameIndex) +
                            " presents=1"
                            " audio=" +
                            std::string(audioActive_.load() ? "on" : "off") +
                            " audio_s=" +
                            std::to_string(static_cast<double>(audioBytes_.load()) /
                                          (48000.0 * 4.0))
                                .substr(0, 5) +
                            " tag=measured");
                        // SIX-FIELD cluster instrument at first present.
                        // Prefer FPGA state over daemon software state.
                        // Cost: 1× readBankRelease (SPI mailbox) + struct copy of
                        // lastDdrTiming already filled by the publish just done;
                        // no presentProfile_ path; no extra DDR frame copy.
                        {
                            const auto dt = fpga_.lastDdrTiming();
                            BankReleaseStatus brs{};
                            // frames_done MUST be paired with the ARM time of THIS read.
                            const int64_t fdMono = steadyMonoMs();
                            const auto fdTp = std::chrono::steady_clock::now();
                            const bool brOk = fpga_.readBankRelease(brs);
                            const double fdWallS =
                                std::chrono::duration<double>(fdTp - t0).count();
                            const int pubBank = fpga_.lastPublishedBank();
                            const int64_t q0 =
                                firstAudioQueuedGe0MonoMs_.load(std::memory_order_acquire);
                            std::string q0f = " audio_queued_first_ge0_mono_ms=NO-DATA"
                                              " audio_queued_first_ge0_since_origin_ms=NO-DATA"
                                              " audio_queued_first_ge0_tag=NO-DATA";
                            if (q0 >= 0) {
                                const int64_t origin =
                                    sessionOriginMonoMs_.load(std::memory_order_acquire);
                                std::string so = "NO-DATA";
                                if (origin >= 0)
                                    so = std::to_string(q0 - origin);
                                q0f = " audio_queued_first_ge0_mono_ms=" +
                                      std::to_string(q0) +
                                      " audio_queued_first_ge0_since_origin_ms=" + so +
                                      " audio_queued_first_ge0_tag=measured";
                            }
                            std::string brf =
                                " br_ok=0 free_bank_mask=NO-DATA disp_bank=NO-DATA"
                                " swap_pending=NO-DATA frames_done=NO-DATA"
                                " frames_done_mono_ms=" +
                                std::to_string(fdMono) + " frames_done_wall_s=" +
                                std::to_string(fdWallS).substr(0, 8) +
                                " frames_done_tag=measured";
                            if (brOk) {
                                brf = " br_ok=1 free_bank_mask=" +
                                      std::to_string(static_cast<unsigned>(brs.free_bank_mask)) +
                                      " disp_bank=" +
                                      std::to_string(static_cast<unsigned>(brs.disp_bank)) +
                                      " swap_pending=" +
                                      std::to_string(brs.swap_pending ? 1 : 0) +
                                      " frames_done=" + std::to_string(brs.frames_done) +
                                      " frames_done_mono_ms=" + std::to_string(fdMono) +
                                      " frames_done_wall_s=" +
                                      std::to_string(fdWallS).substr(0, 8) +
                                      " frames_done_tag=measured";
                            }
                            log("media: first_video_fpga_state mono_ms=" +
                                std::to_string(mono) + " wall_s=" +
                                std::to_string(fvWall).substr(0, 8) +
                                " plxa_used=" + std::to_string(dt.plxa_used ? 1 : 0) +
                                " plxd_liveness_proven=" +
                                std::to_string(fpga_.plxdLivenessProven() ? 1 : 0) +
                                " published_bank=" + std::to_string(pubBank) + brf +
                                " ddr_prep_wait_us=" + std::to_string(dt.prep_wait_us) +
                                " ddr_copy_us=" + std::to_string(dt.copy_us) +
                                " ddr_flush_us=" + std::to_string(dt.flush_us) +
                                " ddr_doorbell_us=" + std::to_string(dt.doorbell_us) +
                                " ddr_post_wait_us=" + std::to_string(dt.post_wait_us) +
                                " ddr_total_us=" + std::to_string(dt.total_us) +
                                " ddr_bank_reuse_wait_us=" +
                                std::to_string(dt.bank_reuse_wait_us) +
                                " ddr_plxa_poll_us=" + std::to_string(dt.plxa_poll_us) +
                                " ddr_plxa_poll_iters=" +
                                std::to_string(dt.plxa_poll_iters) +
                                " av_hold_count=" + std::to_string(avHoldCount) +
                                " av_hold_wait_us=" + std::to_string(avHoldWaitUs) +
                                q0f + " tag=measured");
                        }
                        // VIDEO present vs ring phase. frames_done is swap count
                        // (not audio). Pair handoff_at=first_video_present A vs B.
                        if (audioActive_.load())
                            logMrAudioHandoffAt("first_video_present");
                    }
                    if ((presentCount_ % 48) == 0) {
                        log(std::string("media: fpga frame_tx ok via ") +
                            "DDR" +
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

        // Deterministic A/V origin:
        // 1) Wait for the audio pump thread so we never start on wall and then
        //    switch to audio mid-stream (that step discontinuity randomised lipsync
        //    by tens of ms — measured spread ~67 ms across identical runs).
        // 2) MrAudio stays GATED (audioStartGate_=false) until the first complete
        //    video frame. Early play created ~206 ms of already-heard audio before
        //    frame 1 (measured audio_origin_ms); the pacer then either dropped ~13
        //    frames to repay it (odd-only counters) or — under co-arm — re-based
        //    the clock and left the lead as permanent lip-sync error (grabber
        //    −168 → −456 ms). Holding the device closed removes the lead.
        // 3) On first frame we open the gate; pump writes held PCM from content
        //    t=0. Pacer uses raw audibleClockMs (no origin subtract). Startup only.
        if (wantAudio && apipe[0] >= 0) {
            const auto waitStart = std::chrono::steady_clock::now();
            while (!stop_.load() && !audioActive_.load() &&
                   std::chrono::steady_clock::now() - waitStart < std::chrono::seconds(5)) {
                std::this_thread::sleep_for(std::chrono::milliseconds(2));
            }
            const int64_t waited = std::chrono::duration_cast<std::chrono::milliseconds>(
                                       std::chrono::steady_clock::now() - waitStart)
                                       .count();
            log("media: A/V audio_active=" +
                std::string(audioActive_.load() ? "1" : "0") +
                " waited_ms=" + std::to_string(waited) +
                " — MrAudio gated until first video frame");
        }
        t0 = std::chrono::steady_clock::now(); // provisional; re-latched at audio release
        bool avAudioReleased = false;
        bool pauseClockHeld = false;
        bool pausedOverlayWasVisible = false;
        std::chrono::steady_clock::time_point pauseStarted{};
        std::chrono::steady_clock::time_point lastCompleteVideoFrame = t0;
        std::chrono::steady_clock::time_point lastAudioByte = t0;
        int64_t lastAudioBytesForEof = audioBytes_.load();
        bool eofStallLogged = false;
        size_t got = 0;
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
                        const auto now = std::chrono::steady_clock::now();
                        const int64_t elapsedMs =
                            std::chrono::duration_cast<std::chrono::milliseconds>(now - t0)
                                .count();
                        const int64_t noVideoMs =
                            std::chrono::duration_cast<std::chrono::milliseconds>(
                                now - lastCompleteVideoFrame)
                                .count();
                        const int64_t audioNow = audioBytes_.load();
                        if (audioNow > lastAudioBytesForEof) {
                            lastAudioBytesForEof = audioNow;
                            lastAudioByte = now;
                        }
                        const bool audioSeen = lastAudioBytesForEof > 0;
                        const int64_t noAudioSinceProgressMs =
                            std::chrono::duration_cast<std::chrono::milliseconds>(
                                now - lastAudioByte)
                                .count();
                        const int64_t noAudioMs = misterplex::eofStallAudioSilenceMs(
                            wantAudio, audioSeen, noVideoMs, noAudioSinceProgressMs);
                        const bool knownDurationStall = misterplex::knownDurationEofStall(
                            startMs, durationMs, elapsedMs, static_cast<int64_t>(got), noVideoMs,
                            noAudioMs);
                        if (misterplex::rawVideoTerminalSignal(
                                /*explicitStopOrSeek=*/false, /*readZero=*/false,
                                /*readError=*/false, /*shortRead=*/false,
                                knownDurationStall)) {
                            videoEof = true;
                            if (!eofStallLogged) {
                                eofStallLogged = true;
                                log("media: known-duration EOF after rawvideo stall elapsed_ms=" +
                                    std::to_string(elapsedMs) +
                                    " duration_ms=" + std::to_string(durationMs) +
                                    " partial_bytes=" + std::to_string(got) +
                                    " no_video_ms=" + std::to_string(noVideoMs) +
                                    " no_audio_ms=" + std::to_string(noAudioMs));
                            }
                            break;
                        }
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
                    if (misterplex::rawVideoTerminalSignal(/*explicitStopOrSeek=*/false,
                                                           /*readZero=*/false,
                                                           /*readError=*/true,
                                                           /*shortRead=*/false,
                                                           /*knownDurationStall=*/false)) {
                        log("media: read err errno=" + std::to_string(errno));
                        break;
                    }
                }
                if (n == 0) {
                    ++frameReadZero;
                    if (misterplex::rawVideoTerminalSignal(/*explicitStopOrSeek=*/false,
                                                           /*readZero=*/true,
                                                           /*readError=*/false,
                                                           /*shortRead=*/false,
                                                           /*knownDurationStall=*/false)) {
                        videoEof = true;
                        break;
                    }
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
                if (misterplex::rawVideoTerminalSignal(/*explicitStopOrSeek=*/false,
                                                       /*readZero=*/false,
                                                       /*readError=*/false,
                                                       /*shortRead=*/true,
                                                       /*knownDurationStall=*/false)) {
                    shortRead = true;
                    shortReadGot = got;
                    shortReadWant = frameBytes;
                    log("media: short read got=" + std::to_string(got) + "/" +
                        std::to_string(frameBytes) + " totalBytes=" + std::to_string(totalBytes) +
                        (videoEof ? " eof=1" : ""));
                    break;
                }
            }
            lastCompleteVideoFrame = std::chrono::steady_clock::now();
            got = 0;

            if (videoFmt == RawVideoFormat::Yuv420p) {
                if (profilePresent) {
                    const auto pix0 = std::chrono::steady_clock::now();
                    const int64_t pixCpu0 = threadCpuMicros();
                    clearYuv420pCropPadding(frame.data(), ddrGeometry);
                    // Safety net for defect A: if U/V stayed near 0 (green-cast
                    // class), force studio-neutral chroma so scanout is greyscale
                    // rather than full green. Y untouched. Logs once per session.
                    if (repairDeadYuv420pChroma(frame.data(), rawW, rawH)) {
                        static std::atomic<bool> chromaRepairLogged{false};
                        if (!chromaRepairLogged.exchange(true))
                            log("media: WARN repaired dead YUV420p chroma (U/V~0 → 128) "
                                "at " +
                                std::to_string(rawW) + "x" + std::to_string(rawH) +
                                " — green-cast class; check identity_skip / PMS delivery");
                    }
                    const int64_t pixCpu1 = threadCpuMicros();
                    const auto pix1 = std::chrono::steady_clock::now();
                    prof.pixelUs += microsBetween(pix0, pix1);
                    prof.pixelCpuUs += pixCpu1 - pixCpu0;
                } else {
                    clearYuv420pCropPadding(frame.data(), ddrGeometry);
                    if (repairDeadYuv420pChroma(frame.data(), rawW, rawH)) {
                        static std::atomic<bool> chromaRepairLogged{false};
                        if (!chromaRepairLogged.exchange(true))
                            log("media: WARN repaired dead YUV420p chroma (U/V~0 → 128) "
                                "at " +
                                std::to_string(rawW) + "x" + std::to_string(rawH) +
                                " — green-cast class; check identity_skip / PMS delivery");
                    }
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
                // Release audio once: open MrAudio gate at the first complete video
                // frame. Startup-window only (avAudioReleased). Physical start —
                // not a clock re-base (co-arm failed that distinction on silicon).
                if (!avAudioReleased) {
                    avAudioReleased = true;
                    t0 = std::chrono::steady_clock::now();
                    lastCompleteVideoFrame = t0;
                    // Arm shared origin for cluster axis (audio thread reads this).
                    const int64_t originMono = steadyMonoMs();
                    sessionOriginMonoMs_.store(originMono, std::memory_order_release);
                    avAudioReleaseMonoMs_.store(originMono, std::memory_order_release);
                    // Gate open is the physical start. content_origin must be 0:
                    // audioBytes_ is only incremented on MrAudio write, which the
                    // hold path forbids while the gate is closed.
                    const int64_t writtenBefore = audioBytes_.load();
                    const auto rel = misterplex::checkAudioReleaseOrigin(writtenBefore, /*held*/ 0);
                    audioStartGate_.store(true, std::memory_order_release);
                    // hold_wall_ms = first_audio_pcm → gate open (explicit; do not
                    // hand-subtract mono_ms). held_ms here is content_origin check
                    // (0 when hold worked); pump "audio release" has buffer held_ms.
                    const int64_t fa =
                        firstAudioPcmMonoMs_.load(std::memory_order_acquire);
                    std::string holdWall = " hold_wall_ms=NO-DATA";
                    if (fa >= 0)
                        holdWall = " hold_wall_ms=" + std::to_string(originMono - fa);
                    const std::string axis =
                        " mono_ms=" + std::to_string(originMono) + " wall_s=0.000" +
                        " held_ms=" + std::to_string(rel.heldMs) + holdWall +
                        " tag=measured";
                    if (wantAudio && audioActive_.load()) {
                        if (!rel.ok) {
                            log("ERROR media: A/V audio_release first_frame=" +
                                std::to_string(frameIndex) +
                                " content_origin_ms=" + std::to_string(rel.contentOriginMs) +
                                " audio_bytes_at_release=" +
                                std::to_string(rel.audioBytesAtRelease) + axis +
                                " — hold bypassed before gate open");
                        } else {
                            log("media: A/V audio_release first_frame=" +
                                std::to_string(frameIndex) +
                                " content_origin_ms=0 audio_bytes_at_release=0" + axis +
                                " (MrAudio starts; held PCM from content t=0)");
                        }
                        // Handoff sample at gate-open (before first write races).
                        // Parent: pair handoff_at=audio_release rptr/wptr across clusters.
                        logMrAudioHandoffAt("audio_release");
                    } else {
                        log("media: A/V audio_release first_frame=" +
                            std::to_string(frameIndex) +
                            " content_origin_ms=0" + axis +
                            " (wall clock; audio inactive)");
                    }
                }
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
                        // when the ring depth is unavailable. No origin subtract:
                        // gate ensures audible clock starts near 0 with frame 1.
                        clockMs = misterplex::audibleClockMs(
                            audioBytes_.load(), audioQueuedBytes_.load());
                    } else {
                        clockMs = std::chrono::duration_cast<std::chrono::milliseconds>(
                                      std::chrono::steady_clock::now() - t0)
                                      .count();
                    }
                    const int64_t drift = misterplex::avDriftMs(clockMs, frameMs);
                    avDriftMs_.store(drift);
                    const AvAction act = avDecide(drift, leadMs, dropMs, dropRun);
                    if (act == AvAction::Hold) {
                        // Always count holds (field 5). Profile path adds CPU accounting.
                        const auto hold0 = std::chrono::steady_clock::now();
                        if (profilePresent) {
                            const int64_t holdCpu0 = threadCpuMicros();
                            std::this_thread::sleep_for(std::chrono::milliseconds(2));
                            const int64_t holdCpu1 = threadCpuMicros();
                            const auto hold1 = std::chrono::steady_clock::now();
                            const int64_t hus = microsBetween(hold0, hold1);
                            framePacingWaitUs += hus;
                            framePacingWaitCpuUs += holdCpu1 - holdCpu0;
                            ++avHoldCount;
                            avHoldWaitUs += hus;
                        } else {
                            std::this_thread::sleep_for(std::chrono::milliseconds(2));
                            const auto hold1 = std::chrono::steady_clock::now();
                            ++avHoldCount;
                            avHoldWaitUs += microsBetween(hold0, hold1);
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
                const int64_t dropsNow = droppedFrames_.fetch_add(1) + 1;
                if (profilePresent)
                    ++prof.drops;
                // Every drop (not every 24th): startup-window instrument needs
                // wall_s of EACH drop. Steady state is zero drops so volume is
                // ~12–17 lines per session open only. mono_ms joins cluster axis.
                {
                    const auto dropNow = std::chrono::steady_clock::now();
                    const double dropWallS =
                        std::chrono::duration<double>(dropNow - t0).count();
                    log("media: A/V resync drop wall_s=" +
                        std::to_string(dropWallS).substr(0, 6) +
                        " mono_ms=" + std::to_string(steadyMonoMs()) +
                        " drift_ms=" + std::to_string(avDriftMs_.load()) +
                        " drops=" + std::to_string(dropsNow) +
                        " frames=" + std::to_string(frameIndex) +
                        " presents=" + std::to_string(presentCount_));
                }
            } else {
                dropRun = 0;
                presentCleanFrame(frame.data(), /*countPresent*/ true);
            }

            auto now = std::chrono::steady_clock::now();
            const int64_t wall2 = std::chrono::duration_cast<std::chrono::milliseconds>(
                                      now - t0)
                                      .count();
            // Field 5 cumulative: first 10 s of session wall after t0/origin.
            if (!hold10sLogged && wall2 >= 10000) {
                hold10sLogged = true;
                log("media: av_hold_first_10s mono_ms=" +
                    std::to_string(steadyMonoMs()) +
                    " wall_s=" +
                    std::to_string(static_cast<double>(wall2) / 1000.0).substr(0, 6) +
                    " av_hold_count=" + std::to_string(avHoldCount) +
                    " av_hold_wait_us=" + std::to_string(avHoldWaitUs) +
                    " av_hold_wait_ms=" + std::to_string(avHoldWaitUs / 1000) +
                    " tag=measured");
            }
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
                const int mw = measuredDeliveryW_.load();
                const int mh = measuredDeliveryH_.load();
                const auto led = frameLedgerLiveOf(frameIndex, presentCount_,
                                                   droppedFrames_.load(),
                                                   publishMisses_.load());
                const int64_t ltF = lifetimeFrames_.load() + frameIndex;
                const int64_t ltP = lifetimePresents_.load() + presentCount_;
                const int64_t ltD = lifetimeDrops_.load() + droppedFrames_.load();
                const int64_t ltM = lifetimePublishMisses_.load() + publishMisses_.load();
                const int64_t ltU = frameLedgerResidual(ltF, ltP, ltD);
                const uint64_t pep = processEpoch_.load(std::memory_order_acquire);
                const uint64_t sseq = streamSeq_.load(std::memory_order_acquire);
                // A5: av_drift_ms is servo error (pinned near -lead). Also emit
                // display-path offset (presentCount) which drops do not auto-heal.
                char avServoBuf[384];
                const int64_t driftNow = avDriftMs_.load();
                const int64_t dispOff = misterplex::avDisplayOffsetMs(
                    wantAudio && audioActive_.load()
                        ? misterplex::audibleClockMs(audioBytes_.load(), audioQueuedBytes_.load())
                        : wall2,
                    presentCount_, fpsNum, fpsDen);
                const int64_t pipeAhead =
                    misterplex::avPipeAheadMs(frameIndex, presentCount_, fpsNum, fpsDen);
                misterplex::formatAvServoTelemetry(avServoBuf, sizeof(avServoBuf), driftNow,
                                                   leadMs, dispOff, pipeAhead);
                // Exact integers are SoT for soak math; vfps/pfps are derived display
                // only (%.4f). Decode-side deficit = expected_frames - frames (content
                // vs wall). Presentation-side loss is a SEPARATE ledger (presents /
                // glass) — never conflate the two (parent DEFECT 2).
                log("media: " + frameLedgerTelemetryFragment(led) +
                    " vfps=" + fmtFpsRate(vfps) +
                    " pfps=" + fmtFpsRate(pfps) +
                    " audio_s=" + fmtSec3(a_sec) +
                    " wall_s=" + fmtSec3(static_cast<double>(wall2) / 1000.0) +
                    " wall_ms=" + std::to_string(wall2) +
                    " mono_ms=" + std::to_string(steadyMonoMs()) +
                    " audio=" + (audioActive_.load() ? "on" : "off") +
                    " clock=av-lock" +
                    " " + std::string(avServoBuf) +
                    " fps=" + std::to_string(fpsNum) + "/" + std::to_string(fpsDen) +
                    " fps_src=" +
                    [&]() -> std::string {
                        const int mn = measuredFpsNum_.load(std::memory_order_relaxed);
                        const int md = measuredFpsDen_.load(std::memory_order_relaxed);
                        if (mn > 0 && md > 0 &&
                            misterplex::supplyFpsRationalsAgree(fpsNum, fpsDen, mn, md))
                            return "measured";
                        if (fpsNum_ > 0)
                            return "caller_supplied";
                        return "DEFAULT_ASSUMED";
                    }() +
                    " measured_fps=" +
                    [&]() -> std::string {
                        const int mn = measuredFpsNum_.load(std::memory_order_relaxed);
                        const int md = measuredFpsDen_.load(std::memory_order_relaxed);
                        if (mn > 0 && md > 0)
                            return std::to_string(mn) + "/" + std::to_string(md);
                        return "NO-DATA";
                    }() +
                    " decode=" + std::to_string(outW_) + "x" + std::to_string(outH_) +
                    " decode_src=" + decodeSizeSource_ +
                    " decode_src_der=setDecodeSizeSource_not_hardcoded" +
                    " measured_delivery=" +
                    (mw > 0 ? (std::to_string(mw) + "x" + std::to_string(mh)) : "pending") +
                    " measured_delivery_src=" + (mw > 0 ? "measured" : "NO-DATA") +
                    // Live flag: flips to 1 only after MEASURED_DELIVERY (not play-time GEOM).
                    " delivery_verified=" +
                    (deliveryGeometryVerified_.load(std::memory_order_relaxed) ? "1" : "0") +
                    " desync_risk=" + (pipeDesyncRisk_.load() ? "1" : "0") +
                    " lifetime_frames=" + std::to_string(ltF) +
                    " lifetime_presents=" + std::to_string(ltP) +
                    " lifetime_drops=" + std::to_string(ltD) +
                    " lifetime_publish_misses=" + std::to_string(ltM) +
                    " lifetime_residual=" + std::to_string(ltU) +
                    " lifetime_residual_eq=frames-presents-drops" +
                    " lifetime_residual_scope=supply_arm_only" +
                    // Soak continuity markers (P4): process_epoch is stamped once at
                    // daemon start (steady mono_ms). pid changes on every respawn.
                    // A soak that sees either field change mid-window is interrupted.
                    " process_epoch=" + std::to_string(pep) +
                    " pid=" + std::to_string(static_cast<long>(::getpid())) +
                    " stream_seq=" + std::to_string(sseq) +
                    " session_epoch=" + sessionEpochString(pep, sseq) +
                    " session_completed=" + std::to_string(sessionSeq_.load()) +
                    " ffmpeg_out_frames=" +
                    (ffmpegOutFrames_.load(std::memory_order_relaxed) >= 0
                         ? std::to_string(ffmpegOutFrames_.load(std::memory_order_relaxed))
                         : "NO-DATA") +
                    // Line tag = weakest input (fps rate provenance). Counters above
                    // may be measured; do not blanket tag=measured (ERROR 17 / w-instr).
                    " tag=" +
                    [&]() -> std::string {
                        const int mn = measuredFpsNum_.load(std::memory_order_relaxed);
                        const int md = measuredFpsDen_.load(std::memory_order_relaxed);
                        if (mn > 0 && md > 0 &&
                            misterplex::supplyFpsRationalsAgree(fpsNum, fpsDen, mn, md))
                            return "measured";
                        if (fpsNum_ > 0)
                            return "caller_supplied";
                        return "DEFAULT_ASSUMED";
                    }());
                // Per-second supply bucket — resolvable at ~1 skip / 2.71 s.
                {
                    misterplex::SupplyCounters cur;
                    cur.frames = frameIndex;
                    cur.presents = presentCount_;
                    cur.drops = droppedFrames_.load();
                    cur.publish_misses = publishMisses_.load();
                    cur.pipe_bytes = static_cast<int64_t>(totalBytes);
                    cur.ffmpeg_out_frames =
                        ffmpegOutFrames_.load(std::memory_order_relaxed);
                    cur.wall_s = static_cast<double>(wall2) / 1000.0;
                    if (supplyPrevInit) {
                        const int mn =
                            measuredFpsNum_.load(std::memory_order_relaxed);
                        const int md =
                            measuredFpsDen_.load(std::memory_order_relaxed);
                        const bool haveM = mn > 0 && md > 0;
                        // Score expected_frames against measured banner rate when
                        // available; else pace rational. fps_src labels provenance.
                        int scoreN = fpsNum;
                        int scoreD = fpsDen;
                        const char* fpsSrc = misterplex::supplyFpsSrcName(
                            /*measured=*/false, /*caller_set=*/fpsNum_ > 0);
                        if (haveM) {
                            scoreN = mn;
                            scoreD = md;
                            fpsSrc = "measured";
                        }
                        auto d = misterplex::supplyBucketDelta(supplyPrev, cur, scoreN,
                                                               scoreD);
                        // Refuse gap when assumed unverified, or caller≠measured.
                        const char* decideSrc = fpsSrc;
                        if (haveM && fpsNum_ > 0 &&
                            !misterplex::supplyFpsRationalsAgree(fpsNum_, fpsDen_ > 0
                                                                             ? fpsDen_
                                                                             : 1,
                                                                 mn, md)) {
                            decideSrc = "caller_supplied"; // force mismatch path
                            scoreN = fpsNum_;
                            scoreD = fpsDen_ > 0 ? fpsDen_ : 1;
                            d = misterplex::supplyBucketDelta(supplyPrev, cur, scoreN,
                                                              scoreD);
                            fpsSrc = "caller_supplied";
                        } else if (!haveM && fpsNum_ <= 0) {
                            decideSrc = "DEFAULT_ASSUMED";
                            fpsSrc = "DEFAULT_ASSUMED";
                        }
                        const auto dec = misterplex::decideSupplyGapScore(
                            decideSrc, haveM, scoreN, scoreD, mn, md);
                        misterplex::applySupplyGapScore(d, dec);
                        const std::string se = sessionEpochString(pep, sseq);
                        log("media: " +
                            misterplex::formatSupplyBucketLine(
                                d, cur.wall_s, cur.frames, cur.presents, cur.drops,
                                cur.publish_misses, led.residual, cur.ffmpeg_out_frames,
                                scoreN, scoreD, se.c_str(), fpsSrc));
                        // PMS supply: do NOT log /proc/pid/io rchar here.
                        // VOID on this kernel (recv() ∉ rchar; parent syscr=5).
                        // Parent instrument: tools/pms_recvq_backlog_sample.sh (ss Recv-Q).
                    }
                    supplyPrev = cur;
                    supplyPrevInit = true;
                }
            }
            // Periodic hard check (B5): measured size vs reader under identity_skip.
            if (vfPlan.identity_skip && (frameIndex % 120) == 0) {
                const int mw = measuredDeliveryW_.load();
                const int mh = measuredDeliveryH_.load();
                if (mw > 0 && mh > 0) {
                    const size_t pb = yuv420pFrameBytesWH(mw, mh);
                    if (pipeDesyncRisk(pb, frameBytes, true)) {
                        pipeDesyncRisk_.store(true);
                        log("ERROR media: PIPE_DESYNC_RISK periodic measured=" +
                            std::to_string(mw) + "x" + std::to_string(mh) +
                            " producer_bytes=" + std::to_string(pb) +
                            " reader_bytes=" + std::to_string(frameBytes));
                    }
                }
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
        // Close video first so ffmpeg can exit and EOF stderr for the pump join.
        killChildren();
        if (errThr.joinable())
            errThr.join();

        // B5: byte-align + measured desync risk (remainder alone cannot see
        // producer≠reader while the read loop still fills frameBytes each time).
        // Assert total_bytes % runtime frameBytes == 0 (never a literal size).
        const bool byteAligned = rawPipeByteAligned(totalBytes, frameBytes);
        const int mw = measuredDeliveryW_.load();
        const int mh = measuredDeliveryH_.load();
        const size_t prodBytes = (mw > 0 && mh > 0) ? yuv420pFrameBytesWH(mw, mh) : 0;
        const bool phaseDesync =
            (prodBytes > 0) &&
            rawPipeDesynced(prodBytes, frameBytes, static_cast<size_t>(frameIndex));
        const bool risk = pipeDesyncRisk_.load() ||
                          pipeDesyncRisk(prodBytes, frameBytes, vfPlan.identity_skip) ||
                          phaseDesync || !byteAligned;
        if (risk)
            pipeDesyncRisk_.store(true);
        if (!byteAligned) {
            log("ERROR media: PIPE_BYTE_MISALIGN totalBytes=" + std::to_string(totalBytes) +
                " frameBytes=" + std::to_string(frameBytes) +
                " remainder=" + std::to_string(frameBytes ? totalBytes % frameBytes : 0) +
                " shortRead=" + (shortRead ? "1" : "0") + " tag=measured");
        } else if (totalBytes > 0) {
            log("media: pipe_align ok totalBytes=" + std::to_string(totalBytes) +
                " frameBytes=" + std::to_string(frameBytes) +
                " frames=" + std::to_string(frameIndex) +
                " total_mod_frame=0 tag=measured");
        }
        {
            const auto id =
                misterplex::supplyPipeIdentity(totalBytes, frameBytes, frameIndex);
            misterplex::SupplyBucketDelta win{};
            if (supplyPrevInit) {
                misterplex::SupplyCounters endc;
                endc.frames = frameIndex;
                endc.presents = presentCount_;
                endc.drops = droppedFrames_.load();
                endc.publish_misses = publishMisses_.load();
                endc.pipe_bytes = static_cast<int64_t>(totalBytes);
                endc.ffmpeg_out_frames =
                    ffmpegOutFrames_.load(std::memory_order_relaxed);
                endc.wall_s = supplyPrev.wall_s; // not used for stage at teardown
                // Whole-session style: compare end counters to zeros baseline.
                misterplex::SupplyCounters zero{};
                zero.ffmpeg_out_frames = -1;
                win = misterplex::supplyBucketDelta(zero, endc, fpsNum, fpsDen);
                // Prefer first-bucket→end if we have prev from last 1Hz (approx).
                win.d_frames = frameIndex;
                win.d_presents = presentCount_;
                win.d_drops = droppedFrames_.load();
                win.d_publish_misses = publishMisses_.load();
                win.d_residual =
                    misterplex::supplyResidual(frameIndex, presentCount_,
                                               droppedFrames_.load());
                win.supply_gap = 0; // filled below from wall if known
            }
            const int64_t ff = ffmpegOutFrames_.load(std::memory_order_relaxed);
            if (ff >= 0)
                win.d_ffmpeg_out = ff;
            win.ffmpeg_out_known = ff >= 0;
            const char* hint = misterplex::supplyStageHint(win, /*glass*/ 0, risk);
            log("media: " + misterplex::formatSupplyTeardownLine(id, totalBytes, frameBytes,
                                                                   ff, hint));
            if (!id.ok && totalBytes > 0) {
                log("ERROR media: SUPPLY_PIPE_IDENTITY_FAIL frames_from_bytes=" +
                    std::to_string(id.frames_from_bytes) +
                    " frame_index=" + std::to_string(frameIndex) +
                    " delta=" + std::to_string(id.delta_frames_vs_bytes) + " tag=measured");
            }
        }
        if (mw > 0 && mh > 0) {
            log("media: MEASURED_DELIVERY_FINAL delivered_geom=" + std::to_string(mw) + "x" +
                std::to_string(mh) + " src=ffmpeg_banner" +
                " producer_bytes=" + std::to_string(prodBytes) +
                " reader_bytes=" + std::to_string(frameBytes) +
                " identity_skip=" + (vfPlan.identity_skip ? "1" : "0") +
                " phase_desync=" + (phaseDesync ? "1" : "0") +
                " desync_risk=" + (risk ? "1" : "0") +
                " delivery_verified=1 delivery_basis=measured tag=measured");
        } else if (usedRawVideo) {
            log("media: MEASURED_DELIVERY_FINAL delivered_geom=NO-DATA src=ffmpeg_banner "
                "— banner not parsed (need -loglevel info + stderr pipe) delivery_verified=" +
                std::string(deliveryGeometryVerified_.load(std::memory_order_relaxed) ? "1"
                                                                                        : "0") +
                " tag=NO-DATA");
        }
        if (risk) {
            log("ERROR media: PIPE_DESYNC=1 phase_desync=" +
                std::string(phaseDesync ? "1" : "0") +
                " byte_align=" + std::string(byteAligned ? "1" : "0") +
                " producer_bytes=" + std::to_string(prodBytes) +
                " reader_bytes=" + std::to_string(frameBytes) +
                " frames=" + std::to_string(frameIndex) +
                " tag=measured — hard telemetry trip (B5)");
        }
        {
            std::lock_guard<std::mutex> lock(summaryMu_);
            lastSummary_.pipeDesync = risk;
            lastSummary_.pipeByteMisaligned = !byteAligned;
            lastSummary_.measuredW = mw;
            lastSummary_.measuredH = mh;
        }
    }

    killChildren();
    if (audioThr_.joinable())
        audioThr_.join();
    if (streamThr_.joinable())
        streamThr_.join();

    if (streamEnabled_ && frameIndex == 0) {
        FpgaSpi::BitstreamStatus st;
        if (fpga_.readBitstreamStatus(st)) {
            log("ERROR media: frames=0 with STREAM=1; DDR bitstream telemetry "
                "session=" + std::to_string(st.session_id) +
                " active=" + (st.active ? "1" : "0") +
                " paused=" + (st.paused ? "1" : "0") +
                " ring=" + std::to_string(st.ring_level) + "/" +
                std::to_string(st.ring_capacity) +
                " producer_bytes=" + std::to_string(st.producer_count) +
                " consumer_bytes=" + std::to_string(st.consumer_count) +
                " consumer_seq=" + std::to_string(st.consumer_seq) +
                " underrun=" + std::to_string(st.underrun_count) +
                " overrun=" + std::to_string(st.overrun_count) +
                " desync=" + std::to_string(st.desync_count) +
                " last_bad_seq=" + std::to_string(st.last_bad_seq) +
                " flags=u" + (st.underrun ? "1" : "0") +
                "o" + (st.overrun ? "1" : "0") +
                "d" + (st.desync ? "1" : "0") +
                "f" + (st.fatal ? "1" : "0"));
        } else {
            log("ERROR media: frames=0 with STREAM=1; DDR bitstream telemetry unreadable: " +
                fpga_.lastError());
        }
    }

    playing_.store(false);
    {
        std::lock_guard<std::mutex> lock(summaryMu_);
        lastSummary_.rawFrames = frameIndex;
        lastSummary_.presentedFrames = presentCount_;
        lastSummary_.reconFrames = reconFrames_.load();
        lastSummary_.totalBytes = static_cast<int64_t>(totalBytes);
        lastSummary_.usedRawVideo = usedRawVideo;
        lastSummary_.streamEnabled = streamEnabled_;
        lastSummary_.skipRgb = skipRgb;
        lastSummary_.shortRead = shortRead;
        lastSummary_.videoEof = videoEof;
        lastSummary_.shortReadGot = shortReadGot;
        lastSummary_.shortReadWant = shortReadWant;
        // pipeDesync / measured* may already be set from the rawvideo epilogue;
        // only fill measured from atomics if still zero.
        if (lastSummary_.measuredW == 0) {
            lastSummary_.measuredW = measuredDeliveryW_.load();
            lastSummary_.measuredH = measuredDeliveryH_.load();
        }
        if (!lastSummary_.pipeDesync)
            lastSummary_.pipeDesync = pipeDesyncRisk_.load();
    }
    // Natural EOF (not user stop / seek restart) → "ended" so main can auto-next.
    if (!stop_.load() && onProgress_) {
        const bool hadContent = usedRawVideo ? (frameIndex > 0) : (reconFrames_.load() > 0 ||
                                                                   positionMs_.load() > startMs + 500);
        if (hadContent)
            onProgress_("ended", positionMs_.load(), durationMs);
        else
            onProgress_("stopped", 0, durationMs);
    }
    if (idleMode() == IdleMode::LastFrame) {
        bool latched = false;
        if (lastFrameLatch.haveFrame()) {
            std::lock_guard<std::mutex> lk(presentMu_);
            if (!fpga_.ok() && presentMode_ != "none" && fpga_.open())
                useDdrF1_ = true;
            if (fpga_.ok() && useDdrF1_) {
                latched = lastFrameLatch.publishToBothBanks(
                    [this](const LastFrameLatch::Publication& pub) {
                        return fpga_.sendYuv420pFrameDdr(
                            pub.frame.data(), pub.frame.size(), pub.frame.geometry(), pub.bank);
                    },
                    ddrBank_);
            }
        }
        if (latched) {
            const DdrFrameGeometry& g = lastFrameLatch.frame().geometry();
            log("media: LastFrame idle latched complete DDR frame geometry=" +
                std::to_string(g.coded_width.get()) + "x" + std::to_string(g.coded_height.get()));
        } else {
            log("media: LastFrame idle requested but no complete DDR frame was available to latch");
        }
    } else {
        // The frame store latches the last frame written; without this the final frame
        // of the video stays on screen until something else paints over it.
        paintIdle();
    }
    startIdle();

    // Lifetime + append-only ledger BEFORE session counters are discarded.
    // presentCount_/droppedFrames_/publishMisses_ reset on the next play; ledger does not.
    const int64_t sessFrames = usedRawVideo ? frameIndex : reconFrames_.load();
    const int64_t sessPresents = presentCount_;
    const int64_t sessDrops = droppedFrames_.load();
    const int64_t sessPubMiss = publishMisses_.load();
    lifetimeFrames_.fetch_add(sessFrames, std::memory_order_relaxed);
    lifetimePresents_.fetch_add(sessPresents, std::memory_order_relaxed);
    lifetimeDrops_.fetch_add(sessDrops, std::memory_order_relaxed);
    lifetimePublishMisses_.fetch_add(sessPubMiss, std::memory_order_relaxed);
    const uint64_t sid = sessionSeq_.fetch_add(1, std::memory_order_relaxed) + 1;
    const char* endReason = stop_.load() ? "stop_or_seek" : "natural_eof";
    frameLedgerSessionEnd(sid, sessFrames, sessPresents, sessDrops, endReason, sessPubMiss);

    const auto ledEnd = frameLedgerLiveOf(sessFrames, sessPresents, sessDrops, sessPubMiss);
    const int64_t ltF = lifetimeFrames_.load();
    const int64_t ltP = lifetimePresents_.load();
    const int64_t ltD = lifetimeDrops_.load();
    const int64_t ltM = lifetimePublishMisses_.load();
    const uint64_t pep = processEpoch_.load(std::memory_order_acquire);
    const uint64_t sseq = streamSeq_.load(std::memory_order_acquire);
    log("media: session end " + frameLedgerTelemetryFragment(ledEnd) +
        " session=" + std::to_string(sid) +
        " process_epoch=" + std::to_string(pep) +
        " stream_seq=" + std::to_string(sseq) +
        " session_epoch=" + sessionEpochString(pep, sseq) +
        " lifetime_frames=" + std::to_string(ltF) +
        " lifetime_presents=" + std::to_string(ltP) +
        " lifetime_drops=" + std::to_string(ltD) +
        " lifetime_publish_misses=" + std::to_string(ltM) +
        " lifetime_residual=" +
            std::to_string(frameLedgerResidual(ltF, ltP, ltD)) +
        " lifetime_residual_eq=frames-presents-drops" +
        " lifetime_residual_scope=supply_arm_only" +
        " recon=" + std::to_string(reconFrames_.load()) +
        " cabac=" + (cabacSkip_.load() ? "1" : "0") +
        " stream=" + (streamEnabled_ ? "on" : "off") +
        " rawvideo=" + (usedRawVideo ? "on" : "off") +
        " present=" + presentMode_ +
        " skip_rgb=" + (skipRgb ? "1" : "0") +
        " reason=" + endReason +
        " tag=measured");
    // Session-end: interval + swap-delta (Δframes_done / phase ESTIMATE).
    // Parent greps publish_interval / publish_swap_delta.
    if (pubInterval_.iv_n > 0) {
        log(std::string("media: ") + pubInterval_.formatSummaryLine("measured") +
            " phase=session_end");
        log(std::string("media: ") + pubInterval_.formatDiscLine() + " phase=session_end");
        log(std::string("media: ") + pubInterval_.formatHistLine());
        log(std::string("media: ") + pubInterval_.formatAutocorrLine());
        log(std::string("media: ") + pubInterval_.formatCorrLine());
        if (const char* dump = std::getenv("MISTERPLEX_PUBLISH_INTERVAL_DUMP")) {
            if (dump[0] && pubInterval_.dumpMonoUs(dump))
                log(std::string("media: publish_interval_dump path=") + dump +
                    " cols=pre_us,write_us tag=measured");
            else if (dump[0])
                log(std::string("media: publish_interval_dump FAIL path=") + dump);
        }
    }
    if (pubSwapDelta_.pair_n > 0 || pubSwapDelta_.count > 0) {
        log(std::string("media: ") + pubSwapDelta_.formatSummaryLine("measured") +
            " phase=session_end");
        log(std::string("media: ") + pubSwapDelta_.formatCompatAliasLine() +
            " phase=session_end");
        log(std::string("media: ") + pubSwapDelta_.formatPhaseLine());
    }
    pubInterval_.reset();
    pubSwapDelta_.reset();
}

} // namespace misterplex
