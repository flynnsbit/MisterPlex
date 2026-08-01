// /proc/<pid>/io helpers — NOT for PMS HTTP supply scoring.
//
// =============================================================================
// VOID for PMS arrival (parent RESULT_pms_supply_not_the_limiter.md):
//   Product ffmpeg HTTP uses recv(). On the MiSTer kernel that does NOT
//   increment rchar (measured: rchar=1037, syscr=5, wchar≈414MB, healthy vfps).
//   Scoring rchar B/s vs NOMINAL_BPS emitted STALL on 12/12 live windows =
//   blind RED. Never reintroduce rchar- or NOMINAL_BPS-based supply verdicts.
//   Use ss Recv-Q: host/libmisterplex/ss_recvq_sample.hpp +
//   tools/pms_recvq_backlog_sample.sh
// =============================================================================
//
// wchar may still be used as a *work* signal for blindness self-checks
// (process is writing). Do not score supply from rchar.
#pragma once

#include <cstdint>
#include <cstdio>
#include <cstring>
#include <string>

namespace misterplex {

struct ProcIoSample {
    bool ok = false;
    uint64_t rchar = 0; // DO NOT score PMS supply from this field (VOID — see banner).
    uint64_t wchar = 0; // work signal only
    uint64_t syscr = 0;
    uint64_t syscw = 0;
    uint64_t read_bytes = 0;
    uint64_t write_bytes = 0;
};

inline bool parseProcIoText(const char* text, ProcIoSample* out) {
    if (!text || !out)
        return false;
    ProcIoSample s;
    int got = 0;
    const char* p = text;
    while (*p) {
        const char* nl = std::strchr(p, '\n');
        const size_t n = nl ? static_cast<size_t>(nl - p) : std::strlen(p);
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
        }
        if (!nl)
            break;
        p = nl + 1;
    }
    if (got < 1)
        return false;
    s.ok = true;
    *out = s;
    return true;
}

inline bool parseProcIoText(const std::string& text, ProcIoSample* out) {
    return parseProcIoText(text.c_str(), out);
}

// Parent-measured VOID pattern: rchar flat, syscr tiny, wchar huge.
inline bool procIoLooksLikeRcharBlindToNetwork(const ProcIoSample& s, uint64_t min_wchar) {
    if (!s.ok)
        return false;
    return s.syscr <= 32 && s.rchar < 65536 && s.wchar >= min_wchar;
}

} // namespace misterplex
