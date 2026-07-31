#include "death_breadcrumb.hpp"

#include <fcntl.h>
#include <unistd.h>

#include <chrono>
#include <cstdio>
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
std::mutex g_pathMu;
bool g_inited = false;

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
    if (g_deathPathC[0] == '\0' || !info) return;
    const int fd =
        ::open(g_deathPathC, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0644);
    if (fd < 0) return;
    char buf[256];
    size_t o = 0;
    asAppend(buf, sizeof(buf), &o, "death signal=");
    asAppendInt(buf, sizeof(buf), &o, info->si_signo);
    asAppend(buf, sizeof(buf), &o, " si_code=");
    asAppendInt(buf, sizeof(buf), &o, info->si_code);
    asAppend(buf, sizeof(buf), &o, " si_pid=");
    asAppendInt(buf, sizeof(buf), &o, static_cast<long>(info->si_pid));
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

void deathBreadcrumbExit(int code, const char* why) {
    std::lock_guard<std::mutex> lk(g_pathMu);
    char ts[32];
    wallTs(ts, sizeof(ts));
    const int64_t startMs = g_startMs.load(std::memory_order_relaxed);
    const int64_t uptimeS =
        (g_inited && startMs > 0) ? (nowMs() - startMs) / 1000 : 0;
    // Choke-point log: ALWAYS to stderr so a missing death file cannot hide exits.
    // why must name call site + signal/context (never empty "clean").
    std::fprintf(stderr,
                 "misterplexd: EXIT_REASON code=%d why=%s state=%s frames=%lld presents=%lld "
                 "pos_ms=%lld uptime_s=%lld pid=%d death_path=%s\n",
                 code, why ? why : "?",
                 stateName(g_state.load(std::memory_order_relaxed)),
                 static_cast<long long>(g_frames.load(std::memory_order_relaxed)),
                 static_cast<long long>(g_presents.load(std::memory_order_relaxed)),
                 static_cast<long long>(g_posMs.load(std::memory_order_relaxed)),
                 static_cast<long long>(uptimeS), static_cast<int>(::getpid()),
                 g_deathPath.empty() ? "(unset)" : g_deathPath.c_str());
    if (g_deathPath.empty()) return;
    char line[512];
    const int n = std::snprintf(
        line, sizeof(line),
        "ts=%s exit_code=%d why=%s state=%s frames=%lld presents=%lld pos_ms=%lld uptime_s=%lld pid=%d\n",
        ts, code, why ? why : "?",
        stateName(g_state.load(std::memory_order_relaxed)),
        static_cast<long long>(g_frames.load(std::memory_order_relaxed)),
        static_cast<long long>(g_presents.load(std::memory_order_relaxed)),
        static_cast<long long>(g_posMs.load(std::memory_order_relaxed)),
        static_cast<long long>(uptimeS),
        static_cast<int>(::getpid()));
    if (n <= 0) return;
    const int fd = ::open(g_deathPath.c_str(), O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0644);
    if (fd < 0) return;
    (void)::write(fd, line, static_cast<size_t>(n));
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
