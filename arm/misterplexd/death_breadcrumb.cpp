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

// Async-signal-safe write of a small fixed message.
void writeDeathSignalSafe(int sig) {
    if (g_deathPathC[0] == '\0') return;
    const int fd =
        ::open(g_deathPathC, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0644);
    if (fd < 0) return;
    // Fixed format, no libc formatting beyond digits we emit manually.
    char buf[128];
    // "death signal=NN state=N frames=... pid=...\n" — keep simple
    const char prefix[] = "death signal=";
    size_t o = 0;
    for (const char* p = prefix; *p && o + 1 < sizeof(buf); ++p) buf[o++] = *p;
    int s = sig;
    if (s < 0) s = 0;
    if (s > 99) s = 99;
    if (s >= 10) buf[o++] = static_cast<char>('0' + (s / 10));
    buf[o++] = static_cast<char>('0' + (s % 10));
    const char mid[] = " state=";
    for (const char* p = mid; *p && o + 1 < sizeof(buf); ++p) buf[o++] = *p;
    int st = g_state.load(std::memory_order_relaxed);
    if (st < 0) st = 0;
    if (st > 9) st = 9;
    buf[o++] = static_cast<char>('0' + st);
    buf[o++] = '\n';
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
    if (g_deathPath.empty()) return;
    char ts[32];
    wallTs(ts, sizeof(ts));
    char line[512];
    const int n = std::snprintf(
        line, sizeof(line),
        "ts=%s exit_code=%d why=%s state=%s frames=%lld presents=%lld pos_ms=%lld uptime_s=%lld pid=%d\n",
        ts, code, why ? why : "?",
        stateName(g_state.load(std::memory_order_relaxed)),
        static_cast<long long>(g_frames.load(std::memory_order_relaxed)),
        static_cast<long long>(g_presents.load(std::memory_order_relaxed)),
        static_cast<long long>(g_posMs.load(std::memory_order_relaxed)),
        static_cast<long long>((nowMs() - g_startMs.load(std::memory_order_relaxed)) / 1000),
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

} // namespace misterplex
