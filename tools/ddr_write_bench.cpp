// ddr_write_bench — measure sequential write bandwidth into the MiSTerPlex DDR
// frame-store window at phys 0x30000000 via the same /dev/mem mmap class as
// misterplexd (FpgaSpi::ensureDdrMap).
//
// Safety:
//   - Maps only kDdrFramePhysBase + layout.map_bytes (two banks + doorbell page).
//   - Writes only into the selected bank payload; does NOT write doorbell magic
//     and does NOT touch SPI / kick the FPGA reader.
//   - Optional --fb-copy measures /dev/fb0 driver mapping bandwidth as a
//     separate control (different physical pages — not the frame store).
//
// Cache-policy evidence on device:
//   Prints /proc/self/smaps VmFlags for the mapped VA. Look for "dc" (don't
//   cache). Bandwidth class (~60 MiB/s vs multi-hundred+) is the secondary
//   instrument when VmFlags are ambiguous.

#include <cerrno>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <ctime>
#include <fcntl.h>
#include <linux/fb.h>
#include <string>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <sys/syscall.h>
#include <unistd.h>

#include "libmisterplex/ddr_frame_layout.hpp"

namespace {

constexpr uint32_t kDdrFrameBase = 0x30000000u;
constexpr size_t kDefaultFrameBytes = 320 * 240 * 3 / 2;

// Pre-registered predictions (w-bw, BEFORE parent device run). Publish hit/miss
// after parent pastes MiBps lines. Source of prior: archive
// build/arm-sleep-evidence/W-FEED-arm-profile-ORIGINAL.txt @ 624x480 I420.
//   O_SYNC:     MiBps=58.074 frame_ms=7.378
//   no-sync:    MiBps=59.521 frame_ms=7.199
//   +cacheflush MiBps=32.348 frame_ms=13.246
// Prediction band for product /dev/mem path (either sync): 50..70 MiB/s.
// Prediction if write-through like MiSTerFin fb claim: >800 MiB/s.
// Prediction fb0 driver map (if usable): UNKNOWN — measure, do not assume 1.5GB/s.

const char* formatName(misterplex::DdrFrameFormat) {
    return "yuv420p";
}

double nowSec() {
    timespec ts{};
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return static_cast<double>(ts.tv_sec) + static_cast<double>(ts.tv_nsec) / 1e9;
}

double threadCpuSec() {
    timespec ts{};
    clock_gettime(CLOCK_THREAD_CPUTIME_ID, &ts);
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

// Emit the smaps entry covering [addr, addr+len). Parent greps VmFlags=.
void printSmapsFor(const void* addr, size_t len, const char* tag) {
    const uintptr_t start = reinterpret_cast<uintptr_t>(addr);
    const uintptr_t end = start + len;
    FILE* f = std::fopen("/proc/self/smaps", "r");
    if (!f) {
        std::printf("smaps_tag=%s status=open_failed errno=%d\n", tag, errno);
        return;
    }
    char line[512];
    bool in = false;
    bool any = false;
    uintptr_t rangeLo = 0, rangeHi = 0;
    while (std::fgets(line, sizeof(line), f)) {
        unsigned long a = 0, b = 0;
        char perms[8] = {};
        if (std::sscanf(line, "%lx-%lx %7s", &a, &b, perms) == 3) {
            in = (static_cast<uintptr_t>(a) <= start && end <= static_cast<uintptr_t>(b));
            if (in) {
                rangeLo = static_cast<uintptr_t>(a);
                rangeHi = static_cast<uintptr_t>(b);
                any = true;
                std::printf("smaps_tag=%s range=%lx-%lx perms=%s header=%s", tag, a, b, perms,
                            line);
            }
            continue;
        }
        if (!in)
            continue;
        if (std::strncmp(line, "VmFlags:", 8) == 0 ||
            std::strncmp(line, "KernelPageSize:", 15) == 0 ||
            std::strncmp(line, "MMUPageSize:", 12) == 0 ||
            std::strncmp(line, "Size:", 5) == 0 || std::strncmp(line, "MappingName:", 12) == 0) {
            std::printf("smaps_tag=%s %s", tag, line);
        }
    }
    std::fclose(f);
    if (!any) {
        std::printf("smaps_tag=%s status=no_entry va=%p len=%zu\n", tag,
                    static_cast<const void*>(addr), len);
    } else {
        std::printf("smaps_tag=%s note=look_for_VmFlags_token_dc_means_dont_cache "
                    "covered=%lx-%lx\n",
                    tag, static_cast<unsigned long>(rangeLo),
                    static_cast<unsigned long>(rangeHi));
    }
}

void usage(const char* argv0) {
    std::printf(
        "Usage: %s [--sync|--no-sync] [--flush] [--read] [--host-copy] [--fb-copy]\n"
        "          [--no-smaps] [--format yuv420p] [--geometry auto|exact|plex480p]\n"
        "          [--width W --height H | --len BYTES]\n"
        "          [--loops N] [--bank 0|1]\n"
        "\n"
        "Product path: mmap /dev/mem @ 0x30000000 (same class as misterplexd ensureDdrMap).\n"
        "Default: sequential WRITE into bank payload — no doorbell kick, no SPI.\n"
        "--read: sequential READ from bank payload into a local buffer (ARM read BW).\n"
        "  Note: FPGA scanout uses the DDRAM bridge @ clk_ddr, NOT this ARM path.\n"
        "--fb-copy: sequential write into /dev/fb0 driver map (CONTROL; not frame store).\n"
        "--host-copy: anonymous RAM memcpy (build-host sanity only).\n"
        "Prints MiBps= and smaps VmFlags= for parent cache-policy scoring.\n",
        argv0);
}

struct BenchOut {
    double wallSec = 0;
    double cpuSec = 0;
    uint64_t checksum = 0;
};

// dirWrite=true: src -> dst (product push). dirWrite=false: src is mapped bank, dst local.
BenchOut runMemcpyLoops(uint8_t* dst, uint8_t* src, size_t len, int loops, bool flush,
                        bool dirWrite) {
    BenchOut o{};
    if (dirWrite) {
        std::memcpy(dst, src, len);
        __sync_synchronize();
        if (flush)
            (void)cleanDcacheRange(dst, len);
    } else {
        std::memcpy(dst, src, len);
        __sync_synchronize();
    }

    const double t0 = nowSec();
    const double c0 = threadCpuSec();
    for (int i = 0; i < loops; ++i) {
        if (dirWrite) {
            src[static_cast<size_t>(i) % len] ^= static_cast<uint8_t>(i);
            std::memcpy(dst, src, len);
            __sync_synchronize();
            if (flush && !cleanDcacheRange(dst, len)) {
                std::perror("cacheflush");
                o.wallSec = -1;
                return o;
            }
            o.checksum += dst[(static_cast<size_t>(i) * 257) % len];
        } else {
            std::memcpy(dst, src, len);
            __sync_synchronize();
            o.checksum += dst[(static_cast<size_t>(i) * 257) % len];
            dst[static_cast<size_t>(i) % len] ^= static_cast<uint8_t>(i);
        }
    }
    __sync_synchronize();
    const double c1 = threadCpuSec();
    const double t1 = nowSec();
    o.wallSec = t1 - t0;
    o.cpuSec = c1 - c0;
    return o;
}

void printResult(const char* pathTag, bool hostCopy, bool useSync, bool flush, int loops,
                 size_t len, int bank, const misterplex::DdrFrameLayout& layout, double wallSec,
                 double cpuSec, uint64_t checksum, const char* rw) {
    if (wallSec < 0) {
        std::printf("ddr_write_bench path=%s status=fail\n", pathTag);
        return;
    }
    const double mib = (static_cast<double>(len) * loops) / (1024.0 * 1024.0);
    const double mb = (static_cast<double>(len) * loops) / (1000.0 * 1000.0);
    const double frameMs = (wallSec * 1000.0) / static_cast<double>(loops);
    const double frameCpuMs = (cpuSec * 1000.0) / static_cast<double>(loops);
    std::printf(
        "ddr_write_bench path=%s rw=%s host_copy=%d sync=%d flush=%d loops=%d len=%zu bank=%d "
        "format=%s coded=%dx%d display=%dx%d presented=%dx%d "
        "present_x=%d present_y=%d line_bytes=%d line_qwords=%d "
        "chroma_line_bytes=%d chroma_line_qwords=%d bank_stride=0x%X "
        "map_bytes=0x%X phys_base=0x%X seconds=%.6f cpu_seconds=%.6f "
        "MiB=%.3f MiBps=%.3f MBps=%.3f frame_ms=%.3f frame_cpu_ms=%.3f "
        "fps30_budget_pct=%.1f fps60_budget_pct=%.1f checksum=%llu\n",
        pathTag, rw, hostCopy ? 1 : 0, useSync ? 1 : 0, flush ? 1 : 0, loops, len, bank,
        formatName(layout.format), layout.coded_width.get(), layout.coded_height.get(),
        layout.display_width.get(), layout.display_height.get(), layout.presented_width.get(),
        layout.presented_height.get(), layout.present_x, layout.present_y, layout.line_bytes,
        layout.line_qwords, layout.chroma_line_bytes, layout.chroma_line_qwords, layout.bank_stride,
        layout.map_bytes, layout.phys_base, wallSec,
        cpuSec, mib, mib / wallSec, mb / wallSec, frameMs, frameCpuMs, 100.0 * frameMs / 33.333333,
        100.0 * frameMs / 16.666667, static_cast<unsigned long long>(checksum));
}

} // namespace

int main(int argc, char** argv) {
    bool useSync = true;
    bool flush = false;
    bool hostCopy = false;
    bool fbCopy = false;
    bool doRead = false;
    bool dumpSmaps = true;
    int loops = 1000;
    size_t len = kDefaultFrameBytes;
    int bank = 0;
    int width = 320;
    int height = 240;
    bool lenSet = false;
    std::string geometryMode = "auto";
    misterplex::DdrFrameFormat format = misterplex::DdrFrameFormat::Yuv420p;

    for (int i = 1; i < argc; ++i) {
        std::string a = argv[i];
        if (a == "--sync") {
            useSync = true;
        } else if (a == "--no-sync") {
            useSync = false;
        } else if (a == "--flush") {
            flush = true;
        } else if (a == "--read") {
            doRead = true;
        } else if (a == "--host-copy") {
            hostCopy = true;
        } else if (a == "--fb-copy") {
            fbCopy = true;
        } else if (a == "--no-smaps") {
            dumpSmaps = false;
        } else if (a == "--width" && i + 1 < argc) {
            width = std::atoi(argv[++i]);
        } else if (a == "--height" && i + 1 < argc) {
            height = std::atoi(argv[++i]);
        } else if (a == "--format" && i + 1 < argc) {
            std::string v = argv[++i];
            if (v == "yuv420p" || v == "yuv420" || v == "i420") {
                format = misterplex::DdrFrameFormat::Yuv420p;
            } else {
                std::fprintf(stderr,
                             "unsupported DDR format: %s (C3 frame store is yuv420p only)\n",
                             v.c_str());
                return 2;
            }
        } else if (a == "--geometry" && i + 1 < argc) {
            std::string v = argv[++i];
            if (v == "plex480p" || v == "real480p") {
                geometryMode = "plex480p";
            } else if (v == "exact" || v == "coded") {
                geometryMode = "exact";
            } else if (v == "auto") {
                geometryMode = "auto";
            } else {
                std::fprintf(stderr, "unknown geometry: %s\n", v.c_str());
                return 2;
            }
        } else if (a == "--loops" && i + 1 < argc) {
            loops = std::atoi(argv[++i]);
        } else if (a == "--len" && i + 1 < argc) {
            len = static_cast<size_t>(std::strtoull(argv[++i], nullptr, 0));
            lenSet = true;
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

    if (fbCopy && doRead) {
        std::fprintf(stderr, "--fb-copy and --read are mutually exclusive in this build\n");
        return 2;
    }

    std::printf(
        "ddr_write_bench_meta method=%s "
        "product_path=/dev/mem@0x%08X yuv420p_not_bgra "
        "prereg_devmem_mibps_lo=50 prereg_devmem_mibps_hi=70 "
        "prereg_writethrough_mibps_lo=800 "
        "prereg_source=W-FEED-arm-profile-ORIGINAL_624x480 "
        "misterfin_claim_uncached_mbs=60 misterfin_claim_fb_wt_gbs=1.5 "
        "misterfin_claim_NOT_ours=1 "
        "NOTE_fpga_scanout_uses_ddram_bridge_not_this_arm_path=1\n",
        doRead ? "sequential_memcpy_from_mapped_bank" : "sequential_memcpy_into_mapped_bank",
        kDdrFrameBase);

    const bool plex480pGeometry =
        geometryMode == "plex480p" ||
        (geometryMode == "auto" && width == misterplex::kPlex480pPresentedWidth &&
         height == misterplex::kPlex480pPresentedHeight);
    const misterplex::DdrFrameGeometry geometry =
        plex480pGeometry ? misterplex::plex480pDdrFrameGeometry()
                         : misterplex::makeDdrFrameGeometry(width, height);
    misterplex::DdrFrameLayout layout =
        lenSet ? misterplex::makeDdrFrameLayout(320, static_cast<int>(len / (320 * 2)),
                                                kDdrFrameBase)
               : misterplex::makeDdrFrameLayout(geometry, kDdrFrameBase, 0x40000u, format);
    if (lenSet) {
        layout.width = 0;
        layout.height = 0;
        layout.line_bytes = 0;
        layout.line_qwords = 0;
        layout.chroma_line_bytes = 0;
        layout.chroma_line_qwords = 0;
        layout.frame_bytes = len;
        layout.format = format;
        layout.phys_base = kDdrFrameBase;
        layout.bank_stride = misterplex::alignUpU32(static_cast<uint32_t>(len), 0x40000u);
        layout.doorbell_phys = kDdrFrameBase + layout.bank_stride * 2u - 0x1000u;
        layout.map_bytes = layout.bank_stride * 2u;
    } else {
        len = layout.frame_bytes;
    }

    if (loops <= 0 || len == 0 || bank < 0 || bank > 1) {
        std::fprintf(stderr, "bad loops/size/bank\n");
        return 2;
    }
    if (!fbCopy && !hostCopy) {
        if (layout.bank_stride < len ||
            static_cast<size_t>(bank) * layout.bank_stride + len > layout.map_bytes) {
            std::fprintf(stderr, "bad loops/size/bank for DDR layout\n");
            return 2;
        }
    }

    void* srcRaw = nullptr;
    if (posix_memalign(&srcRaw, 64, len) != 0) {
        std::perror("posix_memalign");
        return 1;
    }
    uint8_t* src = static_cast<uint8_t*>(srcRaw);
    fillPattern(src, len);

    if (hostCopy) {
        void* dstRaw = nullptr;
        if (posix_memalign(&dstRaw, 64, len) != 0) {
            std::perror("posix_memalign dst");
            std::free(srcRaw);
            return 1;
        }
        uint8_t* dst = static_cast<uint8_t*>(dstRaw);
        auto o = runMemcpyLoops(dst, src, len, loops, /*flush=*/false, /*dirWrite=*/true);
        printResult("host_anon", true, false, false, loops, len, bank, layout, o.wallSec,
                    o.cpuSec, o.checksum, "write");
        std::free(dstRaw);
        std::free(srcRaw);
        return o.wallSec < 0 ? 1 : 0;
    }

    if (fbCopy) {
        const char* fbPath = "/dev/fb0";
        int fd = ::open(fbPath, O_RDWR | O_CLOEXEC);
        if (fd < 0) {
            std::perror("open /dev/fb0");
            std::free(srcRaw);
            return 1;
        }
        fb_fix_screeninfo finfo{};
        if (ioctl(fd, FBIOGET_FSCREENINFO, &finfo) != 0) {
            std::perror("FBIOGET_FSCREENINFO");
            ::close(fd);
            std::free(srcRaw);
            return 1;
        }
        size_t mapLen = finfo.smem_len;
        if (mapLen < len) {
            std::fprintf(stderr, "fb0 smem_len=%zu < len=%zu\n", mapLen, len);
            ::close(fd);
            std::free(srcRaw);
            return 2;
        }
        void* map = mmap(nullptr, mapLen, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
        if (map == MAP_FAILED) {
            std::perror("mmap fb0");
            ::close(fd);
            std::free(srcRaw);
            return 1;
        }
        std::printf("fb_control smem_start=0x%lX smem_len=%u line_length=%u "
                    "NOTE_not_frame_store_phys=1 frame_store_phys=0x%08X\n",
                    static_cast<unsigned long>(finfo.smem_start), finfo.smem_len,
                    finfo.line_length, kDdrFrameBase);
        if (dumpSmaps)
            printSmapsFor(map, len, "fb0");
        auto o = runMemcpyLoops(static_cast<uint8_t*>(map), src, len, loops, /*flush=*/false,
                                /*dirWrite=*/true);
        std::memset(map, 0, len > 4096 ? 4096 : len);
        printResult("fb0", false, false, false, loops, len, 0, layout, o.wallSec, o.cpuSec,
                    o.checksum, "write");
        munmap(map, mapLen);
        ::close(fd);
        std::free(srcRaw);
        return o.wallSec < 0 ? 1 : 0;
    }

    int flags = O_RDWR | O_CLOEXEC;
    if (useSync)
        flags |= O_SYNC;
    int fd = ::open("/dev/mem", flags);
    if (fd < 0) {
        std::perror("open /dev/mem");
        std::free(srcRaw);
        return 1;
    }

    void* map = mmap(nullptr, layout.map_bytes, PROT_READ | PROT_WRITE, MAP_SHARED, fd,
                     static_cast<off_t>(kDdrFrameBase));
    if (map == MAP_FAILED) {
        std::perror("mmap");
        ::close(fd);
        std::free(srcRaw);
        return 1;
    }

    std::printf("devmem_map phys=0x%08X map_bytes=0x%X open_flags=0x%X O_SYNC=%d "
                "va=%p bank=%d bank_off=0x%zX\n",
                kDdrFrameBase, layout.map_bytes, flags, useSync ? 1 : 0, map, bank,
                static_cast<size_t>(bank) * layout.bank_stride);

    uint8_t* bankPtr =
        static_cast<uint8_t*>(map) + static_cast<size_t>(bank) * layout.bank_stride;
    if (dumpSmaps)
        printSmapsFor(bankPtr, len, useSync ? "devmem_sync" : "devmem_nosync");

    BenchOut o{};
    const char* pathTag =
        useSync ? "devmem_sync" : (flush ? "devmem_nosync_flush" : "devmem_nosync");
    if (doRead) {
        // Read mapped bank → local buffer. Does not modify the bank (except via
        // local dst mutation for checksum entropy). Safe on a live frame store.
        o = runMemcpyLoops(src, bankPtr, len, loops, /*flush=*/false, /*dirWrite=*/false);
        printResult(pathTag, false, useSync, false, loops, len, bank, layout, o.wallSec, o.cpuSec,
                    o.checksum, "read");
    } else {
        o = runMemcpyLoops(bankPtr, src, len, loops, flush, /*dirWrite=*/true);
        printResult(pathTag, false, useSync, flush, loops, len, bank, layout, o.wallSec, o.cpuSec,
                    o.checksum, "write");
    }

    munmap(map, layout.map_bytes);
    ::close(fd);
    std::free(srcRaw);
    return o.wallSec < 0 ? 1 : 0;
}
