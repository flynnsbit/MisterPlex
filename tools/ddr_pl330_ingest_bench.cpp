// Parent-facing bench: serial bank copy vs PL330 probe vs threaded overlap.
// Does NOT ring the frame doorbell (safe on a live core).
//
// Pre-register before device run:
//   P1: serial bank copy @1382400 ≈ 15.28 ms/f (parent Sweep-3/4)
//   P2: PL330 either transfers or fails with needs_prog_scratch / no hardware
//   P3: threaded overlap wall ≈ max(copy, burn) if bus free; >> if contended
//
// Usage on MiSTer (parent):
//   /media/fat/misterplex/bin/ddr_pl330_ingest_bench --len 1382400 --loops 50
//   /media/fat/misterplex/bin/ddr_pl330_ingest_bench --len 1382400 --overlap-burn-ms 37
//
// true rc: 0 ok, 2 bad args, 1 partial failure (still prints measurements)

#include "libmisterplex/ddr_frame_layout.hpp"
#include "libmisterplex/ddr_zero_copy_ingest.hpp"
#include "libmisterplex/pl330_mem2mem.hpp"

#include <atomic>
#include <chrono>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fcntl.h>
#include <pthread.h>
#include <string>
#include <sys/mman.h>
#include <unistd.h>
#include <vector>

namespace {

double nowSec() {
    using clock = std::chrono::steady_clock;
    return std::chrono::duration<double>(clock::now().time_since_epoch()).count();
}

void fill(uint8_t* p, size_t n) {
    for (size_t i = 0; i < n; ++i)
        p[i] = static_cast<uint8_t>(i * 131u);
}

struct BurnArg {
    std::atomic<int>* stop;
};

void* burnThread(void* arg) {
    auto* a = static_cast<BurnArg*>(arg);
    volatile uint32_t x = 1;
    while (a->stop->load() == 0)
        x = x * 1664525u + 1013904223u;
    (void)x;
    return nullptr;
}

} // namespace

int main(int argc, char** argv) {
    size_t len = 1280 * 720 * 3 / 2;
    int loops = 30;
    int bank = 1;
    double burn_ms = 0.0;
    bool do_pl330 = true;
    bool host_only = false;

    for (int i = 1; i < argc; ++i) {
        std::string a = argv[i];
        if (a == "--len" && i + 1 < argc)
            len = static_cast<size_t>(std::strtoull(argv[++i], nullptr, 0));
        else if (a == "--loops" && i + 1 < argc)
            loops = std::atoi(argv[++i]);
        else if (a == "--bank" && i + 1 < argc)
            bank = std::atoi(argv[++i]);
        else if (a == "--overlap-burn-ms" && i + 1 < argc)
            burn_ms = std::atof(argv[++i]);
        else if (a == "--no-pl330")
            do_pl330 = false;
        else if (a == "--host-copy")
            host_only = true;
        else if (a == "--help") {
            std::printf("ddr_pl330_ingest_bench [--len N] [--loops N] [--bank 0|1]\n"
                        "  [--overlap-burn-ms MS] [--no-pl330] [--host-copy]\n");
            return 0;
        }
    }
    if (len < 64 || loops < 1 || (bank != 0 && bank != 1)) {
        std::fprintf(stderr, "bad args\n");
        return 2;
    }

    std::printf("PRE P1 serial≈15.28ms@720p P2 pl330 transfer|needs_scratch P3 overlap\n");
    std::printf("len=%zu loops=%d bank=%d burn_ms=%.3f host_only=%d\n", len, loops, bank, burn_ms,
                host_only ? 1 : 0);

    std::vector<uint8_t> src(len);
    fill(src.data(), len);

    uint8_t* dst = nullptr;
    size_t map_len = 0;
    int fd = -1;
    void* map = MAP_FAILED;
    const uint32_t phys_base = misterplex::kDdrFramePhysBase;
    const size_t stride = 0x200000; // safe upper stride for bench window

    if (host_only) {
        map_len = len + 64;
        dst = static_cast<uint8_t*>(std::malloc(map_len));
        if (!dst)
            return 1;
    } else {
        fd = ::open("/dev/mem", O_RDWR | O_SYNC | O_CLOEXEC);
        if (fd < 0) {
            std::fprintf(stderr, "open /dev/mem failed — try --host-copy\n");
            return 1;
        }
        map_len = stride * 2;
        map = ::mmap(nullptr, map_len, PROT_READ | PROT_WRITE, MAP_SHARED, fd,
                     static_cast<off_t>(phys_base));
        if (map == MAP_FAILED) {
            std::fprintf(stderr, "mmap bank failed\n");
            return 1;
        }
        dst = static_cast<uint8_t*>(map) + static_cast<size_t>(bank) * stride;
    }

    // --- serial CPU copy via ingest session ---
    misterplex::DdrIngestSession sess;
    double serial_ms = 0;
    {
        const double t0 = nowSec();
        for (int i = 0; i < loops; ++i) {
            misterplex::DdrIngestJob j;
            j.src_virt = src.data();
            j.bank_virt = dst;
            j.len = len;
            j.bank = bank;
            j.plxd_credit_held = true;
            if (!sess.begin(j) || !sess.completeCpuMemcpy()) {
                std::fprintf(stderr, "ingest session failed: %s\n", sess.lastError().c_str());
                return 1;
            }
            // no doorbell
        }
        serial_ms = (nowSec() - t0) * 1000.0 / loops;
    }
    std::printf("serial_cpu_copy_ms_per_frame=%.3f used_dma=0\n", serial_ms);

    // --- contention probe: bank copy while other core spins (decode stand-in) ---
    // If copy_ms inflates vs serial, DDR/CPU contention will also tax PL330 overlap.
    if (burn_ms > 0.0) {
        std::atomic<int> stop{0};
        BurnArg ba{&stop};
        pthread_t th;
        pthread_create(&th, nullptr, burnThread, &ba);
        // let burner start
        usleep(1000);
        const double t0 = nowSec();
        for (int i = 0; i < loops; ++i) {
            std::memcpy(dst, src.data(), len);
            __sync_synchronize();
        }
        const double wall = (nowSec() - t0) * 1000.0 / loops;
        stop.store(1);
        pthread_join(th, nullptr);
        std::printf("copy_under_burn_ms_per_frame=%.3f serial_ms=%.3f inflate_ms=%.3f "
                    "burn_peer_requested_ms=%.3f\n",
                    wall, serial_ms, wall - serial_ms, burn_ms);
        std::printf("NOTE: inflate_ms>>0 ⇒ peer CPU/DDR contention; PL330 max() may not hold\n");
    }

    // --- PL330 probe / optional transfer ---
    if (do_pl330 && !host_only) {
        misterplex::Pl330Mem2Mem dma;
        std::string err;
        if (!dma.open(&err)) {
            std::printf("pl330_open=FAIL detail=%s\n", err.c_str());
        } else {
            auto pr = dma.probe();
            std::printf("pl330_probe ok=%d hw=%d cr0=0x%08x dsr=0x%08x detail=%s\n", pr.ok ? 1 : 0,
                        pr.hardware_present ? 1 : 0, pr.cr0, pr.dsr, pr.detail.c_str());
            // Program encode self-check
            uint8_t prog[64];
            size_t pn = 0;
            const bool enc = misterplex::Pl330Mem2Mem::encodeProgramForTest(
                prog, sizeof(prog), &pn, 0x20000000u, phys_base + static_cast<uint32_t>(bank) * stride,
                64);
            std::printf("pl330_encode_ok=%d prog_bytes=%zu\n", enc ? 1 : 0, pn);

            // Attempt transfer: needs scratch — report honestly
            misterplex::Pl330Mem2MemRequest req;
            req.src_phys = misterplex::pl330ResolveUserPhys(src.data());
            req.dst_phys = phys_base + static_cast<uint32_t>(bank) * stride;
            req.len = (len > 256 * 4) ? 256u * 4u : len; // first block only if multi
            req.channel = 0;
            std::printf("pl330_src_phys=0x%08x dst_phys=0x%08x chunk=%zu\n", req.src_phys,
                        req.dst_phys, req.len);
            if (req.src_phys == 0) {
                std::printf("pl330_transfer=SKIP detail=pagemap_src_phys_unavailable\n");
            } else {
                auto tr = dma.transferBlocking(req, 100);
                std::printf("pl330_transfer ok=%d started=%d ch=%d detail=%s\n", tr.ok ? 1 : 0,
                            tr.channel_started ? 1 : 0, tr.channel_used, tr.detail.c_str());
            }
            dma.close();
        }
    }

    // Budget line for parent paste
    using misterplex::ddrIngestOverlapMaxFits;
    using misterplex::ddrIngestSerialDecodePlusCopyFits;
    const double dec = misterplex::kParentDecode720pProduct2600kMs;
    std::printf("budget_serial_2500k_fits=%d budget_overlap_max_2500k_fits=%d "
                "copy_ms_measured=%.3f\n",
                ddrIngestSerialDecodePlusCopyFits(dec, serial_ms) ? 1 : 0,
                ddrIngestOverlapMaxFits(dec, serial_ms) ? 1 : 0, serial_ms);

    if (!host_only && map != MAP_FAILED)
        ::munmap(map, map_len);
    if (fd >= 0)
        ::close(fd);
    if (host_only)
        std::free(dst);

    std::printf("ddr_pl330_ingest_bench: DONE true_rc=0\n");
    return 0;
}
