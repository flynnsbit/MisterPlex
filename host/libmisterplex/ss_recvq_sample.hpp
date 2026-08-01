// Parse `ss -tinp` for PMS TCP Recv-Q backlog (host-pure, unit-tested).
//
// VOID — never score PMS supply from /proc/pid/io rchar or NOMINAL_BPS:
//   Parent: rchar blind to recv() (syscr=5); stall floor 0.4*57000=22800 B/s but
//   real arrival ~9851 B/s on healthy cast → STALL even with a correct counter.
//   Any rate comparison needs a *per-asset runtime* denominator, not a constant.
//
// Valid path: Recv-Q backlog + optional depth_s = recv_q / consume_Bps where
// consume_Bps is derived from the same socket (Δbytes_received − Δrecv_q)/Δt.
// No hardcoded nominal bitrate.
//
// Socket identity: pin the TCP **4-tuple** (local:port peer:port), NOT fd=N.
// ffmpeg -reconnect* can open a new socket; fd 5 is often reused and
// bytes_received resets to 0. A DECREASE in bytes_received is a RECONNECT
// marker — never a measurement.
//
// Recv-Q semantics (kernel): idiag_rqueue = rcv_nxt − copied_seq (in-order,
// unread, immediately readable). Do NOT cite app_limited (sender-path flag).
// Prefer rcv_ssthresh vs Recv-Q for receive-side window evidence.
//
// Rule 0: absence = NO-DATA. Blind all-zero scored counter while work advances
// → NO-DATA, never a defect class.
#pragma once

#include <cstdint>
#include <cstdio>
#include <cstring>
#include <string>

namespace misterplex {

struct SsSocketSample {
    bool ok = false;
    int pid = -1;
    int fd = -1; // informational only — do not pin identity on fd
    int64_t recv_q = -1;
    int64_t send_q = -1;
    int64_t bytes_received = -1;
    int64_t rcv_ssthresh = -1;
    char local[64]{};  // "ip:port" or "[v6]:port"
    char peer[64]{};
    char four_tuple[140]{}; // "local peer"
};

// Extract "a.b.c.d:port" or bare ":port" tokens; prefers lines with users:( pid=
inline bool parseSsTinpTextByTuple(const char* text, int want_pid, const char* want_tuple,
                                   SsSocketSample* out) {
    if (!text || !out || want_pid <= 0)
        return false;
    SsSocketSample best;
    const char* p = text;
    std::string cur_block;

    auto flush_block = [&](const std::string& block) {
        if (block.empty())
            return;
        char needle[48];
        std::snprintf(needle, sizeof(needle), "pid=%d", want_pid);
        if (block.find(needle) == std::string::npos)
            return;

        SsSocketSample s;
        s.pid = want_pid;
        // fd= optional
        if (const char* fdp = std::strstr(block.c_str(), "fd=")) {
            int v = 0;
            if (std::sscanf(fdp, "fd=%d", &v) == 1)
                s.fd = v;
        }

        // Find first line of block for state / addresses
        const char* bl = block.c_str();
        const char* nl0 = std::strchr(bl, '\n');
        std::string head = nl0 ? std::string(bl, nl0) : std::string(bl);

        // Recv-Q explicit
        if (const char* rq = std::strstr(block.c_str(), "Recv-Q")) {
            unsigned long long v = 0;
            if (std::sscanf(rq, "Recv-Q %llu", &v) == 1 || std::sscanf(rq, "Recv-Q:%llu", &v) == 1)
                s.recv_q = static_cast<int64_t>(v);
        }
        // Column form: ESTAB rcv snd local peer ...
        if (s.recv_q < 0) {
            char st[32];
            unsigned long long rqv = 0, sqv = 0;
            char loc[64], pr[64];
            loc[0] = pr[0] = 0;
            // ESTAB 494010 0 192.168.1.183:50346 192.168.1.24:32400 users:...
            int n = std::sscanf(head.c_str(), "%31s %llu %llu %63s %63s", st, &rqv, &sqv, loc, pr);
            if (n >= 5 && std::strcmp(st, "State") != 0 && std::strcmp(st, "Netid") != 0 &&
                std::strcmp(st, "tcp") != 0) {
                s.recv_q = static_cast<int64_t>(rqv);
                s.send_q = static_cast<int64_t>(sqv);
                std::snprintf(s.local, sizeof(s.local), "%s", loc);
                std::snprintf(s.peer, sizeof(s.peer), "%s", pr);
            }
        }
        // Also try to pull addresses if missing: scan for two ip:port tokens
        if (s.local[0] == 0) {
            // naive: find two tokens containing ':'
            char t1[64], t2[64];
            t1[0] = t2[0] = 0;
            const char* q = head.c_str();
            int found = 0;
            while (*q && found < 2) {
                while (*q == ' ' || *q == '\t')
                    ++q;
                const char* start = q;
                while (*q && *q != ' ' && *q != '\t')
                    ++q;
                size_t len = static_cast<size_t>(q - start);
                if (len > 0 && len < sizeof(t1) && memchr(start, ':', len)) {
                    char tmp[64];
                    std::memcpy(tmp, start, len);
                    tmp[len] = 0;
                    // skip users:(
                    if (std::strncmp(tmp, "users:", 6) != 0) {
                        if (found == 0)
                            std::snprintf(t1, sizeof(t1), "%s", tmp);
                        else
                            std::snprintf(t2, sizeof(t2), "%s", tmp);
                        ++found;
                    }
                }
            }
            if (found >= 2) {
                // first may be state junk; prefer tokens that look like addr:port
                // head tokens after numeric Recv-Q: already handled. Fallback: last two.
                std::snprintf(s.local, sizeof(s.local), "%s", t1);
                std::snprintf(s.peer, sizeof(s.peer), "%s", t2);
            }
        }
        if (s.local[0] && s.peer[0])
            std::snprintf(s.four_tuple, sizeof(s.four_tuple), "%s %s", s.local, s.peer);

        if (const char* br = std::strstr(block.c_str(), "bytes_received:")) {
            unsigned long long v = 0;
            if (std::sscanf(br, "bytes_received:%llu", &v) == 1)
                s.bytes_received = static_cast<int64_t>(v);
        }
        if (const char* rs = std::strstr(block.c_str(), "rcv_ssthresh:")) {
            unsigned long long v = 0;
            if (std::sscanf(rs, "rcv_ssthresh:%llu", &v) == 1)
                s.rcv_ssthresh = static_cast<int64_t>(v);
        }

        s.ok = (s.recv_q >= 0);
        if (!s.ok)
            return;

        if (want_tuple && want_tuple[0]) {
            if (s.four_tuple[0] == 0 || std::strcmp(s.four_tuple, want_tuple) != 0)
                return;
        }
        // Prefer peer :32400 (PMS) when no tuple pin yet
        bool pms = (std::strstr(s.peer, ":32400") != nullptr);
        if (!best.ok || (want_tuple && want_tuple[0]) ||
            (pms && std::strstr(best.peer, ":32400") == nullptr) ||
            s.recv_q > best.recv_q) {
            best = s;
        }
    };

    // Split into records: a non-indented line starts a new record; indented continues.
    while (*p) {
        const char* nl = std::strchr(p, '\n');
        size_t n = nl ? static_cast<size_t>(nl - p) : std::strlen(p);
        std::string line(p, n);
        p = nl ? nl + 1 : p + n;
        const bool indented = !line.empty() && (line[0] == '\t' || line[0] == ' ');
        if (!indented && !cur_block.empty()) {
            flush_block(cur_block);
            cur_block.clear();
        }
        if (!cur_block.empty())
            cur_block.push_back('\n');
        cur_block += line;
        if (!nl)
            break;
    }
    flush_block(cur_block);

    if (!best.ok)
        return false;
    *out = best;
    return true;
}

// Convenience: match pid only (discover tuple).
inline bool parseSsTinpText(const char* text, int want_pid, int /*want_fd_ignored*/,
                            SsSocketSample* out) {
    return parseSsTinpTextByTuple(text, want_pid, /*want_tuple=*/nullptr, out);
}

inline bool parseSsTinpText(const std::string& text, int want_pid, int want_fd,
                            SsSocketSample* out) {
    return parseSsTinpText(text.c_str(), want_pid, want_fd, out);
}

inline bool parseSsTinpTextByTuple(const std::string& text, int want_pid, const char* want_tuple,
                                   SsSocketSample* out) {
    return parseSsTinpTextByTuple(text.c_str(), want_pid, want_tuple, out);
}

// bytes_received decrease ⇒ reconnect (new socket / counter reset). Not a rate.
inline bool bytesReceivedIndicatesReconnect(int64_t prev_br, int64_t cur_br) {
    if (prev_br < 0 || cur_br < 0)
        return false;
    return cur_br < prev_br;
}

// Consume B/s from one window (no nominal):
//   arrived ≈ max(0, Δbytes_received) if no reconnect
//   consumed ≈ arrived - Δrecv_q
//   consume_Bps = consumed / d_wall_s
// Returns -1 if NO-DATA.
inline double deriveConsumeBps(int64_t prev_rq, int64_t cur_rq, int64_t prev_br, int64_t cur_br,
                               double d_wall_s, bool reconnect) {
    if (reconnect || !(d_wall_s > 0.0) || prev_rq < 0 || cur_rq < 0 || prev_br < 0 || cur_br < 0)
        return -1.0;
    const double arrived = static_cast<double>(cur_br - prev_br);
    if (arrived < 0.0)
        return -1.0;
    const double d_rq = static_cast<double>(cur_rq - prev_rq);
    double consumed = arrived - d_rq;
    // Clamp noise: tiny negative from sampling jitter → 0
    if (consumed < 0.0 && consumed > -4096.0)
        consumed = 0.0;
    if (consumed < 0.0)
        return -1.0;
    return consumed / d_wall_s;
}

// Backlog depth in seconds of consumption (assumption-free if consume_Bps measured).
// depth_s = recv_q / consume_Bps. Returns -1 if NO-DATA.
inline double backlogDepthSeconds(int64_t recv_q, double consume_Bps) {
    if (recv_q < 0 || !(consume_Bps > 0.0))
        return -1.0;
    return static_cast<double>(recv_q) / consume_Bps;
}

// Recv-Q vs rcv_ssthresh (receive-side). Do not use app_limited.
inline double recvQOverSsthresh(int64_t recv_q, int64_t rcv_ssthresh) {
    if (recv_q < 0 || rcv_ssthresh <= 0)
        return -1.0;
    return static_cast<double>(recv_q) / static_cast<double>(rcv_ssthresh);
}

enum class RecvQClass {
    NoData = 0,
    BacklogHeld,
    BacklogLow,
    QueueEmpty,
    Reconnect,
};

inline RecvQClass classifyRecvQ(int64_t recv_q, int64_t backlog_min, bool reconnect) {
    if (reconnect)
        return RecvQClass::Reconnect;
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
    case RecvQClass::Reconnect:
        return "RECONNECT";
    default:
        return "NO-DATA";
    }
}

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
        r.reason = "process_dead";
        return r;
    }
    if (work_delta <= 0) {
        r.reason = "no_work_delta";
        return r;
    }
    for (int i = 0; i < n; ++i) {
        if (scored[i] != 0) {
            r.reason = "counter_nonzero";
            return r;
        }
    }
    r.blind = true;
    r.reason = "all_zero_while_work_advanced";
    return r;
}

struct RecvQCampaignVerdict {
    const char* verdict = "NO-DATA";
    int held_n = 0;
    int low_n = 0;
    int empty_n = 0;
    int nodata_n = 0;
    int reconnect_n = 0;
    int ok_n = 0;
    int64_t min_recv_q = -1;
    int64_t max_recv_q = -1;
    double min_depth_s = -1.0;
    double max_depth_s = -1.0;
};

// depth_s[i] optional (-1 = unknown). Reconnect samples excluded from ok_n.
inline RecvQCampaignVerdict scoreRecvQCampaign(const int64_t* recv_q, int n, int64_t backlog_min,
                                               const int* reconnect_flags /*nullable*/,
                                               const double* depth_s /*nullable*/) {
    RecvQCampaignVerdict v;
    if (!recv_q || n <= 0)
        return v;
    for (int i = 0; i < n; ++i) {
        const bool recon = reconnect_flags && reconnect_flags[i];
        const auto c = classifyRecvQ(recv_q[i], backlog_min, recon);
        if (c == RecvQClass::Reconnect) {
            ++v.reconnect_n;
            continue;
        }
        if (c == RecvQClass::NoData) {
            ++v.nodata_n;
            continue;
        }
        ++v.ok_n;
        if (v.min_recv_q < 0 || recv_q[i] < v.min_recv_q)
            v.min_recv_q = recv_q[i];
        if (recv_q[i] > v.max_recv_q)
            v.max_recv_q = recv_q[i];
        if (depth_s && depth_s[i] >= 0.0) {
            if (v.min_depth_s < 0.0 || depth_s[i] < v.min_depth_s)
                v.min_depth_s = depth_s[i];
            if (depth_s[i] > v.max_depth_s)
                v.max_depth_s = depth_s[i];
        }
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
    if (v.held_n * 2 >= v.ok_n) {
        v.verdict = "NOT_SUPPLY_LIMITED";
        return v;
    }
    // Deep backlog in time even if byte threshold not met
    if (v.min_depth_s >= 5.0) {
        v.verdict = "NOT_SUPPLY_LIMITED";
        return v;
    }
    v.verdict = "INCONCLUSIVE";
    return v;
}

// Back-compat overload used by older tests
inline RecvQCampaignVerdict scoreRecvQCampaign(const int64_t* recv_q, int n, int64_t backlog_min) {
    return scoreRecvQCampaign(recv_q, n, backlog_min, nullptr, nullptr);
}

inline std::string formatRecvQSampleLine(int sample_i, double d_wall_s, int64_t recv_q,
                                         int64_t bytes_received, int64_t rcv_ssthresh,
                                         double consume_Bps, double depth_s, const char* four_tuple,
                                         int pid, int fd, RecvQClass cls, const char* live_tag) {
    char brbuf[32], ssbuf[32], cbuf[32], dbuf[32];
    if (bytes_received >= 0)
        std::snprintf(brbuf, sizeof(brbuf), "%lld", static_cast<long long>(bytes_received));
    else
        std::snprintf(brbuf, sizeof(brbuf), "NO-DATA");
    if (rcv_ssthresh >= 0)
        std::snprintf(ssbuf, sizeof(ssbuf), "%lld", static_cast<long long>(rcv_ssthresh));
    else
        std::snprintf(ssbuf, sizeof(ssbuf), "NO-DATA");
    if (consume_Bps >= 0.0)
        std::snprintf(cbuf, sizeof(cbuf), "%.1f", consume_Bps);
    else
        std::snprintf(cbuf, sizeof(cbuf), "NO-DATA");
    if (depth_s >= 0.0)
        std::snprintf(dbuf, sizeof(dbuf), "%.2f", depth_s);
    else
        std::snprintf(dbuf, sizeof(dbuf), "NO-DATA");
    const double rq_over_ss = recvQOverSsthresh(recv_q, rcv_ssthresh);
    char ratio[32];
    if (rq_over_ss >= 0.0)
        std::snprintf(ratio, sizeof(ratio), "%.2f", rq_over_ss);
    else
        std::snprintf(ratio, sizeof(ratio), "NO-DATA");

    char buf[640];
    std::snprintf(buf, sizeof(buf),
                  "sample=%d d_wall_s=%.3f recv_q=%lld bytes_received=%s rcv_ssthresh=%s "
                  "recv_q_over_ssthresh=%s consume_Bps=%s backlog_depth_s=%s "
                  "four_tuple=%s pid=%d fd=%d class=%s live=%s "
                  "note=no_nominal_bps_no_app_limited pin=four_tuple tag=measured",
                  sample_i, d_wall_s, static_cast<long long>(recv_q), brbuf, ssbuf, ratio, cbuf,
                  dbuf, four_tuple && four_tuple[0] ? four_tuple : "NO-DATA", pid, fd,
                  recvQClassName(cls), live_tag ? live_tag : "NO-DATA");
    return std::string(buf);
}

// Legacy signature used by older test — maps to new formatter.
inline std::string formatRecvQSampleLine(int sample_i, double d_wall_s, int64_t recv_q,
                                         int64_t bytes_received, int pid, int fd, RecvQClass cls,
                                         const char* live_tag) {
    return formatRecvQSampleLine(sample_i, d_wall_s, recv_q, bytes_received, /*ssthresh*/ -1,
                                 /*consume*/ -1.0, /*depth*/ -1.0, /*tuple*/ nullptr, pid, fd, cls,
                                 live_tag);
}

} // namespace misterplex
