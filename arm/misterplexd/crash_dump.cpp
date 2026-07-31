#include "crash_dump.hpp"

#include <atomic>
#include <cerrno>
#include <cstdint>
#include <cstring>
#include <execinfo.h>
#include <fcntl.h>
#include <signal.h>
#include <unistd.h>

#if defined(__linux__)
#include <sys/syscall.h>
#endif

#ifndef MISTERPLEXD_BUILD_ID
#define MISTERPLEXD_BUILD_ID "unknown"
#endif

namespace misterplex {
namespace {

constexpr int kMaxFrames = 64;
constexpr size_t kNoteCap = 240;
constexpr size_t kPathCap = 256;
constexpr size_t kBuildCap = 96;

std::atomic<int> g_logFd{STDERR_FILENO};
std::atomic<int> g_crashFd{-1};
std::atomic<uintptr_t> g_loadBase{0};

char g_note[kNoteCap + 1]{};
std::atomic<int> g_noteLen{0};

char g_crashPath[kPathCap]{};
char g_buildId[kBuildCap]{};

void (*g_beforeReraise)(int) = nullptr;

// reentrancy: if we fault inside the handler, die immediately
std::atomic<int> g_dumping{0};

void asWrite(int fd, const char* s, size_t n) {
    if (fd < 0 || !s || n == 0)
        return;
    while (n > 0) {
        ssize_t w = ::write(fd, s, n);
        if (w < 0) {
            if (errno == EINTR)
                continue;
            return;
        }
        s += static_cast<size_t>(w);
        n -= static_cast<size_t>(w);
    }
}

void asWriteStr(int fd, const char* s) {
    if (!s)
        return;
    size_t n = 0;
    while (s[n])
        ++n;
    asWrite(fd, s, n);
}

char* u64ToHex(char* out, uintptr_t v) {
    static const char kHex[] = "0123456789abcdef";
    char tmp[2 * sizeof(uintptr_t)];
    int n = 0;
    if (v == 0) {
        out[0] = '0';
        out[1] = 0;
        return out;
    }
    while (v && n < static_cast<int>(sizeof(tmp))) {
        tmp[n++] = kHex[v & 0xfu];
        v >>= 4;
    }
    for (int i = 0; i < n; ++i)
        out[i] = tmp[n - 1 - i];
    out[n] = 0;
    return out;
}

char* i64ToDec(char* out, long long v) {
    char tmp[32];
    int n = 0;
    bool neg = v < 0;
    unsigned long long u =
        neg ? static_cast<unsigned long long>(-(v + 1)) + 1u : static_cast<unsigned long long>(v);
    if (u == 0) {
        out[0] = '0';
        out[1] = 0;
        return out;
    }
    while (u && n < 31) {
        tmp[n++] = static_cast<char>('0' + (u % 10u));
        u /= 10u;
    }
    int o = 0;
    if (neg)
        out[o++] = '-';
    while (n > 0)
        out[o++] = tmp[--n];
    out[o] = 0;
    return out;
}

long crashTid() {
#if defined(__NR_gettid)
    return static_cast<long>(::syscall(__NR_gettid));
#elif defined(SYS_gettid)
    return static_cast<long>(::syscall(SYS_gettid));
#else
    return static_cast<long>(::getpid());
#endif
}

uintptr_t captureLoadBase() {
    int fd = ::open("/proc/self/maps", O_RDONLY | O_CLOEXEC);
    if (fd < 0)
        return 0x10000u;
    char buf[512];
    ssize_t n = ::read(fd, buf, sizeof(buf) - 1);
    ::close(fd);
    if (n <= 0)
        return 0x10000u;
    buf[n] = 0;
    uintptr_t base = 0;
    for (int i = 0; i < n && buf[i] != '-' && buf[i] != ' '; ++i) {
        char c = buf[i];
        int d;
        if (c >= '0' && c <= '9')
            d = c - '0';
        else if (c >= 'a' && c <= 'f')
            d = 10 + c - 'a';
        else if (c >= 'A' && c <= 'F')
            d = 10 + c - 'A';
        else
            break;
        base = (base << 4) | static_cast<uintptr_t>(d);
    }
    return base ? base : 0x10000u;
}

void copyCapped(char* dst, size_t cap, const char* src) {
    if (!dst || cap == 0)
        return;
    size_t n = 0;
    if (src) {
        while (src[n] && n + 1 < cap)
            ++n;
        if (n)
            std::memcpy(dst, src, n);
    }
    dst[n] = 0;
}

int openCrashFile(const char* path) {
    if (!path || !path[0])
        return -1;
    // O_APPEND so successive crashes accumulate; O_CLOEXEC so ffmpeg children
    // do not inherit the crash fd.
    int fd = ::open(path, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0644);
    return fd;
}

void dumpToFd(int fd, int sig, const void* faultAddr, int siCode) {
    if (fd < 0)
        return;
    char num[40];
    asWriteStr(fd, "\n===== misterplexd FATAL =====\n");
    asWriteStr(fd, "build=");
    asWriteStr(fd, g_buildId[0] ? g_buildId : MISTERPLEXD_BUILD_ID);
    asWriteStr(fd, "\nsignal=");
    asWriteStr(fd, i64ToDec(num, sig));
    asWriteStr(fd, " si_code=");
    asWriteStr(fd, i64ToDec(num, siCode));
    asWriteStr(fd, " si_addr=0x");
    asWriteStr(fd, u64ToHex(num, reinterpret_cast<uintptr_t>(faultAddr)));
    asWriteStr(fd, " tid=");
    asWriteStr(fd, i64ToDec(num, crashTid()));
    asWriteStr(fd, " pid=");
    asWriteStr(fd, i64ToDec(num, static_cast<long long>(::getpid())));
    asWriteStr(fd, "\nload_base=0x");
    asWriteStr(fd, u64ToHex(num, g_loadBase.load(std::memory_order_relaxed)));
    asWriteStr(fd, "\n");

    const int nlen = g_noteLen.load(std::memory_order_acquire);
    if (nlen > 0) {
        asWriteStr(fd, "context=");
        int n = nlen;
        if (n > static_cast<int>(kNoteCap))
            n = static_cast<int>(kNoteCap);
        asWrite(fd, g_note, static_cast<size_t>(n));
        asWriteStr(fd, "\n");
    }

    void* frames[kMaxFrames];
    int nframes = ::backtrace(frames, kMaxFrames);
    asWriteStr(fd, "nframes=");
    asWriteStr(fd, i64ToDec(num, nframes));
    asWriteStr(fd, "\nraw_frames:\n");
    for (int i = 0; i < nframes; ++i) {
        asWriteStr(fd, "  #");
        asWriteStr(fd, i64ToDec(num, i));
        asWriteStr(fd, " 0x");
        asWriteStr(fd, u64ToHex(num, reinterpret_cast<uintptr_t>(frames[i])));
        asWriteStr(fd, "\n");
    }

    asWriteStr(fd, "symbols (may be bare addresses on static link):\n");
    ::backtrace_symbols_fd(frames, nframes, fd);
    asWriteStr(fd, "===== end FATAL =====\n");
    // Best-effort durability for the SD-card crash file.
    ::fsync(fd);
}

void dumpAll(int sig, const void* faultAddr, int siCode) {
    const int logFd = g_logFd.load(std::memory_order_relaxed);
    const int crashFd = g_crashFd.load(std::memory_order_relaxed);
    dumpToFd(logFd >= 0 ? logFd : STDERR_FILENO, sig, faultAddr, siCode);
    if (crashFd >= 0 && crashFd != logFd)
        dumpToFd(crashFd, sig, faultAddr, siCode);
}

void fatalHandler(int sig, siginfo_t* info, void* /*uctx*/) {
    // If we fault again while dumping, restore default and re-raise immediately.
    if (g_dumping.exchange(1) != 0) {
        struct sigaction sa;
        std::memset(&sa, 0, sizeof(sa));
        sa.sa_handler = SIG_DFL;
        sigemptyset(&sa.sa_mask);
        ::sigaction(sig, &sa, nullptr);
        ::raise(sig);
        return;
    }

    const void* faultAddr = info ? info->si_addr : nullptr;
    const int siCode = info ? info->si_code : 0;
    dumpAll(sig, faultAddr, siCode);

    if (g_beforeReraise)
        g_beforeReraise(sig);

    struct sigaction sa;
    std::memset(&sa, 0, sizeof(sa));
    sa.sa_handler = SIG_DFL;
    sigemptyset(&sa.sa_mask);
    ::sigaction(sig, &sa, nullptr);
    ::raise(sig);
}

int tryOpenCrashPaths(const char* preferred) {
    if (preferred && preferred[0]) {
        int fd = openCrashFile(preferred);
        if (fd >= 0) {
            copyCapped(g_crashPath, sizeof(g_crashPath), preferred);
            return fd;
        }
    }
    int fd = openCrashFile(kDefaultCrashPath);
    if (fd >= 0) {
        copyCapped(g_crashPath, sizeof(g_crashPath), kDefaultCrashPath);
        return fd;
    }
    fd = openCrashFile(kFallbackCrashPath);
    if (fd >= 0) {
        copyCapped(g_crashPath, sizeof(g_crashPath), kFallbackCrashPath);
        return fd;
    }
    g_crashPath[0] = 0;
    return -1;
}

} // namespace

void crashDumpInit(int logFd, const char* crashPath, const char* buildId) {
    if (logFd >= 0) {
        int d = ::dup(logFd);
        if (d >= 0) {
            int fl = ::fcntl(d, F_GETFD);
            if (fl >= 0)
                ::fcntl(d, F_SETFD, fl | FD_CLOEXEC);
            g_logFd.store(d, std::memory_order_relaxed);
        } else {
            g_logFd.store(logFd, std::memory_order_relaxed);
        }
    } else {
        int d = ::dup(STDERR_FILENO);
        if (d >= 0) {
            int fl = ::fcntl(d, F_GETFD);
            if (fl >= 0)
                ::fcntl(d, F_SETFD, fl | FD_CLOEXEC);
            g_logFd.store(d, std::memory_order_relaxed);
        } else {
            g_logFd.store(STDERR_FILENO, std::memory_order_relaxed);
        }
    }

    // Close previous crash fd if re-init (unit tests).
    int old = g_crashFd.exchange(-1, std::memory_order_relaxed);
    if (old >= 0)
        ::close(old);

    int cfd = tryOpenCrashPaths(crashPath);
    g_crashFd.store(cfd, std::memory_order_relaxed);

    g_loadBase.store(captureLoadBase(), std::memory_order_relaxed);

    if (buildId && buildId[0])
        copyCapped(g_buildId, sizeof(g_buildId), buildId);
    else
        copyCapped(g_buildId, sizeof(g_buildId), MISTERPLEXD_BUILD_ID);
}

void crashDumpNote(const char* msg) {
    if (!msg)
        msg = "";
    size_t n = 0;
    while (msg[n] && n < kNoteCap)
        ++n;
    g_noteLen.store(0, std::memory_order_release);
    if (n)
        std::memcpy(g_note, msg, n);
    g_note[n] = 0;
    g_noteLen.store(static_cast<int>(n), std::memory_order_release);
}

void crashDumpNoteKey(const char* key, const char* sessionId) {
    char buf[kNoteCap + 1];
    size_t o = 0;
    auto append = [&](const char* s) {
        if (!s)
            return;
        while (*s && o < kNoteCap)
            buf[o++] = *s++;
    };
    append("key=");
    append(key && key[0] ? key : "-");
    if (sessionId && sessionId[0]) {
        append(" session=");
        append(sessionId);
    }
    buf[o] = 0;
    crashDumpNote(buf);
}

void crashDumpInstall(void (*on_before_reraise)(int sig)) {
    g_beforeReraise = on_before_reraise;
    g_dumping.store(0, std::memory_order_relaxed);

    struct sigaction sa;
    std::memset(&sa, 0, sizeof(sa));
    sa.sa_sigaction = fatalHandler;
    // SA_RESETHAND: nested fault dies immediately.
    sa.sa_flags = SA_SIGINFO | SA_RESETHAND;
    sigemptyset(&sa.sa_mask);
    sigaddset(&sa.sa_mask, SIGSEGV);
    sigaddset(&sa.sa_mask, SIGABRT);
    sigaddset(&sa.sa_mask, SIGBUS);
    sigaddset(&sa.sa_mask, SIGFPE);
    sigaddset(&sa.sa_mask, SIGILL);
    sigaddset(&sa.sa_mask, SIGQUIT);
    const int fatals[] = {SIGSEGV, SIGABRT, SIGBUS, SIGFPE, SIGILL, SIGQUIT};
    for (size_t i = 0; i < sizeof(fatals) / sizeof(fatals[0]); ++i)
        ::sigaction(fatals[i], &sa, nullptr);
}

void crashDumpWriteNow(int sig, const void* faultAddr, int siCode) {
    dumpAll(sig, faultAddr, siCode);
}

const char* crashDumpPath() { return g_crashPath; }

} // namespace misterplex
