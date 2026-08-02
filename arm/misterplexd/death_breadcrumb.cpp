#include "death_breadcrumb.hpp"

#include <fcntl.h>
#include <unistd.h>

#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <ctime>
#include <cstring>
#include <mutex>
#include <string>

namespace misterplex {
namespace {

std::string g_lastPath;
std::string g_deathPath;
// Fixed buffers for async-signal-safe path (set once at init).
char g_deathPathC[512] = {};
char g_lastPathC[512] = {};
std::atomic<int> g_state{static_cast<int>(DeathState::Boot)};
std::atomic<int64_t> g_frames{0};
std::atomic<int64_t> g_presents{0};
std::atomic<int64_t> g_posMs{0};
std::atomic<int64_t> g_startMs{0};
std::atomic<int64_t> g_lastWriteMs{0};
// Last fatal/stop signal snapshot (set by OnSig*/read by Exit). 0 = none.
std::atomic<int> g_lastSig{0};
std::atomic<int> g_lastSiCode{0};
std::atomic<int> g_lastSiPid{0};
// Sender attribution captured outside signal context (CaptureSender).
// Fixed buffers — written once per exit, read by Exit.
char g_senderStatus[16] = "UNSET";
char g_senderCmd[256] = {};
char g_senderComm[64] = {};
char g_senderChain[512] = {};
std::mutex g_pathMu;
bool g_inited = false;

// Collapse whitespace / NULs to single spaces; truncate into dst.
void copyFlat(char* dst, size_t dstCap, const char* src, size_t srcLen) {
    if (!dst || dstCap == 0)
        return;
    size_t o = 0;
    bool sp = false;
    for (size_t i = 0; i < srcLen && o + 1 < dstCap; ++i) {
        unsigned char c = static_cast<unsigned char>(src[i]);
        if (c == '\0' || c == '\n' || c == '\r' || c == '\t' || c == ' ') {
            if (o > 0)
                sp = true;
            continue;
        }
        if (sp && o + 1 < dstCap) {
            dst[o++] = ' ';
            sp = false;
        }
        // Keep printable-ish argv; drop control bytes.
        if (c >= 32 && c < 127)
            dst[o++] = static_cast<char>(c);
    }
    dst[o] = '\0';
}

bool readFileFlat(const char* path, char* dst, size_t dstCap) {
    if (!dst || dstCap == 0)
        return false;
    dst[0] = '\0';
    const int fd = ::open(path, O_RDONLY | O_CLOEXEC);
    if (fd < 0)
        return false;
    char buf[512];
    const ssize_t n = ::read(fd, buf, sizeof(buf));
    ::close(fd);
    if (n <= 0)
        return false;
    copyFlat(dst, dstCap, buf, static_cast<size_t>(n));
    return dst[0] != '\0';
}

int readPpid(int pid) {
    char path[64];
    std::snprintf(path, sizeof(path), "/proc/%d/status", pid);
    const int fd = ::open(path, O_RDONLY | O_CLOEXEC);
    if (fd < 0)
        return -1;
    char buf[256];
    const ssize_t n = ::read(fd, buf, sizeof(buf) - 1);
    ::close(fd);
    if (n <= 0)
        return -1;
    buf[n] = '\0';
    const char* p = std::strstr(buf, "PPid:");
    if (!p)
        return -1;
    p += 5;
    while (*p == ' ' || *p == '\t')
        ++p;
    return static_cast<int>(std::strtol(p, nullptr, 10));
}

int64_t nowMs() {
    using namespace std::chrono;
    return duration_cast<milliseconds>(steady_clock::now().time_since_epoch()).count();
}

const char* stateName(int s) {
    switch (static_cast<DeathState>(s)) {
    case DeathState::Boot: return "boot";
    case DeathState::Idle: return "idle";
    case DeathState::Playing: return "playing";
    case DeathState::Paused: return "paused";
    case DeathState::Stopping: return "stopping";
    case DeathState::Seeking: return "seeking";
    }
    return "unknown";
}

// Best-effort wall clock for logs (not async-safe).
void wallTs(char* buf, size_t n) {
    const auto t = std::chrono::system_clock::now();
    const std::time_t sec = std::chrono::system_clock::to_time_t(t);
    std::tm tm{};
    gmtime_r(&sec, &tm);
    std::snprintf(buf, n, "%04d-%02d-%02dT%02d:%02d:%02dZ", tm.tm_year + 1900, tm.tm_mon + 1,
                  tm.tm_mday, tm.tm_hour, tm.tm_min, tm.tm_sec);
}

void writeLastUnlocked(bool /*force*/) {
    if (g_lastPath.empty()) return;
    char ts[32];
    wallTs(ts, sizeof(ts));
    const int64_t start = g_startMs.load(std::memory_order_relaxed);
    const int64_t up =
        start > 0 ? (nowMs() - start) / 1000 : 0;
    char line[512];
    const int n = std::snprintf(
        line, sizeof(line),
        "ts=%s state=%s frames=%lld presents=%lld pos_ms=%lld uptime_s=%lld pid=%d\n", ts,
        stateName(g_state.load(std::memory_order_relaxed)),
        static_cast<long long>(g_frames.load(std::memory_order_relaxed)),
        static_cast<long long>(g_presents.load(std::memory_order_relaxed)),
        static_cast<long long>(g_posMs.load(std::memory_order_relaxed)),
        static_cast<long long>(up), static_cast<int>(::getpid()));
    if (n <= 0) return;
    // Atomic replace via tmp+rename when possible.
    const std::string tmp = g_lastPath + ".tmp";
    const int fd = ::open(tmp.c_str(), O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0644);
    if (fd < 0) return;
    const ssize_t w = ::write(fd, line, static_cast<size_t>(n));
    ::close(fd);
    if (w == n) ::rename(tmp.c_str(), g_lastPath.c_str());
    else ::unlink(tmp.c_str());
    g_lastWriteMs.store(nowMs(), std::memory_order_relaxed);
}

// ---- async-signal-safe helpers (no libc formatting, no heap) ----

void asAppend(char* buf, size_t cap, size_t* o, const char* s) {
    if (!s || !o) return;
    while (*s && *o + 1 < cap) buf[(*o)++] = *s++;
}

void asAppendInt(char* buf, size_t cap, size_t* o, long v) {
    if (!o || *o + 1 >= cap) return;
    if (v < 0) {
        buf[(*o)++] = '-';
        if (v == (-2147483647L - 1L)) v = 2147483647L;
        else v = -v;
    }
    char tmp[24];
    int n = 0;
    if (v == 0) tmp[n++] = '0';
    while (v > 0 && n < static_cast<int>(sizeof(tmp))) {
        tmp[n++] = static_cast<char>('0' + (v % 10));
        v /= 10;
    }
    while (n > 0 && *o + 1 < cap) buf[(*o)++] = tmp[--n];
}

void asAppendHexPtr(char* buf, size_t cap, size_t* o, unsigned long v) {
    asAppend(buf, cap, o, "0x");
    int started = 0;
    for (int shift = static_cast<int>(sizeof(void*) * 8) - 4; shift >= 0; shift -= 4) {
        const unsigned nibble = static_cast<unsigned>((v >> shift) & 0xfu);
        if (!started && nibble == 0 && shift > 0) continue;
        started = 1;
        const char c = static_cast<char>(nibble < 10 ? '0' + nibble : 'a' + (nibble - 10));
        if (*o + 1 < cap) buf[(*o)++] = c;
    }
    if (!started && *o + 1 < cap) buf[(*o)++] = '0';
}

void writeDeathSignalSafe(int sig) {
    g_lastSig.store(sig, std::memory_order_relaxed);
    g_lastSiCode.store(0, std::memory_order_relaxed);
    g_lastSiPid.store(0, std::memory_order_relaxed);
    if (g_deathPathC[0] == '\0') return;
    const int fd =
        ::open(g_deathPathC, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0644);
    if (fd < 0) return;
    char buf[128];
    size_t o = 0;
    asAppend(buf, sizeof(buf), &o, "death signal=");
    asAppendInt(buf, sizeof(buf), &o, sig);
    asAppend(buf, sizeof(buf), &o, " state=");
    asAppendInt(buf, sizeof(buf), &o, g_state.load(std::memory_order_relaxed));
    asAppend(buf, sizeof(buf), &o, "\n");
    (void)::write(fd, buf, o);
    ::close(fd);
}

void writeDeathSigInfoSafe(const siginfo_t* info) {
    if (!info) return;
    g_lastSig.store(info->si_signo, std::memory_order_relaxed);
    g_lastSiCode.store(info->si_code, std::memory_order_relaxed);
    g_lastSiPid.store(static_cast<int>(info->si_pid), std::memory_order_relaxed);
    if (g_deathPathC[0] == '\0') return;
    const int fd =
        ::open(g_deathPathC, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0644);
    if (fd < 0) return;
    char buf[320];
    size_t o = 0;
    asAppend(buf, sizeof(buf), &o, "death signal=");
    asAppendInt(buf, sizeof(buf), &o, info->si_signo);
    asAppend(buf, sizeof(buf), &o, " si_code=");
    asAppendInt(buf, sizeof(buf), &o, info->si_code);
    // Linux: SI_USER=0 (kill/raise), SI_KERNEL=0x80. Highest-value race-free bit.
    asAppend(buf, sizeof(buf), &o, " si_code_name=");
    if (info->si_code == 0)
        asAppend(buf, sizeof(buf), &o, "SI_USER");
    else if (info->si_code == 0x80)
        asAppend(buf, sizeof(buf), &o, "SI_KERNEL");
    else
        asAppend(buf, sizeof(buf), &o, "OTHER");
    asAppend(buf, sizeof(buf), &o, " si_pid=");
    asAppendInt(buf, sizeof(buf), &o, static_cast<long>(info->si_pid));
    asAppend(buf, sizeof(buf), &o, " si_uid=");
    asAppendInt(buf, sizeof(buf), &o, static_cast<long>(info->si_uid));
    asAppend(buf, sizeof(buf), &o, " si_addr=");
    asAppendHexPtr(buf, sizeof(buf), &o,
                   static_cast<unsigned long>(reinterpret_cast<uintptr_t>(info->si_addr)));
    asAppend(buf, sizeof(buf), &o, " state=");
    asAppendInt(buf, sizeof(buf), &o, g_state.load(std::memory_order_relaxed));
    asAppend(buf, sizeof(buf), &o, " pid=");
    asAppendInt(buf, sizeof(buf), &o, static_cast<long>(::getpid()));
    asAppend(buf, sizeof(buf), &o, "\n");
    (void)::write(fd, buf, o);
    ::close(fd);
}

} // namespace

void deathBreadcrumbInit(const std::string& confDir) {
    std::lock_guard<std::mutex> lk(g_pathMu);
    if (!g_inited) {
        g_startMs.store(nowMs(), std::memory_order_relaxed);
        g_inited = true;
    }
    if (g_lastPath.empty()) {
        const std::string base = confDir.empty() ? std::string(".") : confDir;
        g_lastPath = base + "/misterplexd.last";
        g_deathPath = base + "/misterplexd.death";
    }
    std::snprintf(g_lastPathC, sizeof(g_lastPathC), "%s", g_lastPath.c_str());
    std::snprintf(g_deathPathC, sizeof(g_deathPathC), "%s", g_deathPath.c_str());
    g_state.store(static_cast<int>(DeathState::Boot), std::memory_order_relaxed);
    writeLastUnlocked(true);
}

void deathBreadcrumbSetPathsForTest(const std::string& lastPath, const std::string& deathPath) {
    std::lock_guard<std::mutex> lk(g_pathMu);
    g_lastPath = lastPath;
    g_deathPath = deathPath;
    std::snprintf(g_lastPathC, sizeof(g_lastPathC), "%s", g_lastPath.c_str());
    std::snprintf(g_deathPathC, sizeof(g_deathPathC), "%s", g_deathPath.c_str());
    if (!g_inited) {
        g_startMs.store(nowMs(), std::memory_order_relaxed);
        g_inited = true;
    }
}

void deathBreadcrumbUpdate(DeathState st, int64_t frames, int64_t presents, int64_t posMs,
                           bool force) {
    g_state.store(static_cast<int>(st), std::memory_order_relaxed);
    g_frames.store(frames, std::memory_order_relaxed);
    g_presents.store(presents, std::memory_order_relaxed);
    g_posMs.store(posMs, std::memory_order_relaxed);
    if (!force) {
        const int64_t last = g_lastWriteMs.load(std::memory_order_relaxed);
        if (last != 0 && (nowMs() - last) < 5000) return;
    }
    std::lock_guard<std::mutex> lk(g_pathMu);
    if (g_lastPath.empty()) return;
    writeLastUnlocked(force);
}

int64_t deathBreadcrumbUptimeS() {
    const int64_t startMs = g_startMs.load(std::memory_order_relaxed);
    if (!g_inited || startMs <= 0)
        return 0;
    return (nowMs() - startMs) / 1000;
}

void deathBreadcrumbCaptureSender(int sender_pid) {
    // Outside signal context — may use stdio and /proc. Call ASAP after g_stop.
    // Note: parameter must NOT be named si_pid — glibc signal.h macros that name.
    std::lock_guard<std::mutex> lk(g_pathMu);
    g_senderCmd[0] = '\0';
    g_senderComm[0] = '\0';
    g_senderChain[0] = '\0';
    if (sender_pid <= 0) {
        std::snprintf(g_senderStatus, sizeof(g_senderStatus), "NONE");
        std::snprintf(g_senderCmd, sizeof(g_senderCmd), "(no_si_pid)");
        std::snprintf(g_senderChain, sizeof(g_senderChain), "(none)");
    } else {
        char path[64];
        std::snprintf(path, sizeof(path), "/proc/%d/cmdline", sender_pid);
        const bool liveCmd = readFileFlat(path, g_senderCmd, sizeof(g_senderCmd));
        std::snprintf(path, sizeof(path), "/proc/%d/comm", sender_pid);
        (void)readFileFlat(path, g_senderComm, sizeof(g_senderComm));
        if (!liveCmd && g_senderComm[0] == '\0') {
            // pid gone before capture — NO-DATA, never invent "nobody".
            std::snprintf(g_senderStatus, sizeof(g_senderStatus), "GONE");
            std::snprintf(g_senderCmd, sizeof(g_senderCmd), "(pid_gone si_pid=%d)",
                          sender_pid);
            std::snprintf(g_senderChain, sizeof(g_senderChain), "%d:(gone)", sender_pid);
        } else {
            std::snprintf(g_senderStatus, sizeof(g_senderStatus), "LIVE");
            if (g_senderCmd[0] == '\0' && g_senderComm[0] != '\0')
                std::snprintf(g_senderCmd, sizeof(g_senderCmd), "(%s)", g_senderComm);
            // Walk PPid chain (operator ssh/bash vs resident killer).
            size_t o = 0;
            auto append = [&](const char* s) {
                while (s && *s && o + 1 < sizeof(g_senderChain))
                    g_senderChain[o++] = *s++;
            };
            char num[16];
            std::snprintf(num, sizeof(num), "%d", sender_pid);
            append(num);
            append(":");
            append(g_senderCmd[0] ? g_senderCmd : "?");
            int walk = readPpid(sender_pid);
            for (int depth = 0; depth < 6 && walk > 1; ++depth) {
                char ccmd[128] = {};
                char ccomm[64] = {};
                std::snprintf(path, sizeof(path), "/proc/%d/cmdline", walk);
                const bool ok = readFileFlat(path, ccmd, sizeof(ccmd));
                std::snprintf(path, sizeof(path), "/proc/%d/comm", walk);
                (void)readFileFlat(path, ccomm, sizeof(ccomm));
                append(" <- ");
                std::snprintf(num, sizeof(num), "%d", walk);
                append(num);
                append(":");
                if (ok && ccmd[0])
                    append(ccmd);
                else if (ccomm[0])
                    append(ccomm);
                else {
                    append("(gone)");
                    break;
                }
                walk = readPpid(walk);
            }
            g_senderChain[o] = '\0';
        }
    }
    // Immediate witness on disk — survives if later teardown hangs.
    if (g_deathPath.empty())
        return;
    char ts[32];
    wallTs(ts, sizeof(ts));
    char line[1536];
    const int n = std::snprintf(
        line, sizeof(line),
        "ts=%s sender_capture si_pid=%d sender_status=%s sender_comm=%s sender_cmd=%s "
        "sender_chain=%s pid=%d\n",
        ts, sender_pid, g_senderStatus, g_senderComm[0] ? g_senderComm : "?",
        g_senderCmd[0] ? g_senderCmd : "?", g_senderChain[0] ? g_senderChain : "?",
        static_cast<int>(::getpid()));
    if (n <= 0)
        return;
    // Append-style second line would race; write dedicated sender file + stderr.
    std::fprintf(stderr, "misterplexd: SENDER_CAPTURE %s", line);
    const std::string senderPath = g_deathPath + ".sender";
    const int fd = ::open(senderPath.c_str(), O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0644);
    if (fd >= 0) {
        (void)::write(fd, line, static_cast<size_t>(n));
        ::close(fd);
    }
}

const char* deathBreadcrumbSenderStatus() { return g_senderStatus; }
const char* deathBreadcrumbSenderCmd() { return g_senderCmd[0] ? g_senderCmd : "(unset)"; }
const char* deathBreadcrumbSenderChain() {
    return g_senderChain[0] ? g_senderChain : "(unset)";
}

void deathBreadcrumbExit(int code, const char* why) {
    std::lock_guard<std::mutex> lk(g_pathMu);
    char ts[32];
    wallTs(ts, sizeof(ts));
    const int64_t uptimeS = deathBreadcrumbUptimeS();
    const int lastSig = g_lastSig.load(std::memory_order_relaxed);
    const int lastCode = g_lastSiCode.load(std::memory_order_relaxed);
    const int lastPid = g_lastSiPid.load(std::memory_order_relaxed);
    const char* siName = "NONE";
    if (lastSig != 0) {
        if (lastCode == 0)
            siName = "SI_USER";
        else if (lastCode == 0x80)
            siName = "SI_KERNEL";
        else
            siName = "OTHER";
    }
    const char* senderSt = g_senderStatus;
    const char* senderCmd = g_senderCmd[0] ? g_senderCmd : "(unset)";
    const char* senderComm = g_senderComm[0] ? g_senderComm : "(unset)";
    const char* senderChain = g_senderChain[0] ? g_senderChain : "(unset)";
    // Choke-point log: ALWAYS to stderr so a missing death file cannot hide exits.
    // why must name call site + signal/context (never empty "clean").
    // Keep si_* + sender_* as first-class fields for SUPERVISE_EXIT / operator vs 3p.
    std::fprintf(stderr,
                 "misterplexd: EXIT_REASON code=%d why=%s state=%s frames=%lld presents=%lld "
                 "pos_ms=%lld uptime_s=%lld pid=%d signal=%d si_code=%d si_code_name=%s "
                 "si_pid=%d sender_status=%s sender_comm=%s sender_cmd=%s sender_chain=%s "
                 "death_path=%s\n",
                 code, why ? why : "?",
                 stateName(g_state.load(std::memory_order_relaxed)),
                 static_cast<long long>(g_frames.load(std::memory_order_relaxed)),
                 static_cast<long long>(g_presents.load(std::memory_order_relaxed)),
                 static_cast<long long>(g_posMs.load(std::memory_order_relaxed)),
                 static_cast<long long>(uptimeS), static_cast<int>(::getpid()), lastSig,
                 lastCode, siName, lastPid, senderSt, senderComm, senderCmd, senderChain,
                 g_deathPath.empty() ? "(unset)" : g_deathPath.c_str());
    if (g_deathPath.empty())
        return;
    char line[1536];
    const int n = std::snprintf(
        line, sizeof(line),
        "ts=%s exit_code=%d why=%s state=%s frames=%lld presents=%lld pos_ms=%lld "
        "uptime_s=%lld pid=%d signal=%d si_code=%d si_code_name=%s si_pid=%d "
        "sender_status=%s sender_comm=%s sender_cmd=%s sender_chain=%s\n",
        ts, code, why ? why : "?",
        stateName(g_state.load(std::memory_order_relaxed)),
        static_cast<long long>(g_frames.load(std::memory_order_relaxed)),
        static_cast<long long>(g_presents.load(std::memory_order_relaxed)),
        static_cast<long long>(g_posMs.load(std::memory_order_relaxed)),
        static_cast<long long>(uptimeS), static_cast<int>(::getpid()), lastSig, lastCode,
        siName, lastPid, senderSt, senderComm, senderCmd, senderChain);
    if (n <= 0)
        return;
    const int fd = ::open(g_deathPath.c_str(), O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0644);
    if (fd < 0)
        return;
    (void)::write(fd, line, static_cast<size_t>(n > 0 ? static_cast<size_t>(n) : 0));
    ::close(fd);
    writeLastUnlocked(true);
}

void deathBreadcrumbOnSignal(int sig) {
    writeDeathSignalSafe(sig);
}

void deathBreadcrumbOnSigInfo(const siginfo_t* info) {
    if (!info) {
        writeDeathSignalSafe(-1);
        return;
    }
    writeDeathSigInfoSafe(info);
}

} // namespace misterplex
