// Fabric DMA kick ABI for 720p Option-C (w-plxd compose).
// POS: default staging → bank0 is valid, 8-byte aligned, 1382400 bytes.
// NEG: misaligned src, wrong size, src overlapping bank, bank out of range.

#include "libmisterplex/fabric_dma_kick.hpp"
#include "libmisterplex/fabric_copy_handover.hpp"

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>

static int g_fails = 0;

#define CHECK(cond, msg)                                                       \
    do {                                                                       \
        if (!(cond)) {                                                         \
            std::fprintf(stderr, "FAIL %s:%d: %s\n", __FILE__, __LINE__, msg); \
            ++g_fails;                                                         \
        }                                                                      \
    } while (0)

int main() {
    using namespace misterplex;

    std::printf("CASE fabric_dma_kick_720p EXECUTED\n");
    std::printf("PRE_REGISTER: Option-C bank0=0x30180000 stride=0x180000 "
                "bytes=1382400 src_default=0x30601000\n");
    std::printf("M10K fabric_dma_kick.hpp=0 layout=N/A (host-only)\n");
    std::printf("M10K fabric_dma_arm_kick.sv=0 layout=N/A (regs only)\n");
    std::printf("M10K ddr_frame_dma bounce EST=2 layout=2x(256x32)@64b "
                "(w-mem; unfitted)\n");
    std::printf("REFRESH: not owned by w-plxd; compose claims 24 Hz only with "
                "PRESENT_CLK_PIX_PLL@29.7MHz (w-clock)\n");

    CHECK(kPlex720pYuv420pBytes == 1382400, "720p I420 bytes");
    CHECK(kPlex720pPhysBase == 0x30180000u, "Option-C base");
    CHECK(kPlex720pYuv420pBankStride == 0x00180000u, "bank stride");
    CHECK(kPl330StagingPhys == 0x30601000u, "staging phys");
    CHECK(fabric_copy_handover::kM10kCost == 0, "handover M10K=0");

    std::string err;
    const auto ok = buildFabricDmaKick720p(fabricDma720pDefaultSrcPhys(), 0, kPlex720pYuv420pBytes, &err);
    CHECK(ok.valid, "default kick valid");
    CHECK(err.empty(), "default kick no err");
    CHECK(ok.src_phys == 0x30601000u, "src staging");
    CHECK(ok.bank_phys == 0x30180000u, "bank0");
    CHECK(ok.frame_bytes == 1382400u, "frame bytes");
    CHECK(fabricDmaPhysAligned(ok.src_phys) && fabricDmaPhysAligned(ok.bank_phys), "align");

    const auto bank1 = buildFabricDmaKick720p(fabricDma720pDefaultSrcPhys(), 1);
    CHECK(bank1.valid, "bank1 valid");
    CHECK(bank1.bank_phys == 0x30180000u + 0x00180000u, "bank1 phys");

    // NEG: misaligned src
    err.clear();
    const auto bad_al = buildFabricDmaKick720p(0x30601001u, 0, kPlex720pYuv420pBytes, &err);
    CHECK(!bad_al.valid, "NEG misaligned src rejected");
    CHECK(err.find("8-byte") != std::string::npos, "NEG misalign message");

    // NEG: wrong size (480p payload)
    err.clear();
    const auto bad_sz =
        buildFabricDmaKick720p(fabricDma720pDefaultSrcPhys(), 0, kPlex480pYuv420pBytes, &err);
    CHECK(!bad_sz.valid, "NEG 480p size rejected for 720p kick");

    // NEG: src overlaps bank0
    err.clear();
    const auto bad_ov =
        buildFabricDmaKick720p(kPlex720pPhysBase + 64u, 0, kPlex720pYuv420pBytes, &err);
    CHECK(!bad_ov.valid, "NEG src-in-bank rejected");
    CHECK(err.find("overlap") != std::string::npos, "NEG overlap message");

    // NEG: bank index
    err.clear();
    const auto bad_b = buildFabricDmaKick720p(fabricDma720pDefaultSrcPhys(), 2, kPlex720pYuv420pBytes, &err);
    CHECK(!bad_b.valid, "NEG bank=2 rejected");

    CHECK(fabricDmaRequiredForPayload(kPlex720pYuv420pBytes), "720p requires fabric DMA");
    CHECK(!fabricDmaRequiredForPayload(static_cast<size_t>(kPlex480pYuv420pBytes)),
          "480p may still CpuSerial");

    if (g_fails) {
        std::fprintf(stderr, "test_fabric_dma_kick: %d failures\n", g_fails);
        return 1;
    }
    std::printf("PASS fabric_dma_kick_720p checks ok\n");
    return 0;
}
