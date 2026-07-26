#include <cerrno>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <ctime>
#include <fcntl.h>
#include <string>
#include <sys/mman.h>
#include <sys/syscall.h>
#include <unistd.h>

namespace {

constexpr uint32_t kDdrFrameBase = 0x30000000u;
constexpr uint32_t kDdrFrameStride = 0x40000u;
constexpr size_t kDdrMapLen = 0x80000u;
constexpr size_t kDefaultFrameBytes = 320 * 240 * 2;

double nowSec() {
    timespec ts{};
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return static_cast<double>(ts.tv_sec) + static_cast<double>(ts.tv_nsec) / 1e9;
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

void fillPattern(uint8_t* buf, size_t len) {
    uint32_t x = 0x12345678u;
    for (size_t i = 0; i < len; ++i) {
        x ^= x << 13;
        x ^= x >> 17;
        x ^= x << 5;
        buf[i] = static_cast<uint8_t>(x);
    }
}

void usage(const char* argv0) {
    std::printf(
        "Usage: %s [--sync|--no-sync] [--flush] [--loops N] [--len BYTES] [--bank 0|1]\n"
        "Writes a DDR frame window only; it does not touch SPI or kick the frame reader.\n",
        argv0);
}

} // namespace

int main(int argc, char** argv) {
    bool useSync = true;
    bool flush = false;
    int loops = 1000;
    size_t len = kDefaultFrameBytes;
    int bank = 0;

    for (int i = 1; i < argc; ++i) {
        std::string a = argv[i];
        if (a == "--sync") {
            useSync = true;
        } else if (a == "--no-sync") {
            useSync = false;
        } else if (a == "--flush") {
            flush = true;
        } else if (a == "--loops" && i + 1 < argc) {
            loops = std::atoi(argv[++i]);
        } else if (a == "--len" && i + 1 < argc) {
            len = static_cast<size_t>(std::strtoull(argv[++i], nullptr, 0));
        } else if (a == "--bank" && i + 1 < argc) {
            bank = std::atoi(argv[++i]);
        } else if (a == "-h" || a == "--help") {
            usage(argv[0]);
            return 0;
        } else {
            std::fprintf(stderr, "unknown arg: %s\n", a.c_str());
            usage(argv[0]);
            return 2;
        }
    }

    if (loops <= 0 || len == 0 || bank < 0 || bank > 1 ||
        static_cast<size_t>(bank) * kDdrFrameStride + len > kDdrMapLen) {
        std::fprintf(stderr, "bad loops/len/bank\n");
        return 2;
    }

    void* srcRaw = nullptr;
    if (posix_memalign(&srcRaw, 64, len) != 0) {
        std::perror("posix_memalign");
        return 1;
    }
    uint8_t* src = static_cast<uint8_t*>(srcRaw);
    fillPattern(src, len);

    int flags = O_RDWR | O_CLOEXEC;
    if (useSync)
        flags |= O_SYNC;
    int fd = ::open("/dev/mem", flags);
    if (fd < 0) {
        std::perror("open /dev/mem");
        std::free(srcRaw);
        return 1;
    }

    void* map =
        mmap(nullptr, kDdrMapLen, PROT_READ | PROT_WRITE, MAP_SHARED, fd, kDdrFrameBase);
    if (map == MAP_FAILED) {
        std::perror("mmap");
        ::close(fd);
        std::free(srcRaw);
        return 1;
    }

    uint8_t* dst = static_cast<uint8_t*>(map) + static_cast<size_t>(bank) * kDdrFrameStride;
    std::memcpy(dst, src, len);
    __sync_synchronize();
    if (flush && !cleanDcacheRange(dst, len)) {
        std::perror("cacheflush warmup");
        munmap(map, kDdrMapLen);
        ::close(fd);
        std::free(srcRaw);
        return 1;
    }

    const double t0 = nowSec();
    for (int i = 0; i < loops; ++i) {
        src[static_cast<size_t>(i) % len] ^= static_cast<uint8_t>(i);
        std::memcpy(dst, src, len);
        __sync_synchronize();
        if (flush && !cleanDcacheRange(dst, len)) {
            std::perror("cacheflush");
            munmap(map, kDdrMapLen);
            ::close(fd);
            std::free(srcRaw);
            return 1;
        }
    }
    __sync_synchronize();
    const double t1 = nowSec();

    const double sec = t1 - t0;
    const double mib = (static_cast<double>(len) * loops) / (1024.0 * 1024.0);
    std::printf("ddr_write_bench sync=%d flush=%d loops=%d len=%zu bank=%d seconds=%.6f "
                "MiB=%.3f MiBps=%.3f frame_ms=%.3f\n",
                useSync ? 1 : 0, flush ? 1 : 0, loops, len, bank, sec, mib, mib / sec,
                (sec * 1000.0) / static_cast<double>(loops));

    munmap(map, kDdrMapLen);
    ::close(fd);
    std::free(srcRaw);
    return 0;
}
