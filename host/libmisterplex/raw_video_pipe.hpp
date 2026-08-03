// Raw video pipe capacity (F_SETPIPE_SZ) for STREAM=0 ffmpeg → daemon decoupling.
//
// A 624x480 I420 frame is 449280 bytes. Linux default pipe capacity is 65536
// (~0.15 frames), so a single DDR publish spike (ms=13–14) backpressures the
// decoder. Raising capacity to ~2 MiB (~4.7 frames) absorbs brief publish
// latency without changing steady-state throughput.
//
// Contract: never claim success without F_GETPIPE_SZ read-back. On F_SETPIPE_SZ
// failure, log errno and keep the kernel default — do not abort playback.
#pragma once

#include <cerrno>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>

#include <fcntl.h>
#include <unistd.h>

namespace misterplex {

// Coded 624x480 yuv420p plane size used by the product DDR frame store.
inline constexpr int kYuv420p624x480FrameBytes = 624 * 480 * 3 / 2; // 449280

// Default target: 2 MiB ≈ 4.67 frames @ 449280 B. Power-of-two page multiple
// that F_SETPIPE_SZ accepts cleanly; large enough for multi-frame jitter absorb.
inline constexpr int kDefaultRawVideoPipeBytes = 2 * 1024 * 1024;

// Minimum actual size we treat as "decoupled enough" in host unit tests
// (~2 frames at 480p). Below this the pipe still couples decoder to publish.
inline constexpr int kMinUsefulRawVideoPipeBytes = 2 * kYuv420p624x480FrameBytes; // 898560

struct RawVideoPipeSizeResult {
    int requested = 0;   // bytes we asked F_SETPIPE_SZ for (0 = skipped)
    int actual = -1;     // F_GETPIPE_SZ read-back (-1 if unavailable)
    bool attempted = false;
    bool set_ok = false; // true only when F_SETPIPE_SZ returned >= 0
    int set_errno = 0;
};

// Parse conf RAW_VIDEO_PIPE_BYTES:
//   empty / "auto" / "on" / "1" / "true" / "yes" → default target
//   "0" / "off" / "false" / "no"                 → disable (kernel default)
//   positive integer                             → that many bytes
//   garbage                                      → default target
inline int parseRawVideoPipeBytesConf(const std::string& raw) {
    std::string v = raw;
    while (!v.empty() && (v.back() == ' ' || v.back() == '\t' || v.back() == '\r' || v.back() == '\n'))
        v.pop_back();
    size_t i = 0;
    while (i < v.size() && (v[i] == ' ' || v[i] == '\t' || v[i] == '\r' || v[i] == '\n'))
        ++i;
    if (i)
        v.erase(0, i);
    if (v.empty() || v == "auto" || v == "on" || v == "1" || v == "true" || v == "yes")
        return kDefaultRawVideoPipeBytes;
    if (v == "0" || v == "off" || v == "false" || v == "no")
        return 0;
    char* end = nullptr;
    long n = std::strtol(v.c_str(), &end, 10);
    if (end == v.c_str() || n < 0)
        return kDefaultRawVideoPipeBytes;
    if (n > 64L * 1024 * 1024)
        n = 64L * 1024 * 1024; // hard ceiling — absurd conf values
    return static_cast<int>(n);
}

// Read /proc/sys/fs/pipe-max-size (0 if unavailable). Used only as a retry
// ceiling after EPERM — never as a silent substitute for the conf request.
inline int readPipeMaxSizeProc() {
    FILE* f = std::fopen("/proc/sys/fs/pipe-max-size", "r");
    if (!f)
        return 0;
    int v = 0;
    if (std::fscanf(f, "%d", &v) != 1)
        v = 0;
    std::fclose(f);
    return v > 0 ? v : 0;
}

// Apply F_SETPIPE_SZ when requestBytes > 0, then ALWAYS read F_GETPIPE_SZ.
// requestBytes <= 0: skip set, still report actual kernel size.
// On EPERM (unprivileged > pipe-max-size), retry once at pipe-max-size and
// record the retried request in `requested` so logs show what was actually
// attempted last. set_ok reflects only the final F_SETPIPE_SZ outcome.
inline RawVideoPipeSizeResult applyRawVideoPipeSize(int fd, int requestBytes) {
    RawVideoPipeSizeResult out;
    out.requested = requestBytes > 0 ? requestBytes : 0;
    if (fd < 0) {
        out.actual = -1;
        return out;
    }
#ifdef F_SETPIPE_SZ
    if (requestBytes > 0) {
        out.attempted = true;
#ifdef RAW_PIPE_FAULT_NO_SET
        // Unit-test fault injection: pretend set was never attempted successfully.
        // Green checks must FAIL under this define (see test_raw_video_pipe_red.sh).
        (void)fd;
        out.set_ok = false;
        out.set_errno = EPERM;
#else
        errno = 0;
        int setRc = ::fcntl(fd, F_SETPIPE_SZ, requestBytes);
        if (setRc < 0) {
            out.set_ok = false;
            out.set_errno = errno;
            // Unprivileged processes cannot exceed pipe-max-size. Retry once at
            // the sysctl ceiling so product still gets multi-frame buffering
            // when 2 MiB is above the local max (host lab measured: max=1 MiB).
            if (out.set_errno == EPERM) {
                const int maxSz = readPipeMaxSizeProc();
                if (maxSz > 0 && maxSz < requestBytes) {
                    errno = 0;
                    setRc = ::fcntl(fd, F_SETPIPE_SZ, maxSz);
                    out.requested = maxSz; // last attempted size
                    if (setRc < 0) {
                        out.set_ok = false;
                        out.set_errno = errno;
                    } else {
                        out.set_ok = true;
                        out.set_errno = 0;
                    }
                }
            }
        } else {
            // Kernel returns the (possibly rounded-up) capacity on success.
            out.set_ok = true;
            out.set_errno = 0;
        }
#endif // !RAW_PIPE_FAULT_NO_SET
    }
#ifdef F_GETPIPE_SZ
    errno = 0;
    const int got = ::fcntl(fd, F_GETPIPE_SZ);
    if (got < 0) {
        out.actual = -1;
    } else {
        out.actual = got;
    }
#else
    out.actual = -1;
#endif
#else
    (void)requestBytes;
    out.actual = -1;
#endif
    return out;
}

// Single-line telemetry. Uses ACTUAL read-back, never the request alone as success.
inline std::string formatRawVideoPipeLog(const RawVideoPipeSizeResult& r) {
    char buf[256];
    if (!r.attempted) {
        std::snprintf(buf, sizeof(buf),
                      "raw_video_pipe req=0 (disabled) actual=%d frame_bytes=%d",
                      r.actual, kYuv420p624x480FrameBytes);
        return buf;
    }
    if (r.set_ok) {
        std::snprintf(buf, sizeof(buf),
                      "raw_video_pipe req=%d actual=%d set_ok=1 frames_cap≈%.2f",
                      r.requested, r.actual,
                      r.actual > 0
                          ? static_cast<double>(r.actual) /
                                static_cast<double>(kYuv420p624x480FrameBytes)
                          : 0.0);
    } else {
        std::snprintf(buf, sizeof(buf),
                      "raw_video_pipe req=%d actual=%d set_ok=0 errno=%d (%s) "
                      "— keeping kernel default",
                      r.requested, r.actual, r.set_errno,
                      r.set_errno ? std::strerror(r.set_errno) : "unknown");
    }
    return buf;
}

// True when the measured capacity holds at least ~2 coded 480p frames.
inline bool rawVideoPipeIsDecoupled(const RawVideoPipeSizeResult& r) {
    return r.actual >= kMinUsefulRawVideoPipeBytes;
}

} // namespace misterplex
