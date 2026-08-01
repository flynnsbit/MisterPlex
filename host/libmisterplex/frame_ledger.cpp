#include "libmisterplex/frame_ledger.hpp"

#include <fcntl.h>
#include <unistd.h>

#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <ctime>
#include <fstream>
#include <mutex>
#include <string>

namespace misterplex {
namespace {

std::string g_path;
std::mutex g_mu;
bool g_inited = false;

void wallTs(char* buf, size_t n) {
    const auto t = std::chrono::system_clock::now();
    const std::time_t sec = std::chrono::system_clock::to_time_t(t);
    std::tm tm{};
    gmtime_r(&sec, &tm);
    std::snprintf(buf, n, "%04d-%02d-%02dT%02d:%02d:%02dZ", tm.tm_year + 1900, tm.tm_mon + 1,
                  tm.tm_mday, tm.tm_hour, tm.tm_min, tm.tm_sec);
}

void appendLine(const char* line, size_t n) {
    if (g_path.empty() || !line || n == 0)
        return;
    const int fd = ::open(g_path.c_str(), O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0644);
    if (fd < 0)
        return;
    (void)::write(fd, line, n);
    ::close(fd);
}

} // namespace

void frameLedgerSetPathForTest(const std::string& path) {
    std::lock_guard<std::mutex> lk(g_mu);
    g_path = path;
    g_inited = true;
}

void frameLedgerInit(const std::string& confDir) {
    std::lock_guard<std::mutex> lk(g_mu);
    if (g_path.empty()) {
        const std::string base = confDir.empty() ? std::string(".") : confDir;
        g_path = base + "/misterplexd.frame_ledger";
    }
    g_inited = true;
}

void frameLedgerProcessStart(int64_t lifetimeFrames, int64_t lifetimePresents,
                             int64_t lifetimeDrops) {
    std::lock_guard<std::mutex> lk(g_mu);
    if (!g_inited || g_path.empty())
        return;
    char ts[32];
    wallTs(ts, sizeof(ts));
    char line[512];
    const int n = std::snprintf(
        line, sizeof(line),
        "ts=%s event=process_start pid=%d lifetime_frames=%lld lifetime_presents=%lld "
        "lifetime_drops=%lld\n",
        ts, static_cast<int>(::getpid()), static_cast<long long>(lifetimeFrames),
        static_cast<long long>(lifetimePresents), static_cast<long long>(lifetimeDrops));
    if (n > 0)
        appendLine(line, static_cast<size_t>(n));
    std::fprintf(stderr,
                 "misterplexd: FRAME_LEDGER event=process_start path=%s pid=%d\n", g_path.c_str(),
                 static_cast<int>(::getpid()));
}

void frameLedgerSessionEnd(uint64_t sessionId, int64_t frames, int64_t presents, int64_t drops,
                           const char* reason, int64_t publishMisses) {
    std::lock_guard<std::mutex> lk(g_mu);
    if (!g_inited || g_path.empty())
        return;
    const int64_t residual = frameLedgerResidual(frames, presents, drops);
    char ts[32];
    wallTs(ts, sizeof(ts));
    char line[768];
    const int n = std::snprintf(
        line, sizeof(line),
        "ts=%s event=session_end pid=%d session=%llu frames=%lld presents=%lld drops=%lld "
        "publish_misses=%lld unaccounted=%lld residual=%lld "
        "unaccounted_eq=frames-presents-drops scope=ARM_PUBLISH_NOT_DISPLAY reason=%s tag=measured\n",
        ts, static_cast<int>(::getpid()), static_cast<unsigned long long>(sessionId),
        static_cast<long long>(frames), static_cast<long long>(presents),
        static_cast<long long>(drops), static_cast<long long>(publishMisses),
        static_cast<long long>(residual), static_cast<long long>(residual),
        reason ? reason : "?");
    if (n > 0)
        appendLine(line, static_cast<size_t>(n));
    std::fprintf(stderr,
                 "misterplexd: FRAME_LEDGER event=session_end session=%llu frames=%lld "
                 "presents=%lld drops=%lld publish_misses=%lld unaccounted=%lld "
                 "residual=%lld scope=ARM_PUBLISH_NOT_DISPLAY reason=%s tag=measured\n",
                 static_cast<unsigned long long>(sessionId), static_cast<long long>(frames),
                 static_cast<long long>(presents), static_cast<long long>(drops),
                 static_cast<long long>(publishMisses), static_cast<long long>(residual),
                 static_cast<long long>(residual), reason ? reason : "?");
}

void frameLedgerProcessExit(int code, const char* why, int64_t lifetimeFrames,
                            int64_t lifetimePresents, int64_t lifetimeDrops, int64_t uptimeS) {
    std::lock_guard<std::mutex> lk(g_mu);
    if (!g_inited || g_path.empty())
        return;
    char ts[32];
    wallTs(ts, sizeof(ts));
    char line[640];
    const int n = std::snprintf(
        line, sizeof(line),
        "ts=%s event=process_exit pid=%d code=%d why=%s uptime_s=%lld lifetime_frames=%lld "
        "lifetime_presents=%lld lifetime_drops=%lld\n",
        ts, static_cast<int>(::getpid()), code, why ? why : "?",
        static_cast<long long>(uptimeS), static_cast<long long>(lifetimeFrames),
        static_cast<long long>(lifetimePresents), static_cast<long long>(lifetimeDrops));
    if (n > 0)
        appendLine(line, static_cast<size_t>(n));
}

bool frameLedgerSumFile(const std::string& path, FrameLedgerTotals* out) {
    if (!out)
        return false;
    *out = FrameLedgerTotals{};
    std::ifstream in(path);
    if (!in)
        return false;
    std::string line;
    while (std::getline(in, line)) {
        if (line.find("event=process_start") != std::string::npos)
            ++out->processStarts;
        else if (line.find("event=process_exit") != std::string::npos)
            ++out->processExits;
        else if (line.find("event=session_end") != std::string::npos) {
            ++out->sessionEnds;
            auto grab = [&](const char* key) -> int64_t {
                const std::string k = std::string(key) + "=";
                const auto p = line.find(k);
                if (p == std::string::npos)
                    return 0;
                return std::strtoll(line.c_str() + p + k.size(), nullptr, 10);
            };
            out->frames += grab("frames");
            out->presents += grab("presents");
            out->drops += grab("drops");
            out->publish_misses += grab("publish_misses");
            out->residual += grab("residual");
        }
    }
    return true;
}

} // namespace misterplex
