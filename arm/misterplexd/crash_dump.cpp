#include "crash_dump.hpp"

#include <atomic>
#include <cerrno>
#include <cstdint>
#include <cstring>
#include <execinfo.h>
#include <fcntl.h>
#include <signal.h>
#include <unistd.h>

// gettid: glibc 2.30+; MiSTer static builds may be older — fall back to syscall.
#if defined(__linux__)
#include <sys/syscall.h>
#endif

namespace misterplex {
namespace {

constexpr int kMaxFrames = 64;
constexpr size_t kNoteCap = 240;

// Pre-opened dump destination. STDERR_FILENO is valid from process start; init
// may replace it with a dup of the redirected log.
std::atomic<int> g_logFd{STDERR_FILENO};

// Executable load base captured at init (first PT_LOAD VirtAddr from maps, or
// the link-time base for non-PIE static ARM which is typically 0x10000).
std::atomic<uintptr_t> g_loadBase{0};

// Plain C buffer: signal handler only reads; writers copy then publish length.
char g_note[kNoteCap + 1]{};
std::atomic<int> g_noteLen{0};

void (*g_beforeReraise)(int) = nullptr;

// --- async-signal-safe helpers ------------------------------------------------

void asWrite(int fd, const char* s, size_t n) {
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

// lowercase hex, no leading 0x. buf must hold >= 2*sizeof(uintptr_t)+1.
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
    // Non-PIE static EXEC: first LOAD VirtAddr is the link base (0x10000 on our
    // armhf toolchain). Prefer /proc/self/maps so PIE builds still work.
    int fd = ::open("/proc/self/maps", O_RDONLY | O_CLOEXEC);
    if (fd < 0)
        return 0x10000u; // documented fallback for this static ARM link
    char buf[512];
    ssize_t n = ::read(fd, buf, sizeof(buf) - 1);
    ::close(fd);
    if (n <= 0)
        return 0x10000u;
    buf[n] = 0;
    // First line: "00010000-0005d000 r-xp ... /path/misterplexd"
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

void dumpToFd(int fd, int sig, const void* faultAddr) {
    char num[40];
    asWriteStr(fd, "\n===== misterplexd FATAL =====\n");
    asWriteStr(fd, "signal=");
    asWriteStr(fd, i64ToDec(num, sig));
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
        // Bound to published length; buffer may be mid-update.
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

    // Static glibc typically cannot resolve symbols; still emit for hosts that can.
    asWriteStr(fd, "symbols (may be bare addresses on static link):\n");
    ::backtrace_symbols_fd(frames, nframes, fd);
    asWriteStr(fd, "===== end FATAL =====\n");
}

void fatalHandler(int sig, siginfo_t* info, void* /*uctx*/) {
    const int fd = g_logFd.load(std::memory_order_relaxed);
    // si_addr is a macro on Linux (expands via siginfo union) — use only as field.
    const void* faultAddr = info ? info->si_addr : nullptr;
    dumpToFd(fd >= 0 ? fd : STDERR_FILENO, sig, faultAddr);

    if (g_beforeReraise)
        g_beforeReraise(sig);

    // Ensure default disposition then re-raise so supervisor sees rc=128+sig.
    struct sigaction sa;
    std::memset(&sa, 0, sizeof(sa));
    sa.sa_handler = SIG_DFL;
    sigemptyset(&sa.sa_mask);
    ::sigaction(sig, &sa, nullptr);
    ::raise(sig);
}

} // namespace

void crashDumpInit(int logFd) {
    if (logFd >= 0) {
        // Dup so fclose/close of caller-owned streams cannot steal our fd.
        int d = ::dup(logFd);
        if (d >= 0) {
            // Best-effort CLOEXEC so children do not inherit the log.
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
    g_loadBase.store(captureLoadBase(), std::memory_order_relaxed);
}

void crashDumpNote(const char* msg) {
    if (!msg)
        msg = "";
    size_t n = 0;
    while (msg[n] && n < kNoteCap)
        ++n;
    // Publish length 0 first so a concurrent handler prefers empty over torn.
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
    struct sigaction sa;
    std::memset(&sa, 0, sizeof(sa));
    sa.sa_sigaction = fatalHandler;
    // SA_RESETHAND: if we crash again inside the handler, die immediately.
    // SA_NODEFER omitted: keep the signal blocked while dumping.
    sa.sa_flags = SA_SIGINFO | SA_RESETHAND;
    sigemptyset(&sa.sa_mask);
    // Block the other fatals while dumping one.
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

void crashDumpWriteNow(int sig, const void* faultAddr) {
    const int fd = g_logFd.load(std::memory_order_relaxed);
    dumpToFd(fd >= 0 ? fd : STDERR_FILENO, sig, faultAddr);
}

} // namespace misterplex
