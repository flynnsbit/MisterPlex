// Parse `ss -tinp` (or fixture text) for per-socket Recv-Q + bytes_received.
//
// WHY NOT /proc/pid/io rchar (VOID — parent RESULT_pms_supply_not_the_limiter):
//   On MiSTer kernel, product ffmpeg HTTP input uses recv(), which does NOT
//   increment rchar. Live cast: rchar≈1037, syscr=5, wchar≈414MB while healthy
//   at vfps≈24. Scoring rchar B/s emitted STALL on 12/12 windows = blind RED.
//   Never reintroduce rchar/NOMINAL_BPS ratio scoring for PMS supply.
//
// Valid observable: Recv-Q backlog on the PMS TCP socket (ss match pid= AND fd=).
// Sustained Recv-Q > 0 ⇒ not input-starved (no assumed nominal bitrate).
//
// Rule 0: absence / parse fail = NO-DATA, never 0.0-as-measurement.
// Blindness rule: if the scored counter is 0 on all windows while the process is
// alive and doing work (e.g. wchar advancing), return NO-DATA — never a defect.
#pragma once

#include <cstdint>
#include <cstdio>
#include <cstring>
#include <string>

namespace misterplex {

struct SsSocketSample {
    bool ok = false;
    int pid = -1;
    int fd = -1;
    int64_t recv_q = -1;          // -1 = NO-DATA
    int64_t bytes_received = -1;  // -1 = NO-DATA (info field may be absent)
    bool app_limited = false;
    bool has_app_limited_token = false;
};

// Parse one ss -tinp blob (may be multi-line). Prefer line matching pid= AND fd=.
// If fd < 0, first users:(("…",pid=P match wins.
inline bool parseSsTinpText(const char* text, int want_pid, int want_fd, SsSocketSample* out) {
    if (!text || !out || want_pid <= 0)
        return false;
    SsSocketSample best;
    const char* p = text;
    while (*p) {
        const char* nl = std::strchr(p, '\n');
        size_t n = nl ? static_cast<size_t>(nl - p) : std::strlen(p);
        std::string line(p, n);
        // Advance first so continue paths are simple.
        p = nl ? nl + 1 : p + n;

        // users:(("ffmpeg",pid=13172,fd=5))
        char needle[64];
        std::snprintf(needle, sizeof(needle), "pid=%d", want_pid);
        if (line.find(needle) == std::string::npos)
            continue;
        int fd = -1;
        const char* fdp = std::strstr(line.c_str(), "fd=");
        if (fdp) {
            int v = 0;
            if (std::sscanf(fdp, "fd=%d", &v) == 1)
                fd = v;
        }
        if (want_fd >= 0 && fd >= 0 && fd != want_fd)
            continue;
        if (want_fd >= 0 && fd < 0)
            continue; // required fd not on this line

        SsSocketSample s;
        s.pid = want_pid;
        s.fd = fd;
        // Recv-Q: "ESTAB 494010 0 ..." or "Recv-Q 494010" or column after state.
        // Try explicit token first.
        const char* rq = std::strstr(line.c_str(), "Recv-Q");
        if (rq) {
            unsigned long long v = 0;
            if (std::sscanf(rq, "Recv-Q %llu", &v) == 1 ||
                std::sscanf(rq, "Recv-Q:%llu", &v) == 1) {
                s.recv_q = static_cast<int64_t>(v);
            }
        }
        if (s.recv_q < 0) {
            // ss -t default: State Recv-Q Send-Q Local Address:Port Peer...
            // ESTAB 494010 0 192.168...
            char state[32];
            unsigned long long rqv = 0, sqv = 0;
            if (std::sscanf(line.c_str(), "%31s %llu %llu", state, &rqv, &sqv) >= 2) {
                // Reject if first token looks like "tcp" with different layout.
                if (std::strcmp(state, "tcp") != 0 && std::strcmp(state, "Netid") != 0 &&
                    std::strcmp(state, "State") != 0) {
                    s.recv_q = static_cast<int64_t>(rqv);
                }
            }
        }
        // bytes_received may be on this line or a following indented line — scan rest of text
        // from current line start within a small window handled by full-text search below.
        s.ok = (s.recv_q >= 0);
        if (s.ok && (!best.ok || (want_fd >= 0 && s.fd == want_fd) || s.recv_q > best.recv_q))
            best = s;
    }

    if (!best.ok)
        return false;

    // bytes_received / app_limited: search whole blob near pid match.
    char pidtok[32];
    std::snprintf(pidtok, sizeof(pidtok), "pid=%d", want_pid);
    const char* hit = std::strstr(text, pidtok);
    if (hit) {
        // Search forward up to ~800 chars for info fields (ss wraps).
        const char* region = hit;
        size_t remain = std::strlen(region);
        if (remain > 800)
            remain = 800;
        std::string win(region, remain);
        // Also allow searching backward a bit for Recv-Q on previous physical line.
        const char* br = std::strstr(win.c_str(), "bytes_received:");
        if (br) {
            unsigned long long v = 0;
            if (std::sscanf(br, "bytes_received:%llu", &v) == 1)
                best.bytes_received = static_cast<int64_t>(v);
        }
        if (win.find("app_limited") != std::string::npos) {
            best.has_app_limited_token = true;
            best.app_limited = true;
        }
    }
    *out = best;
    return true;
}

inline bool parseSsTinpText(const std::string& text, int want_pid, int want_fd,
                            SsSocketSample* out) {
    return parseSsTinpText(text.c_str(), want_pid, want_fd, out);
}

// Classification — no assumed nominal bitrate.
// backlog_min: Recv-Q at or above this ⇒ held backlog (not supply-starved).
enum class RecvQClass {
    NoData = 0,
    BacklogHeld,   // recv_q >= backlog_min — not supply-limited
    BacklogLow,    // 0 < recv_q < backlog_min — weak / inconclusive
    QueueEmpty,    // recv_q == 0 — NOT a defect by itself
};

inline RecvQClass classifyRecvQ(int64_t recv_q, int64_t backlog_min) {
    if (recv_q < 0)
        return RecvQClass::NoData;
    if (recv_q == 0)
        return RecvQClass::QueueEmpty;
    if (backlog_min > 0 && recv_q >= backlog_min)
        return RecvQClass::BacklogHeld;
    return RecvQClass::BacklogLow;
}

inline const char* recvQClassName(RecvQClass c) {
    switch (c) {
    case RecvQClass::BacklogHeld:
        return "BACKLOG_HELD";
    case RecvQClass::BacklogLow:
        return "BACKLOG_LOW";
    case RecvQClass::QueueEmpty:
        return "QUEUE_EMPTY";
    default:
        return "NO-DATA";
    }
}

// Blindness self-check for a scored counter series.
// If every sample of `scored` is exactly 0 while `work` (e.g. wchar) advanced
// over the run and the process was alive, the counter is blind → NO-DATA, not defect.
struct BlindCounterCheck {
    bool blind = false;
    const char* reason = "";
};

inline BlindCounterCheck scoredCounterBlindAllZero(const int64_t* scored, int n,
                                                   int64_t work_delta, bool process_alive) {
    BlindCounterCheck r;
    if (!scored || n <= 0) {
        r.blind = true;
        r.reason = "no_samples";
        return r;
    }
    if (!process_alive) {
        r.blind = false;
        r.reason = "process_dead";
        return r;
    }
    if (work_delta <= 0) {
        r.blind = false;
        r.reason = "no_work_delta"; // cannot prove counter is blind
        return r;
    }
    for (int i = 0; i < n; ++i) {
        if (scored[i] != 0) {
            r.blind = false;
            r.reason = "counter_nonzero";
            return r;
        }
    }
    r.blind = true;
    r.reason = "all_zero_while_work_advanced";
    return r;
}

// Aggregate verdict for Recv-Q campaign (no ratio-vs-nominal).
struct RecvQCampaignVerdict {
    const char* verdict = "NO-DATA"; // NOT_SUPPLY_LIMITED | INCONCLUSIVE | NO-DATA
    int held_n = 0;
    int low_n = 0;
    int empty_n = 0;
    int nodata_n = 0;
    int ok_n = 0;
    int64_t min_recv_q = -1;
    int64_t max_recv_q = -1;
};

inline RecvQCampaignVerdict scoreRecvQCampaign(const int64_t* recv_q, int n,
                                               int64_t backlog_min) {
    RecvQCampaignVerdict v;
    if (!recv_q || n <= 0)
        return v;
    for (int i = 0; i < n; ++i) {
        const auto c = classifyRecvQ(recv_q[i], backlog_min);
        if (c == RecvQClass::NoData) {
            ++v.nodata_n;
            continue;
        }
        ++v.ok_n;
        if (v.min_recv_q < 0 || recv_q[i] < v.min_recv_q)
            v.min_recv_q = recv_q[i];
        if (recv_q[i] > v.max_recv_q)
            v.max_recv_q = recv_q[i];
        if (c == RecvQClass::BacklogHeld)
            ++v.held_n;
        else if (c == RecvQClass::BacklogLow)
            ++v.low_n;
        else
            ++v.empty_n;
    }
    if (v.ok_n == 0) {
        v.verdict = "NO-DATA";
        return v;
    }
    // Majority held backlog → not supply-limited (parent: never below ~482KB).
    if (v.held_n * 2 >= v.ok_n) {
        v.verdict = "NOT_SUPPLY_LIMITED";
        return v;
    }
    // All empty is NOT automatic supply-limited (could be app keeping up).
    v.verdict = "INCONCLUSIVE";
    return v;
}

inline std::string formatRecvQSampleLine(int sample_i, double d_wall_s, int64_t recv_q,
                                         int64_t bytes_received, int pid, int fd,
                                         RecvQClass cls, const char* live_tag) {
    char brbuf[32];
    if (bytes_received >= 0)
        std::snprintf(brbuf, sizeof(brbuf), "%lld", static_cast<long long>(bytes_received));
    else
        std::snprintf(brbuf, sizeof(brbuf), "NO-DATA");
    char buf[384];
    std::snprintf(buf, sizeof(buf),
                  "sample=%d d_wall_s=%.3f recv_q=%lld bytes_received=%s pid=%d fd=%d "
                  "class=%s live=%s tag=measured",
                  sample_i, d_wall_s, static_cast<long long>(recv_q), brbuf, pid, fd,
                  recvQClassName(cls), live_tag ? live_tag : "NO-DATA");
    return std::string(buf);
}

} // namespace misterplex
