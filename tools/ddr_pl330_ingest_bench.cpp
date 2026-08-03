// Parent-facing bench: serial bank copy vs PL330 with fixed ABI scratch.
// Does NOT ring the frame doorbell (safe on a live core).
//
// PRE-REGISTER (device, this build) — publish hits/misses:
//   P1 dma-only: pl330_transfer started=1 ok_frac=1.0 for full-frame auto burst
//   P2 dma-only pure (no restage): dma_ms_per_frame < serial_cpu (prior 21ms was
//      restage+chunk tax; pure DMA expected ~8–18 ms — MISS if still > serial)
//   P3 --bank-sweep: serial@0x30200000 within 1.5 ms of serial@0x30300000 when
//      same mmap/O_SYNC recipe (if not → address/alignment real; if yes → harness)
//   P4 sustained --dma-only --duration-s 20 runnable alongside ffmpeg_cpu_probe
//
// Parent architecture gate (dma-only in bg + decode 300f real720p_2600k):
//   decode stays < 41.667 ms/f → Route A REAL
//   decode inflates past deadline → Route A dead for serial-style overlap claim
//
// Usage on MiSTer (parent):
//   # Sustained DMA for decode-overlap experiment (THE gate):
//   ddr_pl330_ingest_bench --dma-only --duration-s 25 --bank 1
//   # Bank anomaly chase (serial only, several phys targets):
//   ddr_pl330_ingest_bench --bank-sweep --len 1382400 --loops 40
//   # Classic compare (serial then DMA; DMA timed WITHOUT restage by default):
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

struct MapWin {
    int fd = -1;
    void* map = MAP_FAILED;
    size_t map_len = 0;
    uint32_t map_phys = 0;

    uint8_t* ptrAt(uint32_t phys) const {
        if (map == MAP_FAILED || phys < map_phys)
            return nullptr;
        const uint64_t off = static_cast<uint64_t>(phys) - map_phys;
        if (off + 64 > map_len)
            return nullptr;
        return static_cast<uint8_t*>(map) + static_cast<size_t>(off);
    }

    void close() {
        if (map != MAP_FAILED) {
            ::munmap(map, map_len);
            map = MAP_FAILED;
        }
        if (fd >= 0) {
            ::close(fd);
            fd = -1;
        }
    }
};

// Map a window covering [phys, phys+need). Uses O_SYNC like product path.
bool mapWindow(MapWin& w, uint32_t phys, size_t need, std::string* err) {
    w.close();
    const uint32_t page = phys & ~0xFFFu;
    const size_t off = static_cast<size_t>(phys - page);
    const size_t map_need = off + need;
    size_t map_len = (map_need + 0xFFFu) & ~static_cast<size_t>(0xFFFu);
    if (map_len < 0x400000u && phys >= 0x30000000u && phys < 0x31000000u)
        map_len = 0x400000u;
    w.fd = ::open("/dev/mem", O_RDWR | O_SYNC | O_CLOEXEC);
    if (w.fd < 0) {
        if (err)
            *err = "open /dev/mem failed";
        return false;
    }
    w.map = ::mmap(nullptr, map_len, PROT_READ | PROT_WRITE, MAP_SHARED, w.fd,
                   static_cast<off_t>(page));
    if (w.map == MAP_FAILED) {
        ::close(w.fd);
        w.fd = -1;
        if (err)
            *err = "mmap failed";
        return false;
    }
    w.map_len = map_len;
    w.map_phys = page;
    return true;
}

double timeSerialCopy(uint8_t* dst, const uint8_t* src, size_t len, int loops) {
    const double t0 = nowSec();
    for (int i = 0; i < loops; ++i) {
        std::memcpy(dst, src, len);
        __sync_synchronize();
    }
    return (nowSec() - t0) * 1000.0 / loops;
}

} // namespace

int main(int argc, char** argv) {
    size_t len = static_cast<size_t>(misterplex::kPlex720pYuv420pBytes);
    int loops = 30;
    int bank = 1;
    double burn_ms = 0.0;
    double duration_s = 0.0;
    bool do_pl330 = true;
    bool host_only = false;
    bool use_option_c = true;
    bool dma_only = false;
    bool bank_sweep = false;
    bool restage_each = false; // default OFF for fair DMA wall
    bool verify_each = false;
    uint32_t phys_override = 0;

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
        else if (a == "--duration-s" && i + 1 < argc)
            duration_s = std::atof(argv[++i]);
        else if (a == "--dma-only")
            dma_only = true;
        else if (a == "--bank-sweep")
            bank_sweep = true;
        else if (a == "--restage")
            restage_each = true;
        else if (a == "--verify-each")
            verify_each = true;
        else if (a == "--no-pl330")
            do_pl330 = false;
        else if (a == "--host-copy")
            host_only = true;
        else if (a == "--legacy-base")
            use_option_c = false;
        else if (a == "--phys" && i + 1 < argc)
            phys_override = static_cast<uint32_t>(std::strtoul(argv[++i], nullptr, 0));
        else if (a == "--help") {
            std::printf(
                "ddr_pl330_ingest_bench [options]\n"
                "  --dma-only --duration-s N   sustained DMA only (parent decode gate)\n"
                "  --bank-sweep                serial copy table across phys targets\n"
                "  --len N --loops N --bank 0|1 --phys 0x...\n"
                "  --restage                   reload staging every DMA iter (default off)\n"
                "  --verify-each               memcmp bank vs src each DMA iter (slow)\n"
                "  --overlap-burn-ms MS --no-pl330 --host-copy --legacy-base\n"
                "PL330 scratch 0x30600000 staging 0x30601000; Option-C banks default.\n");
            return 0;
        }
    }
    if (len < 64 || loops < 1 || (bank != 0 && bank != 1 && phys_override == 0)) {
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
    const uint32_t bank_phys =
        phys_override ? phys_override : (phys_base + static_cast<uint32_t>(bank) * stride);

    std::printf("PRE P1 dma_started P2 pure_dma_ms P3 bank_sweep_delta P4 duration_ok\n");
    std::printf("len=%zu loops=%d bank=%d burn_ms=%.3f duration_s=%.3f dma_only=%d "
                "bank_sweep=%d restage=%d host_only=%d option_c=%d\n",
                len, loops, bank, burn_ms, duration_s, dma_only ? 1 : 0, bank_sweep ? 1 : 0,
                restage_each ? 1 : 0, host_only ? 1 : 0, use_option_c ? 1 : 0);
    std::printf("bank_phys=0x%08x pl330_scratch=0x%08x pl330_staging=0x%08x\n", bank_phys,
                misterplex::kPl330ProgScratchPhys, misterplex::kPl330StagingPhys);
    std::printf("abi_overlap_option_c=%d mmap_flags=O_RDWR|O_SYNC\n",
                misterplex::pl330AbiOverlapsOptionCBanks(misterplex::kPl330AbiRegionPhys,
                                                        misterplex::kPl330AbiRegionBytes)
                    ? 1
                    : 0);

    std::vector<uint8_t> src(len);
    fill(src.data(), len);

    // -------- bank-sweep: serial only, several phys (anomaly chase) --------
    if (bank_sweep) {
        struct Tgt {
            const char* name;
            uint32_t phys;
        };
        const Tgt tgts[] = {
            {"option_c_bank0", misterplex::kPlex720pDdrFramePhysBase},
            {"option_c_bank1",
             misterplex::kPlex720pDdrFramePhysBase + misterplex::kPlex720pYuv420pBankStride},
            {"prior_0x30200000", 0x30200000u},
            {"legacy_base", misterplex::kDdrFramePhysBase},
            {"legacy_yuv_bank1",
             misterplex::kDdrFramePhysBase + misterplex::kPlex480pYuv420pBankStride},
            {"pl330_staging", misterplex::kPl330StagingPhys},
        };
        std::printf("BANK_SWEEP begin loops=%d len=%zu (same O_SYNC /dev/mem recipe)\n", loops,
                    len);
        MapWin win;
        std::string err;
        // Cover legacy base through PL330 staging end (0x30781000).
        if (!mapWindow(win, 0x30000000u, 0x00900000u, &err)) {
            std::printf("bank_sweep mmap FAIL %s\n", err.c_str());
            return 1;
        }
        {
            std::vector<uint8_t> host(len);
            const double host_ms = timeSerialCopy(host.data(), src.data(), len, loops);
            std::printf("bank_sweep name=host_ram phys=n/a ms_per_frame=%.3f\n", host_ms);
        }
        uint8_t* ref = win.ptrAt(misterplex::kPlex720pDdrFramePhysBase +
                                 misterplex::kPlex720pYuv420pBankStride);
        const double ref_ms = ref ? timeSerialCopy(ref, src.data(), len, loops) : -1;
        std::printf("bank_sweep_ref option_c_bank1 phys=0x%08x ms=%.3f\n",
                    misterplex::kPlex720pDdrFramePhysBase + misterplex::kPlex720pYuv420pBankStride,
                    ref_ms);
        for (const auto& t : tgts) {
            uint8_t* d = win.ptrAt(t.phys);
            if (!d || (static_cast<uint64_t>(t.phys - win.map_phys) + len) > win.map_len) {
                std::printf("bank_sweep name=%s phys=0x%08x SKIP out_of_map\n", t.name, t.phys);
                continue;
            }
            const double ms = timeSerialCopy(d, src.data(), len, loops);
            std::printf("bank_sweep_delta name=%s phys=0x%08x ms=%.3f delta_vs_oc_b1=%.3f\n",
                        t.name, t.phys, ms, ms - ref_ms);
        }
        win.close();
        std::printf("ddr_pl330_ingest_bench: DONE true_rc=0\n");
        return 0;
    }

    // -------- map destination bank --------
    MapWin win;
    uint8_t* dst = nullptr;
    std::vector<uint8_t> host_dst;
    if (host_only) {
        host_dst.resize(len + 64);
        dst = host_dst.data();
    } else {
        std::string err;
        if (!mapWindow(win, bank_phys & ~0xFFFu, static_cast<size_t>(stride) * 2u + 0x1000u,
                       &err)) {
            std::fprintf(stderr, "mmap bank failed: %s — try --host-copy\n", err.c_str());
            return 1;
        }
        dst = win.ptrAt(bank_phys);
        if (!dst) {
            std::fprintf(stderr, "bank_phys out of map\n");
            return 1;
        }
    }

    double serial_ms = -1.0;
    if (!dma_only) {
        serial_ms = timeSerialCopy(dst, src.data(), len, loops);
        std::printf("serial_cpu_copy_ms_per_frame=%.3f used_dma=0\n", serial_ms);

        if (burn_ms > 0.0) {
            std::atomic<int> stop{0};
            BurnArg ba{&stop};
            pthread_t th;
            pthread_create(&th, nullptr, burnThread, &ba);
            usleep(1000);
            const double wall = timeSerialCopy(dst, src.data(), len, loops);
            stop.store(1);
            pthread_join(th, nullptr);
            std::printf("copy_under_burn_ms_per_frame=%.3f serial_ms=%.3f inflate_ms=%.3f "
                        "burn_peer_requested_ms=%.3f\n",
                        wall, serial_ms, wall - serial_ms, burn_ms);
        }
    } else {
        std::printf("serial_cpu_copy_ms_per_frame=skipped dma_only=1\n");
    }

    // -------- PL330 --------
    if (do_pl330 && !host_only) {
        misterplex::Pl330Mem2Mem dma;
        std::string err;
        if (!dma.open(&err)) {
            std::printf("pl330_open=FAIL detail=%s\n", err.c_str());
        } else {
            auto pr = dma.probe();
            std::printf("pl330_probe ok=%d hw=%d cr0=0x%08x dsr=0x%08x detail=%s\n",
                        pr.ok ? 1 : 0, pr.hardware_present ? 1 : 0, pr.cr0, pr.dsr,
                        pr.detail.c_str());
            std::printf("pl330_scratch_mapped phys=0x%08x virt=%p staging_phys=0x%08x\n",
                        dma.progScratchPhys(), dma.progScratchVirt(), dma.stagingPhys());

            unsigned burst = 0;
            uint8_t prog[64];
            const size_t pn = misterplex::pl330BuildMem2MemProgramAuto(
                prog, sizeof(prog), dma.stagingPhys(), bank_phys, len, &burst);
            std::printf("pl330_encode_auto ok=%d prog_bytes=%zu burst=%u\n", pn ? 1 : 0, pn,
                        burst);

            if (!dma.loadStaging(src.data(), len, &err)) {
                std::printf("pl330_staging_load=FAIL detail=%s\n", err.c_str());
            } else {
                {
                    const double t0 = nowSec();
                    for (int i = 0; i < loops; ++i)
                        dma.loadStaging(src.data(), len);
                    const double st_ms = (nowSec() - t0) * 1000.0 / loops;
                    std::printf("staging_load_ms_per_frame=%.3f\n", st_ms);
                }

                misterplex::Pl330Mem2MemRequest req;
                req.src_phys = dma.stagingPhys();
                req.dst_phys = bank_phys;
                req.len = len;
                req.channel = 0;
                std::printf("pl330_src_phys=0x%08x dst_phys=0x%08x len=%zu\n", req.src_phys,
                            req.dst_phys, req.len);

                auto tr0 = dma.transferBlocking(req, 500);
                std::printf("pl330_transfer ok=%d started=%d ch=%d detail=%s\n", tr0.ok ? 1 : 0,
                            tr0.channel_started ? 1 : 0, tr0.channel_used, tr0.detail.c_str());

                if (tr0.ok || tr0.channel_started) {
                    if (verify_each) {
                        dma.loadStaging(src.data(), len);
                        dma.transferBlocking(req, 500);
                        const int cmp = std::memcmp(dst, src.data(), len);
                        std::printf("pl330_verify_memcmp=%s\n",
                                    cmp == 0 ? "match" : "MISMATCH");
                    }

                    int ok_n = 0;
                    int iters = 0;
                    const double t0 = nowSec();
                    if (duration_s > 0.0) {
                        const double deadline = t0 + duration_s;
                        while (nowSec() < deadline) {
                            if (restage_each)
                                dma.loadStaging(src.data(), len);
                            auto tr = dma.transferBlocking(req, 500);
                            if (tr.ok)
                                ++ok_n;
                            ++iters;
                        }
                    } else {
                        for (int i = 0; i < loops; ++i) {
                            if (restage_each)
                                dma.loadStaging(src.data(), len);
                            auto tr = dma.transferBlocking(req, 500);
                            if (tr.ok)
                                ++ok_n;
                            ++iters;
                        }
                    }
                    const double wall_s = nowSec() - t0;
                    const double dma_ms = iters > 0 ? (wall_s * 1000.0 / iters) : -1;
                    const double fps = wall_s > 0 ? iters / wall_s : 0;
                    std::printf("pl330_dma_ms_per_frame=%.3f ok_frac=%.3f iters=%d wall_s=%.3f "
                                "sustained_fps=%.2f restage_each=%d\n",
                                dma_ms, iters ? static_cast<double>(ok_n) / iters : 0.0, iters,
                                wall_s, fps, restage_each ? 1 : 0);
                    if (serial_ms > 0)
                        std::printf("dma_minus_serial=%.3f serial_ms=%.3f\n", dma_ms - serial_ms,
                                    serial_ms);
                    std::printf("NOTE: default times PURE dma (staging prefilled). "
                                "Prior 23.8ms included restage+1KB chunk poll tax.\n");

                    if (burn_ms > 0.0 && !dma_only) {
                        std::atomic<int> stop{0};
                        BurnArg ba{&stop};
                        pthread_t th;
                        pthread_create(&th, nullptr, burnThread, &ba);
                        usleep(1000);
                        const double t1 = nowSec();
                        int ok2 = 0;
                        for (int i = 0; i < loops; ++i) {
                            if (restage_each)
                                dma.loadStaging(src.data(), len);
                            auto tr = dma.transferBlocking(req, 500);
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

    if (!dma_only && serial_ms > 0) {
        const double dec = misterplex::kParentDecode720pProduct2600kMs;
        std::printf("budget_serial_product_fits=%d budget_overlap_max_product_fits=%d "
                    "decode_ms=%.3f copy_ms_measured=%.3f\n",
                    misterplex::ddrIngestSerialDecodePlusCopyFits(dec, serial_ms) ? 1 : 0,
                    misterplex::ddrIngestOverlapMaxFits(dec, serial_ms) ? 1 : 0, dec, serial_ms);
    }

    win.close();
    std::printf("ddr_pl330_ingest_bench: DONE true_rc=0\n");
    return 0;
}
