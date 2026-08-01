// Sample /proc/<pid>/io for per-process byte counters (host-pure, unit-tested).
//
// Use for PMS HTTP arrival rate on the product ffmpeg child during a real cast.
// Prefer rchar (bytes read() by the process, includes socket reads).
// read_bytes is filesystem-backed only on many kernels — often 0 for pure HTTP.
//
// Rule 0: absence of /proc/pid/io is NO-DATA, never 0.0 B/s.
#pragma once

#include <cstdint>
#include <cstdio>
#include <cstring>
#include <string>

namespace misterplex {

struct ProcIoSample {
    bool ok = false;
    uint64_t rchar = 0;
    uint64_t wchar = 0;
    uint64_t syscr = 0;
    uint64_t syscw = 0;
    uint64_t read_bytes = 0;
    uint64_t write_bytes = 0;
    uint64_t cancelled_write_bytes = 0;
};

struct ProcIoDelta {
    bool ok = false;
    double d_wall_s = 0;
    int64_t d_rchar = 0;
    int64_t d_wchar = 0;
    int64_t d_read_bytes = 0;
    int64_t d_write_bytes = 0;
    double rchar_Bps = 0;
    double read_bytes_Bps = 0;
    bool read_bytes_usable = false; // false when both endpoints read_bytes==0 (common for net)
};

// Parse a full /proc/pid/io blob (key: value\n lines).
inline bool parseProcIoText(const char* text, ProcIoSample* out) {
    if (!text || !out)
        return false;
    ProcIoSample s;
    int got = 0;
    const char* p = text;
    while (*p) {
        const char* nl = std::strchr(p, '\n');
        const size_t n = nl ? static_cast<size_t>(nl - p) : std::strlen(p);
        // "rchar: 123"
        unsigned long long v = 0;
        if (n > 7 && std::strncmp(p, "rchar:", 6) == 0) {
            if (std::sscanf(p + 6, " %llu", &v) == 1) {
                s.rchar = static_cast<uint64_t>(v);
                ++got;
            }
        } else if (n > 7 && std::strncmp(p, "wchar:", 6) == 0) {
            if (std::sscanf(p + 6, " %llu", &v) == 1) {
                s.wchar = static_cast<uint64_t>(v);
                ++got;
            }
        } else if (n > 7 && std::strncmp(p, "syscr:", 6) == 0) {
            if (std::sscanf(p + 6, " %llu", &v) == 1) {
                s.syscr = static_cast<uint64_t>(v);
                ++got;
            }
        } else if (n > 7 && std::strncmp(p, "syscw:", 6) == 0) {
            if (std::sscanf(p + 6, " %llu", &v) == 1) {
                s.syscw = static_cast<uint64_t>(v);
                ++got;
            }
        } else if (n > 12 && std::strncmp(p, "read_bytes:", 11) == 0) {
            if (std::sscanf(p + 11, " %llu", &v) == 1) {
                s.read_bytes = static_cast<uint64_t>(v);
                ++got;
            }
        } else if (n > 13 && std::strncmp(p, "write_bytes:", 12) == 0) {
            if (std::sscanf(p + 12, " %llu", &v) == 1) {
                s.write_bytes = static_cast<uint64_t>(v);
                ++got;
            }
        } else if (n > 22 && std::strncmp(p, "cancelled_write_bytes:", 22) == 0) {
            if (std::sscanf(p + 22, " %llu", &v) == 1) {
                s.cancelled_write_bytes = static_cast<uint64_t>(v);
                ++got;
            }
        }
        if (!nl)
            break;
        p = nl + 1;
    }
    // Need at least rchar to be useful for HTTP arrival.
    if (got < 1)
        return false;
    s.ok = true;
    *out = s;
    return true;
}

inline bool parseProcIoText(const std::string& text, ProcIoSample* out) {
    return parseProcIoText(text.c_str(), out);
}

// Read /proc/<pid>/io from the filesystem. Returns false → NO-DATA.
inline bool readProcIoFile(const char* path, ProcIoSample* out) {
    if (!path || !out)
        return false;
    FILE* f = std::fopen(path, "r");
    if (!f)
        return false;
    char buf[512];
    const size_t n = std::fread(buf, 1, sizeof(buf) - 1, f);
    std::fclose(f);
    if (n == 0)
        return false;
    buf[n] = '\0';
    return parseProcIoText(buf, out);
}

inline bool readProcIoPid(int pid, ProcIoSample* out) {
    if (pid <= 0 || !out)
        return false;
    char path[64];
    std::snprintf(path, sizeof(path), "/proc/%d/io", pid);
    return readProcIoFile(path, out);
}

inline ProcIoDelta procIoDelta(const ProcIoSample& a, const ProcIoSample& b, double d_wall_s) {
    ProcIoDelta d;
    if (!a.ok || !b.ok || !(d_wall_s > 0.0))
        return d;
    d.ok = true;
    d.d_wall_s = d_wall_s;
    d.d_rchar = static_cast<int64_t>(b.rchar) - static_cast<int64_t>(a.rchar);
    d.d_wchar = static_cast<int64_t>(b.wchar) - static_cast<int64_t>(a.wchar);
    d.d_read_bytes = static_cast<int64_t>(b.read_bytes) - static_cast<int64_t>(a.read_bytes);
    d.d_write_bytes = static_cast<int64_t>(b.write_bytes) - static_cast<int64_t>(a.write_bytes);
    d.rchar_Bps = static_cast<double>(d.d_rchar) / d_wall_s;
    d.read_bytes_Bps = static_cast<double>(d.d_read_bytes) / d_wall_s;
    // If both samples have read_bytes==0, field is unusable for net input (NO-DATA).
    d.read_bytes_usable = !(a.read_bytes == 0 && b.read_bytes == 0);
    return d;
}

// Compare measured rchar B/s to nominal stream bytes/s.
// ratio = measured / nominal. Supports "≈1× PMS pacing" when near 1.0.
inline double arrivalRatioVsNominal(double rchar_Bps, double nominal_Bps) {
    if (!(nominal_Bps > 0.0) || !(rchar_Bps >= 0.0))
        return -1.0;
    return rchar_Bps / nominal_Bps;
}

// Format one telemetry line (no media: prefix).
inline std::string formatFfmpegIoLine(const ProcIoDelta& d, int pid, double nominal_Bps,
                                      const char* sessionEpoch) {
    char buf[512];
    if (!d.ok) {
        std::snprintf(buf, sizeof(buf),
                      "ffmpeg_io pid=%d d_wall_s=NO-DATA d_rchar=NO-DATA rchar_Bps=NO-DATA "
                      "d_read_bytes=NO-DATA read_bytes_Bps=NO-DATA "
                      "nominal_Bps=%.0f ratio_vs_nominal=NO-DATA "
                      "session_epoch=%s tag=NO-DATA",
                      pid, nominal_Bps, sessionEpoch ? sessionEpoch : "NO-DATA");
        return std::string(buf);
    }
    const double ratio = arrivalRatioVsNominal(d.rchar_Bps, nominal_Bps);
    if (d.read_bytes_usable) {
        std::snprintf(buf, sizeof(buf),
                      "ffmpeg_io pid=%d d_wall_s=%.3f d_rchar=%lld rchar_Bps=%.1f "
                      "d_wchar=%lld d_read_bytes=%lld read_bytes_Bps=%.1f "
                      "nominal_Bps=%.0f ratio_vs_nominal=%.3f "
                      "session_epoch=%s note=rchar_includes_socket_reads tag=measured",
                      pid, d.d_wall_s, static_cast<long long>(d.d_rchar), d.rchar_Bps,
                      static_cast<long long>(d.d_wchar),
                      static_cast<long long>(d.d_read_bytes), d.read_bytes_Bps, nominal_Bps,
                      ratio, sessionEpoch ? sessionEpoch : "NO-DATA");
    } else {
        std::snprintf(buf, sizeof(buf),
                      "ffmpeg_io pid=%d d_wall_s=%.3f d_rchar=%lld rchar_Bps=%.1f "
                      "d_wchar=%lld d_read_bytes=NO-DATA read_bytes_Bps=NO-DATA "
                      "nominal_Bps=%.0f ratio_vs_nominal=%.3f "
                      "session_epoch=%s note=rchar_includes_socket_reads "
                      "read_bytes_note=zero_both_ends_typical_for_http tag=measured",
                      pid, d.d_wall_s, static_cast<long long>(d.d_rchar), d.rchar_Bps,
                      static_cast<long long>(d.d_wchar), nominal_Bps, ratio,
                      sessionEpoch ? sessionEpoch : "NO-DATA");
    }
    return std::string(buf);
}

} // namespace misterplex
