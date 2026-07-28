#include "fpga_spi.hpp"

#include "libmisterplex/status_telemetry.hpp"
#include "libmisterplex/pixel_format.hpp"

#include <algorithm>
#include <atomic>
#include <cerrno>
#include <csignal>
#include <chrono>
#include <cstdio>
#include <cstring>
#include <dirent.h>
#include <fcntl.h>
#include <mutex>
#include <new>
#include <signal.h>
#include <string>
#include <sys/syscall.h>
#include <sys/file.h>
#include <sys/mman.h>
#include <sys/wait.h>
#include <unistd.h>
#include <vector>

// usleep
#include <time.h>

namespace misterplex {
namespace {

constexpr uint8_t FIO_FILE_TX = 0x53;
constexpr uint8_t FIO_FILE_TX_DAT = 0x54;
constexpr uint8_t FIO_FILE_INDEX = 0x55;
constexpr uint8_t UIO_SET_STATUS2 = 0x1e;
constexpr uint8_t UIO_GET_STATUS = 0x29;
constexpr uint8_t UIO_GET_STRING = 0x14;
constexpr int kDdrBankReuseMinUs = 40000;

// Serialize all HPS↔FPGA SPI (F1/F2/F3 + status). Audio + video + stream threads
// share one FpgaSpi; concurrent sendFileTx without this races GPO and Main pause.
// Also guards err_ (std::string is not thread-safe — concurrent writes crashed soak).
// recursive: setErr/lastError may run while SpiExclusive already holds the lock.
std::recursive_mutex& spiMutex() {
    static std::recursive_mutex m;
    return m;
}

bool cleanDcacheRange(const void* p, size_t len) {
    if (!p || !len)
        return true;
#if defined(__arm__)
#ifndef __ARM_NR_BASE
#define __ARM_NR_BASE 0x0f0000
#endif
#ifndef __ARM_NR_cacheflush
#define __ARM_NR_cacheflush (__ARM_NR_BASE + 2)
#endif
    const uintptr_t start = reinterpret_cast<uintptr_t>(p);
    const uintptr_t end = start + len;
    return ::syscall(__ARM_NR_cacheflush, start, end, 0) == 0;
#else
    (void)p;
    (void)len;
    return true;
#endif
}

int64_t elapsedUs(std::chrono::steady_clock::time_point a,
                  std::chrono::steady_clock::time_point b) {
    return std::chrono::duration_cast<std::chrono::microseconds>(b - a).count();
}

// Main_MiSTer owns the same SPI; STOP it for exclusive status/file ops.
// Matches /media/fat/MiSTer and MiSTer_groovy-style host binaries.
// IMPORTANT: no system()/fork here — multi-threaded misterplexd (F1+F2+F3) must
// not call system() under load (glibc fork+malloc deadlock → silent process death).
std::vector<pid_t> findMisterPids() {
    std::vector<pid_t> out;
    DIR* d = opendir("/proc");
    if (!d)
        return out;
    while (dirent* e = readdir(d)) {
        if (e->d_name[0] < '1' || e->d_name[0] > '9')
            continue;
        char path[96];
        std::snprintf(path, sizeof(path), "/proc/%.32s/cmdline", e->d_name);
        int fd = ::open(path, O_RDONLY | O_CLOEXEC);
        if (fd < 0)
            continue;
        char buf[256]{};
        ssize_t n = ::read(fd, buf, sizeof(buf) - 1);
        ::close(fd);
        if (n <= 0)
            continue;
        // cmdline is NUL-separated argv; argv0 is first token
        const char* argv0 = buf;
        if (std::strstr(argv0, "misterplex") != nullptr)
            continue;
        // Exact basename match for main host binaries only (avoid "mister*" false positives)
        const char* base = std::strrchr(argv0, '/');
        base = base ? base + 1 : argv0;
        if (std::strcmp(base, "MiSTer") == 0 || std::strcmp(base, "MiSTer_groovy") == 0)
            out.push_back(static_cast<pid_t>(std::atoi(e->d_name)));
    }
    closedir(d);
    return out;
}

// Bits Main sets in GPO while it owns a SPI transaction (spi.cpp EnableFpga/
// EnableOsd/EnableIO) plus the handshake strobe. If every one of these is clear
// then Main is between transactions and cannot be hurt by us driving the bus.
constexpr uint32_t kSspiStrobe = 1u << 17;
constexpr uint32_t kSspiFpgaEn = 1u << 18;
constexpr uint32_t kSspiOsdEn = 1u << 19;
constexpr uint32_t kSspiIoEn = 1u << 20;
constexpr uint32_t kMainBusyMask = kSspiStrobe | kSspiFpgaEn | kSspiOsdEn | kSspiIoEn;

volatile uint32_t* gpoReg(volatile uint32_t* map) {
    constexpr uint32_t kMgrBase = 0xFF706000;
    constexpr uint32_t kMapBase = 0xFF000000;
    return map + ((kMgrBase - kMapBase + 0x10) >> 2);
}

// Non-zero while this process holds Main stopped, so resumeStrandedMain() does
// not fight a window we are legitimately holding right now.
std::atomic<int>& mainPauseDepth() {
    static std::atomic<int> d{0};
    return d;
}

// Read the scheduler state character from /proc/<pid>/stat. 'T' = stopped by a
// signal. stat is "pid (comm) state ..." and comm may contain spaces or ')', so
// scan back from the LAST ')' rather than tokenising forward.
char procStateFile(const char* path) {
    int fd = ::open(path, O_RDONLY | O_CLOEXEC);
    if (fd < 0)
        return 0;
    char buf[256]{};
    ssize_t n = ::read(fd, buf, sizeof(buf) - 1);
    ::close(fd);
    if (n <= 0)
        return 0;
    buf[n] = 0;
    const char* close_paren = std::strrchr(buf, ')');
    if (!close_paren)
        return 0;
    const char* s = close_paren + 1;
    while (*s == ' ')
        ++s;
    return *s;
}

char misterProcState(pid_t p) {
    char path[64];
    std::snprintf(path, sizeof(path), "/proc/%d/stat", static_cast<int>(p));
    return procStateFile(path);
}

// A window in which it is provably safe to drive GPO ourselves.
//
// Acquire: SIGSTOP Main -> wait for /proc to actually report state 'T' (kill()
// returns long before the target stops) -> read the live GPO register. If any
// of Main's transaction-enable bits or the strobe is set, Main was frozen inside
// fpga_spi() and touching GPO now would hang it forever; resume it, back off and
// retry. All-clear means Main is parked between transactions and, being stopped,
// cannot start another one.
//
// Release: put GPO back exactly as Main left it, THEN SIGCONT. Main's shadow
// copy (`gpo_copy`) is never re-read from hardware, so handing the register back
// bit-for-bit is what keeps its view of the world true.
//
// Only the outermost SpiExclusive builds a window; nested frames inherit it.
struct MainSafeWindow {
    volatile uint32_t* map = nullptr;
    std::vector<pid_t> pids;
    uint32_t savedGpo = 0;
    bool enabled = false;
    bool safe = false;

    // A process-directed SIGSTOP initiates a *group* stop: the thread-group
    // leader can already report 'T' while a worker thread is still running.
    // Main is multi-threaded (offload.cpp) and its workers touch SPI, so it is
    // not enough to look at /proc/<pid>/stat — every task in /proc/<pid>/task
    // must have stopped before the GPO sample means anything.
    static bool allTasksStopped(pid_t p) {
        char dir[64];
        std::snprintf(dir, sizeof(dir), "/proc/%d/task", static_cast<int>(p));
        DIR* d = opendir(dir);
        if (!d)
            return true; // process is gone; it can no longer race us
        bool all = true;
        while (dirent* e = readdir(d)) {
            if (e->d_name[0] < '1' || e->d_name[0] > '9')
                continue;
            char path[128];
            std::snprintf(path, sizeof(path), "%.48s/%.16s/stat", dir, e->d_name);
            const char st = procStateFile(path);
            if (st != 'T' && st != 0) {
                all = false;
                break;
            }
        }
        closedir(d);
        return all;
    }

    static bool waitStopped(const std::vector<pid_t>& pids, int maxUs) {
        for (int waited = 0; waited <= maxUs; waited += 200) {
            bool all = true;
            for (pid_t p : pids) {
                if (!allTasksStopped(p)) {
                    all = false;
                    break;
                }
            }
            if (all)
                return true;
            usleep(200);
        }
        return false;
    }

    MainSafeWindow(volatile uint32_t* m, int attempts, bool enable) : map(m), enabled(enable) {
        if (!enabled)
            return;
        mainPauseDepth().fetch_add(1);
        for (int attempt = 0; attempt < attempts && !safe; ++attempt) {
            pids = findMisterPids();
            if (pids.empty()) {
                // No Main on this system (dev host) — nobody to race.
                if (map)
                    savedGpo = *gpoReg(map);
                safe = true;
                break;
            }
            for (pid_t p : pids)
                kill(p, SIGSTOP);
            if (waitStopped(pids, 50000) && map) {
                savedGpo = *gpoReg(map);
                if ((savedGpo & kMainBusyMask) == 0) {
                    safe = true;
                    break;
                }
            }
            // Main is mid-transaction (or would not stop): let it finish and
            // try again a little later. Backing off is always better than
            // corrupting a handshake we cannot repair.
            for (pid_t p : pids)
                kill(p, SIGCONT);
            usleep(500 + static_cast<unsigned>(attempt) * 500);
        }
        if (!safe) {
            // Never leave Main stopped just because we gave up.
            for (pid_t p : findMisterPids())
                kill(p, SIGCONT);
        }
    }

    ~MainSafeWindow() {
        if (!enabled)
            return;
        if (safe && map)
            *gpoReg(map) = savedGpo;
        auto now = findMisterPids();
        if (now.empty())
            now = pids;
        for (pid_t p : now)
            kill(p, SIGCONT);
        mainPauseDepth().fetch_sub(1);
    }
    MainSafeWindow(const MainSafeWindow&) = delete;
    MainSafeWindow& operator=(const MainSafeWindow&) = delete;
};

// Cross-process lock. Held for the whole window, including the GPO restore —
// another process writing GPO while we are sampling or restoring would make
// savedGpo a lie and could hang Main exactly as before.
struct FlockGuard {
    int fd = -1;
    explicit FlockGuard(bool enable) {
        if (!enable)
            return;
        fd = ::open("/tmp/misterplex_spi.lock", O_CREAT | O_RDWR, 0666);
        if (fd >= 0)
            flock(fd, LOCK_EX);
    }
    ~FlockGuard() {
        if (fd >= 0) {
            flock(fd, LOCK_UN);
            ::close(fd);
        }
    }
    FlockGuard(const FlockGuard&) = delete;
    FlockGuard& operator=(const FlockGuard&) = delete;
};

// Nesting state, only ever touched while spiMutex (recursive) is held.
int& spiDepth() {
    static int d = 0;
    return d;
}
bool& spiWindowSafe() {
    static bool s = false;
    return s;
}

// Every SPI transaction goes through this; there is no "fast, unpaused" variant,
// because an unsynchronised GPO write can hang Main just as dead as a paused one.
//
// Member order IS the lock order: mutex -> flock -> window on the way in, and
// the exact reverse on the way out (members are destroyed in reverse declaration
// order, after the destructor body). The flock must outlive the window so that
// GPO is restored and Main resumed while we still hold the cross-process lock.
// No system()/fork under the lock: multi-threaded misterplexd must not fork
// (glibc fork+malloc deadlock).
struct SpiExclusive {
    std::lock_guard<std::recursive_mutex> mu;
    bool outer;
    FlockGuard lock;
    MainSafeWindow win;
    explicit SpiExclusive(volatile uint32_t* map, int attempts = 8)
        : mu(spiMutex()), outer(spiDepth()++ == 0), lock(outer), win(map, attempts, outer) {
        if (outer)
            spiWindowSafe() = win.safe;
    }
    ~SpiExclusive() { --spiDepth(); }
    // False when Main could not be parked safely: the caller must not touch SPI.
    // Nested frames report the outermost window's real state, never a blind true.
    bool safe() const { return spiWindowSafe(); }
    SpiExclusive(const SpiExclusive&) = delete;
    SpiExclusive& operator=(const SpiExclusive&) = delete;
};

bool gpiUserMode(volatile uint32_t* map) {
    if (!map)
        return false;
    constexpr uint32_t kMgrBase = 0xFF706000;
    constexpr uint32_t kMapBase = 0xFF000000;
    volatile uint32_t* gpi = map + ((kMgrBase - kMapBase + 0x14) >> 2);
    // MiSTer: high bit of GPI indicates not-in-user-mode (core reconfig / menu).
    return (static_cast<int>(*gpi) >= 0);
}

} // namespace

FpgaSpi::~FpgaSpi() { close(); }

bool FpgaSpi::mainPaused() { return mainPauseDepth().load() > 0; }

bool FpgaSpi::mainAlive() { return !findMisterPids().empty(); }

void FpgaSpi::resumeStrandedMain() {
    // Never fight a pause we are legitimately holding right now.
    if (mainPauseDepth().load() > 0)
        return;
    for (pid_t p : findMisterPids()) {
        if (misterProcState(p) == 'T')
            kill(p, SIGCONT);
    }
}

namespace {

// async-signal-safe enough: kill()/open()/read()/close() are all on the safe
// list, and we re-raise with the default handler so the crash still surfaces.
void crashGuardHandler(int sig) {
    mainPauseDepth().store(0);
    for (pid_t p : findMisterPids())
        kill(p, SIGCONT);
    std::signal(sig, SIG_DFL);
    ::raise(sig);
}

} // namespace

void FpgaSpi::installCrashGuard() {
    // SIGKILL cannot be caught — resumeStrandedMain() at startup covers it.
    for (int sig : {SIGSEGV, SIGABRT, SIGBUS, SIGILL, SIGFPE, SIGQUIT})
        std::signal(sig, crashGuardHandler);
}

void FpgaSpi::setErr(std::string msg) {
    std::lock_guard<std::recursive_mutex> g(spiMutex());
    err_ = std::move(msg);
}

void FpgaSpi::clearErr() {
    std::lock_guard<std::recursive_mutex> g(spiMutex());
    err_.clear();
}

std::string FpgaSpi::lastError() const {
    std::lock_guard<std::recursive_mutex> g(spiMutex());
    return err_;
}

bool FpgaSpi::open() {
    close();
    fd_ = ::open("/dev/mem", O_RDWR | O_SYNC | O_CLOEXEC);
    if (fd_ < 0) {
        setErr("open /dev/mem failed");
        return false;
    }
    void* p = mmap(nullptr, kMapSize, PROT_READ | PROT_WRITE, MAP_SHARED, fd_, kMapBase);
    if (p == MAP_FAILED) {
        setErr("mmap FPGA regs failed");
        ::close(fd_);
        fd_ = -1;
        return false;
    }
    map_ = static_cast<volatile uint32_t*>(p);
    // Seed gpo from hardware
    volatile uint32_t* gpo = map_ + ((kMgrBase - kMapBase + 0x10) >> 2);
    gpo_copy_ = *gpo;
    clearErr();
    return true;
}

void FpgaSpi::close() {
    releaseDdrMap();
    releaseBitstreamDdrMap();
    if (map_) {
        munmap((void*)map_, kMapSize);
        map_ = nullptr;
    }
    if (fd_ >= 0) {
        ::close(fd_);
        fd_ = -1;
    }
    ddrKickMode_ = 0;
    ddrKickFailMs_ = -1.0;
    doorbellSeq_ = 0;
}

bool FpgaSpi::ensureBitstreamDdrMap() {
    namespace ring = ddr_bitstream_ring;
    if (bitstreamMap_ && bitstreamMemFd_ >= 0)
        return true;
    releaseBitstreamDdrMap();
    bitstreamMapLen_ = ring::kRingBytes + 0x1000u;
    bitstreamMemFd_ = ::open("/dev/mem", O_RDWR | O_CLOEXEC | O_SYNC);
    if (bitstreamMemFd_ < 0) {
        setErr("ensureBitstreamDdrMap: open /dev/mem failed");
        return false;
    }
    void* p = mmap(nullptr, bitstreamMapLen_, PROT_READ | PROT_WRITE, MAP_SHARED,
                   bitstreamMemFd_, static_cast<off_t>(ring::kDataPhys));
    if (p == MAP_FAILED) {
        setErr("ensureBitstreamDdrMap: mmap bitstream ring failed");
        ::close(bitstreamMemFd_);
        bitstreamMemFd_ = -1;
        bitstreamMapLen_ = 0;
        return false;
    }
    bitstreamMap_ = static_cast<uint8_t*>(p);
    return true;
}

void FpgaSpi::releaseBitstreamDdrMap() {
    if (bitstreamMap_) {
        munmap(bitstreamMap_, bitstreamMapLen_);
        bitstreamMap_ = nullptr;
        bitstreamMapLen_ = 0;
    }
    if (bitstreamMemFd_ >= 0) {
        ::close(bitstreamMemFd_);
        bitstreamMemFd_ = -1;
    }
    bitstreamWriteCount_ = 0;
    bitstreamLegacySeq_ = 0;
    bitstreamLegacyActive_ = false;
    bitstreamResetEpoch_ = false;
}

bool FpgaSpi::readBitstreamFpgaCount(uint32_t& readCount) {
    namespace ring = ddr_bitstream_ring;
    if (!ensureBitstreamDdrMap())
        return false;
    const size_t off = ring::kReadPhys - ring::kDataPhys;
    volatile uint64_t* p = reinterpret_cast<volatile uint64_t*>(bitstreamMap_ + off);
    const uint64_t raw = *p;
    if (static_cast<uint32_t>(raw) != ring::kReadMagic)
        return false;
    readCount = static_cast<uint32_t>(raw >> 32);
    return true;
}

bool FpgaSpi::readBitstreamStatus(BitstreamStatus& status) {
    namespace ring = ddr_bitstream_ring;
    status = BitstreamStatus{};
    if (!ensureBitstreamDdrMap())
        return false;
    auto read64 = [&](uint32_t phys) -> uint64_t {
        const size_t off = phys - ring::kDataPhys;
        volatile uint64_t* p = reinterpret_cast<volatile uint64_t*>(bitstreamMap_ + off);
        return *p;
    };
    const uint64_t ctrlRaw = read64(ring::kCtrlPhys);
    const uint64_t readRaw = read64(ring::kReadPhys);
    const uint64_t errRaw = read64(ring::kErrPhys);
    const uint64_t st0 = read64(ring::kStat0Phys);
    const uint64_t st1 = read64(ring::kStat1Phys);
    const uint64_t st2 = read64(ring::kStat2Phys);
    const uint64_t st3 = read64(ring::kStat3Phys);
    const uint64_t st4 = read64(ring::kStat4Phys);
    const uint64_t st5 = read64(ring::kStat5Phys);
    const uint64_t st6 = read64(ring::kStat6Phys);
    // PLXD in CTRL means the ARM deliberately marked the producer dormant.
    if (static_cast<uint32_t>(ctrlRaw) == ring::kCtrlDormantMagic) {
        status.dormant = true;
        return true;
    }
    if (static_cast<uint32_t>(readRaw) != ring::kReadMagic)
        return false;
    status.producer_count = bitstreamWriteCount_;
    status.consumer_count = static_cast<uint32_t>(readRaw >> 32);
    (void)ring::decodeErrStatusWord(errRaw, status);
    if (static_cast<uint32_t>(st0) == ring::kStat0Magic)
        status.ring_level = static_cast<uint32_t>(st0 >> 32);
    else
        status.ring_level = bitstreamWriteCount_ - status.consumer_count;
    if (static_cast<uint32_t>(st1) == ring::kStat1Magic)
        status.consumer_seq = static_cast<uint32_t>(st1 >> 32);
    if (static_cast<uint32_t>(st2) == ring::kStat2Magic)
        status.last_bad_seq = static_cast<uint32_t>(st2 >> 32);
    if (static_cast<uint32_t>(st3) == ring::kStat3Magic)
        status.session_id = static_cast<uint32_t>(st3 >> 32);
    if (static_cast<uint32_t>(st4) == ring::kStat4Magic)
        status.session_id |= static_cast<uint64_t>(static_cast<uint32_t>(st4 >> 32)) << 32;
    (void)ring::decodeStat5StatusWord(st5, status);
    (void)ring::decodeStat6StatusWord(st6, status);
    return true;
}

bool FpgaSpi::waitBitstreamReadCount(uint32_t target, int timeout_ms) {
    const int stepUs = 500;
    const int maxUs = std::max(0, timeout_ms) * 1000;
    for (int waited = 0; waited <= maxUs; waited += stepUs) {
        uint32_t readCount = 0;
        if (readBitstreamFpgaCount(readCount) &&
            static_cast<int32_t>(readCount - target) >= 0)
            return true;
        usleep(stepUs);
    }
    return false;
}

FpgaSpi::BitstreamPushResult FpgaSpi::writeBitstreamRecord(ddr_bitstream_ring::Event event,
                                                           uint64_t session_id,
                                                           uint32_t seq,
                                                           uint8_t nal_type,
                                                           const uint8_t* payload,
                                                           size_t len,
                                                           int timeout_ms) {
    namespace ring = ddr_bitstream_ring;
    if (len && !payload) {
        setErr("writeBitstreamRecord: empty payload pointer");
        return BitstreamPushResult::Fatal;
    }
    const size_t recordLen = ring::kRecordHeaderBytes + len;
    if (recordLen > ring::kRingBytes) {
        setErr("writeBitstreamRecord: record larger than ring");
        return BitstreamPushResult::Fatal;
    }
    if (!ensureBitstreamDdrMap())
        return BitstreamPushResult::Fatal;

    auto statusIsFatal = [&]() {
        BitstreamStatus st;
        return readBitstreamStatus(st) && (st.fatal || st.desync);
    };
    if (statusIsFatal()) {
        setErr("writeBitstreamRecord: FPGA reports transport desync");
        return BitstreamPushResult::Desync;
    }

    uint32_t readCount = bitstreamWriteCount_;
    (void)readBitstreamFpgaCount(readCount);
    const auto deadline = std::chrono::steady_clock::now() +
                          std::chrono::milliseconds(std::max(0, timeout_ms));
    while (bitstreamWriteCount_ - readCount + recordLen > ring::kRingBytes) {
        if (std::chrono::steady_clock::now() >= deadline) {
            setErr("writeBitstreamRecord: FPGA ring full");
            return BitstreamPushResult::Full;
        }
        usleep(500);
        if (statusIsFatal()) {
            setErr("writeBitstreamRecord: FPGA reports transport desync");
            return BitstreamPushResult::Desync;
        }
        (void)readBitstreamFpgaCount(readCount);
    }

    std::vector<uint8_t> header(ring::kRecordHeaderBytes, 0);
    auto put32 = [&](size_t off, uint32_t v) {
        header[off + 0] = static_cast<uint8_t>(v);
        header[off + 1] = static_cast<uint8_t>(v >> 8);
        header[off + 2] = static_cast<uint8_t>(v >> 16);
        header[off + 3] = static_cast<uint8_t>(v >> 24);
    };
    auto put64 = [&](size_t off, uint64_t v) {
        put32(off, static_cast<uint32_t>(v));
        put32(off + 4, static_cast<uint32_t>(v >> 32));
    };
    put32(0, ring::kRecordMagic);
    header[4] = static_cast<uint8_t>(event);
    header[5] = nal_type;
    put64(8, session_id);
    put32(16, seq);
    put32(20, static_cast<uint32_t>(len));

    auto writeBytes = [&](const uint8_t* src, size_t n) {
        uint32_t wr = bitstreamWriteCount_ & static_cast<uint32_t>(ring::kRingBytes - 1u);
        const size_t first = std::min(n, static_cast<size_t>(ring::kRingBytes - wr));
        std::memcpy(bitstreamMap_ + wr, src, first);
        if (first < n)
            std::memcpy(bitstreamMap_, src + first, n - first);
        bitstreamWriteCount_ += static_cast<uint32_t>(n);
    };
    writeBytes(header.data(), header.size());
    if (len)
        writeBytes(payload, len);
    __sync_synchronize();
    publishBitstreamCtrl();
    clearErr();
    return BitstreamPushResult::Ok;
}

void FpgaSpi::publishBitstreamCtrl() {
    namespace ring = ddr_bitstream_ring;
    const size_t off = ring::kCtrlPhys - ring::kDataPhys;
    volatile uint64_t* p = reinterpret_cast<volatile uint64_t*>(bitstreamMap_ + off);
    *p = (static_cast<uint64_t>(bitstreamResetEpoch_ ? 1u : 0u) << 63) |
         (static_cast<uint64_t>(bitstreamWriteCount_ & 0x7fffffffu) << 32) |
         ring::kCtrlMagic;
}

bool FpgaSpi::publishBitstreamDormant() {
    namespace ring = ddr_bitstream_ring;
    if (!ensureBitstreamDdrMap())
        return false;
    const size_t off = ring::kCtrlPhys - ring::kDataPhys;
    volatile uint64_t* p = reinterpret_cast<volatile uint64_t*>(bitstreamMap_ + off);
    // PLXD magic: the FPGA reader checks for PLXB only, so this word is
    // harmlessly ignored.  A DDR probe sees a valid MiSTerPlex mailbox and
    // knows the ARM wrote it deliberately with STREAM=0.
    *p = ring::kCtrlDormantMagic;
    return true;
}

bool FpgaSpi::ensureDdrMap() {
    if (ddrMap_ && ddrMemFd_ >= 0)
        return true;
    releaseDdrMap();
    // Map both frame banks plus the final doorbell/mailbox page. 320×240 keeps
    // the historical 0x80000 window; larger cores grow this at runtime.
    const size_t kLen = ddrLayout_.map_bytes;
    int flags = O_RDWR | O_CLOEXEC;
    if (ddrMemSync_)
        flags |= O_SYNC;
    ddrMemFd_ = ::open("/dev/mem", flags);
    if (ddrMemFd_ < 0) {
        setErr("ensureDdrMap: open /dev/mem failed");
        return false;
    }
    void* p = mmap(nullptr, kLen, PROT_READ | PROT_WRITE, MAP_SHARED, ddrMemFd_,
                   static_cast<off_t>(ddrLayout_.phys_base));
    if (p == MAP_FAILED) {
        setErr("ensureDdrMap: mmap frame window failed");
        ::close(ddrMemFd_);
        ddrMemFd_ = -1;
        return false;
    }

    ddrMap_ = static_cast<uint8_t*>(p);
    ddrMapLen_ = kLen;
    const size_t doorbellOff = static_cast<size_t>(ddrLayout_.doorbell_phys - ddrLayout_.phys_base);
    if (doorbellOff + 8 <= ddrMapLen_) {
        volatile uint32_t* dw = reinterpret_cast<volatile uint32_t*>(ddrMap_ + doorbellOff);
        for (int attempt = 0; attempt < 4; ++attempt) {
            const uint32_t lo0 = dw[0];
            const uint32_t hi = dw[1];
            const uint32_t lo1 = dw[0];
            if (lo0 != lo1)
                continue;
            uint32_t seq = 0;
            int bank = 0;
            if (decodeDdrDoorbell(lo0, hi, ddrLayout_.format, seq, bank)) {
                (void)bank;
                doorbellSeq_ = seq;
            }
            break;
        }
    }
    return true;
}

bool FpgaSpi::setDdrFrameLayout(const DdrFrameGeometry& geometry, DdrFrameFormat format) {
    DdrFrameLayout next =
        makeDdrFrameLayout(geometry, kDdrFrameBase, kDdrFrameStrideAlign, format);
    if (!ddrFrameLayoutValid(next)) {
        setErr("setDdrFrameLayout: invalid DDR frame layout");
        return false;
    }
    if (next.coded_width == ddrLayout_.coded_width &&
        next.coded_height == ddrLayout_.coded_height &&
        next.display_width == ddrLayout_.display_width &&
        next.display_height == ddrLayout_.display_height &&
        next.presented_width == ddrLayout_.presented_width &&
        next.presented_height == ddrLayout_.presented_height &&
        next.crop_left == ddrLayout_.crop_left && next.crop_right == ddrLayout_.crop_right &&
        next.crop_top == ddrLayout_.crop_top && next.crop_bottom == ddrLayout_.crop_bottom &&
        next.present_x == ddrLayout_.present_x && next.present_y == ddrLayout_.present_y &&
        next.format == ddrLayout_.format)
        return true;
    ddrLayout_ = next;
    releaseDdrMap();
    ddrKickMode_ = 0;
    ddrKickFailMs_ = -1.0;
    doorbellSeq_ = 0;
    clearErr();
    return true;
}

bool FpgaSpi::setDdrFrameLayout(int width, int height, DdrFrameFormat format) {
    return setDdrFrameLayout(makeDdrFrameGeometry(width, height), format);
}

void FpgaSpi::setDdrMemSync(bool on) {
    if (ddrMemSync_ == on)
        return;
    ddrMemSync_ = on;
    releaseDdrMap();
    ddrKickMode_ = 0;
    ddrKickFailMs_ = -1.0;
}

void FpgaSpi::releaseDdrMap() {
    mboxInit_ = false;
    mboxAlive_ = false;
    inputMboxEdge_.reset();
    if (ddrMap_) {
        munmap(ddrMap_, ddrMapLen_);
        ddrMap_ = nullptr;
        ddrMapLen_ = 0;
    }
    if (ddrMemFd_ >= 0) {
        ::close(ddrMemFd_);
        ddrMemFd_ = -1;
    }
}

bool FpgaSpi::waitCoreFlag(bool clearBusy, bool clearPending, int maxUs) {
    // Poll status until flags clear (or timeout).
    const int step = 500;
    int waited = 0;
    while (waited < maxUs) {
        uint8_t raw[16]{};
        {
            SpiExclusive guard(map_);
            if (!guard.safe() || !map_ || !gpiUserMode(map_))
                return false;
            if (!readStatusRaw(raw))
                return false;
        }
        CoreStatus st = parseCoreStatus(raw);
        const bool busyOk = !clearBusy || !st.ddr_busy;
        const bool pendOk = !clearPending || !st.swap_pending;
        if (busyOk && pendOk)
            return true;
        usleep(step);
        waited += step;
    }
    return false;
}

bool FpgaSpi::kickDdrDoorbell(int bank) {
    if (!ddrMap_ || bank < 0 || bank > 1)
        return false;
    const size_t kOff = static_cast<size_t>(ddrLayout_.doorbell_phys - ddrLayout_.phys_base);
    if (kOff + 8 > ddrMapLen_)
        return false;
    volatile uint32_t* dw = reinterpret_cast<volatile uint32_t*>(ddrMap_ + kOff);
    ++doorbellSeq_;
    // Pack: [31:0]=magic, high=[31]=bank, [30:29]=format, [28:0]=sequence.
    const uint32_t seq = doorbellSeq_ & 0x1FFFFFFFu;
    const uint32_t hi = ddrDoorbellHi(seq, bank, ddrLayout_.format);
    // Publish the complete token before magic. On a cold mailbox this prevents
    // the reader from seeing PLXK paired with a zero/old format; on a warm
    // mailbox the already-valid magic may expose the new token immediately,
    // which is safe because sendDdrFrame fences payload writes before this call.
    dw[1] = hi;
    __sync_synchronize();
    dw[0] = kDdrDoorbellMagic;
    __sync_synchronize();
    return true;
}

bool FpgaSpi::readOsdMailbox(uint16_t& osd) {
    if (!ensureDdrMap())
        return false;
    const size_t kOff = static_cast<size_t>(ddrStatusMailboxPhys() - ddrLayout_.phys_base);
    if (kOff + 8 > ddrMapLen_)
        return false;
    volatile uint32_t* mb = reinterpret_cast<volatile uint32_t*>(ddrMap_ + kOff);
    // The core writes all 8 bytes in one DDR burst, but the ARM sees it as two
    // 32-bit loads, so re-read until the sequence number is stable to be sure we
    // did not catch a publish in flight.
    for (int attempt = 0; attempt < 4; ++attempt) {
        const uint32_t lo = mb[0];
        const uint32_t hi = mb[1];
        __sync_synchronize();
        if (lo != kDdrMailboxMagic)
            return false; // core has not published (pre-mailbox RBF, or reset)
        if (mb[1] != hi || mb[0] != lo)
            continue; // caught a publish in flight; re-read
        const uint16_t seq = static_cast<uint16_t>(hi >> 16);
        const double now = std::chrono::duration<double, std::milli>(
                               std::chrono::steady_clock::now().time_since_epoch())
                               .count();
        if (!mboxInit_) {
            // First sight proves nothing: the magic may be a leftover from a
            // previous core. Wait for seq to actually move.
            mboxInit_ = true;
            mboxSeq_ = seq;
            mboxSeqMs_ = now;
            return false;
        }
        if (seq != mboxSeq_) {
            mboxSeq_ = seq;
            mboxSeqMs_ = now;
            mboxAlive_ = true;
        } else if (now - mboxSeqMs_ > 2000.0) {
            // Heartbeat is milliseconds; two seconds of a frozen counter means
            // nothing is publishing. Hand the caller back to the SPI path.
            mboxAlive_ = false;
        }
        if (!mboxAlive_)
            return false;
        osd = static_cast<uint16_t>(hi & 0xFFFFu);
        return true;
    }
    return false;
}

bool FpgaSpi::readDdrDoorbellStatus(DdrDoorbellStatus& status) {
    status = DdrDoorbellStatus{};
    if (!ensureDdrMap())
        return false;
    const size_t kOff = static_cast<size_t>(ddrLayout_.doorbell_phys - ddrLayout_.phys_base);
    if (kOff + 8 > ddrMapLen_)
        return false;
    volatile uint32_t* dw = reinterpret_cast<volatile uint32_t*>(ddrMap_ + kOff);
    for (int attempt = 0; attempt < 4; ++attempt) {
        const uint32_t lo = dw[0];
        const uint32_t hi = dw[1];
        __sync_synchronize();
        if (dw[0] != lo || dw[1] != hi)
            continue;
        uint32_t seq = 0;
        int bank = 0;
        if (!decodeDdrDoorbell(lo, hi, ddrLayout_.format, seq, bank))
            return false;
        status.seq = seq;
        status.bank = bank;
        status.format = ddrLayout_.format;
        return true;
    }
    return false;
}

bool FpgaSpi::readInputMailbox(PlaybackCommand& command) {
    command = PlaybackCommand::None;
    if (!ensureDdrMap())
        return false;
    const size_t kOff = static_cast<size_t>(ddrInputMailboxPhys() - ddrLayout_.phys_base);
    if (kOff + 8 > ddrMapLen_)
        return false;
    volatile uint32_t* mb = reinterpret_cast<volatile uint32_t*>(ddrMap_ + kOff);
    for (int attempt = 0; attempt < 4; ++attempt) {
        const uint32_t lo = mb[0];
        const uint32_t hi = mb[1];
        __sync_synchronize();
        const uint32_t verifyLo = mb[0];
        const uint32_t verifyHi = mb[1];
        if (lo != verifyLo || hi != verifyHi)
            continue;
        if (lo != kInputMailboxMagic) {
            inputMboxEdge_.noteNoValidWord();
            return false;
        }
        InputMailboxSample sample;
        if (!decodeInputMailboxWord(static_cast<uint64_t>(lo) | (static_cast<uint64_t>(hi) << 32),
                                    sample))
            return false;
        if (inputMboxEdge_.accept(sample, command))
            return true;
        return false;
    }
    return false;
}

bool FpgaSpi::kickDdrSpi(int bank, bool first_verify, bool& saw_busy, bool& saw_kick,
                         bool& saw_frame) {
    SpiExclusive guard(map_);
    if (!guard.safe()) {
        err_ = "Main busy on SPI — skipped";
        return false;
    }
    if (!gpiUserMode(map_)) {
        err_ = "FPGA not in user mode";
        return false;
    }
    err_.clear();
    uint8_t word[16]{};
    std::memcpy(word, status_, 16);
    if (first_verify) {
        uint8_t live[16]{};
        if (readStatusRaw(live)) {
            word[0] = live[0];
            word[1] = live[1];
        }
    }
    encodeDdrSpiKickStatusWord(word, bank, false, word);
    writeStatusWordRaw(word);
    encodeDdrSpiKickStatusWord(word, bank, true, word);
    writeStatusWordRaw(word);
    if (first_verify) {
        for (int i = 0; i < 40; ++i) {
            uint8_t raw[16]{};
            if (!readStatusRaw(raw))
                break;
            if (raw[1] & 0x10)
                saw_kick = true;
            CoreStatus st = parseCoreStatus(raw);
            if (st.ddr_busy)
                saw_busy = true;
            if (st.has_frame)
                saw_frame = true;
            if (saw_busy || (saw_kick && saw_frame && i >= 2))
                break;
            usleep(200);
        }
    }
    encodeDdrSpiKickStatusWord(word, bank, false, word);
    writeStatusWordRaw(word);
    if (first_verify) {
        uint8_t raw[16]{};
        if (readStatusRaw(raw)) {
            if (raw[1] & 0x10)
                saw_kick = true;
            CoreStatus st = parseCoreStatus(raw);
            if (st.has_frame)
                saw_frame = true;
            if (st.ddr_busy)
                saw_busy = true;
        }
    }
    std::memcpy(status_, word, 16);
    return true;
}

void FpgaSpi::gpoWrite(uint32_t v) {
    gpo_copy_ = v;
    volatile uint32_t* gpo = map_ + ((kMgrBase - kMapBase + 0x10) >> 2);
    *gpo = v;
}

uint32_t FpgaSpi::gpoRead() const {
    // Read the live register, not a shadow. Main keeps a static `gpo_copy` and
    // never re-reads hardware, so a shadow of our own would drift from Main's
    // every time it drove the bus, and we would hand back bits it never set.
    // Inside a SpiExclusive window we are the only writer, so this is stable.
    if (map_)
        return *gpoReg(map_);
    return gpo_copy_;
}

int FpgaSpi::gpiRead() const {
    volatile uint32_t* gpi = map_ + ((kMgrBase - kMapBase + 0x14) >> 2);
    return static_cast<int>(*gpi);
}

void FpgaSpi::spiEn(uint32_t mask, int en) {
    uint32_t gpo = gpoRead() | 0x80000000u;
    gpoWrite(en ? (gpo | mask) : (gpo & ~mask));
}

uint16_t FpgaSpi::spiWord(uint16_t word) {
    // Caller must hold SpiExclusive (spiMutex). Touch err_ without re-locking.
    uint32_t gpo = (gpoRead() & ~(0xFFFFu | SSPI_STROBE)) | word;
    gpoWrite(gpo);
    gpoWrite(gpo | SSPI_STROBE);
    int gpi;
    int spins = 0;
    do {
        gpi = gpiRead();
        if (gpi < 0) {
            err_ = "FPGA not in user mode";
            return 0;
        }
        if (++spins > 1000000) {
            err_ = "SPI ACK timeout (set)";
            return 0;
        }
    } while (!(gpi & static_cast<int>(SSPI_STROBE)));

    gpoWrite(gpo);
    spins = 0;
    do {
        gpi = gpiRead();
        if (gpi < 0) {
            err_ = "FPGA not in user mode";
            return 0;
        }
        if (++spins > 1000000) {
            err_ = "SPI ACK timeout (clr)";
            return 0;
        }
    } while (gpi & static_cast<int>(SSPI_STROBE));
    return static_cast<uint16_t>(gpi);
}

void FpgaSpi::spiByte(uint8_t b) { spiWord(b); }

void FpgaSpi::spiWriteBytes(const uint8_t* p, size_t n) {
    // Fast path (no ACK wait) — matches Main_MiSTer fpga_spi_fast for bulk data.
    uint32_t gpoH = gpoRead() & ~(0xFFFFu | SSPI_STROBE);
    while (n--) {
        uint32_t gpo = gpoH | *p++;
        gpoWrite(gpo);
        gpoWrite(gpo | SSPI_STROBE);
        gpoWrite(gpo);
    }
}

void FpgaSpi::enableFpga(int on) { spiEn(SSPI_FPGA_EN, on); }
void FpgaSpi::enableIo(int on) { spiEn(SSPI_IO_EN, on); }

void FpgaSpi::setIndex(uint8_t index) {
    enableFpga(1);
    spiByte(FIO_FILE_INDEX);
    spiByte(index);
    enableFpga(0);
}

void FpgaSpi::setDownload(int enable) {
    enableFpga(1);
    spiByte(FIO_FILE_TX);
    spiByte(enable ? 0xff : 0x00);
    enableFpga(0);
}

// SPI body for UIO_SET_STATUS2. Caller must hold SpiExclusive and user mode.
void FpgaSpi::writeStatusWordRaw(const uint8_t word[16]) {
    std::memcpy(status_, word, 16);
    enableIo(1);
    spiWord(UIO_SET_STATUS2);
    for (int i = 0; i < 16; i += 2) {
        uint16_t w = static_cast<uint16_t>((status_[i + 1] << 8) | status_[i]);
        spiWord(w);
    }
    enableIo(0);
}

// SPI body for UIO_GET_STATUS. Caller must hold SpiExclusive and user mode.
bool FpgaSpi::readStatusRaw(uint8_t out[16]) {
    if (!out)
        return false;
    enableIo(1);
    (void)spiWord(UIO_GET_STATUS);
    for (int i = 0; i < 16; i += 2) {
        uint16_t w = spiWord(0);
        out[i] = static_cast<uint8_t>(w & 0xFF);
        out[i + 1] = static_cast<uint8_t>((w >> 8) & 0xFF);
    }
    enableIo(0);
    return err_.empty();
}

// UIO_GET_STRING: the same read Main_MiSTer does to build the OSD. Reading it back
// from the live core is the only way to prove the deployed RBF carries the CONF_STR
// we think it does — the string lives in the bitstream, so nothing on disk shows it.
bool FpgaSpi::getConfigString(std::string& out) {
    if (!ok()) {
        setErr("getConfigString: not open");
        return false;
    }
    SpiExclusive guard(map_);
    if (!guard.safe()) {
        err_ = "Main busy on SPI — skipped";
        return false;
    }
    if (!gpiUserMode(map_)) {
        err_ = "FPGA not in user mode";
        return false;
    }
    err_.clear();
    out.clear();
    enableIo(1);
    (void)spiWord(UIO_GET_STRING);
    // The core streams one character per word, NUL-terminated. Cap the read so a
    // wedged core cannot spin here forever.
    for (int i = 0; i < 4096; ++i) {
        const uint8_t c = static_cast<uint8_t>(spiWord(0) & 0xFF);
        if (c == 0)
            break;
        out.push_back(static_cast<char>(c));
    }
    enableIo(0);
    return !out.empty();
}

bool FpgaSpi::setStatusWord(const uint8_t word[16]) {
    if (!ok() || !word) {
        setErr("setStatusWord: bad args");
        return false;
    }
    SpiExclusive guard(map_);
    if (!guard.safe()) {
        err_ = "Main busy on SPI — skipped";
        return false;
    }
    if (!gpiUserMode(map_)) {
        err_ = "FPGA not in user mode";
        return false;
    }
    err_.clear();
    writeStatusWordRaw(word);
    return err_.empty();
}

bool FpgaSpi::setStatusBit(int bit, int value) {
    if (!ok() || bit < 0 || bit > 127) {
        setErr("setStatusBit: bad args");
        return false;
    }
    const int byte = bit / 8;
    const int b = bit % 8;
    uint8_t word[16];
    std::memcpy(word, status_, 16);
    // Live RMW of OSD / DDR kick low word (status_in v2 [15:0]) so rising-edge
    // kicks on bit 12 see a true 0→1 on the FPGA (private shadow alone is stale
    // across processes and after status_set echoes).
    if (bit < 16) {
        uint8_t live[16]{};
        if (getCoreStatus(live)) {
            word[0] = live[0];
            word[1] = live[1];
            if (bit != 0)
                word[0] = static_cast<uint8_t>(word[0] & ~0x01);
        }
    }
    if (value)
        word[byte] = static_cast<uint8_t>(word[byte] | (1u << b));
    else
        word[byte] = static_cast<uint8_t>(word[byte] & ~(1u << b));
    return setStatusWord(word);
}

bool FpgaSpi::setStatusBits(const int* bit_val_pairs, int n_pairs) {
    if (!ok() || !bit_val_pairs || n_pairs <= 0) {
        setErr("setStatusBits: bad args");
        return false;
    }
    // RMW base: private shadow (same process), then overlay live OSD echo from
    // status_in v2 [15:0] when non-zero so successive set_status CLI processes
    // accumulate (shadow is not shared across processes).
    uint8_t word[16];
    std::memcpy(word, status_, 16);
    uint8_t live[16]{};
    if (getCoreStatus(live)) {
        const uint16_t live_lo =
            static_cast<uint16_t>(live[0] | (static_cast<uint16_t>(live[1]) << 8));
        if (live_lo != 0) {
            word[0] = live[0];
            word[1] = live[1];
        }
        // Aspect ratio O[122:121] lives in byte 15 bits [2:1]
        if (live[15] & 0x06)
            word[15] = static_cast<uint8_t>((word[15] & ~0x06) | (live[15] & 0x06));
    }

    // CRITICAL: never leave Reset (bit 0) or flush pulses stuck high.
    // Holding status[0] keeps the core in reset → status_set stops → Main never
    // adopts a clear, and UIO_GET_STATUS freezes. Pulse bits must be edge-only.
    bool want_pulse0 = false;
    for (int i = 0; i < n_pairs; ++i) {
        const int bit = bit_val_pairs[i * 2];
        const int value = bit_val_pairs[i * 2 + 1] ? 1 : 0;
        if (bit < 0 || bit > 127) {
            setErr("setStatusBits: bit out of range");
            return false;
        }
        if (bit == 0 && value)
            want_pulse0 = true;
        const int byte = bit / 8;
        const int b = bit % 8;
        if (value)
            word[byte] = static_cast<uint8_t>(word[byte] | (1u << b));
        else
            word[byte] = static_cast<uint8_t>(word[byte] & ~(1u << b));
    }
    // Clear sticky pulses unless this call intentionally raises bit 0.
    if (!want_pulse0)
        word[0] = static_cast<uint8_t>(word[0] & ~0x01);
    // Always clear flush sticky bits unless the pairs explicitly set them.
    bool want10 = false, want11 = false;
    for (int i = 0; i < n_pairs; ++i) {
        if (bit_val_pairs[i * 2] == 10 && bit_val_pairs[i * 2 + 1])
            want10 = true;
        if (bit_val_pairs[i * 2] == 11 && bit_val_pairs[i * 2 + 1])
            want11 = true;
    }
    if (!want10)
        word[1] = static_cast<uint8_t>(word[1] & ~0x04);
    if (!want11)
        word[1] = static_cast<uint8_t>(word[1] & ~0x08);

    if (!setStatusWord(word))
        return false;
    // Give FPGA status_set a chance to echo; Main check_status_change adopts it.
    usleep(30000);
    // If we raised bit 0 for reset, immediately clear so the core can run.
    if (want_pulse0) {
        usleep(5000);
        word[0] = static_cast<uint8_t>(word[0] & ~0x01);
        if (!setStatusWord(word))
            return false;
        usleep(20000);
    }
    return true;
}

bool FpgaSpi::sendFileTx(const uint8_t* data, size_t len, uint8_t index) {
    if (index == 1) {
        setErr("non-YUV frame send refused: SPI F1 RGB frame path is disabled; use DDR "
               "YUV420p (sendYuv420pFrameDdr / push_frame --ddr --yuv420p)");
        return false;
    }
    if (!ok() || !data || !len) {
        setErr("sendFileTx: not open or empty");
        return false;
    }
    auto t0 = std::chrono::steady_clock::now();
    // Mutex + flock + Main pause (no system()/fork — thread-safe under STREAM load).
    SpiExclusive guard(map_);
    err_.clear(); // drop stale DDR probe text so SPI callers see real SPI errors
    if (!guard.safe()) {
        err_ = "Main busy on SPI — skipped";
        return false;
    }
    if (!gpiUserMode(map_)) {
        err_ = "FPGA not in user mode";
        return false;
    }

    setIndex(index);
    setDownload(1);

    // Chunk data with FIO_FILE_TX_DAT sessions.
    // Lab measure @320×240 (153600 B): 8 KiB→~220 ms, 32 KiB→~194 ms, 128 KiB→~196 ms.
    // SPI is the ceiling (~0.8 MB/s); DDR3 bulk (3.1b) needed for real-time F1.
    const size_t chunk = 32768;
    size_t off = 0;
    while (off < len) {
        size_t n = len - off;
        if (n > chunk)
            n = chunk;
        enableFpga(1);
        spiByte(FIO_FILE_TX_DAT);
        spiWriteBytes(data + off, n);
        enableFpga(0);
        off += n;
        if (!err_.empty()) {
            setDownload(0);
            return false;
        }
    }

    setDownload(0);
    auto t1 = std::chrono::steady_clock::now();
    lastPushMs_ = std::chrono::duration<double, std::milli>(t1 - t0).count();
    err_.clear();
    return true;
}

bool FpgaSpi::sendRgb24Frame(const uint8_t* rgb, int w, int h, uint8_t index) {
    if (!rgb || w <= 0 || h <= 0) {
        setErr("bad rgb frame");
        return false;
    }
    std::vector<uint8_t> packed(static_cast<size_t>(w) * static_cast<size_t>(h) * 2);
    pixel::rgb24ToRgb565Le(rgb, packed.data(), static_cast<size_t>(w) * static_cast<size_t>(h));
    return sendFileTx(packed.data(), packed.size(), index);
}

bool FpgaSpi::sendRgb565Bytes(const uint8_t* rgb565le, size_t len, uint8_t index) {
    if (!rgb565le || !len || (len & 1)) {
        setErr("bad rgb565 bytes");
        return false;
    }
    return sendFileTx(rgb565le, len, index);
}

bool FpgaSpi::sendRgb565Frame(const uint16_t* rgb, int w, int h, uint8_t index) {
    if (!rgb || w <= 0 || h <= 0) {
        setErr("bad rgb565 frame");
        return false;
    }
    const size_t npx = static_cast<size_t>(w) * static_cast<size_t>(h);
    std::vector<uint8_t> packed(npx * 2);
    for (size_t i = 0; i < npx; ++i) {
        const uint16_t p = rgb[i];
        packed[i * 2 + 0] = static_cast<uint8_t>(p & 0xFF);
        packed[i * 2 + 1] = static_cast<uint8_t>(p >> 8);
    }
    return sendFileTx(packed.data(), packed.size(), index);
}

bool FpgaSpi::sendDdrFrame(const DdrPublishFrame& frame, const DdrPublishPlan& plan) {
    const uint8_t* payload = frame.payload;
    const size_t len = frame.len;
    int bank = plan.bank;
    if (!payload || len != plan.layout.frame_bytes || plan.layout.bank_stride != ddrLayout_.bank_stride ||
        plan.layout.doorbell_phys != ddrLayout_.doorbell_phys ||
        plan.layout.frame_bytes != ddrLayout_.frame_bytes) {
        setErr("sendDdrFrame: publish plan does not match active DDR layout");
        return false;
    }
    if (ddrKickMode_ < 0) {
        // Allow re-probe after a cooldown so transient FPGA stalls (e.g. core
        // reload, timing recovery) don't permanently kill the frame path.
        constexpr double kReprobeIntervalMs = 5000.0;
        const double nowMs = std::chrono::duration<double, std::milli>(
                                 std::chrono::steady_clock::now().time_since_epoch())
                                 .count();
        if (ddrKickFailMs_ >= 0.0 && (nowMs - ddrKickFailMs_) < kReprobeIntervalMs) {
            setErr("sendDdrFrame: DDR path previously unavailable (re-probe in " +
                   std::to_string(static_cast<int>(kReprobeIntervalMs - (nowMs - ddrKickFailMs_))) +
                   " ms)");
            return false;
        }
        ddrKickMode_ = 0;
    }
    if (!ok() && !open())
        return false;
    if (!ensureDdrMap())
        return false;

    DdrTiming timing{};
    auto t0 = std::chrono::steady_clock::now();

    // Prefer the PLXD bank-release mailbox when it is present and live: it is the
    // authoritative scanout/release signal, so the old same-bank timing floor is
    // redundant on that path. Keep the timed interlock only as the structural
    // fallback for pre-PLXD cores, mailbox absence, or stale DDR residue.
    auto tPrep0 = std::chrono::steady_clock::now();
    bool plxdUsed = false;
    bool timedFallback = false;
    const int plannedBank = bank;
    {
        BankReleaseStatus brs;
        constexpr int kPlxdPollMaxIters = 20;  // bounded one-vsync release window
        int plxdIters = 0;
        if (readBankRelease(brs)) {
            // One-shot provenance diagnostic on first PLXD contact.
            if (!plxdLivenessProven_ && plxdStaleCount_ == 0 &&
                plxdLastFramesDone_ == 0) {
                auto diag = diagnosePlxdProvenance();
                const char* label = "?";
                switch (diag.provenance) {
                case PlxdProvenance::Absent:    label = "ABSENT"; break;
                case PlxdProvenance::Residue:   label = "RESIDUE(reserved!=0)"; break;
                case PlxdProvenance::InitOnly:  label = "INIT_ONLY(frames_done=0)"; break;
                case PlxdProvenance::Alive:     label = "ALIVE(frames_done>0,static)"; break;
                case PlxdProvenance::LiveAdvance: label = "LIVE_ADVANCE"; break;
                }
                fprintf(stderr,
                        "[PLXD-PROVENANCE] %s raw=0x%08x_%08x "
                        "frames_done=%u free_mask=%u disp=%u swap=%d reserved=0x%03x\n",
                        label, diag.raw_hi, diag.raw_lo,
                        diag.frames_done, diag.free_bank_mask,
                        diag.disp_bank, diag.swap_pending, diag.reserved_bits);
            }

            // --- Degeneracy defence (instrument-integrity #18) ---
            // A DDR word that happens to contain PLXD magic by coincidence
            // (boot residue) would pass the magic check and return valid-
            // looking fields. Defence: check frames_done advances between
            // successive frames. If it never advances, the mailbox is stale
            // (never written by the FPGA) and we must not trust it.
            if (brs.frames_done != plxdLastFramesDone_) {
                plxdLivenessProven_ = true;
                plxdStaleCount_ = 0;
            } else {
                ++plxdStaleCount_;
            }
            plxdLastFramesDone_ = brs.frames_done;
            constexpr int kPlxdStaleLimitFrames = 10;
            if (!plxdLivenessProven_ && plxdStaleCount_ >= kPlxdStaleLimitFrames) {
                // frames_done has not advanced in 10 consecutive reads.
                // This is almost certainly boot residue, not a live mailbox.
                fprintf(stderr,
                        "[STALE] sendDdrFrame: PLXD mailbox frames_done stuck at %u for "
                        "%d frames — treating as boot residue, falling back to timed delay\n",
                        static_cast<unsigned>(brs.frames_done), plxdStaleCount_);
                timedFallback = true;
            }

            BankReleaseStatus finalBrs = brs;
            if (!timedFallback && !plxdBankReleasePolicy_.release_stuck && !brs.anyFree()) {
                for (int i = 0; i < kPlxdPollMaxIters; ++i) {
                    usleep(1000);
                    ++plxdIters;
                    BankReleaseStatus next{};
                    if (readBankRelease(next)) {
                        finalBrs = next;
                        if (next.anyFree())
                            break;
                    }
                }
            }

            if (!timedFallback) {
                const bool wasStuck = plxdBankReleasePolicy_.release_stuck;
                const BankReleaseDecision decision =
                    chooseDdrPresentBankFromRelease(plxdBankReleasePolicy_, plannedBank,
                                                    brs, finalBrs);
                if (!wasStuck && decision.release_stuck) {
                    fprintf(stderr,
                            "[STALE] sendDdrFrame: PLXD free_bank_mask stayed 0 while "
                            "frames_done advanced %u→%u; using timed bank fallback until "
                            "free_bank_mask is observed\n",
                            static_cast<unsigned>(brs.frames_done),
                            static_cast<unsigned>(finalBrs.frames_done));
                }
                if (wasStuck && !decision.release_stuck && decision.kind ==
                        BankReleaseDecisionKind::UseFreeBank) {
                    fprintf(stderr,
                            "[PLXD-RECOVER] sendDdrFrame: free_bank_mask=%u observed; "
                            "resuming PLXD bank-release handshake\n",
                            static_cast<unsigned>(brs.free_bank_mask));
                }
                if (decision.kind == BankReleaseDecisionKind::UseFreeBank) {
                    // PLXD present and live — use it for bank selection. Do
                    // not also apply kDdrBankReuseMinUs here; the mailbox is
                    // the release proof.
                    bank = decision.bank;
                    plxdUsed = true;
                } else if (decision.kind == BankReleaseDecisionKind::UseTimedFallback) {
                    bank = decision.bank;
                    timedFallback = true;
                } else {
                    fprintf(stderr,
                            "[STALL] sendDdrFrame: PLXD bank-release busy after %d ms "
                            "(free_bank_mask=0, frames_done=%u disp_bank=%u swap_pending=%d); "
                            "skipping frame rather than guessing a bank\n",
                            plxdIters, static_cast<unsigned>(finalBrs.frames_done),
                            static_cast<unsigned>(finalBrs.disp_bank),
                            static_cast<int>(finalBrs.swap_pending));
                    setErr("sendDdrFrame: PLXD bank release busy; skipped unsafe overwrite");
                    return false;
                }
            }

            auto tPlxd1 = std::chrono::steady_clock::now();
            timing.plxa_poll_us = elapsedUs(tPrep0, tPlxd1);
            timing.plxa_poll_iters = plxdIters;
            timing.plxa_used = plxdUsed;
        } else {
            timedFallback = true;
        }
        if (timedFallback) {
            // PLXD absent, stale, or proven stuck on current silicon. For a
            // proven stuck live mailbox, choose the bank not currently scanned
            // out; for absent/stale mailboxes, use the host-planned bank. Keep
            // the same-bank reuse floor as the structural fallback interlock.
            //
            // Reachability: the absent branch (readBankRelease failed, no
            // magic) and the stale branch (magic present, frames_done never
            // advances) both set timedFallback WITHOUT calling
            // chooseDdrPresentBankFromRelease, so displayAvoidingFallbackBank()
            // never runs on a permanently silent fabric. Those are exactly the
            // paths a silent fabric takes. Apply the host-derived interlock
            // here, where all three silence routes converge, and only when the
            // mailbox has never been proven live — if frames_done has advanced
            // then disp_bank is a real reading and outranks our inference.
            if (!plxdLivenessProven_) {
                const int silentBank =
                    misterplex::silentFabricFallbackBank(bank, lastDdrDoorbellBank_);
                if (silentBank != bank) {
                    fprintf(stderr,
                            "[SILENT-FABRIC] sendDdrFrame: planned bank %d is the bank last "
                            "doorbelled (scanned per ddr_frame_store.sv:238); writing bank %d "
                            "instead\n",
                            bank, silentBank);
                    bank = silentBank;
                }
            }
            const double nowMs = std::chrono::duration<double, std::milli>(
                                     std::chrono::steady_clock::now().time_since_epoch())
                                     .count();
            const double lastBankMs = lastDdrBankDoorbellMs_[bank];
            if (lastBankMs >= 0.0) {
                const int64_t sinceUs =
                    static_cast<int64_t>((nowMs - lastBankMs) * 1000.0);
                if (sinceUs < kDdrBankReuseMinUs) {
                    const int64_t waitUs = kDdrBankReuseMinUs - sinceUs;
                    usleep(static_cast<useconds_t>(waitUs));
                    timing.bank_reuse_wait_us = waitUs;
                }
            }
        }
    }
    auto tPrep1 = std::chrono::steady_clock::now();
    timing.prep_wait_us = elapsedUs(tPrep0, tPrep1);

    // Copy frame into bank (persistent map).
    const size_t bankOff = static_cast<size_t>(bank) * plan.layout.bank_stride;
    auto tCopy0 = std::chrono::steady_clock::now();
    std::memcpy(ddrMap_ + bankOff, payload, len);
    __sync_synchronize();
    auto tCopy1 = std::chrono::steady_clock::now();
    timing.copy_us = elapsedUs(tCopy0, tCopy1);
    if (!ddrMemSync_ && ddrMemFlush_) {
        auto tFlush0 = std::chrono::steady_clock::now();
        if (!cleanDcacheRange(ddrMap_ + bankOff, len)) {
            setErr("sendDdrFrame: cache clean failed");
            return false;
        }
        __sync_synchronize();
        auto tFlush1 = std::chrono::steady_clock::now();
        timing.flush_us = elapsedUs(tFlush0, tFlush1);
    }

    bool saw_busy = false;
    bool saw_kick = false;
    bool saw_frame = false;
    const bool first = (ddrKickMode_ == 0);
    auto frameStoreStatusSuffix = [this]() -> std::string {
        FrameStoreStatus st{};
        if (readFrameStoreStatus(st)) {
            if (st.nonYuvDoorbellRejected())
                return std::string(": ") + frameStoreDebugDescription(st.debug_state);
            char buf[128]{};
            std::snprintf(buf, sizeof(buf),
                          ": frame-store status frame_debug=0x%02x frame_seq=%u "
                          "frame_underrun=%u",
                          static_cast<unsigned>(st.debug_state), static_cast<unsigned>(st.seq),
                          static_cast<unsigned>(st.underrun_count));
            return std::string(buf);
        }
        return std::string(": ") + frameStoreStatusUnavailableDescription() + ": " + lastError();
    };

    // Prefer mmap doorbell (no SPI on hot path). Fall back to SPI kick.
    bool kicked = false;
    auto tKick0 = std::chrono::steady_clock::now();
    if (ddrKickMode_ == 1 || ddrKickMode_ == 0) {
        if (kickDdrDoorbell(bank)) {
            kicked = true;
            if (first) {
                // Give poller time to see seq; expect busy / pending / has_frame.
                usleep(3000);
                for (int i = 0; i < 40; ++i) {
                    uint8_t raw[16]{};
                    {
                        SpiExclusive guard(map_);
                        if (!guard.safe() || !readStatusRaw(raw))
                            break;
                    }
                    CoreStatus st = parseCoreStatus(raw);
                    if (st.ddr_busy)
                        saw_busy = true;
                    if (st.has_frame)
                        saw_frame = true;
                    if (st.swap_pending)
                        saw_kick = true;
                    if (saw_busy || saw_frame || saw_kick)
                        break;
                    usleep(500);
                }
                if (!(saw_busy || saw_frame || saw_kick)) {
                    kicked = false; // fall through to SPI
                } else {
                    ddrKickMode_ = 1;
                }
            }
        }
    }
    if (!kicked && (ddrKickMode_ == 2 || ddrKickMode_ == 0)) {
        if (!kickDdrSpi(bank, first, saw_busy, saw_kick, saw_frame))
            return false;
        if (first) {
            const bool ok = saw_busy || (saw_kick && saw_frame) || saw_frame;
            if (!ok) {
                ddrKickMode_ = -1;
                ddrKickFailMs_ = std::chrono::duration<double, std::milli>(
                                     std::chrono::steady_clock::now().time_since_epoch())
                                     .count();
                setErr("sendDdrFrame: no kick/frame via SPI or doorbell" +
                       frameStoreStatusSuffix());
                return false;
            }
            ddrKickMode_ = 2;
        }
    }
    auto tKick1 = std::chrono::steady_clock::now();
    timing.doorbell_us = elapsedUs(tKick0, tKick1);
    if (first && ddrKickMode_ == 0) {
        ddrKickMode_ = -1;
        ddrKickFailMs_ = std::chrono::duration<double, std::milli>(
                             std::chrono::steady_clock::now().time_since_epoch())
                             .count();
        setErr("sendDdrFrame: could not kick DDR path" + frameStoreStatusSuffix());
        return false;
    }
    lastDdrBankDoorbellMs_[bank] = std::chrono::duration<double, std::milli>(
                                       std::chrono::steady_clock::now().time_since_epoch())
                                       .count();
    // The fabric adopts pending_bank on swap (ddr_frame_store.sv:238), so after
    // a successful doorbell this is the bank being scanned out. Recorded here
    // rather than inferred from PLXD so it survives a silent mailbox.
    lastDdrDoorbellBank_ = bank;

    // Steady-state: no fixed host sleep. PLXD (when valid), or the same-bank
    // reuse floor (fallback), is the safety interlock.
    auto tPost0 = std::chrono::steady_clock::now();
    auto tPost1 = std::chrono::steady_clock::now();
    timing.post_wait_us = elapsedUs(tPost0, tPost1);

    auto t1 = std::chrono::steady_clock::now();
    lastPushMs_ = std::chrono::duration<double, std::milli>(t1 - t0).count();
    timing.total_us = elapsedUs(t0, t1);
    lastDdrTiming_ = timing;
    clearErr();
    return true;
}

bool FpgaSpi::readFrameStoreStatus(FrameStoreStatus& out) {
    if (!ok() && !open())
        return false;
    if (!ensureDdrMap())
        return false;
    if (kUnderrunMailboxPhys < ddrLayout_.phys_base) {
        setErr("readFrameStoreStatus: PLXF mailbox is outside DDR frame window");
        return false;
    }
    const size_t off = static_cast<size_t>(kUnderrunMailboxPhys - ddrLayout_.phys_base);
    if (off + 8 > ddrMapLen_) {
        setErr("readFrameStoreStatus: PLXF mailbox is outside mapped DDR frame window");
        return false;
    }
    volatile uint32_t* mw = reinterpret_cast<volatile uint32_t*>(ddrMap_ + off);
    uint32_t lastLo = 0;
    uint32_t lastHi = 0;
    bool stable = false;
    for (int attempt = 0; attempt < 4; ++attempt) {
        const uint32_t lo0 = mw[0];
        const uint32_t hi0 = mw[1];
        __sync_synchronize();
        const uint32_t lo1 = mw[0];
        const uint32_t hi1 = mw[1];
        lastLo = lo1;
        lastHi = hi1;
        stable = (lo0 == lo1 && hi0 == hi1);
        if (decodeStableFrameStoreStatus(lo0, hi0, lo1, hi1, out)) {
            clearErr();
            return true;
        }
        usleep(200);
    }
    if (stable && lastLo != kUnderrunMailboxMagic) {
        char buf[160]{};
        std::snprintf(buf, sizeof(buf),
                      "readFrameStoreStatus: PLXF mailbox absent/unwritten "
                      "(lo=0x%08x hi=0x%08x)",
                      static_cast<unsigned>(lastLo), static_cast<unsigned>(lastHi));
        setErr(buf);
        return false;
    }
    setErr("readFrameStoreStatus: PLXF mailbox not valid/stable");
    return false;
}

bool FpgaSpi::readBankRelease(BankReleaseStatus& out) {
    if (!ok() && !open())
        return false;
    if (!ensureDdrMap())
        return false;
    if (kBankReleaseMailboxPhys < ddrLayout_.phys_base) {
        setErr("readBankRelease: PLXD mailbox is outside DDR frame window");
        return false;
    }
    const size_t off = static_cast<size_t>(kBankReleaseMailboxPhys - ddrLayout_.phys_base);
    if (off + 8 > ddrMapLen_) {
        setErr("readBankRelease: PLXD mailbox is outside mapped DDR frame window");
        return false;
    }
    volatile uint32_t* mw = reinterpret_cast<volatile uint32_t*>(ddrMap_ + off);
    for (int attempt = 0; attempt < 4; ++attempt) {
        const uint32_t lo0 = mw[0];
        const uint32_t hi0 = mw[1];
        __sync_synchronize();
        const uint32_t lo1 = mw[0];
        const uint32_t hi1 = mw[1];
        if (decodeStableBankRelease(lo0, hi0, lo1, hi1, out)) {
            clearErr();
            return true;
        }
        usleep(200);
    }
    setErr("readBankRelease: PLXD mailbox absent or unstable");
    return false;
}

FpgaSpi::PlxdDiag FpgaSpi::diagnosePlxdProvenance() {
    PlxdDiag d{};
    if ((!ok() && !open()) || !ensureDdrMap())
        return d; // Absent
    if (kBankReleaseMailboxPhys < ddrLayout_.phys_base)
        return d;
    const size_t off = static_cast<size_t>(kBankReleaseMailboxPhys - ddrLayout_.phys_base);
    if (off + 8 > ddrMapLen_)
        return d;

    volatile uint32_t* mw = reinterpret_cast<volatile uint32_t*>(ddrMap_ + off);
    __sync_synchronize();
    d.raw_lo = mw[0];
    d.raw_hi = mw[1];
    __sync_synchronize();

    // Check magic
    if (d.raw_lo != mailbox_abi::kPlxdMagic) {
        d.provenance = PlxdProvenance::Absent;
        return d;
    }

    // Decode fields from raw_hi per PLXD layout:
    // [33:32] = raw_hi[1:0] = free_bank_mask
    // [34]    = raw_hi[2]   = disp_bank
    // [35]    = raw_hi[3]   = swap_pending
    // [47:36] = raw_hi[15:4]= reserved (should be 0)
    // [63:48] = raw_hi[31:16]= frames_done
    d.free_bank_mask = d.raw_hi & 0x03;
    d.disp_bank = (d.raw_hi >> 2) & 0x01;
    d.swap_pending = ((d.raw_hi >> 3) & 0x01) != 0;
    d.reserved_bits = (d.raw_hi >> 4) & 0x0FFF;
    d.frames_done = static_cast<uint16_t>(d.raw_hi >> 16);

    // Reserved bits should be zero if RTL wrote this. Non-zero = suspect residue.
    if (d.reserved_bits != 0) {
        d.provenance = PlxdProvenance::Residue;
        return d;
    }

    // Valid magic, clean reserved bits. Check frames_done.
    if (d.frames_done == 0) {
        d.provenance = PlxdProvenance::InitOnly;
        return d;
    }

    // frames_done > 0 — at least one bank swap occurred. Now check liveness
    // by reading again after a short delay to see if it advances.
    usleep(5000); // 5 ms — one vsync at 60 Hz is ~16.7 ms
    __sync_synchronize();
    const uint32_t hi2 = mw[1];
    __sync_synchronize();
    const uint16_t frames_done2 = static_cast<uint16_t>(hi2 >> 16);

    if (frames_done2 != d.frames_done) {
        d.provenance = PlxdProvenance::LiveAdvance;
    } else {
        d.provenance = PlxdProvenance::Alive;
    }
    return d;
}

bool FpgaSpi::sendYuv420pFrameDdr(const uint8_t* yuv420p, size_t len,
                                  const DdrFrameGeometry& geometry, int bank) {
    DdrPublishFrame frame{yuv420p, len, geometry, DdrFrameFormat::Yuv420p};
    return publishDdrFrame(frame, bank);
}

bool FpgaSpi::publishDdrFrame(const DdrPublishFrame& frame, int bank) {
    DdrPublishPlan plan{};
    std::string err;
    if (!makeDdrPublishPlan(frame, bank, plan, &err)) {
        setErr(err);
        return false;
    }
    if (plan.layout.coded_width != ddrLayout_.coded_width ||
        plan.layout.coded_height != ddrLayout_.coded_height ||
        plan.layout.display_width != ddrLayout_.display_width ||
        plan.layout.display_height != ddrLayout_.display_height ||
        plan.layout.presented_width != ddrLayout_.presented_width ||
        plan.layout.presented_height != ddrLayout_.presented_height ||
        plan.layout.crop_left != ddrLayout_.crop_left ||
        plan.layout.crop_right != ddrLayout_.crop_right ||
        plan.layout.crop_top != ddrLayout_.crop_top ||
        plan.layout.crop_bottom != ddrLayout_.crop_bottom ||
        plan.layout.present_x != ddrLayout_.present_x ||
        plan.layout.present_y != ddrLayout_.present_y ||
        plan.layout.format != ddrLayout_.format) {
        if (!setDdrFrameLayout(frame.geometry, frame.format))
            return false;
    }
    if (ddrLayout_.bank_stride != plan.layout.bank_stride ||
        ddrLayout_.doorbell_phys != plan.layout.doorbell_phys ||
        ddrLayout_.frame_bytes != plan.layout.frame_bytes) {
        setErr("publishDdrFrame: active DDR layout disagrees with derived frame geometry");
        return false;
    }
    return sendDdrFrame(frame, plan);
}

bool FpgaSpi::sendYuv420pFrameDdr(const uint8_t* yuv420p, size_t len, int width, int height,
                                  int bank) {
    return sendYuv420pFrameDdr(yuv420p, len, makeDdrFrameGeometry(width, height), bank);
}

bool FpgaSpi::sendPcmChunk(const uint8_t* pcm, size_t len, uint8_t index) {
    if (!pcm || !len) {
        setErr("sendPcmChunk: empty");
        return false;
    }
    // Align to 4-byte stereo frames
    len &= ~size_t(3);
    if (!len)
        return true;
    return sendFileTx(pcm, len, index);
}

bool FpgaSpi::sendBitstreamChunk(const uint8_t* data, size_t len, uint8_t index) {
    if (!data || !len) {
        setErr("sendBitstreamChunk: empty");
        return false;
    }
    return sendFileTx(data, len, index);
}

bool FpgaSpi::flushBitstreamDdr() {
    namespace ring = ddr_bitstream_ring;
    if (!ensureBitstreamDdrMap())
        return false;
    bitstreamWriteCount_ = 0;
    bitstreamLegacySeq_ = 0;
    bitstreamLegacyActive_ = false;
    bitstreamResetEpoch_ = !bitstreamResetEpoch_;
    std::memset(bitstreamMap_, 0, ring::kRingBytes);
    publishBitstreamCtrl();
    clearErr();
    return true;
}

bool FpgaSpi::beginBitstreamSession(uint64_t session_id, int timeout_ms) {
    BitstreamStatus st;
    if (readBitstreamStatus(st) && st.active) {
        setErr("beginBitstreamSession: session already active; end first");
        return false;
    }
    const auto r = writeBitstreamRecord(ddr_bitstream_ring::Event::Begin, session_id, 0, 0,
                                        nullptr, 0, timeout_ms);
    if (r != BitstreamPushResult::Ok)
        return false;
    return waitBitstreamReadCount(bitstreamWriteCount_, timeout_ms);
}

FpgaSpi::BitstreamPushResult FpgaSpi::pushBitstreamNal(const BitstreamNal& nal,
                                                       int timeout_ms) {
    if (!nal.annexb || !nal.len) {
        setErr("pushBitstreamNal: empty NAL");
        return BitstreamPushResult::Fatal;
    }
    BitstreamStatus st;
    if (readBitstreamStatus(st)) {
        if (st.fatal || st.desync)
            return BitstreamPushResult::Desync;
        if (!st.active || st.session_id != nal.session_id) {
            setErr("pushBitstreamNal: stale or inactive session");
            return BitstreamPushResult::Desync;
        }
    }
    return writeBitstreamRecord(ddr_bitstream_ring::Event::Nal, nal.session_id, nal.seq,
                                nal.nal_type, nal.annexb, nal.len, timeout_ms);
}

bool FpgaSpi::flushBitstreamSession(uint64_t session_id, int timeout_ms) {
    const auto r = writeBitstreamRecord(ddr_bitstream_ring::Event::Flush, session_id, 0, 0,
                                        nullptr, 0, timeout_ms);
    if (r != BitstreamPushResult::Ok)
        return false;
    return waitBitstreamReadCount(bitstreamWriteCount_, timeout_ms);
}

bool FpgaSpi::endBitstreamSession(uint64_t session_id, int timeout_ms) {
    const auto r = writeBitstreamRecord(ddr_bitstream_ring::Event::End, session_id, 0, 0,
                                        nullptr, 0, timeout_ms);
    if (r != BitstreamPushResult::Ok)
        return false;
    const bool ok = waitBitstreamReadCount(bitstreamWriteCount_, timeout_ms);
    if (ok && session_id == bitstreamLegacySessionId_)
        bitstreamLegacyActive_ = false;
    return ok;
}

bool FpgaSpi::pauseBitstreamSession(uint64_t session_id, int timeout_ms) {
    const auto r = writeBitstreamRecord(ddr_bitstream_ring::Event::Pause, session_id, 0, 0,
                                        nullptr, 0, timeout_ms);
    if (r != BitstreamPushResult::Ok)
        return false;
    return waitBitstreamReadCount(bitstreamWriteCount_, timeout_ms);
}

bool FpgaSpi::resumeBitstreamSession(uint64_t session_id, int timeout_ms) {
    const auto r = writeBitstreamRecord(ddr_bitstream_ring::Event::Resume, session_id, 0, 0,
                                        nullptr, 0, timeout_ms);
    if (r != BitstreamPushResult::Ok)
        return false;
    return waitBitstreamReadCount(bitstreamWriteCount_, timeout_ms);
}

bool FpgaSpi::sendBitstreamChunkDdr(const uint8_t* data, size_t len) {
    if (!data || !len) {
        setErr("sendBitstreamChunkDdr: empty");
        return false;
    }
    if (!bitstreamLegacyActive_) {
        if (!beginBitstreamSession(bitstreamLegacySessionId_, 250))
            return false;
        bitstreamLegacyActive_ = true;
        bitstreamLegacySeq_ = 0;
    }
    BitstreamNal nal;
    nal.session_id = bitstreamLegacySessionId_;
    nal.seq = bitstreamLegacySeq_++;
    nal.nal_type = len >= 5 && data[0] == 0 && data[1] == 0
                       ? static_cast<uint8_t>(data[(data[2] == 1) ? 3 : 4] & 0x1f)
                       : 0;
    nal.annexb = data;
    nal.len = len;
    const auto r = pushBitstreamNal(nal, 250);
    if (r == BitstreamPushResult::Ok)
        return true;
    if (r == BitstreamPushResult::Full)
        setErr("sendBitstreamChunkDdr: FPGA ring full");
    else if (r == BitstreamPushResult::Desync)
        setErr("sendBitstreamChunkDdr: FPGA transport desync");
    else
        setErr("sendBitstreamChunkDdr: FPGA transport fatal");
    return false;
}

bool FpgaSpi::flushAudioFifo() {
    // Pulse status[10] high then low (OSD T[10] / present_core af_wr_flush)
    if (!setStatusBit(10, 1))
        return false;
    // brief hold so FPGA samples the bit
    usleep(2000);
    return setStatusBit(10, 0);
}

bool FpgaSpi::flushBitstreamFifo() {
    bool ddr_ok = flushBitstreamDdr();
    if (!setStatusBit(11, 1))
        return ddr_ok;
    usleep(2000);
    return setStatusBit(11, 0) || ddr_ok;
}

bool FpgaSpi::getCoreStatus(uint8_t out[16]) {
    if (!ok() || !out) {
        setErr("getCoreStatus: not open");
        return false;
    }
    // Mutex + flock + Main pause so UIO_GET_STATUS is not interleaved.
    SpiExclusive guard(map_);
    if (!guard.safe()) {
        err_ = "Main busy on SPI — skipped";
        return false;
    }
    if (!gpiUserMode(map_)) {
        err_ = "FPGA not in user mode";
        return false;
    }
    err_.clear();
    if (!readStatusRaw(out))
        return false;
    err_.clear();
    return true;
}

FpgaSpi::CoreStatus FpgaSpi::parseCoreStatus(const uint8_t raw[16]) {
    // status_in v2 (OSD-safe) — see Plex.sv. Telemetry starts at bit 16 so
    // Main status_set does not wipe OSD / DDR kick bits 12–13.
    //   [15:0]   OSD (ignored for telem)
    //   [23:16]  flags   [31:24] last_nal
    //   [47:32]  nalu_count
    //   [55:48]  mb0     [63:56] slice_type
    //   [71:64]  residual pack   [79:72] {ddr_busy,swap_pending,qp}
    //   [87:80]  sps_mb_w        [95:88] sps_mb_h
    //   [103:96] residual_dc  [111:104] residual_csum8
    //   [119:112] recon_sig   [127:120] recon RCA debug flags (AR may touch [122:121])
    //   Pre-3.3l-1 RBF: [127:104] was 24b bytes; pre-3.3l-2: [127:112] was 16b bytes.
    CoreStatus s{};
    const uint16_t w1 = static_cast<uint16_t>(raw[2] | (raw[3] << 8));
    const uint16_t w2 = static_cast<uint16_t>(raw[4] | (raw[5] << 8));
    const uint16_t w3 = static_cast<uint16_t>(raw[6] | (raw[7] << 8));
    const uint16_t w4 = static_cast<uint16_t>(raw[8] | (raw[9] << 8));
    const uint16_t w5 = static_cast<uint16_t>(raw[10] | (raw[11] << 8));

    const uint8_t flags = static_cast<uint8_t>(w1 & 0xFF);
    s.has_frame = (flags & 1) != 0;
    s.has_audio = (flags & 2) != 0;
    s.has_stream = (flags & 4) != 0;
    s.audio_underrun = (flags & 8) != 0;
    s.has_idr = (flags & 16) != 0;
    s.stub_busy = (flags & 32) != 0;
    s.sps_valid = (flags & 64) != 0;
    s.pps_valid = (flags & 128) != 0;
    s.last_nal_type = static_cast<uint8_t>((w1 >> 8) & 0xFF);
    s.nalu_count = w2;
    s.first_mb_type = static_cast<uint8_t>(w3 & 0xFF);
    s.slice_type = static_cast<uint8_t>((w3 >> 8) & 0xFF);
    s.stub_frames = s.slice_type;
    s.wr_count_lo = w3;

    const uint8_t res_pack = static_cast<uint8_t>(w4 & 0xFF);
    s.residual_ok = (res_pack & 0x80) != 0;
    s.residual_tc = static_cast<uint8_t>((res_pack >> 2) & 0x1F);
    s.residual_t1 = static_cast<uint8_t>(res_pack & 0x3);
    const uint8_t ddr_qp = static_cast<uint8_t>((w4 >> 8) & 0xFF);
    s.ddr_busy = (ddr_qp & 0x80) != 0;
    s.swap_pending = (ddr_qp & 0x40) != 0;
    s.slice_qp = static_cast<uint8_t>(ddr_qp & 0x3F);
    s.stream_fifo_level = 0;

    const uint8_t mb_w = static_cast<uint8_t>(w5 & 0xFF);
    const uint8_t mb_h = static_cast<uint8_t>((w5 >> 8) & 0xFF);
    s.sps_width = static_cast<uint16_t>(mb_w) * 16u;
    s.sps_height = static_cast<uint16_t>(mb_h) * 16u;

    s.stream_bytes_seen = 0;
    // [103:96]=residual_dc (raw[12]); [111:104]=residual_csum (raw[13]);
    // [119:112]=recon_sig (raw[14]); [127:120]=recon RCA flags (raw[15]).
    // residual_dc/csum/recon_sig stay below AR splice.
    using namespace status_telemetry;
    s.residual_dc = static_cast<int8_t>(raw[kResidualDcByte]);
    s.residual_csum = raw[kResidualCsumByte];
    s.recon_sig = raw[kReconSigByte];
    s.recon_dbg = raw[kReconDbgByte];
    // Stream byte telemetry was reclaimed for P3-3l2 silicon RCA. Publish the
    // NAL-count liveness mirror under an explicit name; keep stream_bytes_in
    // only as a deprecated in-process compatibility alias.
    s.stream_nalus = static_cast<uint32_t>(s.nalu_count);
    s.stream_bytes_in = s.stream_nalus;
    s.idr_count = s.has_idr ? 1 : 0;
    return s;
}

bool FpgaSpi::readCoreStatus(CoreStatus& out) {
    // Prefer consistent samples: same NAL liveness twice, or any stable stream with NALs.
    CoreStatus best{};
    bool have = false;
    for (int attempt = 0; attempt < 8; ++attempt) {
        uint8_t raw[16]{};
        if (!getCoreStatus(raw))
            return false;
        CoreStatus s = parseCoreStatus(raw);
        // Sanity: status no longer carries byte counts; nalu not huge garbage.
        bool sane = s.nalu_count < 10000 && s.stream_nalus < 10000 &&
                    s.sps_width <= 4096 && s.sps_height <= 2160;
        if (!sane) {
            usleep(10000);
            continue;
        }
        if (have && s.nalu_count == best.nalu_count && s.stream_nalus == best.stream_nalus &&
            s.has_stream == best.has_stream && s.sps_valid == best.sps_valid) {
            out = s;
            return true;
        }
        best = s;
        have = true;
        // Strong signal: stream with NALs (and optional SPS)
        if (s.has_stream && s.stream_nalus > 0 && s.nalu_count > 0) {
            out = s;
            return true;
        }
        usleep(10000);
    }
    out = best;
    return have;
}

} // namespace misterplex
