#include <pthread.h>
#include "media_player.hpp"
#include "log_redact.hpp"
#include <sstream>

#include "libmisterplex/cached_src_phys.hpp"
#include "libmisterplex/ddr_frame_layout.hpp"
#include "libmisterplex/input_mailbox.hpp"
#include "libmisterplex/av_clock.hpp"
#include "libmisterplex/idle_screen.hpp"
#include "libmisterplex/osd_menu.hpp"
#include "libmisterplex/display_raster.hpp"
#include "libmisterplex/hdmi_auto_delay.hpp"
#include "libmisterplex/stick_bank_score.hpp"
#include "libmisterplex/h264_nal_dispatch.hpp"
#include "libmisterplex/h264_recon.hpp"
#include "libmisterplex/av_inproc_decode.hpp"
#include "libmisterplex/p720_transcode_vf.hpp"
#include "libmisterplex/p720_audio_keepup.hpp"
#include "libmisterplex/present_bank.hpp"
#include "libmisterplex/source_aspect.hpp"
#include "libmisterplex/fpga_playback_overlay.hpp"
#include "plex_resolve.hpp"
#include <algorithm>
#include <array>
#include <cctype>
#include <cerrno>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <chrono>
#include <condition_variable>
#include <exception>
#include <signal.h>
#include <time.h>
#include <vector>

#include <cstdlib>
#include <dirent.h>
#include <fcntl.h>
#include <poll.h>
#include <sched.h>
#include <sys/mman.h>
#include <sys/resource.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <unistd.h>
#ifdef __linux__
#include <sys/syscall.h>
#endif

#ifndef MAP_HUGETLB
#define MAP_HUGETLB 0x40000
#endif
#ifndef MPX_FABRIC_DIRECT
#define MPX_FABRIC_DIRECT 0
#endif
#ifndef MPX_STICK_I420
#define MPX_STICK_I420 0
#endif

namespace misterplex {
namespace {

#if MPX_FPGA_AV_TRACE && defined(MPX_HAVE_LIBAV)
using AvTraceSpan = FpgaAvTrace::Span;
struct AvTraceRelease {
    AvTraceSpan& span;
    ~AvTraceRelease() { span.released(); }
};

void tracePressure(AvTraceSpan& span, const AvCompressedPressure& before,
                   const AvCompressedPressure& after) {
    span.flags(FpgaAvRecord::ApproximatePressure);
    if (before.available) span.uvalue(2, before.pcmBytes);
    if (!after.available) return;
    span.uvalue(3, after.pcmBytes);
    span.uvalue(4, after.queuedPackets);
    span.uvalue(5, after.queuedBytes);
    span.value(6, static_cast<int>(after.blocked));
    span.value(7, after.inputEof);
    span.value(8, after.audioEof);
    span.value(9, after.reservedVideo);
}

void traceMast(AvTraceSpan& span, bool ok, const FpgaSpi::AudioSessionStatus& status,
               int64_t written, int64_t held, bool paused, bool approximateWritten) {
    span.value(0, ok);
    span.value(7, written);
    span.value(9, held);
    span.value(10, paused);
    if (approximateWritten) span.flags(FpgaAvRecord::ApproximateWritten);
    if (!ok) { span.force(); return; }
    span.uvalue(1, status.session_id);
    span.uvalue(2, status.nonce);
    span.uvalue(3, status.publication);
    span.uvalue(4, status.samples_consumed);
    span.value(5, unsigned(status.active) | (unsigned(status.paused) << 1) |
        (unsigned(status.read_pending) << 2) | (unsigned(status.prefetched) << 3));
    span.value(6, status.error);
    if (written >= 0 &&
        status.samples_consumed <= uint64_t(std::numeric_limits<int64_t>::max() / 4))
        span.value(8, written - static_cast<int64_t>(status.samples_consumed) * 4);
    if (!status.active || status.error) span.force();
}
#endif

// PMS universal already bakes offset= (seconds). Applying FFmpeg -ss again double-seeks
// and breaks resume / mid-play scrub on STREAM=0 cast. Timeline still uses startMs.
inline bool isUniversalTranscodeUrl(const std::string& url) {
    return url.find("transcode/universal") != std::string::npos ||
           url.find("/video/:/transcode/") != std::string::npos;
}

inline bool waitPidMs(pid_t pid, int timeoutMs, int* statusOut) {
    if (pid <= 0)
        return false;
    const auto t0 = std::chrono::steady_clock::now();
    for (;;) {
        int st = 0;
        const pid_t w = ::waitpid(pid, &st, WNOHANG);
        if (w == pid) {
            if (statusOut)
                *statusOut = st;
            return true;
        }
        const auto ms = std::chrono::duration_cast<std::chrono::milliseconds>(
                            std::chrono::steady_clock::now() - t0)
                            .count();
        if (ms >= timeoutMs)
            return false;
        ::usleep(20000);
    }
}

// Never mix pthread_timedjoin_np with std::thread: a successful native join
// leaves the C++ object joinable, and detach() then throws system_error
// "No such process" — terminate, Play spinner, last frame stuck. Interrupt
// + close PCM fds + WNOHANG reap make a normal join return.

// Branch B: compile-time MPX_FABRIC_DIRECT=1 or env MPX_FABRIC_DIRECT=1.
// Default OFF — 480p / 07f54d9f still use sendDdrFrame memcpy.
inline bool fabricDirectWanted() {
    const char* e = std::getenv("MPX_FABRIC_DIRECT");
    if (e && *e) {
        const char c = e[0];
        if (c == '0' || c == 'n' || c == 'N' || c == 'f' || c == 'F' || c == 'o' ||
            c == 'O')
            return false;
        return true;
    }
#if MPX_FABRIC_DIRECT
    return true;
#else
    // 720p call sites also require L4 geometry. Cached contig slots + PL330
    // retire uncached memcpy; 480p still memcpy (geometry gate).
    return true;
#endif
}

#if defined(__linux__)
pid_t findCommPid(const char* name) {
    DIR* dir = ::opendir("/proc");
    if (!dir)
        return -1;
    pid_t found = -1;
    while (dirent* ent = ::readdir(dir)) {
        if (ent->d_name[0] < '1' || ent->d_name[0] > '9')
            continue;
        char path[64];
        std::snprintf(path, sizeof(path), "/proc/%s/comm", ent->d_name);
        FILE* f = std::fopen(path, "r");
        if (!f)
            continue;
        char comm[32] = {};
        const bool ok = std::fgets(comm, sizeof(comm), f) != nullptr;
        std::fclose(f);
        if (!ok)
            continue;
        char* nl = std::strchr(comm, '\n');
        if (nl)
            *nl = 0;
        if (std::strcmp(comm, name) == 0) {
            found = static_cast<pid_t>(std::atoi(ent->d_name));
            break;
        }
    }
    ::closedir(dir);
    return found;
}

bool g_misterNiced = false;
int g_misterNiceSaved = 0;

void setMisterNice(int niceVal, const MediaPlayer::LogFn& log) {
    const pid_t pid = findCommPid("MiSTer");
    if (pid <= 0)
        return;
    errno = 0;
    const int cur = ::getpriority(PRIO_PROCESS, pid);
    if (errno != 0)
        return;
    if (!g_misterNiced) {
        g_misterNiceSaved = cur;
        g_misterNiced = true;
    }
    if (::setpriority(PRIO_PROCESS, pid, niceVal) == 0 && log) {
        log("media: MiSTer pid=" + std::to_string(pid) + " nice=" +
            std::to_string(niceVal) + " (was " + std::to_string(cur) + ")");
    }
}

void restoreMisterNice(const MediaPlayer::LogFn& log) {
    if (!g_misterNiced)
        return;
    const pid_t pid = findCommPid("MiSTer");
    if (pid > 0)
        (void)::setpriority(PRIO_PROCESS, pid, g_misterNiceSaved);
    if (log)
        log("media: MiSTer nice restored");
    g_misterNiced = false;
}
#endif

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

// In-place UV plane bias for planar YUV420p (Y then U then V). Used to counter
// measured fluorescent-green U-low on HDMI vs source (see UV_U_BIAS conf).
inline void applyYuv420pUvBias(uint8_t* yuv, int width, int height, int uBias, int vBias) {
    if (!yuv || width <= 0 || height <= 0 || (uBias == 0 && vBias == 0))
        return;
    const size_t yBytes = static_cast<size_t>(width) * static_cast<size_t>(height);
    const size_t cBytes = yBytes / 4u;
    uint8_t* u = yuv + yBytes;
    uint8_t* v = u + cBytes;
    auto add = [](uint8_t* p, size_t n, int bias) {
        if (bias == 0)
            return;
        for (size_t i = 0; i < n; ++i) {
            int x = static_cast<int>(p[i]) + bias;
            if (x < 0)
                x = 0;
            else if (x > 255)
                x = 255;
            p[i] = static_cast<uint8_t>(x);
        }
    };
    add(u, cBytes, uBias);
    add(v, cBytes, vBias);
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

void setSourceAspectProbeFail(std::string* dest, const char* why,
                              size_t stderrBytes = 0) {
    if (!dest)
        return;
    if (std::strcmp(why, "timeout") == 0 || std::strcmp(why, "empty_dar") == 0) {
        char buf[96];
        std::snprintf(buf, sizeof(buf), "%s stderr_b=%zu", why, stderrBytes);
        *dest = buf;
        return;
    }
    *dest = why;
}

SourceAspect ffmpegSourceAspect(const std::string& ffmpeg, const std::string& url,
                                const std::string& headers,
                                std::string* failDetail = nullptr,
                                int* codedW = nullptr,
                                int* codedH = nullptr,
                                int* fpsNum = nullptr,
                                int* fpsDen = nullptr) {
    int stderrPipe[2]{-1, -1};
#if defined(__linux__)
    if (pipe2(stderrPipe, O_CLOEXEC) != 0) {
        setSourceAspectProbeFail(failDetail, "pipe");
        return {};
    }
#else
    if (pipe(stderrPipe) != 0) {
        setSourceAspectProbeFail(failDetail, "pipe");
        return {};
    }
#endif

    std::vector<std::string> args = {
        ffmpeg, "-hide_banner", "-loglevel", "info", "-nostdin",
    };
    if (!headers.empty()) {
        std::string h = headers;
        if (h.size() < 2 || h[h.size() - 1] != '\n')
            h += "\r\n";
        args.push_back("-headers");
        args.push_back(h);
    }
    if (url.rfind("http", 0) == 0) {
        args.push_back("-rw_timeout");
        args.push_back("4000000");
    }
    args.insert(args.end(), {
        "-i", url, "-map", "0:v:0", "-frames:v", "0",
        "-an", "-sn", "-dn", "-f", "null", "-",
    });

    const pid_t pid = fork();
    if (pid < 0) {
        ::close(stderrPipe[0]);
        ::close(stderrPipe[1]);
        setSourceAspectProbeFail(failDetail, "fork");
        return {};
    }
    if (pid == 0) {
        ::close(stderrPipe[0]);
        const int devnull = ::open("/dev/null", O_WRONLY);
        if (devnull >= 0)
            dup2(devnull, STDOUT_FILENO);
        dup2(stderrPipe[1], STDERR_FILENO);
        if (devnull > STDERR_FILENO)
            ::close(devnull);
        if (stderrPipe[1] > STDERR_FILENO)
            ::close(stderrPipe[1]);
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

    ::close(stderrPipe[1]);
    std::string output;
    std::array<char, 4096> buffer{};
    const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(5);
    bool timedOut = false;
    bool pipeClosed = false;
    while (!pipeClosed) {
        const auto now = std::chrono::steady_clock::now();
        if (now >= deadline) {
            timedOut = true;
            break;
        }
        const int timeoutMs = std::max(
            1, static_cast<int>(std::chrono::duration_cast<std::chrono::milliseconds>(
                                    deadline - now)
                                    .count()));
        pollfd pfd{stderrPipe[0], POLLIN | POLLHUP, 0};
        const int ready = ::poll(&pfd, 1, timeoutMs);
        if (ready < 0) {
            if (errno == EINTR)
                continue;
            pipeClosed = true;
            break;
        }
        if (ready == 0) {
            timedOut = true;
            break;
        }
        if (pfd.revents & (POLLIN | POLLHUP)) {
            const ssize_t n = ::read(stderrPipe[0], buffer.data(), buffer.size());
            if (n > 0) {
                if (output.size() < 65536) {
                    const size_t keep =
                        std::min(static_cast<size_t>(n), 65536u - output.size());
                    output.append(buffer.data(), keep);
                }
            } else if (n == 0) {
                pipeClosed = true;
            } else if (errno != EINTR) {
                pipeClosed = true;
            }
        } else if (pfd.revents & (POLLERR | POLLNVAL)) {
            pipeClosed = true;
        }
    }
    ::close(stderrPipe[0]);
    int st = 0;
    bool reaped = false;
    while (!timedOut && std::chrono::steady_clock::now() < deadline) {
        const pid_t waited = waitpid(pid, &st, WNOHANG);
        if (waited == pid) {
            reaped = true;
            break;
        }
        if (waited < 0 && errno != EINTR) {
            reaped = true;
            break;
        }
        usleep(10000);
    }
    if (!reaped) {
        timedOut = true;
        ::kill(pid, SIGTERM);
        for (int i = 0; i < 20; ++i) {
            if (waitpid(pid, &st, WNOHANG) == pid) {
                reaped = true;
                break;
            }
            usleep(10000);
        }
        if (!reaped) {
            ::kill(pid, SIGKILL);
            while (waitpid(pid, &st, 0) < 0 && errno == EINTR) {
            }
        }
    }
    if (timedOut) {
        setSourceAspectProbeFail(failDetail, "timeout", output.size());
        return {};
    }
    if (reaped && WIFEXITED(st) && WEXITSTATUS(st) == 127) {
        setSourceAspectProbeFail(failDetail, "exec");
        return {};
    }
    // A damaged stream can still have an authoritative DAR in its parsed
    // header. Preserve that fact so playback reaches the independent
    // zero-frame/short-read guard instead of misclassifying it as unknown DAR.
    const auto parsed = sourceAspectFromFfmpegProbeText(output);
    if (!parsed.valid)
        setSourceAspectProbeFail(failDetail, "empty_dar", output.size());
    if (codedW || codedH) {
        int pw = 0, ph = 0;
        if (codedSizeFromFfmpegProbeText(output, pw, ph)) {
            if (codedW)
                *codedW = pw;
            if (codedH)
                *codedH = ph;
        }
    }
    if (fpsNum || fpsDen) {
        std::string tok;
        int pn = 0, pd = 0;
        if (fpsTokenFromFfmpegProbeText(output, tok) &&
            parseExactFps("", tok, pn, pd) && pn > 0 && pd > 0) {
            if (fpsNum)
                *fpsNum = pn;
            if (fpsDen)
                *fpsDen = pd;
        }
    }
    return parsed;
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
    if (log_)
        log_(s);
    else
        std::fprintf(stderr, "%s\n", s.c_str());
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
#if defined(__linux__)
        pthread_setname_np(pthread_self(), "mpx-osd");
#endif
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
                const bool first = !osdSeen_.exchange(true);
                lastOsd_.store(word);
                // Log-only leftover: F12 T[10] must not open browse (PLXI cmd=5).
                if (!first && (word & (1u << 10)) && !(prev & (1u << 10)))
                    log("media: OSD T[10] leftover ignored (browse is PLXI cmd=5)");
                if (first || osdChanged(prev, word))
                    applyOsd(word);
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
#if defined(__linux__)
        pthread_setname_np(pthread_self(), "mpx-input");
#endif
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

void MediaPlayer::suspendFpgaWorkers() {
    stopInputPoll();
    stopOsdPoll();
    stopIdle();
}

void MediaPlayer::resumeFpgaWorkers(bool restoreIdle) {
    if (restoreIdle) {
        paintIdle();
        startIdle();
    }
    startInputPoll();
    startOsdPoll();
}

void MediaPlayer::openLibraryBrowser() {
    if (playing_.load() || shuttingDown_.load()) {
        log("media: library browse aborted (playing/shutdown)");
        return;
    }
    if (!libraryFetch_) {
        log("media: library browse needs PLEX_TOKEN / fetch");
        {
            std::lock_guard<std::mutex> lk(libraryMu_);
            library_.show({}, "no plex token");
        }
        if (!playing_.load() && !shuttingDown_.load())
            paintIdle();
        return;
    }
    log("media: library browse open");
    const std::string xml = libraryFetch_("/library/sections");
    auto rows = parseLibraryXml(xml);
    if (playing_.load() || shuttingDown_.load()) {
        log("media: library browse aborted after fetch (play won)");
        return;
    }
    {
        std::lock_guard<std::mutex> lk(libraryMu_);
        library_.show(std::move(rows), xml.empty() ? "fetch failed" : "");
    }
    if (playing_.load() || shuttingDown_.load()) {
        std::lock_guard<std::mutex> lk(libraryMu_);
        library_.hide();
        log("media: library browse aborted after show (play won)");
        return;
    }
    paintIdle();
}

void MediaPlayer::requestOpenLibraryBrowser() {
    log("media: library browse request (always-open)");
    if (shuttingDown_.load())
        return;
    if (playing_.load()) {
        if (browseOpenBusy_.exchange(true)) {
            log("media: library browse already in flight");
            return;
        }
        // stop() joins play/OSD/idle — never run on those threads.
        std::lock_guard<std::mutex> lk(browseThrMu_);
        if (browseThr_.joinable())
            browseThr_.join();
        browseThr_ = std::thread([this] {
#if defined(__linux__)
            pthread_setname_np(pthread_self(), "mpx-browse");
#endif
            stop();
            if (!shuttingDown_.load() && !playing_.load())
                openLibraryBrowser();
            browseOpenBusy_.store(false);
        });
        return;
    }
    openLibraryBrowser();
}

void MediaPlayer::libraryActivate() {
    LibraryRow row;
    {
        std::lock_guard<std::mutex> lk(libraryMu_);
        const LibraryRow* cur = library_.current();
        if (!cur)
            return;
        row = *cur;
    }
    if (row.directory) {
        if (!libraryFetch_)
            return;
        const std::string path = libraryListPath(row);
        log("media: library enter " + (path.empty() ? row.key : path));
        const std::string xml = libraryFetch_(path.empty() ? row.key : path);
        if (playing_.load() || shuttingDown_.load()) {
            log("media: library enter aborted (play won)");
            return;
        }
        {
            std::lock_guard<std::mutex> lk(libraryMu_);
            library_.push(parseLibraryXml(xml));
        }
        paintIdle();
        return;
    }
    if (row.ratingKey.empty() || !libraryPlay_)
        return;
    {
        std::lock_guard<std::mutex> lk(libraryMu_);
        library_.hide();
    }
    log("media: library play ratingKey=" + row.ratingKey);
    libraryPlay_(row.ratingKey);
}

bool MediaPlayer::libraryHandleInput(PlaybackCommand command) {
    if (command == PlaybackCommand::Browse) {
        requestOpenLibraryBrowser();
        return true;
    }
    bool vis = false;
    {
        std::lock_guard<std::mutex> lk(libraryMu_);
        vis = library_.visible;
    }
    if (!vis) {
        if (!playing_.load() && command == PlaybackCommand::Stop) {
            openLibraryBrowser();
            return true;
        }
        return false;
    }
    log(std::string("media: library input cmd=") + std::to_string(static_cast<int>(command)));
    switch (command) {
    case PlaybackCommand::PlayPause:
        libraryActivate();
        return true;
    case PlaybackCommand::Stop: {
        std::lock_guard<std::mutex> lk(libraryMu_);
        if (!library_.pop())
            library_.hide();
        break;
    }
    case PlaybackCommand::SkipForward: {
        std::lock_guard<std::mutex> lk(libraryMu_);
        library_.move(1);
        break;
    }
    case PlaybackCommand::SkipBack: {
        std::lock_guard<std::mutex> lk(libraryMu_);
        library_.move(-1);
        break;
    }
    default:
        return false;
    }
    paintIdle();
    return true;
}

void MediaPlayer::dispatchPlaybackInput(PlaybackCommand command) {
    log(std::string("media: input cmd=") + std::to_string(static_cast<int>(command)));
    if (libraryHandleInput(command))
        return;
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

    // Content (O[5:4]) owns DECODE/PMS. Display (O[15:14]) owns video_mode.
    // First sample seeds last* (default 240p must not look like 240→720) but
    // still applies the live Display row to /dev/MiSTer_cmd (daemon start).
    const ContentResolution& cr = s.contentResolution;
    const ContentResolution& dr = s.displayResolution;
    int nextW = outW_;
    int nextH = outH_;
    const bool retargeted =
        osdRetargetDecodeSizeFromPresented(nextW, nextH, cr, liveGlass_, rbfPrefix8_);
    if (retargeted)
        setDecodeSize(nextW, nextH);
    if ((idleChanged || retargeted) && !playing_.load())
        paintIdle();
    // Display O[15:14]: persist only. video_mode is latched at daemon start /
    // core reset — do not poke /dev/MiSTer_cmd while the user flips F12.
    const bool contentChanged =
        osdResSeeded_ &&
        (lastContentRes_.width != cr.width || lastContentRes_.height != cr.height);
    const bool displayChanged =
        osdResSeeded_ &&
        (lastDisplayRes_.width != dr.width || lastDisplayRes_.height != dr.height);
    lastContentRes_ = cr;
    lastDisplayRes_ = dr;
    osdResSeeded_ = true;
    if (contentChanged && onContentRes_) {
        const bool nowPlaying = playing_.load();
        log(std::string("media: res change content→") + cr.label + " display→" + dr.label +
            " " + std::to_string(dr.width) + "x" + std::to_string(dr.height) +
            (nowPlaying ? " (live restart)" : " (next play)"));
        onContentRes_(cr, nowPlaying);
    }
    if (displayChanged && onDisplayRes_)
        onDisplayRes_(dr);

    log("media: OSD word=0x" + hex16(word) + " av_offset_ms=" + std::to_string(s.avOffsetMs) +
        " clock_ppm=" + std::to_string(audioClockPpm_) +
        " resync=" + (s.resyncEnabled ? "on" : "off") +
        " content_res=" + cr.label + " display_res=" + dr.label +
        " decode=" + std::to_string(outW_) + "x" + std::to_string(outH_));
}

void MediaPlayer::latchAndApplyDisplayRaster(const ContentResolution& display) {
    latchedDisplayRes_ = display;
    displayRasterLatched_ = true;
    lastDisplayRes_ = display;
    // Seed lastVideoModeCmd_ so IfChanged does not rewrite a live CEA 720p60
    // raster on every daemon start. A same-modeline video_mode poke resets
    // ddr_frame_store (primed=0, have_seq=0) and freezes glass on the chevron.
    if (const char* cmd = videoModeCmdForDisplayLabel(display.label))
        lastVideoModeCmd_ = cmd;
    applyDisplayRaster(display, /*force=*/false);
    if (!playing_.load())
        paintIdle();
}

void MediaPlayer::applyLiveDisplayRaster(const ContentResolution& osdDisplay, bool force) {
    // Re-arm the *latched* row only (Main vid_changed). Ignore a live OSD
    // Display that has not been reset into the latch.
    if (displayRasterLatched_)
        applyDisplayRaster(latchedDisplayRes_, force);
    else
        applyDisplayRaster(osdDisplay, force);
}

void MediaPlayer::applyDisplayRaster(const ContentResolution& display, bool force) {
    const char* cmd = videoModeCmdForDisplayLabel(display.label);
    // 112bb + CEA 720p24 HDMI (30000 kHz) wrote and HURT: 14.5/12.31 vs
    // 15.4/12.87 at 720p60. ascal 60→24 is not the unique24 closer. L4 stays
    // on 720p60. kVideoModeCmd720p24 remains a legal cmd for a later design.
    const char* next = force ? (videoModeCmdIsSafe(cmd) ? cmd : nullptr)
                             : videoModeCmdIfChanged(cmd, lastVideoModeCmd_.c_str());
    if (!next) {
        log(std::string("media: display raster ") + (display.label ? display.label : "?") +
            " unchanged (skip video_mode force=" + (force ? "1" : "0") + ")");
        return;
    }
    const int rc = writeMisterCmdLine(kMisterCmdPath, next);
    if (rc > 0) {
        lastVideoModeCmd_ = next;
        log(std::string("media: display raster ") + (display.label ? display.label : "?") +
            " → " + next);
        return;
    }
    // Fail closed: missing cmd node is not a crash and is not HDMI PASS.
    log(std::string("media: /dev/MiSTer_cmd missing or unwritable; raster unchanged (") + next +
        ")");
}

void MediaPlayer::paintIdle() {
    if (backend_ != VideoBackend::LegacySoftware)
        return; // FPGA picture/reference memory is never an ARM UI scratch bank.
    const IdleMode m = idleMode();
    bool libVis = false;
    {
        std::lock_guard<std::mutex> lk(libraryMu_);
        libVis = library_.visible;
    }
    if (m == IdleMode::LastFrame && !libVis)
        return;
    // Bank is DECODE (L4 1280 store). Chevron *design* follows latched Display
    // so 240p/480p reset makes a chunkier mark; nearest-scale into the bank
    // (do not paint a 624x480 payload into a 1280 store — yellow/static).
    const int w = outW_ > 0 ? outW_ : 320;
    const int h = outH_ > 0 ? outH_ : 240;
    const int designW = (displayRasterLatched_ && latchedDisplayRes_.width > 0)
                            ? latchedDisplayRes_.width
                            : w;
    const int designH = (displayRasterLatched_ && latchedDisplayRes_.height > 0)
                            ? latchedDisplayRes_.height
                            : h;
    std::vector<uint8_t> buf(static_cast<size_t>(w) * h * 3);
    renderIdleRgb24(buf.data(), w, h, m, idlePhase_.load());

    std::lock_guard<std::mutex> lk(presentMu_);
    if (fb_.ok() && !fb_.blitRgb24(buf.data(), w, h))
        log("media: idle fb0 blit failed");
    // F1 latches the last frame written, so the frame store must be repainted too.
    // C3 frame-store DDR is YUV-only, so encode the same idle renderer as I420
    // instead of ringing the doorbell with an RGB payload.
    if (fpga_.ok()) {
        bool ok = false;
        if (useDdrF1_) {
            const DdrFrameGeometry g = ddrFrameGeometryForPresentedSize(w, h);
            const DdrFrameLayout layout =
                makeDdrFrameLayout(g, kDdrFramePhysBase, kDdrFrameStrideAlign,
                                   DdrFrameFormat::Yuv420p);
            std::vector<uint8_t> yuv(layout.frame_bytes);
            bool painted = false;
            if (layout.frame_bytes > 0 && designW > 0 && designH > 0 &&
                (designW & 1) == 0 && (designH & 1) == 0 &&
                (designW != g.coded_width || designH != g.coded_height)) {
                const size_t ysz =
                    static_cast<size_t>(designW) * static_cast<size_t>(designH);
                const size_t csz = ysz / 4;
                std::vector<uint8_t> src(ysz + 2 * csz);
                if (renderIdleYuv420p(src.data(), designW, designH, m, idlePhase_.load(),
                                      0, designW) &&
                    scaleI420NearestPlanes(src.data(), designW, src.data() + ysz,
                                           designW / 2, src.data() + ysz + csz,
                                           designW / 2, designW, designH, yuv.data(),
                                           g.coded_width, g.coded_height,
                                           layout.frame_bytes)) {
                    painted = true;
                    log(std::string("media: idle chevron design=") +
                        std::to_string(designW) + "x" + std::to_string(designH) +
                        " bank=" + std::to_string(g.coded_width) + "x" +
                        std::to_string(g.coded_height));
                }
            }
            if (!painted && layout.frame_bytes > 0)
                painted = renderIdleYuv420p(yuv.data(), g.coded_width, g.coded_height, m,
                                            idlePhase_.load(), g.crop_left, g.display_width);
            {
                std::lock_guard<std::mutex> lk(libraryMu_);
                if (library_.visible && !yuv.empty()) {
                    renderLibraryI420(yuv.data(), g.coded_width, g.coded_height, library_);
                    painted = true;
                }
            }
            if (painted) {
                // 480p: paint both banks so a later swap cannot flash a stale
                // silhouette. 720p24 L4 (5a7c5085): the second idle doorbell
                // leaves PLXD free=0 pending=1 frames_done=2; RequireReleased
                // then cannot retire the next swap (150 ms wait confirmed).
                const bool wantFabric =
                    fabricDirectWanted() && isPlex720pDdrFrameGeometry(g);
                fpga_.setFabricDirectPresent(wantFabric);
                const bool wantStick =
                    stickI420Wanted() && isPlex720pDdrFrameGeometry(g);
                fpga_.setStickI420Present(wantStick);
                uint32_t idleSrcPhys = 0;
                const uint8_t* idlePayload = yuv.data();
                if (wantFabric) {
                    // Heap std::vector is never 338-page contig → always STUB.
                    // Reuse process-lifetime idleFabric_ (same allocator as play).
                    if (idleFabric_.slot[0].phys == 0) {
                        (void)allocateFabricDirectSlots(idleFabric_, yuv.size(),
                                                        /*tryCompact=*/true,
                                                        /*minSlots=*/1);
                    }
                    if (idleFabric_.slot[0].phys != 0 && idleFabric_.slot[0].virt) {
                        std::memcpy(idleFabric_.slot[0].virt, yuv.data(), yuv.size());
                        idlePayload = idleFabric_.slot[0].virt;
                        // Keep process-lifetime virt; phys tracks live PFN.
                        idleSrcPhys = refreshFabricSlotPhys(idleFabric_.slot[0],
                                                            yuv.size());
                    } else {
                        idleSrcPhys = 0;
                    }
                    char pbuf[20];
                    std::snprintf(pbuf, sizeof(pbuf), "0x%08x",
                                  static_cast<unsigned>(idleSrcPhys));
                    log(std::string("media: fabric_direct idle src_phys=") +
                        (idleSrcPhys != 0 ? "REAL" : "STUB") + " slot=" + pbuf +
                        " how=" + fabricDirectHow(idleFabric_));
                }
                {
                    const auto sc = scoreI420Y(yuv.data(), g.coded_width, g.coded_height, 4);
                    char sbuf[192];
                    formatStickBankScore(sbuf, sizeof(sbuf), sc);
                    log(std::string("media: idle I420 ") + sbuf);
                }
                const bool ok0 = fpga_.sendYuv420pFrameDdr(
                    idlePayload, yuv.size(), g, 0, DdrBankWritePolicy::BestEffort,
                    idleSrcPhys);
                const bool ok1 =
                    (g.presented_height >= kPlex720pPresentedHeight)
                        ? false
                        : fpga_.sendYuv420pFrameDdr(
                              idlePayload, yuv.size(), g, 1,
                              DdrBankWritePolicy::BestEffort, idleSrcPhys);
                // 720p paints the free bank then doorbells; if the swap is
                // stuck, HDMI keeps the old chevron. Overwrite the scanned bank.
                const bool okDisp = fpga_.blitDisplayedBank(idlePayload, yuv.size());
                ok = ok0 || ok1 || okDisp;
                ddrBank_ = 0;
            }
        }
        if (!ok) {
            if (!idleWarned_.exchange(true))
                log("media: idle paint DDR failed (will retry on re-probe): " +
                    fpga_.lastError());
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
    if (backend_ != VideoBackend::LegacySoftware)
        return;
    std::lock_guard<std::mutex> lk(idleMu_);
    if (shuttingDown_.load() || idleRun_.exchange(true))
        return;
    if (idleThr_.joinable())
        idleThr_.join();
    idleThr_ = std::thread([this] {
#if defined(__linux__)
        pthread_setname_np(pthread_self(), "mpx-idle");
#endif
        while (idleRun_.load()) {
            bool libVis = false;
            {
                std::lock_guard<std::mutex> lk(libraryMu_);
                libVis = library_.visible;
            }
            if (playing_.load() || (idleMode() == IdleMode::LastFrame && !libVis)) {
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
    if (fpgaH264Backend()) {
        outW_ = 320;
        outH_ = 240;
        return;
    }
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

SourceAspect MediaPlayer::probeSourceAspect(const std::string& urlOrPath,
                                            const std::string& httpHeaders,
                                            std::string* failDetail,
                                            int* codedW,
                                            int* codedH,
                                            int* fpsNum,
                                            int* fpsDen) const {
    if (fpgaH264Backend()) {
        if (failDetail)
            *failDetail = "source aspect deferred to the sole compressed demux";
        return {};
    }
    return ffmpegSourceAspect(ffmpeg_, urlOrPath, httpHeaders, failDetail, codedW,
                              codedH, fpsNum, fpsDen);
}

bool MediaPlayer::setSourceAspect(const SourceAspect& aspect) {
    if (fpgaH264Backend()) {
        std::lock_guard<std::mutex> present(presentMu_);
        sourceAspect_ = aspect;
        return true; // Published with a matching core session, before its first AU.
    }
    if (!aspect.valid) {
        log("ERROR media: refusing playback with unknown source display aspect");
        return false;
    }
    std::lock_guard<std::mutex> present(presentMu_);
    sourceAspect_ = aspect;
    if (presentMode_ != "fpga" && presentMode_ != "both") {
        log("media: source aspect=" + std::to_string(aspect.x) + ":" +
            std::to_string(aspect.y) + " owner=host_present no_fpga_transport");
        return true;
    }
    if (!fpga_.setDdrFrameLayout(ddrFrameGeometryForPresentedSize(outW_, outH_),
                                 DdrFrameFormat::Yuv420p)) {
        log("ERROR media: source aspect DDR layout failed: " + fpga_.lastError());
        return false;
    }
    if (!fpga_.sendSourceAspect(aspect)) {
        // PLXJ WE is blank-only. A missing ACK must not CLOSED-STOP a live
        // cast — Plex Web then shows playing while glass stays on the chevron.
        log("media: source aspect publish optional-continue: " + fpga_.lastError());
        return true;
    }
    log("media: source aspect=" + std::to_string(aspect.x) + ":" +
        std::to_string(aspect.y) + " owner=MiSTer_native_scaler ack=matched");
    return true;
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
    if (backend_ == VideoBackend::Unselected) {
        std::lock_guard<std::mutex> lock(mu_);
        lastError_ = "MPX_VIDEO_BACKEND must explicitly select fpga-h264 or legacy-software";
        return false;
    }
    if (fpgaH264Backend())
        return presentMode_ == "fpga" && (fpga_.ok() || fpga_.open());
    if (presentMode_ != "none" &&
        !matchedLegacyVideoCore(rbfPrefix8_, std::getenv("MPX_LEGACY_CORE_PREFIX"))) {
        std::lock_guard<std::mutex> lock(mu_);
        lastError_ = "legacy presentation requires an explicitly matched OLD baseline core";
        return false;
    }
    if (presentMode_ == "none") {
        log("media: PRESENT=none decode-only path (test/lab; no fb0 or FPGA writes)");
        return true;
    }

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
            useDdrF1_ = true;
            ddrBank_ = 0;
            log("media: FPGA frame path OK (PRESENT=fpga → DDR YUV420p only)");
            // Env/compile MPX_FABRIC_DIRECT: idle + present share sendDdrFrame.
            // 720p layout still required inside sendDdrFrame; 480p memcpy unchanged.
            const bool wantFabric = fabricDirectWanted();
            fpga_.setFabricDirectPresent(wantFabric);
            log(std::string("media: fabric_direct=") + (wantFabric ? "1" : "0") +
                " (MPX_FABRIC_DIRECT env/compile; 720p may poke PLXP)");
            // PATH_SDRAM stick present. Default OFF — live 480p daemon unchanged.
            // Cannot detect SDRAM_I420_STORE vs ddr_frame_store safely at runtime.
            const bool wantStick = stickI420Wanted();
            fpga_.setStickI420Present(wantStick);
            log(std::string("media: stick_i420=") + (wantStick ? "1" : "0") +
                " (MPX_STICK_I420; idle+play memcpy PHYS_BASE 0x30180000)");
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
            // 720p HDMI product: Original AR is 16:9 even before a play-file.
            {
                const SourceAspect idleAr = defaultSourceAspectForBank(outW_, outH_);
                if (idleAr.valid && idleAr.x == 16 && idleAr.y == 9) {
                    const char* prev = std::getenv("MPX_ASPECT_ACK_OPTIONAL");
                    if (!prev)
                        ::setenv("MPX_ASPECT_ACK_OPTIONAL", "1", 0);
                    if (setSourceAspect(idleAr))
                        log("media: HDMI 720p default aspect=16:9");
                    else
                        log("media: HDMI 720p default aspect=16:9 publish skipped: " +
                            fpga_.lastError());
                }
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
    // Pause/resume RGB/audio FFmpeg. STREAM demux stays alive on pause.
    pid_t p = childPid_.load();
    if (p > 0)
        kill(-p, sig);
    pid_t ap = audioPid_.load();
    // Split 720p audio-only ffmpeg must pause with video (unlike streamPid_).
    if (ap > 0)
        kill(-ap, sig);
    pid_t sp = streamPid_.load();
    // Do not SIGSTOP the H.264 source demux on pause: PMS can tear down an HTTP
    // transcode session that stops being consumed. streamPump keeps reading and
    // drops NALs while paused; the FPGA freezes on the last decoded frame.
    if (sp > 0 && sig != SIGSTOP && sig != SIGCONT)
        kill(-sp, sig);
}

void MediaPlayer::killChildren() {
    if (fpgaH264Backend())
        return;
    signalChildren(SIGTERM);
    // Close PCM fds before any wait: O_RDWR self-writer / blocking waitpid
    // used to leave audioPump in pipe_read and freeze Play.
    {
        int hold = remuxPcmHoldFd_.exchange(-1);
        if (hold >= 0)
            ::close(hold);
        int rd = remuxPcmReadFd_.exchange(-1);
        if (rd >= 0)
            ::close(rd);
    }
    auto reap = [](std::atomic<pid_t>& slot) {
        pid_t x = slot.load();
        if (x <= 0)
            return;
        int st = 0;
        if (::waitpid(x, &st, WNOHANG) == x)
            slot.store(-1);
    };
    for (int i = 0; i < 20; ++i) {
        reap(childPid_);
        reap(audioPid_);
        reap(streamPid_);
        if (childPid_.load() <= 0 && audioPid_.load() <= 0 && streamPid_.load() <= 0)
            break;
        std::this_thread::sleep_for(std::chrono::milliseconds(25));
    }
    signalChildren(SIGKILL);
    for (int i = 0; i < 8; ++i) {
        reap(childPid_);
        reap(audioPid_);
        reap(streamPid_);
        if (childPid_.load() <= 0 && audioPid_.load() <= 0 && streamPid_.load() <= 0)
            break;
        std::this_thread::sleep_for(std::chrono::milliseconds(25));
    }
    audioActive_.store(false);
    streamActive_.store(false);
    ::unlink("/tmp/mplex-inproc.ts");
    ::unlink("/tmp/mplex-inproc.h264");
    ::unlink("/tmp/mplex-inproc.pcm");
}

void MediaPlayer::shutdown() {
    // Order matters: retire the play thread FIRST. threadMain calls startIdle()
    // at session end, so stopping the idle painter before joining thr_ leaves a
    // window where a brand new idle thread is spawned after we joined the old
    // one — it is then still joinable in ~MediaPlayer and aborts the process.
    shuttingDown_.store(true);
    {
        std::lock_guard<std::mutex> life(lifeMu_);
        {
            std::lock_guard<std::mutex> lock(mu_);
            playEpoch_.fetch_add(1);
            currentUrl_.clear();
            currentHeaders_.clear();
        }
        stop_.store(true);
        interruptInproc();
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
        resetPlaybackPauseClock();
    }
    // Join outside lifeMu_: browse worker calls stop() which takes lifeMu_.
    {
        std::lock_guard<std::mutex> lk(browseThrMu_);
        if (browseThr_.joinable())
            browseThr_.join();
    }
    stopInputPoll();
    stopOsdPoll();
    stopIdle();
    if (fpgaAudioOutput_ >= 0) {
        ::close(fpgaAudioOutput_);
        fpgaAudioOutput_ = -1;
    }
    releaseFabricDirectAlloc(idleFabric_);
}

MediaPlayer::StoppedPosition MediaPlayer::stop() {
    // Only join thr_ here. threadMain owns audioThr_/streamThr_ joins at session end.
    // Joining helpers from both thr_ and stop() races and can hang the companion HTTP thread.
    std::lock_guard<std::mutex> life(lifeMu_);
    {
        std::lock_guard<std::mutex> lock(mu_);
        playEpoch_.fetch_add(1);
        currentUrl_.clear();
        currentHeaders_.clear();
    }
    stop_.store(true);
    interruptInproc();
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
#if defined(__linux__)
    restoreMisterNice(log_);
#endif
    resetPlaybackPauseClock();
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
    releaseFabricDirectAlloc(idleFabric_);
    if (fb_.ok())
        fb_.clear();
    // Nothing to heal: SPI transactions hand GPO back to Main exactly as they
    // found it, and the frame path never touches SPI at all, so Main is still
    // servicing F12/OSD/MiSTer_cmd. Do NOT unlink /tmp/misterplex_spi.lock here —
    // recreating that inode would put concurrent tools on a different lock.
    paintIdle();
    startIdle();
    startOsdPoll();
    return {finalPos, finalDur};
}

void MediaPlayer::resetPlaybackPauseClock() {
    std::lock_guard<std::mutex> lk(pauseClockMu_);
    MPX_AV_TRACE(tracePauseClock_.beginUpdate();)
    paused_.store(false);
    pauseClockAccumulatedUs_ = 0;
    pauseClockHeld_ = false;
    pauseClockStarted_ = {};
    MPX_AV_TRACE(tracePauseClock_.endUpdate(0, 0, false);)
}

void MediaPlayer::transitionPlaybackPause(
    bool paused, std::chrono::steady_clock::time_point now) {
    std::lock_guard<std::mutex> lk(pauseClockMu_);
    if (paused_.load() == paused)
        return;
    MPX_AV_TRACE(tracePauseClock_.beginUpdate();)
    paused_.store(paused);
    if (paused && !pauseClockHeld_) {
        pauseClockHeld_ = true;
        pauseClockStarted_ = now;
    } else if (!paused && pauseClockHeld_) {
        pauseClockAccumulatedUs_ +=
            std::chrono::duration_cast<std::chrono::microseconds>(
                now - pauseClockStarted_)
                .count();
        pauseClockHeld_ = false;
    }
    MPX_AV_TRACE(tracePauseClock_.endUpdate(pauseClockAccumulatedUs_,
        std::chrono::duration_cast<std::chrono::microseconds>(
            pauseClockStarted_.time_since_epoch()).count(), pauseClockHeld_);)
}

int64_t MediaPlayer::playbackPausedUs(
    std::chrono::steady_clock::time_point now) const {
    std::lock_guard<std::mutex> lk(pauseClockMu_);
    int64_t pausedUs = pauseClockAccumulatedUs_;
    if (pauseClockHeld_ && now > pauseClockStarted_) {
        pausedUs += std::chrono::duration_cast<std::chrono::microseconds>(
                        now - pauseClockStarted_)
                        .count();
    }
    return pausedUs;
}

int64_t MediaPlayer::playbackActiveUs() const {
    const auto now = std::chrono::steady_clock::now();
    return activePlaybackClockUs(
        std::chrono::duration_cast<std::chrono::microseconds>(now.time_since_epoch()).count(),
        playbackPausedUs(now));
}

void MediaPlayer::pause() {
    std::lock_guard<std::mutex> control(pauseControlMu_);
    if (fpgaH264Backend() && (!playing_.load() || stop_.load() || paused_.load()))
        return;
    // Close producer admission before publishing Pause. Any in-flight AU
    // finishes under presentMu_ ahead of Pause; none can occupy Resume's room.
    transitionPlaybackPause(true, std::chrono::steady_clock::now());
    if (fpgaH264Backend() && fpgaSession_.load()) {
        std::lock_guard<std::mutex> present(presentMu_);
        if (!fpga_.pauseBitstreamSession(fpgaSession_.load(), 500)) {
            failFpgaSession("pause ACK failed; references cannot be resumed safely");
            return;
        }
        if (audioEnabled_ && sourceHasAudio_ &&
            !controlFpgaAudio(fpgaSession_.load(), AudioSessionControl::Pause)) {
            failFpgaSession("audio pause ACK failed");
            return;
        }
    }
    signalChildren(SIGSTOP);
    showPlaybackOverlay(PlaybackOverlayState::Paused, positionMs_.load(), durationMs());
    if (onProgress_)
        onProgress_("paused", positionMs_.load(), durationMs_);
}

void MediaPlayer::resume() {
    std::lock_guard<std::mutex> control(pauseControlMu_);
    if (fpgaH264Backend() && (!playing_.load() || stop_.load() || !paused_.load()))
        return;
    if (fpgaH264Backend() && fpgaSession_.load()) {
        std::lock_guard<std::mutex> present(presentMu_);
        if (!fpga_.resumeBitstreamSession(fpgaSession_.load(), 500)) {
            failFpgaSession("resume ACK failed");
            return;
        }
        if (audioEnabled_ && sourceHasAudio_ && fpgaAudioStarted_.load() &&
            !controlFpgaAudio(fpgaSession_.load(), AudioSessionControl::Resume)) {
            failFpgaSession("audio resume ACK failed");
            return;
        }
    }
    transitionPlaybackPause(false, std::chrono::steady_clock::now());
    signalChildren(SIGCONT);
    showPlaybackOverlay(PlaybackOverlayState::Playing, positionMs_.load(), durationMs());
    if (onProgress_)
        onProgress_(fpgaH264Backend() && !fpgaVideoStarted_.load() ? "buffering" : "playing",
                    positionMs_.load(), durationMs_);
}

void MediaPlayer::showPlaybackOverlay(PlaybackOverlayState state, int64_t positionMs,
                                      int64_t durationMs) {
    overlay_.show(state, positionMs, durationMs);
}

void MediaPlayer::flashPlaybackSkip(int64_t deltaMs) {
    overlay_.flashSkip(deltaMs, positionMs_.load(), durationMs());
    if (fpgaH264Backend()) {
        std::lock_guard<std::mutex> lock(mu_);
        const int64_t seconds = deltaMs / 1000;
        fpgaOverlayTransport_ = deltaMs >= 0 ? ">> " : "<< ";
        fpgaOverlayTransport_ += std::to_string(seconds >= 0 ? seconds : -seconds) + "S";
        fpgaOverlayTransportUntil_ = std::chrono::steady_clock::now() +
            std::chrono::milliseconds(PlaybackOverlay::kSkipVisibleMs);
    }
}

void MediaPlayer::setPlaybackTitle(std::string title) {
    std::lock_guard<std::mutex> lock(mu_);
    playbackTitle_ = title.substr(0, 512);
    fpgaOverlayTransport_.clear();
    fpgaOverlayTransportUntil_ = {};
}

void MediaPlayer::seekMs(int64_t ms, const StartedFn& started, uint64_t generation) {
    if (ms < 0)
        ms = 0;
    const int64_t fromMs = positionMs_.load();
    std::string url, headers;
    int64_t dur = 0;
    uint64_t epoch = 0;
    {
        std::lock_guard<std::mutex> lock(mu_);
        url = currentUrl_;
        headers = currentHeaders_;
        dur = durationMs_;
        epoch = playEpoch_.load();
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
        {
            std::lock_guard<std::mutex> lock(mu_);
            startedPlayback_ = {generation, epoch};
        }
        if (started)
            started();
        return;
    }
    if (onProgress_)
        onProgress_("buffering", ms, dur);
    // Full restart: both RGB/audio and STREAM demux re-spawn at new offset (multi-IDR clean).
    playInternal(withUniversalOffset(url, ms), ms, headers, dur, epoch, started, generation);
}

bool MediaPlayer::play(const std::string& urlOrPath, int64_t startOffsetMs,
                       const std::string& httpHeaders, int64_t durationMs, uint64_t generation) {
    return playInternal(urlOrPath, startOffsetMs, httpHeaders, durationMs, 0, {}, generation);
}

bool MediaPlayer::playInternal(const std::string& urlOrPath, int64_t startOffsetMs,
                               const std::string& httpHeaders, int64_t durationMs,
                               uint64_t expectedEpoch, const StartedFn& started,
                               uint64_t generation) {
    {
        std::lock_guard<std::mutex> lk(libraryMu_);
        library_.hide();
    }
    // Idle painter owns fb0/F1 between sessions — retire it before we present.
    stopIdle();
    {
        std::lock_guard<std::mutex> life(lifeMu_);
        if (expectedEpoch && expectedEpoch != playEpoch_.load())
            return false;
        uint64_t epoch = 0;
        {
            std::lock_guard<std::mutex> lock(mu_);
            epoch = playEpoch_.fetch_add(1) + 1;
            currentUrl_.clear();
            currentHeaders_.clear();
        }
        stop_.store(true);
        interruptInproc();
        killChildren();
        if (thr_.joinable())
            thr_.join();

        if (backend_ == VideoBackend::Unselected) {
            std::lock_guard<std::mutex> lock(mu_);
            lastError_ = "select MPX_VIDEO_BACKEND=fpga-h264 or explicit legacy-software";
            return false;
        }
        if (backend_ == VideoBackend::LegacySoftware && presentMode_ != "none") {
            const char* matched = std::getenv("MPX_LEGACY_CORE_PREFIX");
            if (!matchedLegacyVideoCore(rbfPrefix8_, matched) || streamEnabled_) {
                std::lock_guard<std::mutex> lock(mu_);
                lastError_ = "legacy-software requires an explicitly matched OLD baseline core";
                return false;
            }
        }
        if (!fb_.ok() && !initPresent())
            return false;

        {
            std::lock_guard<std::mutex> lock(mu_);
            currentUrl_ = urlOrPath;
            currentHeaders_ = httpHeaders;
            durationMs_ = durationMs;
            lastError_.clear();
        }
        // Local / lab play-file: drop inherited PMS size unless this call already
        // probed the file (main --play-file sets sourceMedia via ffmpeg WxH).
        // Companion HTTP path calls setSourceMediaSize() after resolve, then
        // play(http) — not this branch.
        if (!fpgaH264Backend() && !urlOrPath.empty() && urlOrPath[0] == '/' &&
            urlOrPath.rfind("http", 0) != 0) {
            setSourceHasAudio(true);
            if (sourceMediaW_ <= 0 || sourceMediaH_ <= 0) {
                int sw = 0, sh = 0;
                std::string probeFail;
                (void)probeSourceAspect(urlOrPath, httpHeaders, &probeFail, &sw, &sh);
                if (sw > 0 && sh > 0)
                    setSourceMediaSize(sw, sh);
            }
        }

        stop_.store(false);
        resetPlaybackPauseClock();
        seekReqMs_.store(-1);
        reconFrames_.store(0);
        reconPresentOk_.store(false);
        cabacSkip_.store(false);
        {
            std::lock_guard<std::mutex> lock(summaryMu_);
            lastSummary_ = PlaybackSummary{};
        }
        // Mark playing before thr_ starts so callers (e.g. lab --play-file) that
        // poll playing() cannot race stop() before threadMain runs and wipe the
        // session at frames=0 / audio_s=0.
        if (started)
            started();
        playing_.store(true);
        // Re-arm the latched Display row only if HDMI is not already on it.
        // force=true rewrites video_mode every cast and renegotiates HDMI
        // (user-visible res blink) while vsync is down — ddr_frame_store
        // cannot retire swap_pending, so glass stays on the chevron.
        fpga_.reprobeDdrKick();
        if (displayRasterLatched_)
            applyDisplayRaster(latchedDisplayRes_, /*force=*/kForceDisplayRasterOnPlay);
        showPlaybackOverlay(PlaybackOverlayState::Playing, startOffsetMs, durationMs);
        thr_ = std::thread([this, urlOrPath, startOffsetMs, httpHeaders, durationMs, epoch] {
#if defined(__linux__)
        pthread_setname_np(pthread_self(), "mpx-play");
        // Dual-A9: pin the play/reader thread to CPU0. Isolated ffmpeg needs
        // ~1.8 cores for 32 fps; under play, read_us=53 ms is the limiter
        // (present waits ~38 ms). Do not nice the reader above ffmpeg.
        // In-process libav needs both cores (~1.78 / -threads 2) — do not pin.
#ifdef MPX_HAVE_LIBAV
        const bool skipPlayCpu0 =
            inprocDecodeWanted() && inprocDecodeSizeOk(outW_, outH_) &&
            presentMode_ == "fpga" &&
            ddrFrameFormat_ == DdrFrameFormat::Yuv420p;
        if (!skipPlayCpu0)
#endif
        {
            cpu_set_t cpus;
            CPU_ZERO(&cpus);
            CPU_SET(0, &cpus);
            (void)pthread_setaffinity_np(pthread_self(), sizeof(cpus), &cpus);
            (void)::setpriority(PRIO_PROCESS, 0, 0);
        }
        if (outW_ == kPlex720pPresentedWidth && outH_ == kPlex720pPresentedHeight)
            setMisterNice(19, log_);
#endif
            try {
                if (fpgaH264Backend())
                    fpgaThreadMain(urlOrPath, startOffsetMs, httpHeaders, durationMs, epoch);
                else
                    threadMain(urlOrPath, startOffsetMs, httpHeaders, durationMs);
            } catch (const std::exception& ex) {
                log(std::string("media: threadMain exception: ") + ex.what());
                playing_.store(false);
            } catch (...) {
                log("media: threadMain unknown exception");
                playing_.store(false);
            }
        });
        {
            std::lock_guard<std::mutex> lock(mu_);
            startedPlayback_ = {generation, epoch};
        }
    }
    return true;
}

void MediaPlayer::interruptInproc() {
#ifdef MPX_HAVE_LIBAV
    if (!fpgaH264Backend())
        return;
    std::lock_guard<std::mutex> lock(inprocMu_);
    if (inprocPcm_)
        inprocPcm_->requestStop();
#endif
}

void MediaPlayer::failFpgaSession(const std::string& error) {
    {
        std::lock_guard<std::mutex> lock(mu_);
        lastError_ = "FPGA H.264: " + error;
    }
    log("ERROR FPGA H.264: " + error);
    stop_.store(true);
}

bool MediaPlayer::controlFpgaAudio(uint64_t session, AudioSessionControl command) {
    return fpga_.controlAudioSession(session, command, 1000);
}

void MediaPlayer::fpgaAudioPump(MPX_AV_TRACE(std::shared_ptr<FpgaAvTrace> avTrace)) {
#ifdef MPX_HAVE_LIBAV
    MPX_AV_TRACE(FpgaAvTrace::Writer traceWriter(avTrace.get(), FpgaAvLane::Audio);)
    FpgaAudioExit exit = FpgaAudioExit::Running;
    fpgaAudioExit_.store(exit);
    auto audioFailure = [&](const std::string& error) {
        exit = FpgaAudioExit::Error;
        fpgaAudioExit_.store(exit);
        failFpgaSession(error);
    };
    AvInprocDecoder* demux = nullptr;
    {
        std::lock_guard<std::mutex> lock(inprocMu_);
        demux = inprocPcm_;
    }
    int output = fpgaAudioOutput_;
    int64_t written = 0;
    bool aligned = false;
    int64_t trimBytes = 0;
    int64_t audioAnchorPausedUs = 0;
    auto due = std::chrono::steady_clock::now();
    MPX_AV_TRACE(auto traceWait = [&](FpgaAvWait reason, int64_t queued = -1,
                                     int64_t dueUs = -1, int64_t lateUs = 0) {
        AvTraceSpan span(traceWriter, FpgaAvEvent::AudioWait, tracePauseClock_);
        span.value(0, static_cast<int>(reason));
        if (queued >= 0) span.value(1, queued);
        if (dueUs >= 0) { span.value(2, dueUs); span.value(3, lateUs); }
        span.uvalue(4, fpgaAudioHeldBytes_.load());
        span.value(5, written);
        span.value(6, paused_.load());
        span.value(7, stop_.load());
        span.value(8, fpgaVideoStarted_.load());
    };)
    auto readClock = [&](int64_t& queued) -> bool {
        FpgaSpi::AudioSessionStatus status;
        MPX_AV_TRACE(AvTraceSpan span(traceWriter, FpgaAvEvent::AudioClock, tracePauseClock_);
                     AvTraceRelease release{span};)
        // An older DMA read must not overwrite a newer combined presentation clock.
        std::lock_guard<std::mutex> present(presentMu_);
        MPX_AV_TRACE(span.acquired(); span.serviceBegin();)
        const bool clockRead = fpga_.readAudioSessionStatus(fpgaSession_.load(), status);
        MPX_AV_TRACE(span.serviceEnd();
            traceMast(span, clockRead, status, written, fpgaAudioHeldBytes_.load(),
                      paused_.load(), false);)
        if (!clockRead)
            return false;
        if (!status.active || status.error ||
            status.samples_consumed > static_cast<uint64_t>(written / 4)) {
            audioFailure("audio DMA epoch/error/consumed counter does not match submitted PCM");
            return false;
        }
        const int64_t consumed = static_cast<int64_t>(status.samples_consumed);
        queued = written - consumed * 4;
        fpgaHasConsumedClock_.store(true);
        if (fpgaAudioConsumedSamples_.exchange(consumed) != consumed)
            fpgaAudioClockChangedUs_.store(playbackActiveUs());
        audioQueuedBytes_.store(queued);
        return true;
    };
    uint8_t pcm[3840];
    while (demux && !stop_.load()) {
        if (paused_.load() || !fpgaVideoStarted_.load()) {
            MPX_AV_TRACE(traceWait(paused_.load() ? FpgaAvWait::Paused : FpgaAvWait::VideoNotStarted);)
            std::this_thread::sleep_for(std::chrono::milliseconds(5));
            continue;
        }
        int count;
        MPX_AV_TRACE({
            AvTraceSpan span(traceWriter, FpgaAvEvent::AudioDrain, tracePauseClock_);
            const auto pressure = demux->compressedPressure();
            span.serviceBegin();)
        count = demux->drainPcm(pcm, sizeof(pcm), false);
        MPX_AV_TRACE(span.serviceEnd(); span.value(0, count); span.value(1, sizeof(pcm));
            tracePressure(span, pressure, demux->compressedPressure());
            span.value(10, written); span.value(11, paused_.load());
        })
        fpgaAudioHeldBytes_.store(count);
        if (!count) {
            bool atEof;
            MPX_AV_TRACE({
                AvTraceSpan span(traceWriter, FpgaAvEvent::AudioEof, tracePauseClock_);
                span.serviceBegin();)
            atEof = demux->audioEof();
            MPX_AV_TRACE(span.serviceEnd(); span.value(0, atEof); })
            if (atEof) { exit = FpgaAudioExit::Eof; break; }
            MPX_AV_TRACE(traceWait(FpgaAvWait::PcmEmpty);)
            std::string error;
            AvAudioProgress progress;
            try {
                MPX_AV_TRACE(AvTraceSpan span(traceWriter, FpgaAvEvent::AudioAdvance, tracePauseClock_);
                    const auto pressure = demux->compressedPressure();)
                fpgaAudioProgress_.store(-2);
                MPX_AV_TRACE(span.serviceBegin();)
                progress = demux->advanceCompressedAudio(error);
                MPX_AV_TRACE(span.serviceEnd(); span.value(0, static_cast<int>(progress));
                    tracePressure(span, pressure, demux->compressedPressure());
                    if (progress == AvAudioProgress::Error) span.force();)
            } catch (...) {
                audioFailure("compressed audio progress exception");
                break;
            }
            fpgaAudioProgress_.store(static_cast<int>(progress));
            if (progress == AvAudioProgress::Error) {
                audioFailure(error);
                break;
            }
            if (progress == AvAudioProgress::Cancelled) {
                exit = FpgaAudioExit::Cancelled;
                break;
            }
            if (progress != AvAudioProgress::Ready)
                std::this_thread::sleep_for(std::chrono::milliseconds(2));
            continue;
        }
        if (!aligned) {
            const int64_t audioPts = demux->firstAudioPtsUs();
            if (audioPts == ddr_bitstream_ring::kNoTimestamp) {
                audioFailure("decoded audio has no original timestamp");
                break;
            }
            const long double timestampDelta =
                static_cast<long double>(audioPts) - fpgaFirstVideoPtsUs_.load();
            if (timestampDelta < -2000000 || timestampDelta > 2000000) {
                audioFailure("initial audio/video timestamp gap exceeds two seconds");
                break;
            }
            const int64_t delta = static_cast<int64_t>(timestampDelta);
            fpgaAudioStartRelativeUs_.store(std::max<int64_t>(0, delta));
            trimBytes = delta < 0 ? ((-delta * 48000) / 1000000) * 4 : 0;
            due = std::chrono::steady_clock::time_point(
                std::chrono::microseconds(fpgaVideoStartMonotonicUs_.load() +
                                          std::max<int64_t>(0, delta)));
            audioAnchorPausedUs = fpgaVideoStartPauseUs_.load();
            aligned = true;
        }
        const size_t skipped = static_cast<size_t>(std::min<int64_t>(trimBytes, count));
        trimBytes -= skipped;
        if (skipped == static_cast<size_t>(count)) continue;
        if (output < 0) {
            // open() leaves the kernel cursor unchanged; only write() publishes PCM/metadata.
            MPX_AV_TRACE({
                AvTraceSpan span(traceWriter, FpgaAvEvent::AudioOpen, tracePauseClock_);
                span.serviceBegin();)
            output = ::open(audioDev_.c_str(), O_WRONLY | O_NONBLOCK);
            MPX_AV_TRACE(span.serviceEnd(); span.value(0, output);
                span.value(1, output < 0 ? errno : 0); span.force(); })
            if (output < 0) {
                audioFailure("MrAudio open failed (no silent audio fallback)");
                break;
            }
            fpgaAudioOutput_ = output;
        }
        size_t offset = skipped;
        fpgaAudioHeldBytes_.store(static_cast<size_t>(count) - offset);
        const int64_t deadline = playbackActiveUs() + 2000000;
        while (offset < static_cast<size_t>(count) && !stop_.load()) {
            if (paused_.load()) {
                MPX_AV_TRACE(traceWait(FpgaAvWait::Paused);)
                std::this_thread::sleep_for(std::chrono::milliseconds(5));
                continue;
            }
            if (playbackActiveUs() >= deadline) {
                audioFailure("PCM DMA clock/backpressure timeout");
                break;
            }
            int64_t queued = 0;
            if (!readClock(queued)) {
                MPX_AV_TRACE(traceWait(FpgaAvWait::ClockUnavailable);)
                std::this_thread::sleep_for(std::chrono::milliseconds(2));
                continue;
            }
            const auto now = std::chrono::steady_clock::now();
            const auto audibleDue = due + std::chrono::microseconds(
                playbackPausedUs(now) - audioAnchorPausedUs);
            if (queued > kMrAudioBytesPerSec / 5 || now < audibleDue) {
                MPX_AV_TRACE(const auto dueUs =
                    std::chrono::duration_cast<std::chrono::microseconds>(audibleDue.time_since_epoch()).count();
                    const auto nowUs =
                    std::chrono::duration_cast<std::chrono::microseconds>(now.time_since_epoch()).count();
                    traceWait(queued > kMrAudioBytesPerSec / 5 ? FpgaAvWait::QueueHigh :
                              FpgaAvWait::AudibleDue, queued, dueUs, nowUs - dueUs);)
                std::this_thread::sleep_for(std::chrono::milliseconds(2));
                continue;
            }
            MPX_AV_TRACE(AvTraceSpan writeSpan(traceWriter, FpgaAvEvent::AudioWrite, tracePauseClock_);
                AvTraceRelease writeRelease{writeSpan};
                writeSpan.value(1, count - offset); writeSpan.value(2, written);
                writeSpan.value(3, queued);
                const auto dueUs =
                    std::chrono::duration_cast<std::chrono::microseconds>(audibleDue.time_since_epoch()).count();
                writeSpan.value(4, dueUs);
                writeSpan.value(5, std::chrono::duration_cast<std::chrono::microseconds>(
                    now.time_since_epoch()).count() - dueUs);)
            std::lock_guard<std::mutex> control(pauseControlMu_);
            MPX_AV_TRACE(writeSpan.acquired(); writeSpan.value(9, paused_.load());
                writeSpan.value(10, stop_.load());)
            if (paused_.load() || stop_.load()) continue;
            MPX_AV_TRACE(writeSpan.serviceBegin();)
            const ssize_t accepted = ::write(output, pcm + offset, count - offset);
            MPX_AV_TRACE(writeSpan.serviceEnd(); writeSpan.value(0, accepted);
                writeSpan.value(6, accepted < 0 ? errno : 0);
                if (accepted <= 0) writeSpan.force();)
            if (accepted < 0 && (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR))
                continue;
            if (accepted <= 0) {
                audioFailure("MrAudio write failed");
                break;
            }
            offset += static_cast<size_t>(accepted);
            fpgaAudioHeldBytes_.store(static_cast<size_t>(count) - offset);
            written += accepted;
            audioBytes_.store(written);
            MPX_AV_TRACE(writeSpan.value(7, written);
                writeSpan.value(8, static_cast<size_t>(count) - offset);)
            if (!fpgaAudioStarted_.load()) {
                std::lock_guard<std::mutex> present(presentMu_);
                if (!controlFpgaAudio(fpgaSession_.load(), AudioSessionControl::Resume)) {
                    audioFailure("primed audio DMA Resume ACK failed");
                    break;
                }
                fpgaAudioStarted_.store(true);
            }
            audioActive_.store(true);
            due += std::chrono::microseconds(accepted * 1000000LL / kMrAudioBytesPerSec);
        }
    }
    if (output >= 0 && !stop_.load()) {
        if (exit == FpgaAudioExit::Eof) fpgaAudioExit_.store(FpgaAudioExit::EofDraining);
        const int64_t deadline = playbackActiveUs() + 2000000;
        while (!stop_.load()) {
            int64_t queued = 0;
            if (readClock(queued) && queued == 0) break;
            if (!paused_.load() && playbackActiveUs() >= deadline) {
                audioFailure("audio EOF drain timeout");
                break;
            }
            MPX_AV_TRACE(traceWait(FpgaAvWait::EofDrain);)
            std::this_thread::sleep_for(std::chrono::milliseconds(5));
        }
    }
    if (exit != FpgaAudioExit::Error && stop_.load()) exit = FpgaAudioExit::Cancelled;
    if (!demux && exit == FpgaAudioExit::Running) exit = FpgaAudioExit::NoSource;
    MPX_AV_TRACE({
        AvTraceSpan span(traceWriter, FpgaAvEvent::AudioExit, tracePauseClock_);
        span.value(0, static_cast<int>(exit)); span.value(1, written);
        span.uvalue(2, fpgaAudioHeldBytes_.load()); span.value(3, stop_.load());
        span.force();
    })
    fpgaAudioExit_.store(exit);
#endif
    audioActive_.store(false);
    fpgaAudioDone_.store(true);
    fpgaAudioStarted_.store(false);
}

void MediaPlayer::fpgaThreadMain(std::string url, int64_t startMs, std::string headers,
                                 int64_t durationMs, uint64_t epoch) {
    PlaybackTerminalState terminal = PlaybackTerminalState::Stopped;
    positionMs_.store(startMs);
    fpgaVideoStarted_.store(false);
    fpgaAudioDone_.store(true);
    fpgaAudioStarted_.store(false);
    fpgaAudioExit_.store(FpgaAudioExit::NotStarted);
    fpgaAudioProgress_.store(-1);
    fpgaAudioHeldBytes_.store(0);
    fpgaAudioConsumedSamples_.store(-1);
    fpgaAudioClockChangedUs_.store(playbackActiveUs());
    fpgaHasConsumedClock_.store(false);
    fpgaFirstVideoPtsUs_.store(ddr_bitstream_ring::kNoTimestamp);
    audioBytes_.store(0);
    presentCount_.store(0);
#ifndef MPX_HAVE_LIBAV
    (void)url; (void)headers; (void)epoch;
    failFpgaSession("binary lacks libav demux/audio; software video fallback forbidden");
    terminal = finishFpgaPlayback({}, [] { return std::string("demux=unavailable audio=unavailable mast=unavailable"); },
        [] {}, [] { return true; }, [&] { return playEpoch_.load() == epoch; },
        [&] { return stop_.load(); },
        [&](const FpgaTerminalReceipt& receipt) { log(formatFpgaTerminal(receipt)); });
#else
    const uint64_t session =
        (static_cast<uint64_t>(::getpid()) << 48) ^
        static_cast<uint64_t>(std::chrono::steady_clock::now().time_since_epoch().count()) ^ epoch;
    MPX_AV_TRACE(std::shared_ptr<FpgaAvTrace> avTrace;
        const int traceSavedErrno = errno;
        try { avTrace = std::make_shared<FpgaAvTrace>(epoch, session); } catch (...) {}
        errno = traceSavedErrno;
        FpgaAvTrace::Writer traceWriter(avTrace.get(), FpgaAvLane::Video);
        uint64_t traceReadCalls = 0;)
    bool begun = false, audioBegun = false, eof = false, fullyDrained = false;
    bool demuxOpened = false, drainAttempted = false;
    std::optional<bool> drainAck;
    std::optional<bool> releaseAudioReset, releaseFlush, releaseEnd, releaseAbort;
    bool resetAttempted = false, flushAttempted = false;
    bool endAttempted = false, abortAttempted = false;
    std::optional<int> demuxReturn;
    const char* demuxReturnKind = "not-called";
    std::string demuxError;
    uint32_t sequence = 0;
    uint64_t bytes = 0;
    AvInprocDecoder demux;
    auto current = [&] { return !stop_.load() && playEpoch_.load() == epoch; };
    struct PendingPicture {
        uint32_t sequence;
        int64_t pts;
        uint32_t num, den;
    };
    std::deque<PendingPicture> pending;
    std::thread overlayThread;
    std::atomic<bool> stopOverlay{false};
    uint64_t overlayNonce = 0;
    uint32_t overlaySequence = 0;
    auto startOverlay = [&](uint64_t nonce) {
        overlayNonce = nonce;
        overlayThread = std::thread([&, nonce MPX_AV_TRACE(, avTrace)] {
            MPX_AV_TRACE(FpgaAvTrace::Writer overlayWriter(avTrace.get(), FpgaAvLane::Overlay);)
            unsigned failedTransfers = 0;
            try {
                while (current() && !stopOverlay.load()) {
                    // AutoFit measures native DE in FPGA; never substitute decoded/HDMI geometry.
                    fpga_overlay::Model model;
                    const bool presented = fpgaVideoStarted_.load();
                    model.state = paused_.load() ? fpga_overlay::State::Paused :
                        presented ? fpga_overlay::State::Playing : fpga_overlay::State::Buffering;
                    model.position_ms = presented ? positionMs_.load() : 0;
                    model.duration_ms = durationMs;
                    {
                        std::lock_guard<std::mutex> lock(mu_);
                        model.title = playbackTitle_.empty() ? "MiSTerPlex" : playbackTitle_;
                        if (std::chrono::steady_clock::now() < fpgaOverlayTransportUntil_)
                            model.transport = fpgaOverlayTransport_;
                    }
                    if (presented && !paused_.load() && !overlay_.visible()) {
                        model.state = fpga_overlay::State::Hidden;
                        model.flags = 0;
                    }
                    bool sent = false;
                    {
                        MPX_AV_TRACE(AvTraceSpan span(overlayWriter, FpgaAvEvent::OverlaySend, tracePauseClock_);
                            AvTraceRelease release{span};
                            span.value(1, static_cast<int>(model.state));
                            span.uvalue(2, overlaySequence);
                            span.value(3, model.position_ms);
                            span.value(4, paused_.load());)
                        std::lock_guard<std::mutex> present(presentMu_);
                        MPX_AV_TRACE(span.acquired();)
                        if (!current() || stopOverlay.load()) break;
                        MPX_AV_TRACE(span.serviceBegin();)
                        sent = fpga_overlay::send(fpga_, session, nonce, overlaySequence, model);
                        MPX_AV_TRACE(span.serviceEnd(); span.value(0, sent);
                            if (!sent) span.force();)
                    }
                    if (sent) failedTransfers = 0;
                    else if (++failedTransfers >= 5) {
                        failFpgaSession("native overlay SPI transport failed repeatedly");
                        break;
                    }
                    std::this_thread::sleep_for(std::chrono::milliseconds(200));
                }
            } catch (...) {
                failFpgaSession("native overlay publisher failed");
            }
        });
    };
    int64_t firstPtsUs = ddr_bitstream_ring::kNoTimestamp;
    int64_t firstSubmittedPtsUs = ddr_bitstream_ring::kNoTimestamp;
    int64_t anchorPausedUs = 0;
    int64_t lastCommitActiveUs = playbackActiveUs();
    int64_t heldPts = ddr_bitstream_ring::kNoTimestamp;
    uint32_t heldTimebaseNum = 0, heldTimebaseDen = 0;
    const char* waitReason = "opening";
    MPX_AV_TRACE(auto traceVideoWait = [&](FpgaAvWait reason) {
        AvTraceSpan span(traceWriter, FpgaAvEvent::VideoWait, tracePauseClock_);
        span.value(0, static_cast<int>(reason)); span.uvalue(1, pending.size());
        span.uvalue(2, sequence); span.uvalue(3, presentCount_.load());
        if (heldPts != ddr_bitstream_ring::kNoTimestamp) {
            span.value(4, heldPts); span.uvalue(5, heldTimebaseNum); span.uvalue(6, heldTimebaseDen);
        }
        span.value(7, paused_.load()); span.value(8, stop_.load());
    };)
    auto collectPresentation = [&]() -> bool {
        FpgaSpi::VideoPresentation picture;
        MPX_AV_TRACE(AvTraceSpan span(traceWriter, FpgaAvEvent::VideoPresentation, tracePauseClock_);)
        {
            MPX_AV_TRACE(AvTraceRelease release{span};)
            std::lock_guard<std::mutex> present(presentMu_);
            MPX_AV_TRACE(span.acquired(); span.serviceBegin();)
            const bool pictureRead = fpga_.readVideoPresentation(session, picture);
            MPX_AV_TRACE(span.serviceEnd(); span.value(0, pictureRead);
                if (pictureRead) {
                    span.value(1, picture.active); span.value(2, picture.error);
                    span.value(3, picture.error_code); span.value(4, picture.has_frame);
                    span.uvalue(5, picture.presentation_count);
                    if (picture.has_frame) {
                        span.uvalue(6, picture.seq); span.value(7, picture.pts);
                        span.uvalue(8, picture.timebase_num); span.uvalue(9, picture.timebase_den);
                    }
                    if (picture.has_audio_clock) span.uvalue(12, picture.audio_samples_consumed);
                } else span.force();
                span.uvalue(10, pending.size()); span.uvalue(11, sequence);)
            MPX_AV_TRACE(span.value(13, paused_.load());)
            if (!pictureRead)
                return true;
            if (picture.error || !picture.active) {
                failFpgaSession("core presentation/epoch error " + std::to_string(picture.error_code));
                return false;
            }
            if (picture.has_audio_clock) {
                if (picture.audio_samples_consumed >
                    static_cast<uint64_t>(std::numeric_limits<int64_t>::max() / 1000000)) {
                    failFpgaSession("consumed audio clock overflow");
                    return false;
                }
            }
            // MVPS freezes audio at the display boundary; pacing needs current MAST.
            if (audioBegun) {
                FpgaSpi::AudioSessionStatus audio;
                MPX_AV_TRACE(AvTraceSpan audioSpan(traceWriter, FpgaAvEvent::VideoClock, tracePauseClock_);
                    audioSpan.serviceBegin();)
                const bool audioRead = fpga_.readAudioSessionStatus(session, audio);
                MPX_AV_TRACE(audioSpan.serviceEnd();
                    traceMast(audioSpan, audioRead, audio, audioBytes_.load(),
                              fpgaAudioHeldBytes_.load(), paused_.load(), true);)
                if (audioRead) {
                    if (!audio.active || audio.error ||
                        audio.samples_consumed >
                            static_cast<uint64_t>(std::numeric_limits<int64_t>::max() / 1000000)) {
                        failFpgaSession("current DMA audio clock lost its active epoch");
                        return false;
                    }
                    fpgaHasConsumedClock_.store(true);
                    const auto consumed = static_cast<int64_t>(audio.samples_consumed);
                    if (fpgaAudioConsumedSamples_.exchange(consumed) != consumed)
                        fpgaAudioClockChangedUs_.store(playbackActiveUs());
                }
            }
            if (!picture.has_frame) return true;
        }
        if (picture.session_id != session)
            return true; // A stale mailbox publication never starts this epoch.
        if (picture.presentation_count <= presentCount_.load())
            return true;
        auto it = std::find_if(pending.begin(), pending.end(), [&](const PendingPicture& p) {
            return p.sequence == picture.seq;
        });
        if (it == pending.end()) {
            failFpgaSession("new presentation count references an unsubmitted AU");
            return false;
        }
        if (picture.pts != it->pts || picture.timebase_num != it->num ||
            picture.timebase_den != it->den || !picture.timebase_den ||
            picture.presentation_count !=
                presentCount_.load() + std::distance(pending.begin(), it) + 1) {
            failFpgaSession("presentation ACK does not match queued AU timestamp");
            return false;
        }
        const int64_t us = static_cast<int64_t>(
            static_cast<long double>(picture.pts) * picture.timebase_num * 1000000 /
            picture.timebase_den);
        const bool firstPresentation = firstPtsUs == ddr_bitstream_ring::kNoTimestamp;
        if (firstPresentation) {
            firstPtsUs = us;
            fpgaFirstVideoPtsUs_.store(us);
            fpgaVideoStartMonotonicUs_.store(std::chrono::duration_cast<std::chrono::microseconds>(
                std::chrono::steady_clock::now().time_since_epoch()).count());
            anchorPausedUs = playbackPausedUs(std::chrono::steady_clock::now());
            fpgaVideoStartPauseUs_.store(anchorPausedUs);
        }
        presentCount_.fetch_add(std::distance(pending.begin(), it) + 1);
        {
            std::lock_guard<std::mutex> lock(summaryMu_);
            lastSummary_.lastPresentedAudioSamples = picture.has_audio_clock
                ? static_cast<int64_t>(picture.audio_samples_consumed) : -1;
        }
        pending.erase(pending.begin(), std::next(it));
        lastCommitActiveUs = playbackActiveUs();
        fpgaVideoStarted_.store(true);
        positionMs_.store(startMs + std::max<int64_t>(0, (us - firstSubmittedPtsUs) / 1000));
        MPX_AV_TRACE({
            AvTraceSpan commit(traceWriter, FpgaAvEvent::VideoCommit, tracePauseClock_);
            commit.uvalue(0, picture.presentation_count); commit.uvalue(1, picture.seq);
            commit.value(2, picture.pts); commit.uvalue(3, picture.timebase_num);
            commit.uvalue(4, picture.timebase_den); commit.uvalue(5, pending.size());
            commit.value(6, positionMs_.load()); commit.value(7, paused_.load());
        })
        if (firstPresentation)
            showPlaybackOverlay(paused_.load() ? PlaybackOverlayState::Paused :
                                PlaybackOverlayState::Playing, positionMs_.load(), durationMs);
        if (onProgress_ && current())
            onProgress_(paused_.load() ? "paused" : "playing", positionMs_.load(), durationMs);
        return true;
    };
    try {
        do {
            if (onProgress_) onProgress_("buffering", startMs, durationMs);
            FpgaSpi::VideoCapabilities caps;
            const char* prototype = std::getenv("MPX_H264_PROTOTYPE");
            const char* filtering = std::getenv("MPX_H264_FILTER");
            const std::string selectedPrototype = prototype ? prototype : "ip";
            const std::string selectedFilter = filtering ? filtering : "on";
            {
                std::lock_guard<std::mutex> control(pauseControlMu_);
                std::lock_guard<std::mutex> present(presentMu_);
                const uint64_t retained = fpgaSession_.load();
                if (retained != 0) {
                    if (!fpga_.abortFpgaVideoSession(retained, 2000)) {
                        failFpgaSession("prior epoch still owns an unacknowledged reset fence");
                        break;
                    }
                    fpgaSession_.store(0);
                    if (fpgaAudioOutput_ >= 0) {
                        ::close(fpgaAudioOutput_);
                        fpgaAudioOutput_ = -1;
                    }
                }
                if (!fpga_.beginFpgaVideoSession(session, caps, 1000)) {
                    if (fpga_.videoCapabilities().nonce != 0) {
                        begun = true;
                        fpgaSession_.store(session);
                        MPX_AV_TRACE(if (avTrace) avTrace->bindNonce(caps.nonce);)
                    }
                    failFpgaSession("matching core capability/session ACK failed: " + fpga_.lastError());
                    break;
                }
                begun = true;
                fpgaSession_.store(session);
                MPX_AV_TRACE(if (avTrace) avTrace->bindNonce(caps.nonce);)
                if (!current()) break;
                if (caps.max_width < 320 || caps.max_height < 240) {
                    failFpgaSession("core does not support initial 320x240 tier");
                    break;
                }
                if (!(caps.features & ddr_bitstream_ring::FencedReset)) {
                    failFpgaSession("core lacks acknowledged ingress/DPB/display reset fencing");
                    break;
                }
                if ((selectedPrototype != "ip" && selectedPrototype != "idr") ||
                    (selectedFilter != "on" && selectedFilter != "off") ||
                    (selectedPrototype == "ip" && !(caps.features & ddr_bitstream_ring::Inter)) ||
                    (selectedFilter == "on" && !(caps.features & ddr_bitstream_ring::Deblock))) {
                    failFpgaSession("selected IP/IDR/filter profile exceeds matching core capabilities");
                    break;
                }
                if (audioEnabled_ && sourceHasAudio_) {
                    constexpr uint32_t requiredAudio =
                        ddr_bitstream_ring::ConsumedAudioClock | ddr_bitstream_ring::AudioSessionControl;
                    if ((caps.features & requiredAudio) != requiredAudio) {
                        failFpgaSession("core lacks real audio DMA lifecycle/consumed-clock capability");
                        break;
                    }
                    audioBegun = true; // A timed-out Begin may still own an in-flight command.
                    if (!controlFpgaAudio(session, AudioSessionControl::Begin)) {
                        failFpgaSession("audio session reset ACK failed");
                        break;
                    }
                }
                if (paused_.load() &&
                    (!fpga_.pauseBitstreamSession(session, 500) ||
                     (audioBegun &&
                      !controlFpgaAudio(session, AudioSessionControl::Pause)))) {
                    failFpgaSession("initial paused-session ACK failed");
                    break;
                }
            }
            if (!current()) break;
            AvInprocOpenOpts opts;
            opts.compressedVideo = true;
            opts.expectW = 320; opts.expectH = 240;
            opts.maxAccessUnitBytes = caps.max_au_bytes;
            // Current frontend RBSP RAM is 8192 bytes; the larger transport
            // ring is not evidence that a larger VCL NAL can be decoded.
            opts.maxVclRbspBytes = 8192;
            opts.expectedFpsNum = fpsNum_;
            opts.expectedFpsDen = fpsDen_;
            opts.allowInter = selectedPrototype == "ip" &&
                (caps.features & ddr_bitstream_ring::Inter) != 0;
            opts.allowDeblock = selectedFilter == "on" &&
                (caps.features & ddr_bitstream_ring::Deblock) != 0;
            opts.requireAllIdr = selectedPrototype == "idr";
            opts.decodeAudio = audioEnabled_ && sourceHasAudio_;
            opts.cancelled = &stop_;
            opts.paused = &paused_;
            opts.headers = headers;
            opts.startMs = urlHasUniversalOffset(url) ? 0 : startMs;
            std::string error;
            demuxReturnKind = "opening";
            bool opened;
            MPX_AV_TRACE({
                AvTraceSpan span(traceWriter, FpgaAvEvent::VideoOpen, tracePauseClock_);
                span.serviceBegin();)
            opened = demux.open(url, opts, error);
            MPX_AV_TRACE(span.serviceEnd(); span.value(0, opened); span.force(); })
            if (!opened) {
                demuxReturnKind = "open-error";
                demuxError = error;
                failFpgaSession(error);
                break;
            }
            demuxOpened = true;
            demuxReturnKind = "not-called";
            {
                std::lock_guard<std::mutex> lock(inprocMu_);
                inprocPcm_ = &demux;
            }
            if (opts.decodeAudio) {
                fpgaAudioDone_.store(false);
                audioThr_ = std::thread([this MPX_AV_TRACE(, avTrace)] {
                    try {
                        fpgaAudioPump(MPX_AV_TRACE(avTrace));
                    } catch (...) {
                        fpgaAudioExit_.store(FpgaAudioExit::Error);
                        audioActive_.store(false);
                        fpgaAudioDone_.store(true);
                        fpgaAudioStarted_.store(false);
                        failFpgaSession("compressed audio worker exception");
                    }
                });
            }
            bool aspectSent = false;
            bool firstAu = true;
            auto nextStatus = std::chrono::steady_clock::now();
            while (current()) {
                if (std::chrono::steady_clock::now() >= nextStatus) {
                    FpgaSpi::BitstreamStatus status;
                    bool healthy = false;
                    {
                        MPX_AV_TRACE(AvTraceSpan span(traceWriter, FpgaAvEvent::VideoStatus, tracePauseClock_);
                            AvTraceRelease release{span};)
                        std::lock_guard<std::mutex> present(presentMu_);
                        MPX_AV_TRACE(span.acquired(); span.serviceBegin();)
                        const bool statusRead = fpga_.readBitstreamStatus(status);
                        MPX_AV_TRACE(span.serviceEnd(); span.value(0, statusRead);
                            if (statusRead) {
                                span.value(1, status.active); span.value(2, status.fatal);
                                span.value(3, status.desync); span.uvalue(4, status.session_id);
                            } else span.force();)
                        healthy = statusRead && status.active &&
                                  status.session_id == session && !status.fatal && !status.desync;
                    }
                    if (!healthy) {
                        failFpgaSession("core changed or ingress epoch lost");
                        break;
                    }
                    nextStatus = std::chrono::steady_clock::now() + std::chrono::milliseconds(100);
                }
                if (paused_.load()) {
                    MPX_AV_TRACE(traceVideoWait(FpgaAvWait::Paused);)
                    std::this_thread::sleep_for(std::chrono::milliseconds(5));
                    continue;
                }
                if (!collectPresentation()) break;
                if (pending.size() >= 4) {
                    waitReason = "presentation-queue";
                    MPX_AV_TRACE(traceVideoWait(FpgaAvWait::PresentationQueue);)
                    if (playbackActiveUs() - lastCommitActiveUs > 2000000) {
                        failFpgaSession("video presentation stalled (bounded buffering)");
                        break;
                    }
                    std::this_thread::sleep_for(std::chrono::milliseconds(2));
                    continue;
                }
                AvCompressedAccessUnit packet;
                waitReason = "demux";
                demuxReturn.reset();
                demuxReturnKind = "in-flight";
                demuxError.clear();
                int read;
                MPX_AV_TRACE({
                    AvTraceSpan span(traceWriter, FpgaAvEvent::VideoRead, tracePauseClock_);
                    const auto pressure = demux.compressedPressure();
                    span.uvalue(10, ++traceReadCalls); span.uvalue(11, sequence);
                    span.uvalue(12, pending.size()); span.serviceBegin();)
                read = demux.readAccessUnit(packet, error);
                MPX_AV_TRACE(span.serviceEnd(); span.value(0, read);
                    tracePressure(span, pressure, demux.compressedPressure());
                    if (read > 0) {
                        span.value(1, packet.pts); span.value(13, packet.duration);
                        span.uvalue(14, packet.timebaseNum); span.uvalue(15, packet.timebaseDen);
                    } else span.force();
                })
                demuxReturn = read;
                demuxError = error;
                demuxReturnKind = read > 0 ? "au" : read == 0 ? "eof" :
                    current() ? "error" : "cancelled";
                if (read < 0) { if (current()) failFpgaSession(error); break; }
                if (!read) {
                    if (opts.decodeAudio && !demux.hasAudio())
                        failFpgaSession("expected audio stream was not delivered by the sole demux");
                    else
                        eof = true;
                    break;
                }
                if (firstAu && !packet.keyframe) {
                    failFpgaSession("session/seek must begin at an IDR");
                    break;
                }
                firstAu = false;
                heldPts = packet.pts;
                heldTimebaseNum = packet.timebaseNum;
                heldTimebaseDen = packet.timebaseDen;
                if (!aspectSent) {
                    std::lock_guard<std::mutex> present(presentMu_);
                    const SourceAspect aspect = sourceAspect_.valid ? sourceAspect_ : demux.sourceAspect();
                    const auto& geometry = packet.geometry;
                    {
                        std::lock_guard<std::mutex> lock(summaryMu_);
                        lastSummary_.codedWidth = geometry.codedWidth;
                        lastSummary_.codedHeight = geometry.codedHeight;
                        lastSummary_.visibleWidth = geometry.visibleWidth;
                        lastSummary_.visibleHeight = geometry.visibleHeight;
                        lastSummary_.macroblockColumns = geometry.macroblockColumns;
                        lastSummary_.macroblockRows = geometry.macroblockRows;
                        lastSummary_.cropLeft = geometry.cropLeft;
                        lastSummary_.cropRight = geometry.cropRight;
                        lastSummary_.cropTop = geometry.cropTop;
                        lastSummary_.cropBottom = geometry.cropBottom;
                        lastSummary_.sourceAspect = aspect;
                    }
                    log("media: FPGA stream geometry coded=" +
                        std::to_string(geometry.codedWidth) + "x" + std::to_string(geometry.codedHeight) +
                        " visible=" + std::to_string(geometry.visibleWidth) + "x" +
                        std::to_string(geometry.visibleHeight) + " mb=" +
                        std::to_string(geometry.macroblockColumns) + "x" +
                        std::to_string(geometry.macroblockRows) + " count=" +
                        std::to_string(geometry.macroblockColumns * geometry.macroblockRows) +
                        " crop_px=" + std::to_string(geometry.cropLeft) + "," +
                        std::to_string(geometry.cropRight) + "," + std::to_string(geometry.cropTop) +
                        "," + std::to_string(geometry.cropBottom) + " source_dar=" +
                        std::to_string(aspect.x) + ":" + std::to_string(aspect.y) +
                        " dar_source=" + (sourceAspect_.valid ? "provided" : "demux") +
                        " full_range=" + std::to_string(geometry.fullRange) +
                        " matrix_coefficients=" + std::to_string(geometry.matrixCoefficients) +
                        " limited_bt601_signaling=" +
                        std::to_string(geometry.limitedBt601Signaled()) +
                        (geometry.matrixCoefficients == 2 ?
                            " color_policy=ASSUMED_LIMITED_BT601_UNQUALIFIED" :
                            " color_policy=SIGNALED_LIMITED_BT601") +
                        " storage_stride=FPGA-owned/unreported (no ARM padding)");
                    if (!aspect.valid || !fpga_.sendSourceAspect(aspect)) {
                        failFpgaSession("source DAR unavailable or scaler ACK failed");
                        break;
                    }
                    aspectSent = true;
                    startOverlay(caps.nonce);
                }
                FpgaSpi::BitstreamAccessUnit au;
                au.session_id = session; au.seq = sequence;
                au.annexb = packet.annexb.data(); au.len = packet.annexb.size();
                au.pts = packet.pts; au.duration = packet.duration;
                au.timebase_num = packet.timebaseNum; au.timebase_den = packet.timebaseDen;
                au.flags = packet.keyframe ? ddr_bitstream_ring::kAccessUnitKeyframe : 0;
                // Timestamp pacing is distinct from decoding. No fps filter,
                // frame duplication, or compressed P-picture discard is allowed.
                if (fpgaVideoStarted_.load()) {
                    waitReason = "video-pts";
                    const long double targetUs =
                        static_cast<long double>(packet.pts) * packet.timebaseNum *
                        1000000 / packet.timebaseDen - firstPtsUs;
                    MPX_AV_TRACE(AvTraceSpan pace(traceWriter, FpgaAvEvent::VideoPace, tracePauseClock_);
                        pace.value(1, packet.pts); pace.value(2, packet.duration);
                        pace.uvalue(3, packet.timebaseNum); pace.uvalue(4, packet.timebaseDen);
                        pace.uvalue(5, pending.size()); pace.serviceBegin();)
                    const auto paced = waitForCompressedAccessUnit(targetUs, current,
                        collectPresentation, [&] {
                            const auto now = std::chrono::steady_clock::now();
                            const int64_t pausedUs = playbackPausedUs(now);
                            const int64_t activeUs = activePlaybackClockUs(
                                std::chrono::duration_cast<std::chrono::microseconds>(
                                    now.time_since_epoch()).count(), pausedUs);
                            const int64_t wallUs = activeUs -
                                fpgaVideoStartMonotonicUs_.load() + anchorPausedUs;
                            const int64_t consumed = fpgaAudioConsumedSamples_.load();
                            const int64_t clockUs = audioActive_.load() && consumed >= 0
                                ? fpgaAudioStartRelativeUs_.load() +
                                    consumed * 1000000LL / 48000 : wallUs;
                            MPX_AV_TRACE({
                                AvTraceSpan wait(traceWriter, FpgaAvEvent::VideoWait, tracePauseClock_);
                                wait.value(0, static_cast<int>(FpgaAvWait::Pts));
                                wait.uvalue(1, pending.size()); wait.uvalue(2, sequence);
                                wait.uvalue(3, presentCount_.load()); wait.value(4, packet.pts);
                                wait.uvalue(5, packet.timebaseNum); wait.uvalue(6, packet.timebaseDen);
                                wait.value(7, paused_.load()); wait.value(8, stop_.load());
                                wait.value(9, activeUs); wait.value(10, clockUs);
                                wait.value(11, wallUs);
                                if (targetUs >= std::numeric_limits<int64_t>::min() &&
                                    targetUs <= std::numeric_limits<int64_t>::max())
                                    wait.value(12, static_cast<int64_t>(targetUs));
                                wait.value(13, audioActive_.load() && consumed >= 0);
                            })
                            return CompressedPacingSnapshot{
                                paused_.load(), activeUs, lastCommitActiveUs, clockUs};
                        }, [] { std::this_thread::sleep_for(std::chrono::milliseconds(2)); });
                    MPX_AV_TRACE(pace.serviceEnd(); pace.value(0, static_cast<int>(paced));)
                    if (paced == CompressedPacingResult::Stalled)
                        failFpgaSession("presentation/audio clock stopped advancing");
                    if (paced != CompressedPacingResult::Due) break;
                }
                const int64_t deadline = playbackActiveUs() + 2000000;
                waitReason = "ring-capacity";
                bool accepted = false;
                while (current()) {
                    if (paused_.load()) {
                        MPX_AV_TRACE(traceVideoWait(FpgaAvWait::Paused);)
                        std::this_thread::sleep_for(std::chrono::milliseconds(5));
                        continue;
                    }
                    FpgaSpi::BitstreamPushResult result;
                    {
                        MPX_AV_TRACE(AvTraceSpan span(traceWriter, FpgaAvEvent::VideoSubmit, tracePauseClock_);
                            AvTraceRelease release{span}; span.uvalue(1, sequence);
                            span.value(2, au.pts); span.value(3, au.duration);
                            span.uvalue(4, au.timebase_num); span.uvalue(5, au.timebase_den);
                            span.uvalue(6, au.len); span.uvalue(7, pending.size());)
                        std::lock_guard<std::mutex> present(presentMu_);
                        MPX_AV_TRACE(span.acquired();)
                        if (!current() || paused_.load()) continue;
                        MPX_AV_TRACE(span.serviceBegin();)
                        result = fpga_.pushBitstreamAccessUnit(au, 0);
                        MPX_AV_TRACE(span.serviceEnd(); span.value(0, static_cast<int>(result));)
                    }
                    if (result == FpgaSpi::BitstreamPushResult::Ok) { accepted = true; break; }
                    if (result != FpgaSpi::BitstreamPushResult::Full) {
                        failFpgaSession("AU transport rejected sequence " + std::to_string(sequence));
                        break;
                    }
                    MPX_AV_TRACE(traceVideoWait(FpgaAvWait::RingFull);)
                    if (!collectPresentation()) break;
                    if (!paused_.load() && playbackActiveUs() >= deadline) {
                        failFpgaSession("compressed ring Full timeout; AU retained, never dropped");
                        break;
                    }
                    std::this_thread::sleep_for(std::chrono::milliseconds(2));
                }
                if (!accepted) break;
                if (sequence == 0)
                    firstSubmittedPtsUs = static_cast<int64_t>(
                        static_cast<long double>(packet.pts) * packet.timebaseNum *
                        1000000 / packet.timebaseDen);
                pending.push_back({sequence++, packet.pts, packet.timebaseNum, packet.timebaseDen});
                heldPts = ddr_bitstream_ring::kNoTimestamp;
                bytes += packet.annexb.size();
                if (sequence == 1) {
                    waitReason = "first-presentation";
                    const int64_t firstFrameDeadline = playbackActiveUs() + 2000000;
                    while (current() && !fpgaVideoStarted_.load()) {
                        MPX_AV_TRACE(traceVideoWait(FpgaAvWait::FirstPresentation);)
                        if (!collectPresentation()) break;
                        if (!paused_.load() && playbackActiveUs() >= firstFrameDeadline) {
                            failFpgaSession("first decoded picture was not actually presented");
                            break;
                        }
                        std::this_thread::sleep_for(std::chrono::milliseconds(2));
                    }
                }
            }
            if (eof && current()) {
                waitReason = "eof-drain";
                while (current()) {
                    if (paused_.load()) {
                        MPX_AV_TRACE(traceVideoWait(FpgaAvWait::Paused);)
                        std::this_thread::sleep_for(std::chrono::milliseconds(5));
                        continue;
                    }
                    MPX_AV_TRACE(AvTraceSpan span(traceWriter, FpgaAvEvent::VideoDrain, tracePauseClock_);
                        AvTraceRelease release{span};)
                    std::lock_guard<std::mutex> control(pauseControlMu_);
                    std::lock_guard<std::mutex> present(presentMu_);
                    MPX_AV_TRACE(span.acquired();)
                    if (paused_.load()) continue;
                    drainAttempted = true;
                    MPX_AV_TRACE(span.serviceBegin();)
                    drainAck = fpga_.drainBitstreamSession(session, 2000);
                    MPX_AV_TRACE(span.serviceEnd(); span.value(0, *drainAck); span.force();)
                    if (!*drainAck)
                        failFpgaSession("final access-unit drain ACK failed");
                    break;
                }
                const int64_t deadline = playbackActiveUs() + 3000000;
                while (current() && (!pending.empty() || !fpgaAudioDone_.load())) {
                    MPX_AV_TRACE(traceVideoWait(FpgaAvWait::EofDrain);)
                    if (!collectPresentation()) break;
                    if (!paused_.load() && playbackActiveUs() >= deadline) {
                        failFpgaSession("final video/audio presentation drain timeout");
                        break;
                    }
                    std::this_thread::sleep_for(std::chrono::milliseconds(5));
                }
                fullyDrained = current() && pending.empty() && fpgaAudioDone_.load() &&
                    sequence != 0 && presentCount_.load() == sequence;
            }
        } while (false);
    } catch (const std::exception& ex) {
        if (std::string(demuxReturnKind) == "in-flight" ||
            std::string(demuxReturnKind) == "opening") {
            demuxReturnKind = "exception";
            demuxError = ex.what();
        }
        failFpgaSession(ex.what());
    } catch (...) {
        if (std::string(demuxReturnKind) == "in-flight" ||
            std::string(demuxReturnKind) == "opening") {
            demuxReturnKind = "exception";
            demuxError = "non-standard demux exception";
        }
        failFpgaSession("unexpected compressed session exception");
    }
    auto captureTerminal = [&] {
        const auto queued = demux.compressedDiagnostics();
        FpgaSpi::AudioSessionStatus live{};
        bool liveValid = false;
        std::optional<int64_t> liveReadAtUs;
        {
            std::lock_guard<std::mutex> present(presentMu_);
            if (audioBegun) {
                liveValid = fpga_.readAudioSessionStatus(session, live);
                if (liveValid) liveReadAtUs = playbackActiveUs();
            }
        }
        int64_t frozenSamples = -1;
        {
            std::lock_guard<std::mutex> summary(summaryMu_);
            frozenSamples = lastSummary_.lastPresentedAudioSamples;
        }
        std::ostringstream diagnostic;
        auto field = [&](const char* name, auto value, bool known = true) {
            diagnostic << ' ' << name << '=';
            if (known) diagnostic << value;
            else diagnostic << "unavailable";
        };
        diagnostic << "session=" << session << " wait=" << waitReason
            << " retained_session=" << fpgaSession_.load()
            << " snapshot_active_us=" << playbackActiveUs()
            << " current=" << (playEpoch_.load() == epoch) << " stop=" << stop_.load()
            << " source_opened=" << demuxOpened << " demux_return_kind=" << demuxReturnKind
            << " demux_error=" << fpgaTerminalText(redactSensitive(demuxError))
            << " player_error=" << fpgaTerminalText(redactSensitive(lastError()))
            << ' ' << formatCompressedDiagnostics(queued)
            << " pending_au=" << pending.size() << " submitted_au=" << sequence
            << " presented_au=" << presentCount_.load()
            << " drain_attempted=" << drainAttempted
            << " audio_exit=" << fpgaAudioExitName(fpgaAudioExit_.load())
            << " audio_done=" << fpgaAudioDone_.load();
        field("demux_return", demuxReturn.value_or(0), demuxReturn.has_value());
        field("held_pts", heldPts, heldPts != ddr_bitstream_ring::kNoTimestamp);
        field("held_tb_num", heldTimebaseNum, heldPts != ddr_bitstream_ring::kNoTimestamp);
        field("held_tb_den", heldTimebaseDen, heldPts != ddr_bitstream_ring::kNoTimestamp);
        field("pending_first_pts", pending.empty() ? 0 : pending.front().pts, !pending.empty());
        field("pending_last_pts", pending.empty() ? 0 : pending.back().pts, !pending.empty());
        field("pending_tb_num", pending.empty() ? 0 : pending.front().num, !pending.empty());
        field("pending_tb_den", pending.empty() ? 0 : pending.front().den, !pending.empty());
        field("drain_ack", drainAck.value_or(false), drainAck.has_value());
        const int audioProgress = fpgaAudioProgress_.load();
        field("audio_progress", audioProgress, audioProgress >= 0);
        diagnostic << " audio_progress_call=" <<
            (audioProgress >= 0 ? "returned" : audioProgress == -2 ? "in-flight" : "not-called");
        field("audio_unsubmitted_pcm", fpgaAudioHeldBytes_.load(), audioBegun);
        field("submitted_pcm", audioBytes_.load(), audioBegun);
        const auto dmaQueued = audioQueuedBytes_.load();
        const auto cachedConsumed = fpgaAudioConsumedSamples_.load();
        field("queued_dma_bytes", dmaQueued,
              audioBegun && fpgaHasConsumedClock_.load() && dmaQueued >= 0);
        field("cached_live_samples", cachedConsumed,
              fpgaHasConsumedClock_.load() && cachedConsumed >= 0);
        field("cached_clock_change_age_us", playbackActiveUs() - fpgaAudioClockChangedUs_.load(),
              fpgaHasConsumedClock_.load());
        field("presentation_age_us", playbackActiveUs() - lastCommitActiveUs,
              fpgaVideoStarted_.load());
        diagnostic << " mast_read=" << (liveValid ? "ok" : audioBegun ? "failed" : "not-started");
        field("mast_read_active_us", liveReadAtUs.value_or(0), liveReadAtUs.has_value());
        field("mast_age_us", playbackActiveUs() - liveReadAtUs.value_or(0),
              liveReadAtUs.has_value());
        field("mast_session", live.session_id, liveValid);
        field("mast_nonce", live.nonce, liveValid);
        field("mast_publication", live.publication, liveValid);
        field("mast_consumed", live.samples_consumed, liveValid);
        field("mast_active", live.active, liveValid);
        field("mast_paused", live.paused, liveValid);
        field("mast_read_pending", live.read_pending, liveValid);
        field("mast_prefetched", live.prefetched, liveValid);
        field("mast_error", unsigned(live.error), liveValid);
        field("mvps_frozen_samples", frozenSamples, frozenSamples >= 0);
        return diagnostic.str();
    };
    terminal = finishFpgaPlayback({begun, eof, fullyDrained, presentCount_.load() > 0},
        captureTerminal, [&] {
        MPX_AV_TRACE(AvTraceSpan span(traceWriter, FpgaAvEvent::Quiesce, tracePauseClock_);
            span.serviceBegin();)
        demux.requestStop();
        stopOverlay.store(true);
        if (overlayThread.joinable()) overlayThread.join();
        if (audioThr_.joinable()) audioThr_.join();
        std::lock_guard<std::mutex> lock(inprocMu_);
        inprocPcm_ = nullptr;
        MPX_AV_TRACE(span.serviceEnd(); span.value(0, 1); span.force();)
    }, [&] {
        MPX_AV_TRACE(AvTraceSpan span(traceWriter, FpgaAvEvent::Release, tracePauseClock_);
            AvTraceRelease release{span};)
        std::lock_guard<std::mutex> control(pauseControlMu_);
        std::lock_guard<std::mutex> present(presentMu_);
        MPX_AV_TRACE(span.acquired(); span.serviceBegin();)
        if (overlayNonce) {
            fpga_overlay::Model hidden;
            hidden.state = fpga_overlay::State::Hidden;
            hidden.flags = 0;
            bool hiddenSent;
            MPX_AV_TRACE({
                AvTraceSpan hiddenSpan(traceWriter, FpgaAvEvent::OverlaySend, tracePauseClock_);
                hiddenSpan.value(1, static_cast<int>(hidden.state));
                hiddenSpan.uvalue(2, overlaySequence); hiddenSpan.serviceBegin();)
            hiddenSent = fpga_overlay::send(fpga_, session, overlayNonce, overlaySequence, hidden);
            MPX_AV_TRACE(hiddenSpan.serviceEnd(); hiddenSpan.value(0, hiddenSent);
                hiddenSpan.force(); })
            if (!hiddenSent)
                log("ERROR native overlay hide transfer failed; lifecycle fence must clear the plane");
        }
        bool released = !begun;
        if (begun) {
            bool audioReset = true;
            if (audioBegun) {
                resetAttempted = true;
                audioReset = controlFpgaAudio(session, AudioSessionControl::Reset);
                releaseAudioReset = audioReset;
            }
            flushAttempted = audioReset;
            const bool flushed = audioReset && fpga_.flushBitstreamSession(session, 500);
            if (audioReset) releaseFlush = flushed;
            endAttempted = flushed;
            const bool ended = flushed && fpga_.endBitstreamSession(session, 500);
            if (flushed) releaseEnd = ended;
            released = ended;
            if (!ended) {
                failFpgaSession("audio/DPB/display/ingress reset ACK failed; attempting fenced abort");
                abortAttempted = true;
                released = fpga_.abortFpgaVideoSession(session, 2000);
                releaseAbort = released;
                if (!released)
                    log("ERROR FPGA H.264: reset ownership retained; new play must recover this epoch");
            }
        }
        if (begun && released) {
            fpgaSession_.store(0);
            if (fpgaAudioOutput_ >= 0) {
                ::close(fpgaAudioOutput_);
                fpgaAudioOutput_ = -1;
            }
        }
        MPX_AV_TRACE(span.serviceEnd(); span.value(0, released); span.force();)
        return released;
    }, [&] { return playEpoch_.load() == epoch; }, [&] { return stop_.load(); },
        [&](const FpgaTerminalReceipt& receipt) {
            auto ack = [](std::optional<bool> value, bool attempted) {
                return !attempted ? "not-attempted" : !value ? "unavailable" :
                       *value ? "ok" : "failed";
            };
            log(formatFpgaTerminal(receipt) + " reset_ack=" + ack(releaseAudioReset, resetAttempted) +
                " flush_ack=" + ack(releaseFlush, flushAttempted) +
                " end_ack=" + ack(releaseEnd, endAttempted) +
                " abort_ack=" + ack(releaseAbort, abortAttempted) +
                " audio_exit_final=" + fpgaAudioExitName(fpgaAudioExit_.load()));
        });
    {
        std::lock_guard<std::mutex> lock(summaryMu_);
        lastSummary_.streamEnabled = true;
        lastSummary_.totalBytes = bytes;
        lastSummary_.presentedFrames = presentCount_.load();
        lastSummary_.videoEof = terminal == PlaybackTerminalState::Ended;
    }
#endif
    if (onProgress_)
        reportFpgaPlaybackTerminal(terminal, [&] { return playEpoch_.load() == epoch; },
            [&] { return stop_.load(); }, onProgress_, positionMs_.load(), durationMs);
    playing_.store(false);
#if MPX_FPGA_AV_TRACE && defined(MPX_HAVE_LIBAV)
    // Natural EOF is reported first. Explicit Stop still joins this worker;
    // the bounded dump's measured cost is therefore visible in Stop latency.
    traceWriter.finish();
    try {
        if (!avTrace)
            log("FPGA_AV_TRACE_UNAVAILABLE allocation_failed=1");
        else if (!avTrace->freeze())
            log("FPGA_AV_TRACE_UNAVAILABLE producers_not_quiescent=1");
        else
            avTrace->dump([&](const std::string& chunk) { log(chunk); });
    } catch (...) {
        try { log("FPGA_AV_TRACE_UNAVAILABLE dump_failed=1"); } catch (...) {}
    }
#endif
}

pid_t MediaPlayer::spawnFfmpeg(const std::vector<std::string>& args, int vWriteFd, int aWriteFd) {
    pid_t pid = fork();
    if (pid < 0)
        return -1;
    if (pid == 0) {
        setpgid(0, 0);
        // Do NOT pin ffmpeg to a single core (CPU1-only pin regressed 720p
        // to ~0.3 pfps). Isolated -threads 2 is 32 fps / 1.78 cores. Play
        // produce is the limiter (read_us≈53 ms; present idle ~38 ms) — do
        // not nice decode below present. memcpy 12 ms is not the 16 fps hole
        // (ac18 copy_us=0 still 15.6; 6ffa quiet-FPGA still 15.9).
        ::setpriority(PRIO_PROCESS, 0, -5);
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
        } else if (vWriteFd != 3) {
            // Video-only (720p split / demux): drop inherited fd 3 so this
            // process cannot hold the sibling audio write end or vpipe read end.
            ::close(3);
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

pid_t MediaPlayer::spawnHttpRemuxMpegts(const std::string& url, const std::string& headers,
                                        int64_t startMs, const std::string& fifoPath,
                                        bool keepAudio, const std::string& audioFifo) {
    // Box ffmpeg has HTTP. ARM inproc libav is file+h264+mpegts, no HTTP, no AAC
    // (--disable-network --disable-everything --enable-decoder=h264).
    // keepAudio: ONE remux writes annex-B + 48k s16le PCM (no spawnAudioOnly
    // second HTTP; that locked av_drift_ms≈−5000). mpegts+inproc AAC SIGABRT'd.
    const bool pcmOut = keepAudio && !audioFifo.empty();
    std::vector<std::string> args;
    args.push_back(ffmpeg_);
    args.push_back("-hide_banner");
    args.push_back("-loglevel");
    args.push_back("error");
    args.push_back("-nostdin");
    args.push_back("-fflags");
    args.push_back("+nobuffer");
    args.push_back("-probesize");
    args.push_back("32768");
    args.push_back("-analyzeduration");
    args.push_back("0");
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
    args.push_back("0:v:0");
    if (!pcmOut)
        args.push_back("-an");
    args.push_back("-c:v");
    args.push_back("copy");
    args.push_back("-bsf:v");
    args.push_back("h264_mp4toannexb");
    args.push_back("-f");
    args.push_back("h264");
    args.push_back("-y");
    args.push_back(fifoPath);
    if (pcmOut) {
        args.push_back("-map");
        args.push_back("0:a:0?");
        args.push_back("-vn");
        args.push_back("-af");
        if (audioDelayMs_ > 0)
            args.push_back("aresample=48000,adelay=" + std::to_string(audioDelayMs_) +
                           ":all=1");
        else
            args.push_back("aresample=48000");
        args.push_back("-f");
        args.push_back("s16le");
        args.push_back("-ac");
        args.push_back("2");
        args.push_back("-ar");
        args.push_back("48000");
        args.push_back("-y");
        args.push_back(audioFifo);
    }
    return spawnFfmpeg(args, -1, -1);
}

pid_t MediaPlayer::spawnHttpPrefetchTs(const std::string& url, const std::string& headers,
                                       int64_t startMs, const std::string& destPath) {
    // Copy A+V to a seekable tmpfs mpegts. Inproc of a complete file is the
    // local-identity 24 unique path; fifo remux of the same HTTP is 23.5.
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
    args.push_back("-c");
    args.push_back("copy");
    args.push_back("-muxpreload");
    args.push_back("0");
    args.push_back("-muxdelay");
    args.push_back("0");
    args.push_back("-f");
    args.push_back("mp4");
    args.push_back("-movflags");
    args.push_back("+faststart");
    args.push_back("-y");
    args.push_back(destPath);
    return spawnFfmpeg(args, -1, -1);
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
    // Second HTTP transcode for inproc audio. Default probe waits seconds
    // (Star Trek av_drift_ms≈−5200). Nobuffer so first PCM matches pictures.
    args.push_back("-fflags");
    args.push_back("+nobuffer+genpts");
    args.push_back("-flags");
    args.push_back("low_delay");
    args.push_back("-probesize");
    args.push_back("32768");
    args.push_back("-analyzeduration");
    args.push_back("0");
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

void MediaPlayer::streamPump(int sfd, bool allowF1Present) {
    // Phase 3.3i/product: demux annex-B → host I-slice recon → YUV420 F1 (+ optional fb0).
    // Also feed the FPGA decoder through the continuous HPS-DDR bitstream ring.
    // Robust multi-IDR: retain last SPS/PPS, recon every I/IDR, sticky CABAC skip.
    const bool wantF3 = fpga_.ok();
    const bool wantF1 =
        allowF1Present && fpga_.ok() &&
        (presentMode_ == "fpga" || presentMode_ == "both");
    // PRESENT=both: FFmpeg owns continuous fb0; recon owns F1 only.
    // PRESENT=fb0 + STREAM: recon I-frames may blit fb0 (sparse keyframe present).
    const bool reconToFb =
        fb_.ok() && (presentMode_ == "fb0" || presentMode_.empty());

    auto formatDdrBitstreamStatus = [](const FpgaSpi::BitstreamStatus& st) {
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
                // Match play path: geometry from current decode bank, not 480-only.
                const DdrFrameGeometry g = ddrFrameGeometryForPresentedSize(outW_, outH_);
                if (rec.width == g.coded_width && rec.height == g.coded_height) {
                    ensureYuv420p();
                    clearYuv420pCropPadding(yuv420p.data(), g);
                    if (uvUBias_ != 0 || uvVBias_ != 0) {
                        applyYuv420pUvBias(yuv420p.data(), rec.width, rec.height, uvUBias_,
                                           uvVBias_);
                    }
                    ok = fpga_.sendYuv420pFrameDdr(yuv420p.data(), yuv420p.size(), g, ddrBank_);
                    if (ok)
                        ddrBank_ ^= 1;
                    if (!ok) {
                        log("media: recon YUV420 DDR F1 unavailable: " + fpga_.lastError());
                    } else if ((reconOk % 30) == 0) {
                        log("media: recon F1 via YUV420 DDR " +
                            std::to_string(static_cast<int>(fpga_.lastPushMs())) + "ms");
                    }
                } else if (!reconDdrMismatchLogged) {
                    reconDdrMismatchLogged = true;
                    log("media: recon F1 skipped: YUV DDR frame-store expects coded " +
                        std::to_string(g.coded_width) + "x" + std::to_string(g.coded_height) +
                        ", got " + std::to_string(rec.width) + "x" + std::to_string(rec.height));
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

MrAudioStatus MediaPlayer::readMrAudioStatus() {
    const int fd = ::open(audioDev_.c_str(), O_RDONLY);
    if (fd < 0)
        return {};
    char buf[128];
    const ssize_t n = ::read(fd, buf, sizeof(buf));
    ::close(fd);
    if (n <= 0)
        return {};
    return misterplex::parseMrAudioStatus(buf, n);
}

void MediaPlayer::audioPump(int afd) {
    // Drain PCM to MrAudio. Lab evidence: MrAudio write() does NOT pace realtime
    // (audio_s grew ~3× wall → jumpy audio). Pace ourselves to exact 48 kHz wall
    // clock; that back-pressures FFmpeg and thus video.
    // F2 SPI skipped when MrAudio works (SPI thrash + no heard benefit).
    // AUDIO_DELAY_MS is applied in FFmpeg (adelay) on the product RGB path so A+V
    // stay on one clock. Pump is pure wall-48k MrAudio (no second delay line).
    // afd<0: same-demux inproc PCM (no second HTTP audio transcode).
    {
        cpu_set_t cpus;
        CPU_ZERO(&cpus);
        CPU_SET(0, &cpus);
        (void)::pthread_setaffinity_np(::pthread_self(), sizeof(cpus), &cpus);
    }
#ifdef MPX_HAVE_LIBAV
    AvInprocDecoder* same = (afd < 0) ? inprocPcm_ : nullptr;
    auto pcmRead = [&](char* buf, size_t n) -> ssize_t {
        if (same) {
            const int g = same->drainPcm(reinterpret_cast<uint8_t*>(buf), n);
            if (g > 0)
                return g;
            if (same->audioEof() || !same->isOpen())
                return 0;
            errno = EAGAIN;
            return -1;
        }
        if (afd < 0)
            return 0;
        return ::read(afd, buf, n);
    };
#else
    auto pcmRead = [&](char* buf, size_t n) -> ssize_t {
        if (afd < 0)
            return 0;
        return ::read(afd, buf, n);
    };
#endif
    auto pcmClose = [&]() {
        if (afd < 0)
            return;
        int cur = afd;
        if (remuxPcmReadFd_.compare_exchange_strong(cur, -1))
            ::close(afd);
    };
    const bool wantMr = audioEnabled_ && (::access(audioDev_.c_str(), W_OK) == 0);
    bool wantF2 = fpga_.ok() && presentMode_ == "fpga" && !wantMr;

    int out = -1;
    if (wantMr) {
        out = ::open(audioDev_.c_str(), O_WRONLY);
        if (out < 0)
            log("media: open " + audioDev_ + " failed errno=" + std::to_string(errno));
        else {
            int fl = ::fcntl(out, F_GETFL, 0);
            if (fl >= 0)
                (void)::fcntl(out, F_SETFL, fl | O_NONBLOCK);
            log("media: MrAudio open — software-paced 48kHz delay_ms=" +
                std::to_string(audioDelayMs_) +
                " clock_ppm=" + std::to_string(audioClockPpm_) +
                (afd < 0 ? " src=same_demux" : " (adelay in ffmpeg if >0)"));
        }
    }
    if (out < 0 && !wantF2) {
        char buf[4096];
        while (!stop_.load()) {
            ssize_t n = pcmRead(buf, sizeof(buf));
            if (n < 0) {
                if (errno == EAGAIN || errno == EINTR)
                    continue;
                break;
            }
            if (n == 0)
                break;
        }
        pcmClose();
        return;
    }

    if (wantF2) {
        fpga_.flushAudioFifo();
        log("media: F2 audio_fifo streaming enabled");
    }

    audioBytes_.store(0);
    audioQueuedBytes_.store(-1);
    // Do not set audioActive until MrAudio is actually fed. audioActive=1
    // with audioBytes=0 made avDecide Hold forever (720p trim stall).
    audioActive_.store(false);
    // 20ms chunks @ 48k stereo s16le
    char buf[3840];
    std::vector<uint8_t> gatedAudio;
    gatedAudio.reserve(48000 * 4 * 4);
    if (!audioFeedRelease_.load())
        log("media: MrAudio feed gated; draining pipe until release");
    while (!stop_.load() && !audioFeedRelease_.load()) {
        ssize_t n = 0;
        if (afd >= 0) {
            struct pollfd pfd {};
            pfd.fd = afd;
            pfd.events = POLLIN;
            const int pr = ::poll(&pfd, 1, 20);
            if (pr < 0) {
                if (errno == EINTR)
                    continue;
                break;
            }
            if (pr == 0)
                continue;
        }
        n = pcmRead(buf, sizeof(buf));
        if (n < 0) {
            if (errno == EINTR || errno == EAGAIN)
                continue;
            break;
        }
        if (n == 0)
            break;
        gatedAudio.insert(gatedAudio.end(), buf, buf + n);
        constexpr size_t kMaxGated = 48000u * 4u * 6u;
        if (gatedAudio.size() > kMaxGated)
            gatedAudio.erase(gatedAudio.begin(),
                             gatedAudio.begin() +
                                 static_cast<std::ptrdiff_t>(gatedAudio.size() - kMaxGated));
    }
    if (stop_.load()) {
        if (out >= 0)
            ::close(out);
        pcmClose();
        audioActive_.store(false);
        return;
    }
    {
        const int afterMs = audioAfterVideoMs_.load();
        if (afterMs > 0) {
            log("media: MrAudio start after_video_ms=" + std::to_string(afterMs));
            const auto due = std::chrono::steady_clock::now() +
                             std::chrono::milliseconds(afterMs);
            while (!stop_.load() && std::chrono::steady_clock::now() < due)
                std::this_thread::sleep_for(std::chrono::milliseconds(1));
        }
    }
    if (stop_.load()) {
        if (out >= 0)
            ::close(out);
        pcmClose();
        audioActive_.store(false);
        return;
    }
    if (!gatedAudio.empty()) {
        const int64_t pres = presentCount_.load(std::memory_order_relaxed);
        const size_t drop = misterplex::p720_av::trimGatedPcmDrop(
            gatedAudio.size(), pres, fpsNum_, fpsDen_);
        if (drop > 0)
            gatedAudio.erase(gatedAudio.begin(),
                             gatedAudio.begin() + static_cast<std::ptrdiff_t>(drop));
        // 720p prefetch combined: 40 ms remain left pictures ~90–110 ms
        // ahead of heard audio (soak J/K). 120 ms matches 480p tens-of-ms.
        // Keep the START of the gated PCM (same epoch as the first I420).
        // 120 ms cap discarded ~1.3 s of t=0 audio on live HEVC open and
        // locked av_drift_ms≈−1100. 2.5 s covers the remux-open gate.
        const int capMs = 2500;
        const size_t cap =
            misterplex::p720_av::capGatedPcmRemain(gatedAudio.size(), capMs);
        if (cap < gatedAudio.size())
            gatedAudio.resize(cap);
        audioBytes_.store(static_cast<int64_t>(drop));
        log("media: 720p audio_trim presents=" + std::to_string(pres) +
            " drop_bytes=" + std::to_string(drop) +
            " remain_bytes=" + std::to_string(gatedAudio.size()) +
            " cap_ms=" + std::to_string(capMs));
    }
    audioActive_.store(true);
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
        ssize_t n = 0;
        if (!gatedAudio.empty()) {
            n = static_cast<ssize_t>(std::min(sizeof(buf), gatedAudio.size()));
            std::memcpy(buf, gatedAudio.data(), static_cast<size_t>(n));
            gatedAudio.erase(gatedAudio.begin(),
                             gatedAudio.begin() + static_cast<std::ptrdiff_t>(n));
        } else {
            if (afd >= 0) {
                struct pollfd pfd {};
                pfd.fd = afd;
                pfd.events = POLLIN;
                const int pr = ::poll(&pfd, 1, 20);
                if (pr < 0) {
                    if (errno == EINTR)
                        continue;
                    break;
                }
                if (pr == 0)
                    continue;
            }
            n = pcmRead(buf, sizeof(buf));
            if (n < 0) {
                if (errno == EINTR || errno == EAGAIN)
                    continue;
                break;
            }
            if (n == 0)
                break;
        }

        if (out >= 0) {
            size_t off = 0;
            while (off < static_cast<size_t>(n) && !stop_.load()) {
                ssize_t w = ::write(out, buf + off, static_cast<size_t>(n) - off);
                if (w < 0) {
                    if (errno == EINTR)
                        continue;
                    if (errno == EAGAIN || errno == EWOULDBLOCK)
                        break;
                    log("media: MrAudio write err errno=" + std::to_string(errno));
                    break;
                }
                off += static_cast<size_t>(w);
            }
            audioBytes_.fetch_add(static_cast<size_t>(n));

            // Hold heard audio to presented pictures — 480p gold (unique ~24).
            // 720p inproc + 2-slot prefill deadlocks if this is on: avDecide
            // Hold waits for audio while this loop waits for presentCount
            // (Star Trek stuck at time=5000). Combined 720p matches 480p.
            const bool holdAudioToPictures = holdAudioToPictures_.load();
            if (holdAudioToPictures && fpsNum_ > 0 && fpsDen_ > 0) {
                const double audioSec =
                    static_cast<double>(audioBytes_.load()) / (48000.0 * 4.0);
                for (;;) {
                    const int64_t pres =
                        presentCount_.load(std::memory_order_relaxed);
                    if (pres <= 0 || stop_.load())
                        break;
                    const double videoSec = static_cast<double>(pres) *
                                            static_cast<double>(fpsDen_) /
                                            static_cast<double>(fpsNum_);
                    const double slackSec =
                        static_cast<double>(audioHoldSlackMs_.load()) / 1000.0;
                    if (audioSec <= videoSec + slackSec)
                        break;
                    std::this_thread::sleep_for(std::chrono::milliseconds(4));
                }
            }

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
                const MrAudioStatus status = readMrAudioStatus();
                const int64_t q = status.queuedBytes;
                if (!status.valid()) {
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
                            std::to_string(queuedEma) + "B rptr=" +
                            std::to_string(status.readPointer) + " wptr=" +
                            std::to_string(status.writePointer));
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
    pcmClose();
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

    const bool nativeScalerPresent =
        presentMode_ == "fpga" || presentMode_ == "both";
    const DdrFrameGeometry ddrGeometry =
        nativeScalerPresent ? ddrFrameGeometryForPresentedSize(outW_, outH_)
                            : makeDdrFrameGeometry(outW_, outH_);
    const int rawW = ddrGeometry.coded_width;
    const int rawH = ddrGeometry.coded_height;
    const int rawDisplayW = ddrGeometry.display_width;
    const int rawDisplayH = ddrGeometry.display_height;
    if (budget960Wanted() && !isPlex960BankSize(rawW, rawH)) {
        log("ERROR media: P5_960 contract fail bank=" + std::to_string(rawW) + "x" +
            std::to_string(rawH) + " (refusing 1280 ingest / snap-up)");
        return;
    }

    char scale[64];
    std::snprintf(scale, sizeof(scale), "%d:%d", rawW, rawH);
    std::string vf;
    // Force CFR at the exact content rate FIRST in the chain: frameIndex ↔ content
    // time then holds by construction (even if PMS emits a different rate than its
    // metadata claims), and frames dropped by the fps filter are never scaled.
    // Lab: FFMPEG_FPS_FILTER=off skips this for present-rate ceiling tests.
    if (fpsFilter_ && fpsNum_ > 0 && fpsDen_ > 0) {
        vf = "fps=" + std::to_string(fpsNum_) + "/" + std::to_string(fpsDen_) + ",";
    }
    // Scale filter: default bicubic avoids fast_bilinear vertical banding on
    // 480p-anamorphic→720 skies (BBB). MiSTer's native scaler owns display
    // aspect, so product frames fill the complete visible raster without
    // host-side letterbox bars.
    // Light present-rate ladder:
    //   fast_bilinear|neighbor — full-raster anamorphic scale
    //   exact / exact_fast_bilinear / exact_neighbor — force coded WxH, no foar/pad
    //   skip|none|off|identity — omit scale (size trust; may desync rawvideo)
    std::string swsFlags = swsFlags_;
    bool forceExact = false;
    if (swsFlags == "exact") {
        forceExact = true;
        swsFlags = "neighbor";
    } else if (swsFlags.rfind("exact_", 0) == 0 && swsFlags.size() > 6) {
        forceExact = true;
        swsFlags = swsFlags.substr(6);
    }
    if (budget960Wanted()) {
        forceExact = true;
        if (swsFlags == "bicubic" && swsFlags_ == "bicubic")
            swsFlags = "fast_bilinear";
        log("media: MPX_BUDGET_960 force exact scale to DECODE bank flags=" +
            swsFlags);
    }
    const bool skipScaleFlag =
        (swsFlags_ == "skip" || swsFlags_ == "none" || swsFlags_ == "off" ||
         swsFlags_ == "identity");
    // NEVER auto-skip scale because weak ladder videoResolution == DECODE alone.
    // PMS often returns a smaller coded size (lab FOAR @720p request → 720x480
    // H.264). Bypassing then packs wrong stride into 1280x720 banks → rainbow (L38).
    // Safe skip sources:
    //   - lab FFMPEG_SWS_FLAGS=skip|none|off|identity
    //   - local play-file already at coded WxH
    //   - PMS Media/Stream size *exactly matches* DECODE (identity). Source larger
    //     than bank (FOAR 720×480 into 640×480/320×240) must still scale down — and
    //     preferably come from PMS weak ladder at bank size (G0b).
    const bool urlIsLocalFile =
        !url.empty() && url[0] == '/' && url.rfind("http", 0) != 0 && url != "testsrc" &&
        url.rfind("lavfi", 0) != 0;
    // Universal 720p: probe start.mp4 coded WxH. Library 1440x1080 must not
    // skip (crop+scale of an already-1280x720 transcode is the 14 unique lock).
    // Probe fail keeps crop/scale so a 640x480 delivery cannot pack the bank.
    int vfCodedW = sourceMediaW_;
    int vfCodedH = sourceMediaH_;
    if (misterplex::isPlex720pBankSize(outW_, outH_) &&
        misterplex::isUniversalTranscodeUrl(url)) {
        int probedW = 0, probedH = 0;
        std::string probeFail;
        (void)probeSourceAspect(url, headers, &probeFail, &probedW, &probedH);
        vfCodedW = misterplex::skipVfProbedCodedDim(probedW, sourceMediaW_);
        vfCodedH = misterplex::skipVfProbedCodedDim(probedH, sourceMediaH_);
        char pbuf[160];
        std::snprintf(pbuf, sizeof(pbuf),
                      "media: transcode coded probe=%dx%d skip_coded=%dx%d library=%dx%d %s",
                      probedW, probedH, vfCodedW, vfCodedH, sourceMediaW_, sourceMediaH_,
                      probeFail.empty() ? "ok" : probeFail.c_str());
        log(pbuf);
    }
    const bool skip720pTranscodeVf =
        misterplex::skipRedundant720pTranscodeVf(url, outW_, outH_, vfCodedW, vfCodedH);
    const bool padOnly720p =
        !skip720pTranscodeVf &&
        misterplex::transcodePadOnly720p(vfCodedW, vfCodedH, outW_, outH_);
    const bool cropPmsBars =
        !skip720pTranscodeVf && !padOnly720p && nativeScalerPresent && sourceAspect_.valid &&
        url.find("/transcode/universal/") != std::string::npos;
    if (cropPmsBars) {
        const std::string dar = std::to_string(sourceAspect_.x) + "/" +
                                std::to_string(sourceAspect_.y);
        vf += "crop=trunc(min(iw\\,ih*" + dar +
              ")/2)*2:trunc(min(ih\\,iw/(" + dar + "))/2)*2,";
        log("media: PMS canvas crop to source DAR=" +
            std::to_string(sourceAspect_.x) + ":" +
            std::to_string(sourceAspect_.y));
    }
    if (padOnly720p) {
        vf += "pad=1280:720:(1280-iw)/2:(720-ih)/2:black";
        log("media: 720p pad-only coded=" + std::to_string(vfCodedW) + "x" +
            std::to_string(vfCodedH) + " → 1280x720 (no scale)");
    }
    // Bank==coded is not file==coded. --decode 960x540 on a 1280x720 local clip
    // used to skip vf (31b6d70f: scale/pad skipped local_identity_file) and
    // desync the 777600-byte raw pipe. Require probed source == bank, like PMS.
    const bool identityLocalFile =
        nativeScalerPresent && urlIsLocalFile && !forceExact &&
        rawDisplayW == rawW && rawDisplayH == rawH && outW_ == rawW && outH_ == rawH &&
        sourceMediaW_ > 0 && sourceMediaH_ > 0 &&
        sourceMediaW_ == outW_ && sourceMediaH_ == outH_;
    const bool pmsSourceMatchesBank =
        nativeScalerPresent && !forceExact && !urlIsLocalFile &&
        sourceMediaW_ > 0 && sourceMediaH_ > 0 &&
        sourceMediaW_ == outW_ && sourceMediaH_ == outH_ &&
        rawDisplayW == rawW && rawDisplayH == rawH && outW_ == rawW && outH_ == rawH;
    const bool skipScale =
        skip720pTranscodeVf || padOnly720p ||
        (!cropPmsBars && (skipScaleFlag || identityLocalFile || pmsSourceMatchesBank));
    if (skip720pTranscodeVf)
        log("media: 720p transcode already bank-sized — skip crop/scale vf");
    // skip|none|off|identity are NOT valid libswscale flag names — if 480p (or any
    // non-identity geom) still needs scaling, fall back to bicubic.
    if (skipScaleFlag && !(skipScale && rawDisplayW == rawW && rawDisplayH == rawH)) {
        swsFlags = "bicubic";
        log("media: FFMPEG_SWS_FLAGS=" + swsFlags_ +
            " ignored for non-identity geom; using bicubic native-aspect scale");
    }
    if (skipScale && rawDisplayW == rawW && rawDisplayH == rawH) {
        // Explicit lab skip, local identity, or PMS source exact DECODE match.
        if (!vf.empty() && vf.back() == ',')
            vf.pop_back();
        const char* why = "FFMPEG_SWS_FLAGS";
        if (skip720pTranscodeVf)
            why = "transcode_coded_1280x720";
        else if (padOnly720p)
            why = "pad_only_720tall";
        else if (identityLocalFile && !skipScaleFlag)
            why = "local_identity_file";
        else if (pmsSourceMatchesBank && !skipScaleFlag)
            why = "pms_source_matches_bank";
        log(std::string("media: scale/pad skipped (") + why +
            (pmsSourceMatchesBank
                 ? (" src=" + std::to_string(sourceMediaW_) + "x" +
                    std::to_string(sourceMediaH_))
                 : "") +
            " coded=" + std::to_string(rawW) + "x" + std::to_string(rawH) +
            " scale=bypass)");
    } else if (forceExact) {
        // Hard size contract: stretch/squash to coded WxH (one scale, no pad).
        vf += std::string("scale=") + scale + ":flags=" + swsFlags;
        log("media: force exact scale=" + std::string(scale) + " flags=" + swsFlags +
            " (no foar/pad)");
    } else if (rawDisplayW != rawW || rawDisplayH != rawH) {
        char displayScale[64];
        std::snprintf(displayScale, sizeof(displayScale), "%d:%d", rawDisplayW, rawDisplayH);
        vf += std::string("scale=") + displayScale + ":flags=" + swsFlags + ",pad=" + scale +
              ":" + std::to_string(ddrGeometry.crop_left) + ":" +
              std::to_string(ddrGeometry.crop_top) + ":color=black";
        log("media: native-aspect scale+crop-pad coded=" + std::to_string(rawW) + "x" +
            std::to_string(rawH) +
            " display=" + std::to_string(rawDisplayW) + "x" + std::to_string(rawDisplayH) +
            " present=" + std::to_string(outW_) + "x" + std::to_string(outH_) +
            " flags=" + swsFlags);
    } else if (nativeScalerPresent) {
        vf += std::string("scale=") + scale + ":flags=" + swsFlags;
    } else {
        vf += std::string("scale=") + scale +
              ":force_original_aspect_ratio=decrease:flags=" + swsFlags +
              ",pad=" + scale + ":(ow-iw)/2:(oh-ih)/2:color=black";
        log("media: host aspect preservation enabled (PRESENT=" + presentMode_ + ")");
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
    bool wantAudio = audioEnabled_ && (wantMr || wantF2);
    // Dual-output (pipe:1 + pipe:3) aborts the whole ffmpeg process when the
    // container has no audio — Grid720 freckle map is video-only. Prefer resolve
    // metadata (hasAudio=false); fall back to a local-file probe.
    if (wantAudio && !sourceHasAudio_) {
        wantAudio = false;
        log("media: audio disabled for session: source metadata has no audio stream "
            "(avoid empty pipe:3 abort)");
    } else if (wantAudio && localFile &&
               !ffmpegHasAudioStream(ffmpeg_, url, headers, startMs)) {
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
                // Only the no-RGB path lets sparse reconstruction own F1.
                // Otherwise continuous rawvideo is the sole DDR frame writer.
                streamThr_ =
                    std::thread([this, sfd = spipe[0], allowF1Present = skipRgb] {
                        streamPump(sfd, allowF1Present);
                    });
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

    bool usedRawVideo = false;
    bool videoEof = false;
    bool shortRead = false;
    bool true480PipelineAborted = false;
    size_t shortReadGot = 0;
    size_t shortReadWant = 0;

    // A/V pacing state. The exact rational rate is load-bearing: pacing 23.976 fps
    // content at a hardcoded 24 leaks ~1 ms/s of video lead.
    const int fpsNum = fpsNum_ > 0 ? fpsNum_ : kDefaultFpsNum;
    const int fpsDen = fpsNum_ > 0 && fpsDen_ > 0 ? fpsDen_ : kDefaultFpsDen;
    const int64_t leadMs = presentLeadMs_;
    // L4 / 720p bank: never 2:1-drop for audio drift. Hold (video ahead) stays.
    // FPGA NACK is sendYuv420pFrameDdr / commitDdrBankIngest fail, not Drop.
    // 720p L4 and true480 640×480: never 2:1-drop for wall-clock drift.
    // Silent Grid720 on the 480 store was presenting 13 pfps / dropping half
    // (dropMs>0) after glass pinned true480. FPGA already swaps every kick.
    const bool l4PresentEveryDecoded =
        liveGlass_ == LiveGlass::L4 || isPlex720pDdrFrameGeometry(ddrGeometry) ||
        isPlex480pDdrFrameGeometry(ddrGeometry) ||
        (ddrGeometry.presented_width == 320 && ddrGeometry.presented_height == 240);
    const int64_t dropMs =
        avResyncDropMsForPresent(resyncDropMs_, l4PresentEveryDecoded);
    int dropRun = 0;
    avDriftMs_.store(0);
    droppedFrames_.store(0);
    if (fpsNum_ <= 0)
        log("media: content fps UNKNOWN — pacing at " + std::to_string(kDefaultFpsNum) + "/" +
            std::to_string(kDefaultFpsDen) + " and relying on drift correction");
    else
        log("media: content fps=" + std::to_string(fpsNum) + "/" + std::to_string(fpsDen) +
            " lead_ms=" + std::to_string(leadMs) + " resync_drop_ms=" + std::to_string(dropMs) +
            (l4PresentEveryDecoded ? " (L4 present-every-decoded; FPGA NACK only)" : ""));

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
        audioFeedRelease_.store(true);
        audioReleaseAfterPresents_.store(0);
        audioAfterVideoMs_.store(0);
        BankReleaseStatus hwPresentBaseline;
        bool hwPresentBaselineValid = fpga_.readBankRelease(hwPresentBaseline);
        int64_t hwPresentArmBaseline = 0;
        uint16_t hwPresentLastFrames = hwPresentBaseline.frames_done;
        if (hwPresentBaselineValid) {
            char pbuf[128];
            std::snprintf(pbuf, sizeof(pbuf),
                          "media: plxd_play_start frames_done=%u pending=%d disp=%u free=0x%x",
                          static_cast<unsigned>(hwPresentBaseline.frames_done),
                          hwPresentBaseline.swap_pending ? 1 : 0,
                          static_cast<unsigned>(hwPresentBaseline.disp_bank),
                          static_cast<unsigned>(hwPresentBaseline.free_bank_mask));
            log(pbuf);
        } else {
            log("media: plxd_play_start unavailable: " + fpga_.lastError());
        }
        uint64_t hwPresentTotal = 0;
        auto hwPresentTimeBaseline = std::chrono::steady_clock::now();
        auto hardwarePresentTelemetry = [&]() {
            BankReleaseStatus current;
            if (!fpga_.readBankRelease(current))
                return std::string(" hw_presents=unavailable hw_presents_src=plxd_swap_count");
            const auto now = std::chrono::steady_clock::now();
            if (!hwPresentBaselineValid) {
                hwPresentBaseline = current;
                hwPresentArmBaseline = presentCount_;
                hwPresentLastFrames = current.frames_done;
                hwPresentTotal = 0;
                hwPresentTimeBaseline = now;
                hwPresentBaselineValid = true;
            } else {
                hwPresentTotal += frameCounterDelta(current.frames_done, hwPresentLastFrames);
                hwPresentLastFrames = current.frames_done;
            }
            const int64_t armDelta = presentCount_ - hwPresentArmBaseline;
            const int64_t windowMs =
                std::chrono::duration_cast<std::chrono::milliseconds>(
                    now - hwPresentTimeBaseline)
                    .count();
            const double hardwareFps =
                windowMs > 0 ? 1000.0 * static_cast<double>(hwPresentTotal) /
                                   static_cast<double>(windowMs)
                             : 0.0;
            return std::string(" hw_presents=") + std::to_string(hwPresentTotal) +
                   " hw_arm_delta=" + std::to_string(armDelta) +
                   " hw_fps=" + std::to_string(hardwareFps).substr(0, 5) +
                   " hw_window_ms=" + std::to_string(windowMs) +
                   " hw_match=" +
                   (hardwarePresentTotalsMatch(hwPresentTotal, armDelta)
                        ? "1"
                        : "0") +
                   " hw_presents_src=plxd_swap_count";
        };
        // Live universal never prefetches to tmpfs (waitPid 20s killed the
        // 91 min Trek transcode; identity /tmp body is not product).
        std::vector<std::string> args;
        args.push_back(ffmpeg_);
        args.push_back("-hide_banner");
        args.push_back("-loglevel");
        args.push_back("error");
        args.push_back("-nostdin");
        // Dual-A9: isolated 720p Farpoint is ~32 fps at -threads 2. Product
        // wait_swap sleeps ~41 ms per unique, so both cores can decode during
        // the blank. -threads 1 + wait_swap was unique 22.9; memcpy-era
        // thread=1 without wait was 0.3 pfps (15 ms copy).
        args.push_back("-threads");
        args.push_back("2");
        // Identity 1280×720 baseline: deblock is ~2–4 ms/f on dual-A9 and was
        // the 21.8 unique lock (host x264 is 9.5× realtime). skip-vf path only.
        if (skip720pTranscodeVf) {
            args.push_back("-skip_loop_filter");
            args.push_back("all");
            log("media: 720p identity skip_loop_filter=all");
        }
        // Match scale=...:flags=; omit for skip/none/off/identity (no swscale).
        // exact_* → pass the algorithm only (exact_fast_bilinear → fast_bilinear).
        if (!(swsFlags_ == "skip" || swsFlags_ == "none" || swsFlags_ == "off" ||
              swsFlags_ == "identity")) {
            std::string alg = swsFlags_;
            if (alg == "exact")
                alg = "neighbor";
            else if (alg.rfind("exact_", 0) == 0 && alg.size() > 6)
                alg = alg.substr(6);
            args.push_back("-sws_flags");
            args.push_back(alg);
        }
        // D3 decode cost: skip in-loop deblock on dual-A9 (lab). Softens slightly;
        // measure pfps only — not a quality/product PASS claim.
        // Do not skip loop filter: all-skip left greenish H.264 mosquito / chroma
        // bleed on soft edges (user BBB HDMI). Default deblock is worth the dual-A9
        // cost once present is pipelined.

        // 720p product + audio: video ffmpeg is -an; audio is a second process
        // so MrAudio 48 kHz wall-pace cannot stall I420 produce. 480p and
        // testPattern stay single-process (pipe:1 + pipe:3).
        const bool splitAv720 =
            wantAudio && !testPattern && plex720pClassSplitAv(outW_, outH_);
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
            // Same rule as universal path: -an only when no audio output follows.
            if (!wantAudio)
                args.push_back("-an");
            args.push_back("-f");
            args.push_back("rawvideo");
            args.push_back("-pix_fmt");
            args.push_back(ffmpegPixFmt(videoFmt));
            // Empty vf (scale+fps both skipped) must not pass bare "-vf" — ffmpeg exits.
            if (!vf.empty()) {
                args.push_back("-vf");
                args.push_back(vf);
            }
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

            // Video output first. Combined A+V must not pass global -an when a
            // second audio output follows — FFmpeg 6/7 treats -an as
            // disable-all-audio and then fails pipe:3. Video-only and 720p
            // split sessions use -an so this process does not pull unused audio.
            args.push_back("-map");
            args.push_back("0:v:0");
            if (!wantAudio || splitAv720)
                args.push_back("-an");
            args.push_back("-f");
            args.push_back("rawvideo");
            args.push_back("-pix_fmt");
            args.push_back(ffmpegPixFmt(videoFmt));
            // Empty vf (identity skip + FPS filter off) must not pass bare "-vf".
            if (!vf.empty()) {
                args.push_back("-vf");
                args.push_back(vf);
            }
            args.push_back("pipe:1");

            if (wantAudio && !splitAv720) {
                // 480p combined spawn: MrAudio wall-pace back-pressures A+V
                // together. 720p uses spawnAudioOnly() instead (below).
                // AUDIO_DELAY_MS>0: adelay shifts audio content later (ms).
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

#ifdef MPX_HAVE_LIBAV
        AvInprocDecoder inprocDec;
#endif
        bool useInproc = false;
        int remuxPcmFd = -1;
        int remuxHoldV = -1;
        int remuxHoldA = -1;
        bool remuxPcmPumpEarly = false;
        std::string audioUrl = url;
        std::string audioHeaders = headers;
        int64_t audioStartMs = startMs;
        const bool wantInproc =
            inprocDecodeWanted() && !testPattern &&
            inprocDecodeSizeOk(outW_, outH_);
        log(std::string("media: want_inproc=") + (wantInproc ? "1" : "0") +
            " prefetched=0 url_local=" +
            (url.rfind("/tmp/", 0) == 0 ? "1" : "0"));
        auto abortInprocSession = [&](const std::string& why) {
            log(why);
            playing_.store(false);
            stop_.store(true);
#ifdef MPX_HAVE_LIBAV
            inprocDec.requestStop();
#endif
            killChildren();
            if (audioThr_.joinable())
                audioThr_.join();
            if (streamThr_.joinable())
                streamThr_.join();
#ifdef MPX_HAVE_LIBAV
            inprocPcm_ = nullptr;
#endif
        };
        if (wantInproc) {
#ifndef MPX_HAVE_LIBAV
            abortInprocSession(
                "media: inproc_decode=1 but binary has no libav — abort (no pipe:1)");
            return;
#else
            if (!(wantYuvDdr && presentMode_ == "fpga" &&
                  videoFmt == RawVideoFormat::Yuv420p)) {
                abortInprocSession(
                    "media: inproc_decode=1 needs fpga yuv420p 2-slot — abort (no pipe:1)");
                return;
            }
            AvInprocOpenOpts iopts;
            iopts.cancelled = &stop_;
            iopts.threads = 2;
            iopts.startMs = startMs;
            iopts.headers = headers;
            if (isPlex960BankSize(outW_, outH_) || isPlex960BankSize(rawW, rawH)) {
                if (sourceMediaW_ == kInproc960W && sourceMediaH_ == kInproc960H) {
                    iopts.expectW = kInproc960W;
                    iopts.expectH = kInproc960H;
                } else {
                    // Leftover / 1280 clip: decode coded 1280×720, pack 960×540.
                    iopts.expectW = kInproc720W;
                    iopts.expectH = kInproc720H;
                    iopts.outW = kInproc960W;
                    iopts.outH = kInproc960H;
                }
            } else {
                iopts.expectW = rawW;
                iopts.expectH = rawH;
            }
            std::string ierr;
            std::string inprocUrl = url;
            const bool httpSrc = (url.compare(0, 7, "http://") == 0 ||
                                  url.compare(0, 8, "https://") == 0);
            const bool remuxCopyAudio = misterplex::p720_av::inprocRemuxMustCopyAudio(
                isPlex720pDdrFrameGeometry(ddrGeometry) && !isPlex960BankSize(rawW, rawH),
                true);
            if (httpSrc && inprocUrl == url) {
                // ARM libav: file+h264 only (no HTTP, no AAC). Box ffmpeg remuxes
                // one HTTP into annex-B ± PCM fifos. Direct HTTP open → Protocol
                // not found; mpegts+AAC inproc SIGABRT'd (dl-call-libc-early-init).
                // Sole reader on each fifo: a leftover O_RDWR hold stole annex-B
                // bytes from libav (avcodec_send_packet Invalid data).
                const char* vfifo = "/tmp/mplex-inproc.h264";
                const char* afifo = "/tmp/mplex-inproc.pcm";
                ::unlink(vfifo);
                if (remuxCopyAudio)
                    ::unlink(afifo);
                auto mkSizedFifo = [](const char* path, int bytes) -> bool {
                    if (mkfifo(path, 0644) != 0)
                        return false;
                    const int fd = ::open(path, O_RDWR | O_NONBLOCK);
                    if (fd < 0)
                        return false;
#ifdef F_SETPIPE_SZ
                    (void)::fcntl(fd, F_SETPIPE_SZ, bytes);
#else
                    (void)bytes;
#endif
                    ::close(fd);
                    return true;
                };
                const bool vok =
                    mkSizedFifo(vfifo, remuxCopyAudio ? 4 * 1024 * 1024 : 1048576);
                const bool aok =
                    !remuxCopyAudio || mkSizedFifo(afifo, 4 * 1024 * 1024);
                if (vok && aok) {
                    if (remuxCopyAudio) {
                        // Hold is a dummy writer so ffmpeg's PCM open is not
                        // ENXIO during video rendezvous. Pump reads O_RDONLY:
                        // sharing O_RDWR with the pump hides EOF when remux
                        // exits (pipe_read forever → stop() joins forever →
                        // playMedia HTTP blocks on playHandoffMu → spinner).
                        int hold = remuxPcmHoldFd_.exchange(-1);
                        if (hold >= 0)
                            ::close(hold);
                        hold = ::open(afifo, O_RDWR | O_NONBLOCK);
                        remuxPcmHoldFd_.store(hold);
                        remuxPcmFd = ::open(afifo, O_RDONLY | O_NONBLOCK);
                    }
                    const pid_t rpid = spawnHttpRemuxMpegts(
                        url, headers, startMs, vfifo, remuxCopyAudio,
                        remuxCopyAudio ? afifo : "");
                    if (rpid > 0) {
                        streamPid_.store(rpid);
                        inprocUrl = vfifo;
                        iopts.startMs = 0;
                        iopts.liveFifo = true;
                        log(std::string("media: inproc_decode remux fifo http→") +
                            (remuxCopyAudio ? "annexb+pcm" : "annexb"));
                    } else {
                        log("media: inproc_decode remux spawn failed — pipe");
                        if (remuxPcmFd >= 0) {
                            ::close(remuxPcmFd);
                            remuxPcmFd = -1;
                        }
                        int hold = remuxPcmHoldFd_.exchange(-1);
                        if (hold >= 0)
                            ::close(hold);
                    }
                } else {
                    log(std::string("media: inproc_decode mkfifo failed errno=") +
                        std::to_string(errno) + " — pipe");
                }
            }
            if (remuxPcmFd >= 0) {
                // Gate MrAudio until the first picture, but drain PCM during
                // avformat_open so remux cannot fill the fifo and deadlock.
                audioFeedRelease_.store(false);
                audioReleaseAfterPresents_.store(0);
                holdAudioToPictures_.store(false);
                const int pfd = remuxPcmFd;
                remuxPcmFd = -1;
                remuxPcmReadFd_.store(pfd);
                audioThr_ = std::thread([this, pfd] { audioPump(pfd); });
                remuxPcmPumpEarly = true;
            }
#ifdef MPX_HAVE_LIBAV
            inprocPcm_ = &inprocDec;
#endif
            const bool inprocOpened = inprocDec.open(inprocUrl, iopts, ierr);
            if (inprocOpened && remuxPcmPumpEarly)
                audioFeedRelease_.store(true);
            if (!inprocOpened) {
                const pid_t rp = streamPid_.exchange(-1);
                if (rp > 0) {
                    ::kill(rp, SIGTERM);
                    ::kill(-rp, SIGTERM);
                }
                if (remuxPcmFd >= 0) {
                    ::close(remuxPcmFd);
                    remuxPcmFd = -1;
                }
                if (isPlex720pDdrFrameGeometry(ddrGeometry) &&
                    !isPlex960BankSize(rawW, rawH)) {
                    abortInprocSession("media: inproc_decode open failed: " + ierr +
                                       " — abort (no spawnAudioOnly pipe)");
                    return;
                }
                log("media: inproc_decode open failed: " + ierr +
                    " — pipe fallback");
            } else {
            useInproc = true;
            std::string extra;
            if (inprocDec.width() != iopts.expectW ||
                inprocDec.height() != iopts.expectH) {
                extra = " src=" + std::to_string(iopts.expectW) + "x" +
                        std::to_string(iopts.expectH) + " scale=4/3";
            } else if (sourceMediaW_ > 0 && sourceMediaH_ > 0 &&
                       (sourceMediaW_ != inprocDec.width() ||
                        sourceMediaH_ != inprocDec.height())) {
                extra = " src=" + std::to_string(sourceMediaW_) + "x" +
                        std::to_string(sourceMediaH_) + " scale=nearest";
            }
            log(std::string("media: inproc_decode=1 libav=") +
                AvInprocDecoder::libavIdent() + " wxh=" +
                std::to_string(inprocDec.width()) + "x" +
                std::to_string(inprocDec.height()) + extra + " pix=yuv420p");
            }
#endif
        }

        const bool sameDemuxAudio =
            misterplex::p720_av::inprocSameDemuxAudioWanted(
                useInproc && isPlex720pDdrFrameGeometry(ddrGeometry) &&
                    !isPlex960BankSize(rawW, rawH),
                useInproc)
#ifdef MPX_HAVE_LIBAV
            && inprocDec.hasAudio()
#endif
            ;
        const bool remuxPcmAudio =
            remuxPcmPumpEarly || (remuxPcmFd >= 0 && !sameDemuxAudio);

        int vpipe[2] = {-1, -1};
        int apipe[2] = {-1, -1};
        if (!useInproc && pipe(vpipe) != 0) {
            log("media: video pipe failed");
            playing_.store(false);
            killChildren();
            if (streamThr_.joinable())
                streamThr_.join();
            return;
        }
        // Enlarge video pipe so decode can run ahead of uncached DDR present.
        // Default pipe (~64KiB) and even pipe-max 1MiB are < one 720p I420 frame
        // (1.38MiB) — producer blocks mid-frame. Prefer multi-frame capacity when
        // the kernel allows (sysctl fs.pipe-max-size ≥ 4–8MiB on lab).
#ifndef F_SETPIPE_SZ
#define F_SETPIPE_SZ 1031
#endif
#ifndef F_GETPIPE_SZ
#define F_GETPIPE_SZ 1032
#endif
        if (!useInproc) {
            const int wantPipe = 4 * 1024 * 1024; // 4 MiB ≈ 2.9× 720p I420
            int got0 = static_cast<int>(::fcntl(vpipe[0], F_SETPIPE_SZ, wantPipe));
            int got1 = static_cast<int>(::fcntl(vpipe[1], F_SETPIPE_SZ, wantPipe));
            int sz = static_cast<int>(::fcntl(vpipe[0], F_GETPIPE_SZ));
            log("media: video_pipe_sz want=" + std::to_string(wantPipe) +
                " set0=" + std::to_string(got0) + " set1=" + std::to_string(got1) +
                " get=" + std::to_string(sz));
        }
        if (wantAudio && !sameDemuxAudio && !remuxPcmAudio && pipe(apipe) != 0) {
            log("media: audio pipe failed — video only");
            apipe[0] = apipe[1] = -1;
        } else if (wantAudio && apipe[0] >= 0) {
            // Gated trim may pause MrAudio writes ~1–3 s; 1 MiB ≈ 5 s of
            // 48 kHz s16le stereo so ffmpeg does not stall I420.
            const int wantA = 1024 * 1024;
            (void)::fcntl(apipe[0], F_SETPIPE_SZ, wantA);
            (void)::fcntl(apipe[1], F_SETPIPE_SZ, wantA);
        }

        if (!useInproc) {
            // Never log raw PMS tokens (X-Plex-Token / query) into misterplexd.log.
            auto redactArg = [](std::string a) {
                const char* keys[] = {"X-Plex-Token=", "X-Plex-Token%3D", "token="};
                for (const char* k : keys) {
                    std::size_t p = 0;
                    while ((p = a.find(k, p)) != std::string::npos) {
                        const std::size_t v = p + std::strlen(k);
                        std::size_t e = a.find_first_of("& \t\"'", v);
                        if (e == std::string::npos)
                            e = a.size();
                        a.replace(v, e - v, "REDACTED");
                        p = v + 8;
                    }
                }
                return a;
            };
            if (splitAv720)
                log("media: spawn 720p split A/V (video -an + audio-only) — hypothesized audio backpressure relief");
            std::string joined =
                splitAv720 ? "media: spawn 720p video" : "media: spawn single-process";
            for (const auto& a : args) {
                joined += ' ';
                if (a.find(' ') != std::string::npos || a.find('\r') != std::string::npos)
                    joined += "[...]";
                else
                    joined += redactArg(a);
            }
            log(joined);

            // Combined 480p: one ffmpeg owns pipe:1 + pipe:3. Split 720p: video
            // ffmpeg is video-only (no aWriteFd); audio-only is a second process.
            pid_t pid = spawnFfmpeg(args, vpipe[1],
                                    (splitAv720 || apipe[1] < 0) ? -1 : apipe[1]);
            if (pid < 0) {
                ::close(vpipe[1]);
                if (apipe[1] >= 0)
                    ::close(apipe[1]);
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
        }

        if (sameDemuxAudio) {
#ifdef MPX_HAVE_LIBAV
            inprocPcm_ = &inprocDec;
            log(std::string("media: inproc_audio=same_demux has_audio=") +
                (inprocDec.hasAudio() ? "1" : "0"));
#else
            log("media: inproc_audio=same_demux has_audio=0");
#endif
        } else if (remuxPcmPumpEarly) {
            log("media: inproc_audio=remux_pcm (one HTTP, no spawnAudioOnly)");
        } else if (remuxPcmAudio) {
            apipe[0] = remuxPcmFd;
            remuxPcmFd = -1;
            apipe[1] = -1;
            log("media: inproc_audio=remux_pcm (one HTTP, no spawnAudioOnly)");
        } else if (useInproc && isPlex720pDdrFrameGeometry(ddrGeometry) &&
                   !isPlex960BankSize(rawW, rawH)) {
            log("media: inproc_audio=abort remux_pcm fd missing — no spawnAudioOnly");
            playing_.store(false);
            killChildren();
            if (streamThr_.joinable())
                streamThr_.join();
            return;
        } else if (splitAv720 && apipe[1] >= 0) {
            pid_t apid = spawnAudioOnly(audioUrl, audioHeaders, audioStartMs, apipe[1]);
            if (apid > 0) {
                audioPid_.store(apid);
            } else {
                log("media: 720p audio-only fork failed — continuing video-only");
                ::close(apipe[0]);
                apipe[0] = -1;
            }
        }

        if (vpipe[1] >= 0)
            ::close(vpipe[1]);
        if (apipe[1] >= 0)
            ::close(apipe[1]);
        rfd = vpipe[0];
        // Blocking read: present thread sleeps in kernel until ffmpeg produces
        // bytes — frees A9 for decode. Nonblock+EAGAIN sleep fought the producer
        // (200us spin → 19 pfps; 2ms sleep → 20.7). Blocking is the clean yield.
        if (rfd >= 0) {
            const int rflags = fcntl(rfd, F_GETFL, 0);
            if (rflags >= 0)
                fcntl(rfd, F_SETFL, rflags & ~O_NONBLOCK);
        }

        if (!remuxPcmPumpEarly &&
            (apipe[0] >= 0 || sameDemuxAudio || remuxPcmAudio)) {
            // Gate MrAudio for every 720p inproc session (60-frame warmup).
            // Extra after_video_ms=100 is only native 1280 (lands ~+4 ms).
            // Scaled 240/480: gate until first kick, then 0 ms.
            const bool warmup720Inproc =
                useInproc && isPlex720pDdrFrameGeometry(ddrGeometry) &&
                !isPlex960BankSize(rawW, rawH) &&
                !isPlex960DdrFrameGeometry(ddrGeometry);
            const bool native1280Inproc =
                warmup720Inproc && sourceMediaW_ == kInproc720W &&
                sourceMediaH_ == kInproc720H;
            audioFeedRelease_.store(true);
            // Per-raster / per-source-class bake. AUDIO_DELAY_MS stays the
            // user adelay knob. Conf AV_HDMI_AUDIO_LAG_MS>0 overrides after_ms.
            const char* dlab = (displayRasterLatched_ && latchedDisplayRes_.label)
                                   ? latchedDisplayRes_.label
                                   : "720p";
            const HdmiAutoDelay baked =
                hdmiAutoDelayForPlay(dlab, sourceMediaW_, sourceMediaH_);
            if (native1280Inproc || warmup720Inproc) {
                // 480p-class: start MrAudio with video. Gating until first
                // kick left audio_s/wall≈0.91 at 57 s while unique was 23.7.
                audioAfterVideoMs_.store(0);
                audioHoldSlackMs_.store(baked.holdSlackMs);
                audioReleaseAfterPresents_.store(0);
                log("media: hdmi_audio_lag path=inproc after_video_ms=0 src=" +
                    std::to_string(sourceMediaW_) + "x" +
                    std::to_string(sourceMediaH_));
            } else {
                audioAfterVideoMs_.store(0);
                // 480p gold + combined 720p prefetch: start MrAudio with video.
                // The 24-present gate left 1 s of silence and audio_s/wall≈0.98
                // at 40 s (Star Trek stutter). Inproc warmup still gates above.
                const bool startWithVideo =
                    misterplex::p720_av::combined720pAudioStartsWithVideo(useInproc);
                if (startWithVideo) {
                    audioFeedRelease_.store(true);
                    audioReleaseAfterPresents_.store(0);
                    log("media: hdmi_audio_lag path=pipe after_video_ms=0");
                } else {
                    audioFeedRelease_.store(false);
                    audioReleaseAfterPresents_.store(24);
                    log("media: hdmi_audio_lag path=pipe 720p_trim_after_presents=24");
                }
            }
            holdAudioToPictures_.store(misterplex::p720_av::holdAudioToPicturesWanted(
                isPlex720pDdrFrameGeometry(ddrGeometry) && !isPlex960BankSize(rawW, rawH),
                useInproc));
            log("media: hold_audio_to_pictures=" +
                std::string(holdAudioToPictures_.load() ? "1" : "0") +
                " skip_av_hold=" +
                (misterplex::p720_av::combined720pSkipAvHold(
                     isPlex720pDdrFrameGeometry(ddrGeometry), useInproc)
                     ? "1"
                     : "0"));
            const int pumpFd = sameDemuxAudio ? -1 : apipe[0];
            audioThr_ = std::thread([this, pumpFd] { audioPump(pumpFd); });
        }

        auto closeRemuxHolds = [&]() {
            if (remuxHoldV >= 0) {
                ::close(remuxHoldV);
                remuxHoldV = -1;
            }
            if (remuxHoldA >= 0) {
                ::close(remuxHoldA);
                remuxHoldA = -1;
            }
            if (remuxPcmFd >= 0) {
                ::close(remuxPcmFd);
                remuxPcmFd = -1;
            }
            int hold = remuxPcmHoldFd_.exchange(-1);
            if (hold >= 0)
                ::close(hold);
        };

        const size_t frameBytes = rawVideoFrameBytes(videoFmt, rawW, rawH);
        if (budget960Wanted() || isPlex960BankSize(rawW, rawH)) {
            log("media: P5_960 produce contract bank=" + std::to_string(rawW) + "x" +
                std::to_string(rawH) + " frame_bytes=" + std::to_string(frameBytes) +
                " want=" + std::to_string(static_cast<size_t>(kPlex960Yuv420pBytes)) +
                " src=" + std::to_string(sourceMediaW_) + "x" +
                std::to_string(sourceMediaH_) +
                " skip_last_presented=" +
                (skipLastPresentedWanted() ? "1" : "0") +
                " split_av=" + (splitAv720 ? "1" : "0"));
        }
        std::vector<uint8_t> frame(frameBytes);
        std::vector<uint8_t> fbOverlayBackup;
        I420DirtyBackup i420OverlayBackup;
        // Program DDR geometry before direct bank ingest (pipe→bank).
        if (useDdrF1_ && wantFpgaFrameStore && videoFmt == RawVideoFormat::Yuv420p) {
            if (!fpga_.setDdrFrameLayout(ddrGeometry, DdrFrameFormat::Yuv420p))
                log("media: setDdrFrameLayout failed: " + fpga_.lastError());
            else
                log("media: DDR layout coded=" + std::to_string(rawW) + "x" +
                    std::to_string(rawH) + " frame_bytes=" + std::to_string(frameBytes) +
                    " direct_ingest=" +
                    (presentMode_ == "fpga" ? "on" : "off"));
        }

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

        auto renderPackedOverlay = [&](uint8_t* data) {
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
                return true;
            const size_t bpp = rawVideoPackedBytesPerPixel(videoFmt);
            if (bpp == 0)
                return false;
            const size_t rowBytes = static_cast<size_t>(dirty.w) * bpp;
            fbOverlayBackup.resize(rowBytes * static_cast<size_t>(dirty.h));
            for (int yy = 0; yy < dirty.h; ++yy) {
                const size_t src =
                    (static_cast<size_t>(dirty.y + yy) * rawW + dirty.x) * bpp;
                std::memcpy(fbOverlayBackup.data() + rowBytes * static_cast<size_t>(yy),
                            cleanFrame + src, rowBytes);
            }
            return true;
        };

        auto restoreOverlayDirty = [&](uint8_t* cleanFrame, const OverlayRect& dirty) {
            if (dirty.empty())
                return;
            if (videoFmt == RawVideoFormat::Yuv420p) {
                (void)i420OverlayBackup.restore(cleanFrame, rawW, rawH);
                return;
            }
            if (fbOverlayBackup.empty())
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
            OverlayRect dirty{};
            bool overlayBackedUp = false;
            if (videoFmt == RawVideoFormat::Yuv420p) {
                if (profilePresent) {
                    const auto overlay0 = std::chrono::steady_clock::now();
                    const int64_t overlayCpu0 = threadCpuMicros();
                    overlayBackedUp = overlay_.renderI420WithBackup(
                        cleanFrame, rawW, rawH, i420OverlayBackup);
                    const int64_t overlayCpu1 = threadCpuMicros();
                    const auto overlay1 = std::chrono::steady_clock::now();
                    if (overlayBackedUp) {
                        prof.overlayUs += microsBetween(overlay0, overlay1);
                        prof.overlayCpuUs += overlayCpu1 - overlayCpu0;
                    }
                } else {
                    overlayBackedUp = overlay_.renderI420WithBackup(
                        cleanFrame, rawW, rawH, i420OverlayBackup);
                }
                dirty = i420OverlayBackup.rect;
            } else {
                dirty = overlay_.dirtyBounds(rawW, rawH);
                overlayBackedUp = backupOverlayDirty(cleanFrame, dirty);
                if (!dirty.empty() && overlayBackedUp) {
                    if (profilePresent) {
                        const auto overlay0 = std::chrono::steady_clock::now();
                        const int64_t overlayCpu0 = threadCpuMicros();
                        renderPackedOverlay(cleanFrame);
                        const int64_t overlayCpu1 = threadCpuMicros();
                        const auto overlay1 = std::chrono::steady_clock::now();
                        prof.overlayUs += microsBetween(overlay0, overlay1);
                        prof.overlayCpuUs += overlayCpu1 - overlayCpu0;
                    } else {
                        renderPackedOverlay(cleanFrame);
                    }
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
                        prof.ddrBankReuseWaitUs += dt.bank_reuse_wait_us;
                        prof.ddrTotalUs += dt.total_us;
                        prof.ddrCpuUs += ddrCpu1 - ddrCpu0;
                        if (dt.total_us > accounted)
                            prof.ddrUnaccountedUs += dt.total_us - accounted;
                    }
                    if (ok)
                        ddrBank_ ^= 1;
                    if (!ok)
                        log("media: DDR YUV420p F1 unavailable: " + fpga_.lastError());
                }
                if (!ok && videoFmt != RawVideoFormat::Yuv420p) {
                    log("media: non-YUV F1 frame refused before send; frame store requires DDR "
                        "YUV420p");
                }
                if (!ok) {
                    if (countPresent && (frameIndex % 30) == 0)
                        log("media: fpga frame_tx: " + fpga_.lastError());
                } else if (countPresent) {
                    ++presentCount_;
                    if (profilePresent)
                        ++prof.presented;
                    if ((presentCount_ % 48) == 0) {
                        const auto dt = fpga_.lastDdrTiming();
                        log(std::string("media: fpga frame_tx ok via ") +
                            "DDR" +
                            " presents=" + std::to_string(presentCount_) +
                            " frames=" + std::to_string(frameIndex) +
                            " ms=" + std::to_string(static_cast<int>(fpga_.lastPushMs())) +
                            " prep_us=" + std::to_string(dt.prep_wait_us) +
                            " copy_us=" + std::to_string(dt.copy_us) +
                            " flush_us=" + std::to_string(dt.flush_us) +
                            " doorbell_us=" + std::to_string(dt.doorbell_us) +
                            " post_us=" + std::to_string(dt.post_wait_us) +
                            " bank_reuse_us=" + std::to_string(dt.bank_reuse_wait_us) +
                            " plxd_us=" + std::to_string(dt.plxa_poll_us) +
                            " plxd_iters=" + std::to_string(dt.plxa_poll_iters) +
                            " plxd_used=" + (dt.plxa_used ? "1" : "0") +
                            " total_us=" + std::to_string(dt.total_us));
                    }
                }
            }

            if (overlayBackedUp)
                restoreOverlayDirty(cleanFrame, dirty);
        };

        if (onProgress_)
            onProgress_("playing", startMs, durationMs);

        // Deterministic A/V origin: never start the schedule on the wall clock and then
        // switch to the audio clock mid-stream — that step discontinuity randomises the
        // lipsync offset by tens of ms on every play (measured spread ~67 ms across
        // identical runs). Wait for the audio master clock to exist first.
        if (wantAudio && apipe[0] >= 0 && audioFeedRelease_.load()) {
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
        hwPresentBaselineValid = fpga_.readBankRelease(hwPresentBaseline);
        hwPresentLastFrames = hwPresentBaseline.frames_done;
        hwPresentArmBaseline = presentCount_;
        hwPresentTotal = 0;
        hwPresentTimeBaseline = t0;
        log("media: hw_present_t0_rearm after_prefetch=1");
        // Architecture: 2-slot cached ring — reader fills host RAM while present
        // thread does uncached bank memcpy+kick. Overlaps the ~14ms copy with
        // the next pipe read (direct uncached read was ~30ms serial).
        // Branch B (opt-in MPX_FABRIC_DIRECT): present cache-cleans the slot,
        // pokes PLXP (src_phys), DSB, existing doorbell — skips uncached memcpy.
        // PATH_SDRAM: stick DMA is PHYS_BASE. sendDdrFrame memcpy idle+play
        // into 0x30180000 then doorbell. Do not skip (empty bank = no chevron).
        const bool pipelineDdr = useDdrF1_ && wantFpgaFrameStore &&
                                 videoFmt == RawVideoFormat::Yuv420p &&
                                 presentMode_ == "fpga";
        const bool true480Pipeline =
            pipelineDdr && isPlex480pDdrFrameGeometry(ddrGeometry);
        // 720p L4: RequireReleased waits on PLXD when free=0 and produces ~15
        // while ffmpeg→/dev/null on the same live core holds 24 fps (480/20s).
        // Triple-buffer BestEffort writes a free bank (or non-display) without
        // a 150ms frames_done poll. true480 2-bank stays strict.
        const bool strictDdrPipeline = true480Pipeline;
        // 720p matches 480p A/V: audio master (heard/wall 48 kHz), video hold-only.
        // RequireReleased stays 480p-only (L4 poll produced ~15 unique).
        const bool avLockPresent =
            pipelineDdr && (true480Pipeline || isPlex720pDdrFrameGeometry(ddrGeometry));
        if (pipelineDdr) {
            const bool wantStick =
                stickI420Wanted() &&
                misterplex::p720_av::plex720pWcBankIngest(
                    isPlex720pDdrFrameGeometry(ddrGeometry));
            fpga_.setStickI420Present(wantStick);
            // Publication offload: pipe/inproc writes WC present bank, present
            // doorbells. PLXD 150 ms spin on the reader is banned (pipe:3 starve).
            const bool fabricWant =
                fabricDirectWanted() && isPlex720pDdrFrameGeometry(ddrGeometry);
            bool wantStickIngest = misterplex::p720_av::stickIngestWantedOn720pPipe(
                plex720pStickIngestOverridesFabric(wantStick, fabricWant), useInproc);
            const bool wantFabric = fabricWant && !wantStickIngest;
            fpga_.setFabricDirectPresent(wantFabric);
            log("media: present_pipeline=" +
                std::string(wantStickIngest ? "2slot_stick_ingest"
                                            : "2slot_cached_ring") +
                " frame_bytes=" + std::to_string(frameBytes) +
                " true480_exact_gate=" + (true480Pipeline ? "1" : "0") +
                " strict_ddr_gate=" + (strictDdrPipeline ? "1" : "0") +
                " fabric_direct=" + std::string(wantFabric ? "1" : "0") +
                " stick_i420=" + std::string(wantStick ? "1" : "0") +
                " stick_ingest=" + std::string(wantStickIngest ? "1" : "0") +
                " av_lock=" + (avLockPresent ? "1" : "0"));
            std::array<std::vector<uint8_t>, 2> ring;
            std::array<uint8_t*, 2> ringPtr{{nullptr, nullptr}};
            std::array<uint32_t, 2> ringPhys{{0, 0}};
            FabricDirectAlloc fabricAlloc{};
            auto releaseFabricSlots = [&]() { releaseFabricDirectAlloc(fabricAlloc); };
            bool fabricSlotsReal = false;
            if (wantFabric) {
                // R1: hugepage → compact + 2 MiB memalign retries → 16–32 MiB arena.
                // Full-span pagemap is the only REAL gate. Flag stays default OFF.
                fabricSlotsReal =
                    allocateFabricDirectSlots(fabricAlloc, frameBytes, /*tryCompact=*/true) &&
                    fabricAlloc.real();
                if (fabricSlotsReal) {
                    ringPtr[0] = fabricAlloc.slot[0].virt;
                    ringPtr[1] = fabricAlloc.slot[1].virt;
                    ringPhys[0] = fabricAlloc.slot[0].phys;
                    ringPhys[1] = fabricAlloc.slot[1].phys;
                }
            }
            if (!fabricSlotsReal) {
                ring[0].assign(frameBytes, 0);
                ring[1].assign(frameBytes, 0);
                ringPtr[0] = ring[0].data();
                ringPtr[1] = ring[1].data();
                if (wantFabric) {
                    // Heap is almost never 338-page contiguous; both-or-none.
                    ringPhys[0] = FpgaSpi::resolveCachedSrcPhys(ringPtr[0], frameBytes);
                    ringPhys[1] = FpgaSpi::resolveCachedSrcPhys(ringPtr[1], frameBytes);
                    failClosedFabricDirectPhysPair(ringPhys[0], ringPhys[1]);
                }
            }
            {
                char pbuf[80];
                std::snprintf(pbuf, sizeof(pbuf), "0x%08x,0x%08x",
                              static_cast<unsigned>(ringPhys[0]),
                              static_cast<unsigned>(ringPhys[1]));
                const bool srcReal = fabricDirectPhysPairReal(ringPhys[0], ringPhys[1]);
                const char* how = "stub";
                if (srcReal)
                    how = fabricSlotsReal ? fabricAlloc.how : "heap";
                std::string extra;
                if (wantFabric && !srcReal) {
                    extra = std::string(" pagemap=") +
                            pagemapPfnVisName(probePagemapPfnVisibility());
                    extra += " (need CAP_SYS_ADMIN PFN + contiguous cached System-RAM)";
                }
                log(std::string("media: fabric_direct src_phys=") +
                    (srcReal ? "REAL" : "STUB") + " slots=" + pbuf +
                    " alloc=" + how + extra);
            }
            std::array<int64_t, 2> ringFrameIndex{0, 0};
            std::array<int, 2> ringIngestBank{{-1, -1}};
            std::array<bool, 3> bankHeld{{false, false, false}};
            std::mutex ringMu;
            std::condition_variable ringCv;
            int fullCount = 0;
            auto releaseIngestBank = [&](int slot) {
                const int b = ringIngestBank[static_cast<size_t>(slot)];
                if (b >= 0 && b <= 2)
                    bankHeld[static_cast<size_t>(b)] = false;
                ringIngestBank[static_cast<size_t>(slot)] = -1;
            };
            auto takeIngestBank = [&]() -> int {
                // One PLXD sample. 150×1 ms spin starved combined pipe:3.
                std::lock_guard<std::mutex> lk(ringMu);
                BankReleaseStatus brs{};
                const bool have = fpga_.readBankRelease(brs);
                int pick = -1;
                if (have && brs.anyFree()) {
                    if ((brs.free_bank_mask & 1u) && !bankHeld[0])
                        pick = 0;
                    else if ((brs.free_bank_mask & 2u) && !bankHeld[1])
                        pick = 1;
                }
                if (pick < 0) {
                    const int fallback = have && brs.disp_bank <= 1
                                             ? (brs.disp_bank ^ 1)
                                             : 0;
                    if (fallback >= 0 && fallback <= 1 &&
                        !bankHeld[static_cast<size_t>(fallback)])
                        pick = fallback;
                    else if (!bankHeld[0])
                        pick = 0;
                    else if (!bankHeld[1])
                        pick = 1;
                }
                if (pick >= 0)
                    bankHeld[static_cast<size_t>(pick)] = true;
                return pick;
            };
            int readSlot = 0;
            int presentSlot = 0;
            const bool skipLastPresented = skipLastPresentedWanted();
            std::vector<uint8_t> lastPresentedFrame;
            if (!skipLastPresented)
                lastPresentedFrame.assign(frameBytes, 0);
            bool lastPresentedFrameValid = false;
            bool lastPresentedHadOverlay = false;
            if (skipLastPresented)
                log("media: skip lastPresentedFrame snapshot (P5 produce)");
            std::atomic<bool> readerEof{false};
            std::atomic<bool> pipelineFatal{false};
            std::atomic<int64_t> pipelinePresentCount{0};
            std::atomic<int64_t> pipeReadUs{0};
            std::atomic<int64_t> pipeSlotWaitUs{0};
            std::atomic<int64_t> pipePresentWaitUs{0};
            std::atomic<int64_t> pipeSendUs{0};
            std::atomic<int64_t> pipeCopyUs{0};
            const bool pipeProfile = presentProfile_;
            auto pipeUs = [](std::chrono::steady_clock::time_point a,
                             std::chrono::steady_clock::time_point b) {
                return std::chrono::duration_cast<std::chrono::microseconds>(b - a).count();
            };
            bool hdmiLagArmed = false;
            auto holdHdmiAudioLag = [&]() {
                if (hdmiLagArmed)
                    return;
                hdmiLagArmed = true;
                const int need = audioReleaseAfterPresents_.load();
                if (need > 0) {
                    log("media: hdmi_audio_lag video_first trim_after_presents=" +
                        std::to_string(need));
                    return;
                }
                // First video kick now. Audio pump (if gated) starts after
                // audioAfterVideoMs_ so the HDMI click meets the flash.
                audioFeedRelease_.store(true);
                log("media: hdmi_audio_lag video_first after_video_ms=" +
                    std::to_string(audioAfterVideoMs_.load()));
            };
            int localBank = ddrBank_;
            // This tree's DDR map is 2 banks + doorbell. Bank 2 is rejected
            // by sendDdrFrame/kickDdrDoorbell (map_bytes = 2*stride).
            const int nBanks = 2;
            auto nextBank = [nBanks](int b) {
                if (nBanks <= 1)
                    return 0;
                if (b < 0)
                    return 0;
                return (b + 1) % nBanks;
            };
#ifdef MPX_HAVE_LIBAV
            // First 3s on leftover 2bbe: hw_match=1 and pfps≈hw (~10). FPGA
            // already swaps every kick; last-line 19.86 is host warmup inside
            // the 15s window. Prime both ring slots then re-arm t0/hw baseline.
            if (useInproc && !strictDdrPipeline &&
                isPlex720pDdrFrameGeometry(ddrGeometry) &&
                !isPlex960DdrFrameGeometry(ddrGeometry) &&
                !isPlex960BankSize(rawW, rawH)) {
                int primed = 0;
                for (int i = 0; i < 2 && !stop_.load(); ++i) {
                    std::string ierr;
                    uint8_t* dst = ringPtr[static_cast<size_t>(readSlot)];
                    if (!dst)
                        break;
                    const int rc = inprocDec.readI420(dst, frameBytes, ierr);
                    if (rc != 1) {
                        log("media: warmup_prefill abort rc=" +
                            std::to_string(rc) + " " + ierr);
                        break;
                    }
                    ++frameIndex;
                    ringFrameIndex[static_cast<size_t>(readSlot)] = frameIndex;
                    readSlot = (readSlot + 1) % 2;
                    ++fullCount;
                    ++primed;
                }
                t0 = std::chrono::steady_clock::now();
                hwPresentBaselineValid = fpga_.readBankRelease(hwPresentBaseline);
                hwPresentLastFrames = hwPresentBaseline.frames_done;
                hwPresentArmBaseline = 0;
                hwPresentTotal = 0;
                hwPresentTimeBaseline = t0;
                log("media: warmup_prefill n=" + std::to_string(primed) +
                    " t0_rearm=1");
            }
            // 960 leftover: n=2 prefill never ran (1280-only geom). First 4 s
            // of 620c fair were 6–8 pfps (24 ms uncached memcpy, 2-slot full).
            // Late is already ~24. Decode 36 frames into cached heap first,
            // then BestEffort-present them so CATCH has kicks from t0.
            // Not P1_PREFILL n=2. Not DDR ingest (HURT 12.6/black).
            if (useInproc && !strictDdrPipeline &&
                (budget960Wanted() || isPlex960BankSize(rawW, rawH) ||
                 isPlex960DdrFrameGeometry(ddrGeometry))) {
                constexpr int kAhead = 48; // 64 WASH 23.42 < 48's 23.68
                std::vector<std::vector<uint8_t>> ahead;
                ahead.reserve(static_cast<size_t>(kAhead));
                for (int i = 0; i < kAhead && !stop_.load(); ++i) {
                    std::vector<uint8_t> buf(frameBytes);
                    std::string ierr;
                    const int rc = inprocDec.readI420(buf.data(), frameBytes, ierr);
                    if (rc != 1) {
                        log("media: warmup_ahead abort rc=" + std::to_string(rc) +
                            " " + ierr);
                        break;
                    }
                    ++frameIndex;
                    ahead.push_back(std::move(buf));
                }
                t0 = std::chrono::steady_clock::now();
                hwPresentBaselineValid = fpga_.readBankRelease(hwPresentBaseline);
                hwPresentLastFrames = hwPresentBaseline.frames_done;
                hwPresentArmBaseline = 0;
                hwPresentTotal = 0;
                hwPresentTimeBaseline = t0;
                int sent = 0;
                for (auto& buf : ahead) {
                    if (stop_.load())
                        break;
                    BankReleaseStatus pre{};
                    const bool havePre = fpga_.readBankRelease(pre);
                    const bool ok = fpga_.sendYuv420pFrameDdr(
                        buf.data(), frameBytes, ddrGeometry, localBank,
                        DdrBankWritePolicy::BestEffort, 0);
                    if (!ok) {
                        log("media: warmup_ahead send fail: " + fpga_.lastError());
                        break;
                    }
                    localBank = nextBank(localBank);
                    ++sent;
                    pipelinePresentCount.fetch_add(1);
                    // One kick per blank so CATCH keeps the frame (blast
                    // at memcpy rate overwrote ~half of the 36).
                    const auto wt0 = std::chrono::steady_clock::now();
                    while (havePre && !stop_.load()) {
                        const int64_t waited = pipeUs(
                            wt0, std::chrono::steady_clock::now());
                        BankReleaseStatus cur{};
                        if (fpga_.readBankRelease(cur) &&
                            frameCounterDelta(cur.frames_done, pre.frames_done) > 0)
                            break;
                        if (waited >= 50000)
                            break;
                        std::this_thread::sleep_for(std::chrono::microseconds(200));
                    }
                }
                log("media: warmup_ahead n=" + std::to_string(ahead.size()) +
                    " sent=" + std::to_string(sent) +
                    " frame_bytes=" + std::to_string(frameBytes));
            }
            // True 1280×720 identity only. Scaled 240/480 must not eat 60
            // source frames or the integer upsample cannot hold 24 fps.
            if (useInproc && !strictDdrPipeline &&
                isPlex720pDdrFrameGeometry(ddrGeometry) &&
                !isPlex960BankSize(rawW, rawH) &&
                !isPlex960DdrFrameGeometry(ddrGeometry) &&
                sourceMediaW_ == kInproc720W && sourceMediaH_ == kInproc720H) {
                constexpr int kAhead720 = 60;
                std::vector<std::vector<uint8_t>> ahead720;
                ahead720.reserve(static_cast<size_t>(kAhead720));
                for (int i = 0; i < kAhead720 && !stop_.load(); ++i) {
                    std::vector<uint8_t> buf(frameBytes);
                    std::string ierr;
                    const int rc = inprocDec.readI420(buf.data(), frameBytes, ierr);
                    if (rc != 1) {
                        log("media: warmup_ahead720 abort rc=" + std::to_string(rc) +
                            " " + ierr);
                        break;
                    }
                    ++frameIndex;
                    ahead720.push_back(std::move(buf));
                }
                t0 = std::chrono::steady_clock::now();
                hwPresentBaselineValid = fpga_.readBankRelease(hwPresentBaseline);
                hwPresentLastFrames = hwPresentBaseline.frames_done;
                hwPresentArmBaseline = 0;
                hwPresentTotal = 0;
                hwPresentTimeBaseline = t0;
                int sent720 = 0;
                for (auto& buf : ahead720) {
                    if (stop_.load())
                        break;
                    holdHdmiAudioLag();
                    BankReleaseStatus pre{};
                    const bool havePre = fpga_.readBankRelease(pre);
                    const bool ok = fpga_.sendYuv420pFrameDdr(
                        buf.data(), frameBytes, ddrGeometry, localBank,
                        DdrBankWritePolicy::BestEffort, 0);
                    if (!ok) {
                        log("media: warmup_ahead720 send fail: " + fpga_.lastError());
                        break;
                    }
                    localBank = nextBank(localBank);
                    ++sent720;
                    pipelinePresentCount.fetch_add(1);
                    const auto wt0 = std::chrono::steady_clock::now();
                    while (havePre && !stop_.load()) {
                        const int64_t waited = pipeUs(
                            wt0, std::chrono::steady_clock::now());
                        BankReleaseStatus cur{};
                        if (fpga_.readBankRelease(cur) &&
                            frameCounterDelta(cur.frames_done, pre.frames_done) > 0)
                            break;
                        if (waited >= 50000)
                            break;
                        std::this_thread::sleep_for(std::chrono::microseconds(200));
                    }
                }
                log("media: warmup_ahead720 n=" + std::to_string(ahead720.size()) +
                    " sent=" + std::to_string(sent720) +
                    " frame_bytes=" + std::to_string(frameBytes));
            }
#endif
            auto lastPipeLog = t0;
            const int64_t pipelinePauseBaselineUs = playbackPausedUs(t0);
            auto pipelineElapsedUs = [&](std::chrono::steady_clock::time_point now) {
                const int64_t pausedUs = std::max<int64_t>(
                    0, playbackPausedUs(now) - pipelinePauseBaselineUs);
                const int64_t wallUs =
                    std::chrono::duration_cast<std::chrono::microseconds>(now - t0).count();
                return activePlaybackClockUs(wallUs, pausedUs);
            };
            auto servicePipelinePause = [&]() {
                const bool pipelinePaused = paused_.load();
                if (!pipelinePaused)
                    return false;

                const bool overlayNow = overlay_.visible();
                {
                    std::lock_guard<std::mutex> plk(presentMu_);
                    if (lastPresentedFrameValid &&
                        (overlayNow || lastPresentedHadOverlay)) {
                        uint8_t* slotFrame = lastPresentedFrame.data();
                        const bool overlayDrawn = overlay_.renderI420WithBackup(
                            slotFrame, rawW, rawH, i420OverlayBackup);
                        const OverlayRect dirty = i420OverlayBackup.rect;
                        const bool ok = fpga_.sendYuv420pFrameDdr(
                            slotFrame, frameBytes, ddrGeometry, localBank,
                            strictDdrPipeline ? DdrBankWritePolicy::RequireReleased
                                            : DdrBankWritePolicy::BestEffort);
                        if (overlayDrawn)
                            restoreOverlayDirty(slotFrame, dirty);
                        if (ok) {
                            localBank = nextBank(localBank);
                            lastPresentedHadOverlay = overlayDrawn;
                        } else if (strictDdrPipeline) {
                            log("media: DDR_PIPE paused present fail: " +
                                fpga_.lastError());
                            pipelineFatal.store(true);
                        }
                    }
                }
                std::this_thread::sleep_for(std::chrono::milliseconds(50));
                return true;
            };

            std::thread presentThr([&] {
                // 720p: pin present to CPU0 with audio so ffmpeg -threads 2
                // keeps CPU1 (1.8 ms WC copy on CPU1 was the 23.7 unique hole).
                // 480p stays CPU1 (copy 4.3 ms, unique already ~24).
                {
                    cpu_set_t cpus;
                    CPU_ZERO(&cpus);
                    CPU_SET(isPlex720pDdrFrameGeometry(ddrGeometry) ? 0 : 1, &cpus);
                    (void)::pthread_setaffinity_np(::pthread_self(), sizeof(cpus), &cpus);
                    // Per-thread only. PRIO_PROCESS+pid 0 niced the whole
                    // daemon (decode+present) and slowed 1280 memcpy/decode.
#ifdef __linux__
                    (void)::setpriority(PRIO_PROCESS,
                                        static_cast<int>(::syscall(SYS_gettid)), 5);
#else
                    (void)::setpriority(PRIO_PROCESS, 0, 5);
#endif
                }
                int pipelineFailCount = 0;
                bool overlapReady = false;
                int overlapBank = -1;
                int overlapHits = 0;
                bool paceHaveLast = false;
                BankReleaseStatus paceLast{};
                int64_t lastKickLagUs = 0;
                int64_t lastPaceWaitUs = 0;
                auto prefetchOverlap = [&](int curSlot) {
                    if (overlapReady || wantStickIngest || overlay_.visible())
                        return;
                    if (!isPlex720pDdrFrameGeometry(ddrGeometry) ||
                        isPlex960BankSize(rawW, rawH))
                        return;
                    int nextSlot = -1;
                    {
                        std::lock_guard<std::mutex> lk(ringMu);
                        if (fullCount >= 2)
                            nextSlot = (curSlot + 1) % 2;
                    }
                    if (nextSlot < 0)
                        return;
                    // Never memcpy the displayed bank. overlap_hide used to
                    // write localBank (xor ping-pong) during wait_swap — that
                    // is the scanout bank for ~12 ms of active video and it
                    // tears VGA and HDMI (vga_scaler copies HDMI).
                    BankReleaseStatus brs{};
                    if (!fpga_.readBankRelease(brs) || !brs.anyFree())
                        return;
                    const int destBank = brs.freeBank();
                    if (destBank < 0 || destBank == static_cast<int>(brs.disp_bank))
                        return;
                    uint8_t* dst = fpga_.ddrBankVirt(destBank);
                    if (!dst)
                        return;
                    const uint8_t* nf = ringPtr[static_cast<size_t>(nextSlot)];
                    const auto tc0 = std::chrono::steady_clock::now();
                    std::memcpy(dst, nf, frameBytes);
                    clearYuv420pCropPadding(dst, ddrGeometry);
                    if (uvUBias_ != 0 || uvVBias_ != 0)
                        applyYuv420pUvBias(dst, rawW, rawH, uvUBias_, uvVBias_);
                    __sync_synchronize();
                    if (pipeProfile)
                        pipeCopyUs.fetch_add(
                            pipeUs(tc0, std::chrono::steady_clock::now()));
                    overlapReady = true;
                    overlapBank = destBank;
                    localBank = destBank;
                    static std::atomic<bool> loggedPref{false};
                    if (!loggedPref.exchange(true)) {
                        log("media: overlap_free prefetch bank=" +
                            std::to_string(destBank) +
                            " disp=" + std::to_string(brs.disp_bank) +
                            " free=0x" +
                            std::to_string(brs.free_bank_mask) +
                            " next_slot=" + std::to_string(nextSlot) +
                            " copy_us=" +
                            std::to_string(pipeUs(
                                tc0, std::chrono::steady_clock::now())));
                    }
                };
                auto stageCurrentToFree = [&](uint8_t* src) {
                    if (!src || overlapReady || wantStickIngest)
                        return;
                    if (!isPlex720pDdrFrameGeometry(ddrGeometry) ||
                        isPlex960BankSize(rawW, rawH))
                        return;
                    BankReleaseStatus brs{};
                    if (!fpga_.readBankRelease(brs))
                        return;
                    int dest = -1;
                    if (brs.anyFree())
                        dest = brs.freeBank();
                    else if (brs.disp_bank <= 1)
                        dest = static_cast<int>(brs.disp_bank) ^ 1;
                    if (dest < 0 || dest == static_cast<int>(brs.disp_bank))
                        return;
                    uint8_t* dst = fpga_.ddrBankVirt(dest);
                    if (!dst)
                        return;
                    const auto tc0 = std::chrono::steady_clock::now();
                    std::memcpy(dst, src, frameBytes);
                    clearYuv420pCropPadding(dst, ddrGeometry);
                    if (uvUBias_ != 0 || uvVBias_ != 0)
                        applyYuv420pUvBias(dst, rawW, rawH, uvUBias_, uvVBias_);
                    __sync_synchronize();
                    if (pipeProfile)
                        pipeCopyUs.fetch_add(
                            pipeUs(tc0, std::chrono::steady_clock::now()));
                    overlapReady = true;
                    overlapBank = dest;
                    localBank = dest;
                };
                while (true) {
                    int slot = -1;
                    int64_t slotFrameIndex = 0;
                    {
                        std::unique_lock<std::mutex> lk(ringMu);
                        const auto tw0 = std::chrono::steady_clock::now();
                        ringCv.wait(lk, [&] {
                            return fullCount > 0 || readerEof.load() ||
                                   stop_.load() || pipelineFatal.load();
                        });
                        if (pipeProfile)
                            pipePresentWaitUs.fetch_add(pipeUs(tw0, std::chrono::steady_clock::now()));
                        if (fullCount == 0) {
                            if (readerEof.load() || stop_.load() ||
                                pipelineFatal.load())
                                break;
                            continue;
                        }
                        slot = presentSlot;
                        slotFrameIndex = ringFrameIndex[static_cast<size_t>(slot)];
                    }
                    bool overlayDrawn = false;
                    bool presentFrame = true;
                    if (avLockPresent) {
                        const int64_t frameUs =
                            frameContentUs(slotFrameIndex, fpsNum, fpsDen) +
                            avOffsetMs_.load() * 1000LL;
                        for (;;) {
                            if (stop_.load() || pipelineFatal.load()) {
                                presentFrame = false;
                                break;
                            }
                            if (paused_.load()) {
                                std::this_thread::sleep_for(std::chrono::milliseconds(1));
                                continue;
                            }
                            const int64_t audioB = audioBytes_.load();
                            const int64_t clockUs =
                                (wantAudio && audioActive_.load() && audioB > 0)
                                    ? audibleClockUs(audioB,
                                                     audioQueuedBytes_.load())
                                    : pipelineElapsedUs(std::chrono::steady_clock::now());
                            const int64_t driftUs = clockUs - frameUs;
                            avDriftMs_.store(driftUs / 1000);
                            const int leadHoldMs = misterplex::p720_av::holdLeadMsWithQueued(
                                static_cast<int>(leadMs), audioQueuedBytes_.load());
                            const AvAction action =
                                avDecide(driftUs, static_cast<int64_t>(leadHoldMs) * 1000LL,
                                         dropMs * 1000LL, dropRun);
                            if (action == AvAction::Hold) {
                                // Combined 720p: kick-on-swap is the 24.10 Hz
                                // pace (copy 1.8 ms, kick_lag ~20 us). Hold
                                // slaved unique to heard clock (pfps 23.5,
                                // hw_fps 22.8). 480p still Holds.
                                if (misterplex::p720_av::combined720pSkipAvHold(
                                        isPlex720pDdrFrameGeometry(ddrGeometry),
                                        useInproc))
                                    break;
                                // 480p gold: skip Hold when the ring has no
                                // spare so combined pipe:1+pipe:3 cannot
                                // deadlock (video ahead → Hold → ffmpeg
                                // stalls audio too). Combined 720p prefetch
                                // uses that spawn; split A/V keeps Hold.
                                const bool dualPipe720 =
                                    wantAudio && splitAv720 &&
                                    isPlex720pDdrFrameGeometry(ddrGeometry);
                                if (!dualPipe720) {
                                    int spare = 0;
                                    {
                                        std::lock_guard<std::mutex> lk(ringMu);
                                        spare = fullCount;
                                    }
                                    if (spare < 2)
                                        break;
                                }
                                // Combined A+V: ffmpeg stalls when the video
                                // pipe fills. Refresh MrAudio queued bytes so
                                // the heard clock still advances and Hold
                                // can finish (otherwise soak G hung at 12s).
                                {
                                    const MrAudioStatus st = readMrAudioStatus();
                                    if (st.valid())
                                        audioQueuedBytes_.store(st.queuedBytes);
                                }
                                const int64_t remainUs = -(driftUs + leadMs * 1000LL);
                                const int64_t sleepUs =
                                    std::max<int64_t>(100, std::min<int64_t>(remainUs, 2000));
                                std::this_thread::sleep_for(
                                    std::chrono::microseconds(sleepUs));
                                continue;
                            }
                            if (action == AvAction::Drop) {
                                presentFrame = false;
                                ++dropRun;
                                droppedFrames_.fetch_add(1);
                                if ((droppedFrames_.load() % 24) == 1) {
                                    log("media: DDR_PIPE A/V resync drop frame=" +
                                        std::to_string(slotFrameIndex) +
                                        " drift_ms=" +
                                        std::to_string(avDriftMs_.load()) +
                                        " drops=" +
                                        std::to_string(droppedFrames_.load()));
                                }
                            } else {
                                dropRun = 0;
                            }
                            break;
                        }
                    }
                    if (presentFrame) {
                        holdHdmiAudioLag();
                        bool fatalPresent = false;
                        std::lock_guard<std::mutex> plk(presentMu_);
                        uint8_t* slotFrame = ringPtr[static_cast<size_t>(slot)];
                        clearYuv420pCropPadding(slotFrame, ddrGeometry);
                        if (uvUBias_ != 0 || uvVBias_ != 0) {
                            applyYuv420pUvBias(slotFrame, rawW, rawH, uvUBias_, uvVBias_);
                        }
                        overlayDrawn = overlay_.renderI420WithBackup(
                            slotFrame, rawW, rawH, i420OverlayBackup);
                        const OverlayRect dirty = i420OverlayBackup.rect;
                        const uint32_t slotPhys =
                            wantFabric ? ringPhys[static_cast<size_t>(slot)] : 0u;
                        const int ingestBank = ringIngestBank[static_cast<size_t>(slot)];
                        bool ok = false;
                        const bool doBeamPace =
                            !strictDdrPipeline && pipelineDdr &&
                            beamPaceWanted(outW_, outH_) &&
                            isPlex720pDdrFrameGeometry(ddrGeometry);
                        // Kick-on-swap: wait the PREVIOUS doorbell's blank,
                        // then copy+kick. Wait-THIS-swap put avDecide/overlay
                        // after the blank (~2 ms → unique 22.8 vs 24.1).
                        bool paceSawThis = false;
                        std::chrono::steady_clock::time_point paceSawAt{};
                        if (doBeamPace && paceHaveLast) {
                            constexpr int64_t kSwapWaitUs = 50000;
                            bool sawSwap = false;
                            const auto paceT0 = std::chrono::steady_clock::now();
                            while (!stop_.load() && !pipelineFatal.load()) {
                                const auto noww = std::chrono::steady_clock::now();
                                const int64_t waited = pipeUs(paceT0, noww);
                                BankReleaseStatus cur{};
                                if (fpga_.readBankRelease(cur) &&
                                    frameCounterDelta(cur.frames_done,
                                                      paceLast.frames_done) > 0) {
                                    sawSwap = true;
                                    paceSawThis = true;
                                    paceSawAt = noww;
                                }
                                if (sawSwap || waited >= kSwapWaitUs)
                                    break;
                                if (!overlapReady)
                                    stageCurrentToFree(slotFrame);
                                std::this_thread::sleep_for(
                                    std::chrono::microseconds(overlapReady ? 10 : 50));
                            }
                            if (!overlapReady)
                                stageCurrentToFree(slotFrame);
                            lastPaceWaitUs = pipeUs(paceT0, std::chrono::steady_clock::now());
                            static std::atomic<bool> loggedPace{false};
                            if (!loggedPace.exchange(true)) {
                                log("media: beam_pace=kick_on_swap timeout_us=" +
                                    std::to_string(kSwapWaitUs) +
                                    " first_wait_us=" +
                                    std::to_string(lastPaceWaitUs) +
                                    " saw_swap=" + (sawSwap ? "1" : "0") +
                                    " overlap=" + (overlapReady ? "1" : "0"));
                            }
                        } else if (doBeamPace && !overlapReady) {
                            stageCurrentToFree(slotFrame);
                        }
                        BankReleaseStatus livePre{};
                        const bool haveLivePre =
                            !avLockPresent && !doBeamPace && !wantStickIngest &&
                            isPlex720pDdrFrameGeometry(ddrGeometry) &&
                            !isPlex960BankSize(rawW, rawH) &&
                            fpga_.readBankRelease(livePre);
                        bool usedOverlap = false;
                        BankReleaseStatus pacePre{};
                        const bool havePacePre =
                            doBeamPace && fpga_.readBankRelease(pacePre);
                        if (wantStickIngest && (ingestBank == 0 || ingestBank == 1)) {
                            ok = fpga_.commitDdrBankIngest(ingestBank, frameBytes);
                            if (ok)
                                localBank = ingestBank ^ 1;
                            overlapReady = false;
                            overlapBank = -1;
                        } else if (overlapReady && overlapBank == localBank) {
                            ok = fpga_.commitDdrBankIngest(localBank, frameBytes);
                            usedOverlap = ok;
                            overlapReady = false;
                            overlapBank = -1;
                            if (ok) {
                                localBank = nextBank(localBank);
                                ++overlapHits;
                                static std::atomic<bool> loggedCommit{false};
                                if (!loggedCommit.exchange(true)) {
                                    log("media: overlap_hide commit bank=" +
                                        std::to_string(localBank ^ 1));
                                }
                            }
                        } else {
                            overlapReady = false;
                            overlapBank = -1;
                            ok = fpga_.sendYuv420pFrameDdr(
                                slotFrame, frameBytes, ddrGeometry, localBank,
                                strictDdrPipeline ? DdrBankWritePolicy::RequireReleased
                                                : DdrBankWritePolicy::BestEffort,
                                slotPhys);
                            if (ok)
                                localBank = nextBank(localBank);
                        }
                        if (ok && doBeamPace && havePacePre) {
                            paceLast = pacePre;
                            paceHaveLast = true;
                        } else if (ok && doBeamPace) {
                            paceHaveLast = fpga_.readBankRelease(paceLast);
                        }
                        if (ok && doBeamPace && paceSawThis)
                            lastKickLagUs =
                                pipeUs(paceSawAt, std::chrono::steady_clock::now());
                        else if (ok && doBeamPace)
                            lastKickLagUs = 0;
                        // 1280 live: wait this kick to swap so CATCH keeps it
                        // (BestEffort blast overwrote blanks; 960 ahead pace worked).
                        // Hide the next 1.38 MiB memcpy inside that wait so the
                        // following kick is not 14 ms late of the blank (23.66).
                        if (ok && haveLivePre) {
                            const auto wt0 = std::chrono::steady_clock::now();
                            prefetchOverlap(slot);
                            while (!stop_.load() && !pipelineFatal.load()) {
                                const int64_t waited = pipeUs(
                                    wt0, std::chrono::steady_clock::now());
                                BankReleaseStatus cur{};
                                if (fpga_.readBankRelease(cur) &&
                                    frameCounterDelta(cur.frames_done,
                                                      livePre.frames_done) > 0)
                                    break;
                                if (waited >= 50000)
                                    break;
                                if (!overlapReady)
                                    prefetchOverlap(slot);
                                std::this_thread::sleep_for(
                                    std::chrono::microseconds(overlapReady ? 50 : 200));
                            }
                            if (!overlapReady)
                                prefetchOverlap(slot);
                        }
                        if (pipeProfile && ok) {
                            const auto dt = fpga_.lastDdrTiming();
                            pipeSendUs.fetch_add(dt.total_us);
                            pipeCopyUs.fetch_add(dt.copy_us);
                        }
                        if (overlayDrawn)
                            restoreOverlayDirty(slotFrame, dirty);
                        if (ok) {
                            // Pause-OSD snapshot only. Movie frames do not need a
                            // third 777600/1.38 MiB copy on the same DDR3 as decode.
                            // P5: MPX_SKIP_LAST_PRESENTED (default on 960) skips it.
                            if (!skipLastPresented &&
                                (overlayDrawn || overlay_.visible())) {
                                std::memcpy(lastPresentedFrame.data(), slotFrame,
                                            frameBytes);
                                lastPresentedFrameValid = true;
                            } else {
                                lastPresentedFrameValid = false;
                            }
                            lastPresentedHadOverlay = overlayDrawn;
                            pipelineFailCount = 0;
                            const int64_t presented = pipelinePresentCount.fetch_add(1) + 1;
                            presentCount_ = presented;
                            {
                                const int need = audioReleaseAfterPresents_.load();
                                if (need > 0 && presented >= need &&
                                    !audioFeedRelease_.load()) {
                                    audioFeedRelease_.store(true);
                                    log("media: 720p audio_release presents=" +
                                        std::to_string(presented));
                                }
                            }
                            if ((presented % 48) == 0) {
                                const auto dt = fpga_.lastDdrTiming();
                                log(std::string("media: fpga frame_tx ok via DDR_PIPE") +
                                    " presents=" + std::to_string(presented) +
                                    " frames=" + std::to_string(slotFrameIndex) +
                                    " ms=" +
                                    std::to_string(static_cast<int>(fpga_.lastPushMs())) +
                                    " prep_us=" + std::to_string(dt.prep_wait_us) +
                                    " copy_us=" + std::to_string(dt.copy_us) +
                                    " plxd_us=" + std::to_string(dt.plxa_poll_us) +
                                    " total_us=" + std::to_string(dt.total_us) +
                                    " fabric=" +
                                    std::string(usedOverlap
                                                    ? "overlap"
                                                    : fpga_.lastDdrPublishHow()) +
                                    " overlap_hits=" +
                                    std::to_string(overlapHits) +
                                    " pace_wait_us=" +
                                    std::to_string(lastPaceWaitUs) +
                                    " kick_lag_us=" +
                                    std::to_string(lastKickLagUs));
                            }
                        } else {
                            ++pipelineFailCount;
                            if (pipelineFailCount == 1 || (pipelineFailCount % 60) == 0) {
                                log("media: DDR_PIPE present fail frame=" +
                                    std::to_string(slotFrameIndex) + ": " +
                                    fpga_.lastError());
                            }
                            fatalPresent = strictDdrPipeline;
                        }
                        if (fatalPresent) {
                            pipelineFatal.store(true);
                        }
                    }
                    {
                        std::lock_guard<std::mutex> lk(ringMu);
                        releaseIngestBank(slot);
                        presentSlot = (presentSlot + 1) % 2;
                        --fullCount;
                    }
                    ringCv.notify_all();
                    if (pipelineFatal.load())
                        break;
                }
            });

            while (!stop_.load() && !pipelineFatal.load()) {
                int64_t seekTo = seekReqMs_.exchange(-1);
                if (seekTo >= 0) {
                    log("media: seek requested " + std::to_string(seekTo));
#ifdef MPX_HAVE_LIBAV
                    if (useInproc)
                        inprocDec.requestStop();
#endif
                    break;
                }
                if (servicePipelinePause())
                    continue;
                {
                    std::unique_lock<std::mutex> lk(ringMu);
                    const auto tw0 = std::chrono::steady_clock::now();
                    ringCv.wait_for(lk, std::chrono::milliseconds(50), [&] {
                        return fullCount < 2 || paused_.load() ||
                               stop_.load() || pipelineFatal.load();
                    });
                    if (pipeProfile)
                        pipeSlotWaitUs.fetch_add(pipeUs(tw0, std::chrono::steady_clock::now()));
                    if (stop_.load() || pipelineFatal.load())
                        break;
                    if (paused_.load() || fullCount >= 2)
                        continue;
                }
                if (wantStickIngest) {
                    const int ibank = takeIngestBank();
                    if (ibank < 0) {
                        // Both banks held — wait for present to release. Do not
                        // memcpy-fallback (second copy + 150 ms spin was the
                        // combined-pipe audio starve).
                        std::this_thread::sleep_for(std::chrono::microseconds(200));
                        continue;
                    } else {
                        uint8_t* bp = fpga_.ddrBankVirt(ibank);
                        if (!bp) {
                            {
                                std::lock_guard<std::mutex> lk(ringMu);
                                bankHeld[static_cast<size_t>(ibank)] = false;
                            }
                            log("media: stick ingest: ddrBankVirt failed: " +
                                fpga_.lastError());
                            pipelineFatal.store(true);
                            break;
                        }
                        ringPtr[static_cast<size_t>(readSlot)] = bp;
                        ringIngestBank[static_cast<size_t>(readSlot)] = ibank;
                    }
                }
                size_t got = 0;
                uint8_t* dst = ringPtr[static_cast<size_t>(readSlot)];
                auto lastWaitProgress = std::chrono::steady_clock::now();
                const auto tr0 = lastWaitProgress;
#ifdef MPX_HAVE_LIBAV
                if (useInproc) {
                    std::string ierr;
                    const int rc = inprocDec.readI420(dst, frameBytes, ierr);
                    if (pipeProfile)
                        pipeReadUs.fetch_add(
                            pipeUs(tr0, std::chrono::steady_clock::now()));
                    if (rc == 1) {
                        got = frameBytes;
                        totalBytes += frameBytes;
                    } else if (rc == 0) {
                        videoEof = true;
                    } else {
                        log("media: inproc_decode read failed: " + ierr);
                        {
                            std::lock_guard<std::mutex> lk(ringMu);
                            releaseIngestBank(readSlot);
                        }
                        break;
                    }
                } else
#endif
                {
                while (got < frameBytes && !stop_.load() && !pipelineFatal.load()) {
                    if (servicePipelinePause())
                        continue;
                    fd_set rfds;
                    FD_ZERO(&rfds);
                    FD_SET(rfd, &rfds);
                    timeval tv{};
                    tv.tv_sec = 0;
                    tv.tv_usec = 200000;
                    const int pr = ::select(rfd + 1, &rfds, nullptr, nullptr, &tv);
                    if (pr < 0) {
                        if (errno == EINTR)
                            continue;
                        log("media: pipeline select err errno=" + std::to_string(errno));
                        break;
                    }
                    if (servicePipelinePause())
                        continue;
                    const auto nowWait = std::chrono::steady_clock::now();
                    if (nowWait - lastWaitProgress >= std::chrono::seconds(1)) {
                        lastWaitProgress = nowWait;
                        const int64_t wallWait = pipelineElapsedUs(nowWait) / 1000;
                        const int64_t tms = startMs + std::max<int64_t>(0, wallWait);
                        positionMs_.store(tms);
                        if (!paused_.load() && onProgress_)
                            onProgress_("playing", tms, durationMs);
                    }
                    if (pr == 0)
                        continue;
                    const ssize_t n =
                        ::read(rfd, dst + got, frameBytes - got);
                    if (n < 0) {
                        if (errno == EINTR)
                            continue;
                        log("media: pipeline read err errno=" + std::to_string(errno));
                        break;
                    }
                    if (n == 0) {
                        videoEof = true;
                        break;
                    }
                    got += static_cast<size_t>(n);
                    totalBytes += static_cast<size_t>(n);
                }
                if (pipeProfile)
                    pipeReadUs.fetch_add(pipeUs(tr0, std::chrono::steady_clock::now()));
                }
                if (pipelineFatal.load()) {
                    std::lock_guard<std::mutex> lk(ringMu);
                    releaseIngestBank(readSlot);
                    break;
                }
                if (got < frameBytes) {
                    shortRead = true;
                    shortReadGot = got;
                    shortReadWant = frameBytes;
                    log("media: pipeline short read got=" + std::to_string(got) + "/" +
                        std::to_string(frameBytes));
                    {
                        std::lock_guard<std::mutex> lk(ringMu);
                        releaseIngestBank(readSlot);
                    }
                    break;
                }
                // Legacy pipeline only. true480 and 720p strict present are paced
                // in the present thread from the audible/wall clock.
                if (!strictDdrPipeline && (!wantAudio || !audioActive_.load())) {
                    const int64_t frameMs =
                        frameContentMs(frameIndex + 1, fpsNum, fpsDen) + avOffsetMs_.load();
                    const int64_t clockMs = std::chrono::duration_cast<std::chrono::milliseconds>(
                                               std::chrono::steady_clock::now() - t0)
                                               .count();
                    if (frameMs + leadMs < clockMs) {
                        // behind — present ASAP
                    } else if (frameMs > clockMs + 2) {
                        const int64_t sleepMs = std::min<int64_t>(frameMs - clockMs, 5);
                        if (sleepMs > 0)
                            std::this_thread::sleep_for(std::chrono::milliseconds(sleepMs));
                    }
                    avDriftMs_.store(clockMs - frameMs);
                }
                ++frameIndex;
                {
                    std::lock_guard<std::mutex> lk(ringMu);
                    ringFrameIndex[static_cast<size_t>(readSlot)] = frameIndex;
                    readSlot = (readSlot + 1) % 2;
                    ++fullCount;
                }
                ringCv.notify_all();

                const auto now = std::chrono::steady_clock::now();
                if (now - lastPipeLog > std::chrono::seconds(1)) {
                    lastPipeLog = now;
                    const int64_t wall2 = pipelineElapsedUs(now) / 1000;
                    const double vfps =
                        wall2 > 0 ? (1000.0 * static_cast<double>(frameIndex) /
                                     static_cast<double>(wall2))
                                  : 0.0;
                    const double pfps =
                        wall2 > 0 ? (1000.0 * static_cast<double>(
                                                   pipelinePresentCount.load()) /
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
                        hardwarePresentTelemetry() +
                        " fps=" + std::to_string(fpsNum) + "/" + std::to_string(fpsDen) +
                        " decode=" + std::to_string(outW_) + "x" + std::to_string(outH_) +
                        (useInproc ? " pipe=inproc" : " pipe=1"));
                    if (pipeProfile && frameIndex > 0) {
                        const int64_t n = frameIndex;
                        const int64_t p = std::max<int64_t>(1, pipelinePresentCount.load());
                        log("media: pipe_profile n=" + std::to_string(n) +
                            " p=" + std::to_string(p) +
                            " read_us_f=" + std::to_string(pipeReadUs.load() / n) +
                            " slot_wait_us_f=" + std::to_string(pipeSlotWaitUs.load() / n) +
                            " present_wait_us_p=" +
                            std::to_string(pipePresentWaitUs.load() / p) +
                            " send_us_p=" + std::to_string(pipeSendUs.load() / p) +
                            " copy_us_p=" + std::to_string(pipeCopyUs.load() / p));
                    }
                    // DDR 2-slot ring never hits the non-pipe progress path (frameIndex%15).
                    // Without this, Companion/Plex Web scrubber freezes at plant offset.
                    const int64_t tms = startMs + wall2;
                    positionMs_.store(tms);
                    if (onProgress_)
                        onProgress_("playing", tms, durationMs);
                }
            }
            readerEof.store(true);
            ringCv.notify_all();
            if (presentThr.joinable())
                presentThr.join();
            if (pipeProfile && frameIndex > 0) {
                const int64_t n = frameIndex;
                const int64_t p = std::max<int64_t>(1, pipelinePresentCount.load());
                log("media: pipe_profile_end n=" + std::to_string(n) +
                    " p=" + std::to_string(p) +
                    " read_us_f=" + std::to_string(pipeReadUs.load() / n) +
                    " slot_wait_us_f=" + std::to_string(pipeSlotWaitUs.load() / n) +
                    " present_wait_us_p=" +
                    std::to_string(pipePresentWaitUs.load() / p) +
                    " send_us_p=" + std::to_string(pipeSendUs.load() / p) +
                    " copy_us_p=" + std::to_string(pipeCopyUs.load() / p));
            }
            releaseFabricSlots();
            true480PipelineAborted = pipelineFatal.load();
            if (true480PipelineAborted)
                log("ERROR media: true480 DDR pipeline aborted; suppressing natural EOF");
            presentCount_ = pipelinePresentCount.load();
            ddrBank_ = localBank;
            if (rfd >= 0) {
                ::close(rfd);
                rfd = -1;
            }
        }

        bool pauseClockHeld = false;
        bool pausedOverlayWasVisible = false;
        std::chrono::steady_clock::time_point pauseStarted{};
        size_t got = 0;
        while (!stop_.load() && !pipelineDdr) {
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
            // Zero-intermediate present: read rawvideo straight into the free DDR
            // bank (retires heap frame + second uncached memcpy). FPGA-only YUV path.
            // PRESENT=fpga only: no fb0 blit needed, so payload can land in-bank.
            const bool directDdrIngest =
                useDdrF1_ && wantFpgaFrameStore &&
                videoFmt == RawVideoFormat::Yuv420p && presentMode_ == "fpga";
            int ingestBank = ddrBank_;
            uint8_t* readDst = frame.data();
            bool usingDirectIngest = false;
            // Hold presentMu_ for begin→read→commit so OSD/idle cannot race bank.
            std::unique_lock<std::mutex> presentLk(presentMu_, std::defer_lock);
            if (directDdrIngest) {
                presentLk.lock();
                uint8_t* bankPtr =
                    fpga_.beginDdrBankIngest(frameBytes, ddrBank_, ingestBank);
                if (bankPtr) {
                    readDst = bankPtr;
                    usingDirectIngest = true;
                } else {
                    presentLk.unlock();
                }
            }
            if (profilePresent)
                readStart = std::chrono::steady_clock::now();
            if (profilePresent)
                readCpuStart = threadCpuMicros();
            while (got < frameBytes && !stop_.load() && !paused_.load()) {
                ++frameReadCalls;
                ssize_t n = 0;
                if (profilePresent) {
                    const auto syscall0 = std::chrono::steady_clock::now();
                    n = ::read(rfd, readDst + got, frameBytes - got);
                    const auto syscall1 = std::chrono::steady_clock::now();
                    frameReadSyscallUs += microsBetween(syscall0, syscall1);
                } else {
                    n = ::read(rfd, readDst + got, frameBytes - got);
                }
                if (n < 0) {
                    if (errno == EINTR) {
                        ++frameReadEintr;
                        continue;
                    }
                    if (errno == EAGAIN || errno == EWOULDBLOCK) {
                        ++frameReadEagain;
                        // Prefer 1ms over 2ms (budget) or 200us spin (starves ffmpeg).
                        if (profilePresent) {
                            const auto sleep0 = std::chrono::steady_clock::now();
                            std::this_thread::sleep_for(std::chrono::milliseconds(1));
                            const auto sleep1 = std::chrono::steady_clock::now();
                            frameReadSleepUs += microsBetween(sleep0, sleep1);
                        } else {
                            std::this_thread::sleep_for(std::chrono::milliseconds(1));
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
            if (paused_.load()) {
                // Bank was reserved but frame incomplete — drop reservation by not committing.
                usingDirectIngest = false;
                continue;
            }
            if (got < frameBytes) {
                shortRead = true;
                shortReadGot = got;
                shortReadWant = frameBytes;
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
                    clearYuv420pCropPadding(readDst, ddrGeometry);
                    if (uvUBias_ != 0 || uvVBias_ != 0)
                        applyYuv420pUvBias(readDst, rawW, rawH, uvUBias_, uvVBias_);
                    const int64_t pixCpu1 = threadCpuMicros();
                    const auto pix1 = std::chrono::steady_clock::now();
                    prof.pixelUs += microsBetween(pix0, pix1);
                    prof.pixelCpuUs += pixCpu1 - pixCpu0;
                } else {
                    clearYuv420pCropPadding(readDst, ddrGeometry);
                    if (uvUBias_ != 0 || uvVBias_ != 0)
                        applyYuv420pUvBias(readDst, rawW, rawH, uvUBias_, uvVBias_);
                }
            }
            // Release present lock during A/V pacing; re-acquire only to commit.
            if (usingDirectIngest && presentLk.owns_lock())
                presentLk.unlock();

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
                // Direct ingest: payload is in a free bank but we drop — do not kick.
                if (presentLk.owns_lock())
                    presentLk.unlock();
            } else {
                dropRun = 0;
                if (usingDirectIngest) {
                    if (!presentLk.owns_lock())
                        presentLk.lock();
                    const int64_t ddrCpu0 = profilePresent ? threadCpuMicros() : 0;
                    const bool ok = fpga_.commitDdrBankIngest(ingestBank, frameBytes);
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
                        prof.ddrTotalUs += dt.total_us;
                        prof.ddrCpuUs += ddrCpu1 - ddrCpu0;
                        if (dt.total_us > accounted)
                            prof.ddrUnaccountedUs += dt.total_us - accounted;
                        ++prof.presented;
                    }
                    if (ok) {
                        ++presentCount_;
                        ddrBank_ = ingestBank ^ 1;
                        if ((presentCount_ % 48) == 0) {
                            const auto dt = fpga_.lastDdrTiming();
                            log(std::string("media: fpga frame_tx ok via DDR_INGEST") +
                                " presents=" + std::to_string(presentCount_) +
                                " frames=" + std::to_string(frameIndex) +
                                " ms=" + std::to_string(static_cast<int>(fpga_.lastPushMs())) +
                                " prep_us=" + std::to_string(dt.prep_wait_us) +
                                " copy_us=" + std::to_string(dt.copy_us) +
                                " flush_us=" + std::to_string(dt.flush_us) +
                                " doorbell_us=" + std::to_string(dt.doorbell_us) +
                                " plxd_us=" + std::to_string(dt.plxa_poll_us) +
                                " plxd_iters=" + std::to_string(dt.plxa_poll_iters) +
                                " total_us=" + std::to_string(dt.total_us));
                        }
                    } else {
                        log("media: DDR_INGEST commit failed: " + fpga_.lastError());
                    }
                    if (presentLk.owns_lock())
                        presentLk.unlock();
                } else {
                    if (presentLk.owns_lock())
                        presentLk.unlock();
                    presentCleanFrame(frame.data(), /*countPresent*/ true);
                }
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
                    hardwarePresentTelemetry() +
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
        closeRemuxHolds();
        if (rfd >= 0)
            ::close(rfd);
    }

    killChildren();
#ifdef MPX_HAVE_LIBAV
    if (inprocPcm_)
        inprocPcm_->requestStop();
#endif
    if (audioThr_.joinable())
        audioThr_.join();
#ifdef MPX_HAVE_LIBAV
    inprocPcm_ = nullptr;
#endif
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
        lastSummary_.true480PipelineAborted = true480PipelineAborted;
        lastSummary_.shortReadGot = shortReadGot;
        lastSummary_.shortReadWant = shortReadWant;
    }
    // Only natural EOF with content may report "ended" and trigger auto-next.
    // A strict true480 transport failure is success-shaped without this guard:
    // frameIndex>0 survives teardown even though presentation aborted mid-title.
    if (onProgress_) {
        const bool hadContent = usedRawVideo ? (frameIndex > 0) : (reconFrames_.load() > 0 ||
                                                                   positionMs_.load() > startMs + 500);
        const PlaybackTerminalState terminal = classifyPlaybackTerminalState(
            stop_.load(), true480PipelineAborted, hadContent);
        if (terminal == PlaybackTerminalState::Ended) {
            onProgress_("ended", positionMs_.load(), durationMs);
        } else if (terminal == PlaybackTerminalState::Stopped) {
            const int64_t stoppedAt = true480PipelineAborted ? positionMs_.load() : 0;
            onProgress_("stopped", stoppedAt, durationMs);
        }
    }
    // The frame store latches the last frame written; without this the final frame
    // of the video stays on screen until something else paints over it.
    paintIdle();
    startIdle();

    log("media: session end frames=" + std::to_string(frameIndex) +
        " recon=" + std::to_string(reconFrames_.load()) +
        " cabac=" + (cabacSkip_.load() ? "1" : "0") +
        " stream=" + (streamEnabled_ ? "on" : "off") +
        " rawvideo=" + (usedRawVideo ? "on" : "off") +
        " true480_pipeline_aborted=" + (true480PipelineAborted ? "1" : "0") +
        " present=" + presentMode_ +
        " skip_rgb=" + (skipRgb ? "1" : "0") +
        " stop=" + (stop_.load() ? "1" : "0") +
        " video_eof=" + (videoEof ? "1" : "0") +
        " short_read=" + (shortRead ? "1" : "0") +
        " short_got=" + std::to_string(shortReadGot) +
        " short_want=" + std::to_string(shortReadWant));
}

} // namespace misterplex
