// Parent-facing bench: serial bank copy vs PL330 with fixed ABI scratch.
// Does NOT ring the frame doorbell (safe on a live core).
//
// Pre-register (device, scratch wired @ 0x30600000):
//   P1: serial bank copy @1382400 ∈ 14.5–16.5 ms
//   P2: pl330_transfer started=1 (NOT needs_prog_scratch_phys)
//   P3: dma_ms_per_frame reported; compare to serial
//   P4: --overlap-burn-ms 37 → inflate_ms; large ⇒ max() fiction
//
// Usage on MiSTer (parent):
//   ddr_pl330_ingest_bench --len 1382400 --loops 50 --bank 1
//   ddr_pl330_ingest_bench --len 1382400 --loops 30 --bank 1 --overlap-burn-ms 37

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
    size_t len = static_cast<size_t>(misterplex::kPlex720pYuv420pBytes);
    int loops = 30;
    int bank = 1;
    double burn_ms = 0.0;
    bool do_pl330 = true;
    bool host_only = false;
    bool use_option_c = true;

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
        else if (a == "--legacy-base")
            use_option_c = false;
        else if (a == "--help") {
            std::printf(
                "ddr_pl330_ingest_bench [--len N] [--loops N] [--bank 0|1]\n"
                "  [--overlap-burn-ms MS] [--no-pl330] [--host-copy] [--legacy-base]\n"
                "Default bank window: Option-C 0x30180000 stride 0x180000.\n"
                "PL330 scratch: 0x30600000 (after triple Option-C end).\n");
            return 0;
        }
    }
    if (len < 64 || loops < 1 || (bank != 0 && bank != 1)) {
        std::fprintf(stderr, "bad args\n");
        return 2;
    }
    if (len > misterplex::kPl330StagingBytes) {
        std::fprintf(stderr, "len exceeds PL330 staging (%u)\n",
                     misterplex::kPl330StagingBytes);
        return 2;
    }

    const uint32_t phys_base =
        use_option_c ? misterplex::kPlex720pDdrFramePhysBase : misterplex::kDdrFramePhysBase;
    const uint32_t stride = use_option_c ? misterplex::kPlex720pYuv420pBankStride
                                         : misterplex::kPlex480pYuv420pBankStride;
    const uint32_t bank_phys = phys_base + static_cast<uint32_t>(bank) * stride;

    std::printf("PRE P1 serial~15.9ms P2 pl330 started=1 P3 dma_ms P4 burn inflate\n");
    std::printf("len=%zu loops=%d bank=%d burn_ms=%.3f host_only=%d option_c=%d\n", len, loops,
                bank, burn_ms, host_only ? 1 : 0, use_option_c ? 1 : 0);
    std::printf("bank_phys=0x%08x pl330_scratch=0x%08x pl330_staging=0x%08x\n", bank_phys,
                misterplex::kPl330ProgScratchPhys, misterplex::kPl330StagingPhys);
    std::printf("abi_overlap_option_c=%d\n",
                misterplex::pl330AbiOverlapsOptionCBanks(misterplex::kPl330AbiRegionPhys,
                                                        misterplex::kPl330AbiRegionBytes)
                    ? 1
                    : 0);

    std::vector<uint8_t> src(len);
    fill(src.data(), len);

    uint8_t* dst = nullptr;
    size_t map_len = 0;
    int fd = -1;
    void* map = MAP_FAILED;

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
        map_len = static_cast<size_t>(stride) * 2u;
        map = ::mmap(nullptr, map_len, PROT_READ | PROT_WRITE, MAP_SHARED, fd,
                     static_cast<off_t>(phys_base));
        if (map == MAP_FAILED) {
            std::fprintf(stderr, "mmap bank failed\n");
            return 1;
        }
        dst = static_cast<uint8_t*>(map) + static_cast<size_t>(bank) * stride;
    }

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
        }
        serial_ms = (nowSec() - t0) * 1000.0 / loops;
    }
    std::printf("serial_cpu_copy_ms_per_frame=%.3f used_dma=0\n", serial_ms);

    if (burn_ms > 0.0) {
        std::atomic<int> stop{0};
        BurnArg ba{&stop};
        pthread_t th;
        pthread_create(&th, nullptr, burnThread, &ba);
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
        std::printf("NOTE: inflate_ms>>0 => peer CPU/DDR contention; PL330 max() may not hold\n");
    }

    if (do_pl330 && !host_only) {
        misterplex::Pl330Mem2Mem dma;
        std::string err;
        if (!dma.open(&err)) {
            std::printf("pl330_open=FAIL detail=%s\n", err.c_str());
        } else {
            auto pr = dma.probe();
            std::printf("pl330_probe ok=%d hw=%d cr0=0x%08x dsr=0x%08x detail=%s\n", pr.ok ? 1 : 0,
                        pr.hardware_present ? 1 : 0, pr.cr0, pr.dsr, pr.detail.c_str());
            std::printf("pl330_scratch_mapped phys=0x%08x virt=%p staging_phys=0x%08x\n",
                        dma.progScratchPhys(), dma.progScratchVirt(), dma.stagingPhys());

            uint8_t prog[64];
            size_t pn = 0;
            const bool enc = misterplex::Pl330Mem2Mem::encodeProgramForTest(
                prog, sizeof(prog), &pn, dma.stagingPhys(), bank_phys, 64);
            std::printf("pl330_encode_ok=%d prog_bytes=%zu\n", enc ? 1 : 0, pn);

            if (!dma.loadStaging(src.data(), len, &err)) {
                std::printf("pl330_staging_load=FAIL detail=%s\n", err.c_str());
            } else {
                misterplex::Pl330Mem2MemRequest req;
                req.src_phys = dma.stagingPhys();
                req.dst_phys = bank_phys;
                req.len = len;
                req.channel = 0;
                std::printf("pl330_src_phys=0x%08x dst_phys=0x%08x len=%zu\n", req.src_phys,
                            req.dst_phys, req.len);

                auto tr0 = dma.transferBlocking(req, 200);
                std::printf("pl330_transfer ok=%d started=%d ch=%d detail=%s\n", tr0.ok ? 1 : 0,
                            tr0.channel_started ? 1 : 0, tr0.channel_used, tr0.detail.c_str());

                if (tr0.ok || tr0.channel_started) {
                    const double t0 = nowSec();
                    int ok_n = 0;
                    for (int i = 0; i < loops; ++i) {
                        dma.loadStaging(src.data(), len);
                        auto tr = dma.transferBlocking(req, 200);
                        if (tr.ok)
                            ++ok_n;
                    }
                    const double dma_ms = (nowSec() - t0) * 1000.0 / loops;
                    std::printf("pl330_dma_ms_per_frame=%.3f ok_frac=%.3f serial_ms=%.3f "
                                "dma_minus_serial=%.3f\n",
                                dma_ms, static_cast<double>(ok_n) / loops, serial_ms,
                                dma_ms - serial_ms);

                    if (burn_ms > 0.0) {
                        std::atomic<int> stop{0};
                        BurnArg ba{&stop};
                        pthread_t th;
                        pthread_create(&th, nullptr, burnThread, &ba);
                        usleep(1000);
                        const double t1 = nowSec();
                        int ok2 = 0;
                        for (int i = 0; i < loops; ++i) {
                            dma.loadStaging(src.data(), len);
                            auto tr = dma.transferBlocking(req, 200);
                            if (tr.ok)
                                ++ok2;
                        }
                        const double wall = (nowSec() - t1) * 1000.0 / loops;
                        stop.store(1);
                        pthread_join(th, nullptr);
                        std::printf("pl330_under_burn_ms_per_frame=%.3f inflate_vs_dma_ms=%.3f "
                                    "ok_frac=%.3f\n",
                                    wall, wall - dma_ms, static_cast<double>(ok2) / loops);
                    }
                }
            }
            dma.close();
        }
    }

    const double dec = misterplex::kParentDecode720pProduct2600kMs;
    std::printf("budget_serial_product_fits=%d budget_overlap_max_product_fits=%d "
                "decode_ms=%.3f copy_ms_measured=%.3f\n",
                misterplex::ddrIngestSerialDecodePlusCopyFits(dec, serial_ms) ? 1 : 0,
                misterplex::ddrIngestOverlapMaxFits(dec, serial_ms) ? 1 : 0, dec, serial_ms);

    if (!host_only && map != MAP_FAILED)
        ::munmap(map, map_len);
    if (fd >= 0)
        ::close(fd);
    if (host_only)
        std::free(dst);

    std::printf("ddr_pl330_ingest_bench: DONE true_rc=0\n");
    return 0;
}
