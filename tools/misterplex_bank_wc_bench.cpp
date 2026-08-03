// Write-combine / noncached bank map throughput bench (w-path Route W).
// Uses /dev/misterplex_bank when present. Soft-skips if module absent.
//
// Pass bar (parent): ≥230.2 MiB/s for true 720p serial (decode 35.94 + copy ≤41.667).
// Control: noncached must land near /dev/mem ~88 MiB/s class to trust the instrument.
//
// NEVER unbind dma-pl330. This path does not touch PL330 registers.

#include "libmisterplex/ddr_zero_copy_ingest.hpp"
#include "libmisterplex/misterplex_bank_kabi.hpp"

#include <chrono>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fcntl.h>
#include <string>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <unistd.h>
#include <vector>

using namespace misterplex;

static double miBps(size_t bytes, double sec) {
    if (sec <= 0.0)
        return 0.0;
    return (static_cast<double>(bytes) / (1024.0 * 1024.0)) / sec;
}

int main(int argc, char** argv) {
    size_t len = kPlex720pYuv420pBytes;
    int bank = 1;
    int loops = 64;
    uint32_t prot = kMpbMapProtWriteCombine;
    for (int i = 1; i < argc; ++i) {
        const std::string a = argv[i];
        if (a == "--len" && i + 1 < argc)
            len = static_cast<size_t>(std::atoll(argv[++i]));
        else if (a == "--bank" && i + 1 < argc)
            bank = std::atoi(argv[++i]);
        else if (a == "--loops" && i + 1 < argc)
            loops = std::atoi(argv[++i]);
        else if (a == "--prot" && i + 1 < argc) {
            const std::string p = argv[++i];
            if (p == "wc" || p == "write_combine")
                prot = kMpbMapProtWriteCombine;
            else if (p == "nc" || p == "noncached")
                prot = kMpbMapProtNoncached;
            else if (p == "cached")
                prot = kMpbMapProtCached;
            else {
                std::fprintf(stderr, "unknown --prot %s\n", p.c_str());
                return 2;
            }
        } else if (a == "--help") {
            std::printf("Usage: misterplex_bank_wc_bench [--len N] [--bank 0|1] [--loops N] "
                        "[--prot wc|nc|cached]\n");
            return 0;
        }
    }

    std::printf("wc_bench target_mibps=%.1f decode_ms=%.2f budget_ms=%.3f\n",
                kParentTrue720pCopyMiBpsNeed, kParentDecode720pCleanAloneMs, kIngestBudget24fpsMs);
    std::printf("wc_bench len=%zu bank=%d loops=%d prot=%s\n", len, bank, loops,
                misterplexBankMapProtName(prot));

    const int fd = ::open(kMisterplexBankDevPath, O_RDWR | O_CLOEXEC);
    if (fd < 0) {
        std::printf("wc_verdict=SKIP_NO_MODULE path=%s errno_hint=open_failed\n",
                    kMisterplexBankDevPath);
        std::printf("wc_note=insmod misterplex_bank.ko then rerun; never unbind dma-pl330\n");
        return 77;
    }

    MisterplexBankMapProtReq preq{};
    preq.prot = prot;
    if (::ioctl(fd, static_cast<unsigned long>(kMpbIocSetMapProtCmd), &preq) != 0) {
        std::printf("wc_verdict=FAIL_SET_PROT\n");
        ::close(fd);
        return 1;
    }

    MisterplexBankInfo info{};
    if (::ioctl(fd, static_cast<unsigned long>(kMpbIocInfoCmd), &info) != 0 ||
        !misterplexBankInfoSane(info)) {
        std::printf("wc_verdict=FAIL_INFO\n");
        ::close(fd);
        return 1;
    }
    std::printf("wc_info api=%u banks=%u b0=0x%08x b1=0x%08x bytes=%u dma=%u map_prot=%u\n",
                info.api_version, info.n_banks, info.bank0_phys, info.bank1_phys, info.bank_bytes,
                info.dma_capable, info.map_prot);

    if (len > info.bank_bytes) {
        std::printf("wc_verdict=FAIL_LEN_GT_BANK\n");
        ::close(fd);
        return 1;
    }

    const off_t off = (bank == 0) ? 0 : static_cast<off_t>(info.bank_bytes);
    void* map = ::mmap(nullptr, len, PROT_READ | PROT_WRITE, MAP_SHARED, fd, off);
    if (map == MAP_FAILED) {
        std::printf("wc_verdict=FAIL_MMAP\n");
        ::close(fd);
        return 1;
    }

    std::vector<uint8_t> src(len);
    for (size_t i = 0; i < len; ++i)
        src[i] = static_cast<uint8_t>(i * 131u + 17u);

    // Warmup
    std::memcpy(map, src.data(), len);
    ddrIngestPayloadVisibilityBarrier();

    const auto t0 = std::chrono::steady_clock::now();
    for (int i = 0; i < loops; ++i) {
        std::memcpy(map, src.data(), len);
        ddrIngestPayloadVisibilityBarrier();
    }
    const auto t1 = std::chrono::steady_clock::now();
    const double sec =
        std::chrono::duration_cast<std::chrono::duration<double>>(t1 - t0).count();
    const size_t total = len * static_cast<size_t>(loops);
    const double rate = miBps(total, sec);
    const double ms_per_frame = (sec * 1000.0) / static_cast<double>(loops);

    // Content check last write
    const auto* dst = static_cast<const uint8_t*>(map);
    bool match = (std::memcmp(dst, src.data(), len) == 0);
    std::printf("wc_rate_mibps=%.3f ms_per_frame=%.3f content_match=%d\n", rate, ms_per_frame,
                match ? 1 : 0);
    std::printf("wc_serial_total_ms=%.3f (decode+copy) margin=%.3f\n",
                kParentDecode720pCleanAloneMs + ms_per_frame,
                kIngestBudget24fpsMs - (kParentDecode720pCleanAloneMs + ms_per_frame));

    const char* verdict = "FAIL";
    if (!match)
        verdict = "FAIL_CONTENT";
    else if (prot == kMpbMapProtWriteCombine && misterplexBankWcRateIsProductCandidate(rate))
        verdict = "PASS_WC_TRUE720";
    else if (prot == kMpbMapProtWriteCombine && rate >= kParentBankCopy720pMiBps * 1.5)
        verdict = "PARTIAL_WC_ABOVE_DEVMEM";
    else if (prot == kMpbMapProtNoncached && rate >= 60.0 && rate <= 120.0)
        verdict = "CONTROL_NC_OK"; // instrument trust band around ~88
    else if (prot == kMpbMapProtNoncached)
        verdict = "CONTROL_NC_OUT_OF_BAND";
    else
        verdict = "FAIL_BELOW_BAR";

    std::printf("wc_verdict=%s\n", verdict);

    ::munmap(map, len);
    ::close(fd);
    return (std::strcmp(verdict, "FAIL_CONTENT") == 0 || std::strcmp(verdict, "FAIL") == 0 ||
            std::strcmp(verdict, "FAIL_BELOW_BAR") == 0)
               ? 1
               : 0;
}
