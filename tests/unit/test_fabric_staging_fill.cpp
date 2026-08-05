// Red/green gate: Rank2 fillStagingFromPayload (memcpy into mock staging).
//
// RESEARCH-ONLY (fabric_src_staging.hpp). No device. No mmap /dev/mem.
// Product fabric flag stays false; sendDdrFrame hot path not wired.

#include "libmisterplex/ddr_frame_layout.hpp"
#include "libmisterplex/ddr_zero_copy_ingest.hpp"
#include "libmisterplex/fabric_dma_host.hpp"
#include "libmisterplex/fabric_src_phys.hpp"
#include "libmisterplex/fabric_src_staging.hpp"

#include <cstdint>
#include <cstring>
#include <iostream>
#include <vector>

using namespace misterplex;

static int g_fails = 0;

static void expect(bool cond, const char* msg) {
    if (!cond) {
        std::cerr << "FAIL: " << msg << "\n";
        ++g_fails;
    } else {
        std::cout << "OK: " << msg << "\n";
    }
}

static void expect_eq_u32(uint32_t got, uint32_t want, const char* msg) {
    if (got != want) {
        std::cerr << "FAIL: " << msg << " got=0x" << std::hex << got << " want=0x"
                  << want << std::dec << "\n";
        ++g_fails;
    } else {
        std::cout << "OK: " << msg << "\n";
    }
}

int main() {
    // ---- Product fabric path remains OFF ---------------------------------
    std::cout << "CASE product_flag_still_off EXECUTED\n";
    expect(!kDdrPublishFabricPathEnabledInProduct,
           "kDdrPublishFabricPathEnabledInProduct remains false");
    expect(!ddrPublishSkipTcopyLegal(), "skip T_copy illegal under product default");

    // ---- Bounds / arg rejects (no write on fail) -------------------------
    std::cout << "CASE fill_arg_rejects EXECUTED\n";
    {
        std::vector<uint8_t> staging(64, 0xAAu);
        std::vector<uint8_t> payload(32, 0x55u);

        expect(stagingFillArgsOk(nullptr, payload.data(), 8u) ==
                   StagingFillResult::NullMap,
               "null map → NullMap");
        expect(!fillStagingFromPayload(nullptr, payload.data(), 8u),
               "null map bool fail");

        expect(stagingFillArgsOk(staging.data(), nullptr, 8u) ==
                   StagingFillResult::NullPayload,
               "null payload → NullPayload");
        expect(!fillStagingFromPayload(staging.data(), nullptr, 8u),
               "null payload bool fail");

        expect(stagingFillArgsOk(staging.data(), payload.data(), 0u) ==
                   StagingFillResult::ZeroLen,
               "zero len → ZeroLen");
        expect(!fillStagingFromPayload(staging.data(), payload.data(), 0u),
               "zero len bool fail");

        expect(stagingFillArgsOk(staging.data(), payload.data(), 64u,
                                 /*cap=*/32u) == StagingFillResult::Oversize,
               "oversize → Oversize");
        expect(!fillStagingFromPayload(staging.data(), payload.data(), 64u, 32u),
               "oversize bool fail");

        expect(stagingFillArgsOk(staging.data(), payload.data(), 7u) ==
                   StagingFillResult::Misaligned,
               "7B → Misaligned");
        expect(!fillStagingFromPayload(staging.data(), payload.data(), 7u),
               "7B bool fail");

        // Failed calls must not touch staging contents.
        expect(staging[0] == 0xAAu && staging[63] == 0xAAu,
               "reject path leaves staging untouched");
    }

    // ---- Mock buffer fill (small, no mmap) --------------------------------
    std::cout << "CASE mock_buffer_fill_pattern EXECUTED\n";
    {
        constexpr uint32_t kLen = 64u; // 8B-aligned lab-sized mock
        std::vector<uint8_t> staging(kLen, 0x00u);
        std::vector<uint8_t> payload(kLen);
        for (uint32_t i = 0; i < kLen; ++i)
            payload[i] = static_cast<uint8_t>(i & 0xFFu);

        expect(fillStagingFromPayload(staging.data(), payload.data(), kLen,
                                      /*staging_cap=*/kLen),
               "fill 64B mock ok");
        expect(std::memcmp(staging.data(), payload.data(), kLen) == 0,
               "staging bytes == payload after fill");

        // Partial fill does not require full region capacity when cap passed.
        std::vector<uint8_t> staging2(16, 0xFFu);
        const uint8_t p8[8] = {1, 2, 3, 4, 5, 6, 7, 8};
        expect(fillStagingFromPayload(staging2.data(), p8, 8u, 16u),
               "partial 8B into 16B cap");
        expect(std::memcmp(staging2.data(), p8, 8) == 0, "first 8 match");
        expect(staging2[8] == 0xFFu && staging2[15] == 0xFFu,
               "bytes beyond frame_bytes untouched");
    }

    // ---- 720 I420 length vs Rank2 SSOT capacity ---------------------------
    std::cout << "CASE frame_bytes_720_fits_region EXECUTED\n";
    {
        const uint32_t fb = stagingFrameBytes720();
        expect(fb == 1382400u, "720 I420 frame_bytes");
        expect(stagingFrameBytesOk(fb), "stagingFrameBytesOk(720)");
        expect(stagingFillArgsOk(reinterpret_cast<void*>(1),
                                 reinterpret_cast<const void*>(1), fb) ==
                   StagingFillResult::Ok,
               "720 args ok vs default staging_cap");

        // Full-size mock fill (heap, still no mmap /dev/mem).
        std::vector<uint8_t> staging(stagingRegionBytes(), 0u);
        std::vector<uint8_t> payload(fb, 0xCDu);
        payload[0] = 0x11u;
        payload[fb - 1u] = 0x22u;
        expect(fillStagingFromPayload(staging.data(), payload.data(), fb),
               "fill full 720 into Rank2-sized mock");
        expect(staging[0] == 0x11u && staging[fb - 1u] == 0x22u,
               "720 endpoints written");
        // Cap leaves room after frame (bank-stride region > frame).
        if (stagingRegionBytes() > fb)
            expect(staging[fb] == 0u, "byte past frame_bytes not written");
    }

    // ---- Research handoff: fill → job.src = stagingPhys → program kick ----
    // Sequence doc land: no PLXK, product flag still off, mock MMIO only.
    std::cout << "CASE research_sequence_fill_then_program_kick EXECUTED\n";
    {
        constexpr uint32_t kLen = 16u;
        std::vector<uint8_t> staging(kLen, 0u);
        std::vector<uint8_t> payload(kLen, 0x5Au);
        expect(fillStagingFromPayload(staging.data(), payload.data(), kLen, kLen),
               "step1 fillStagingFromPayload");

        FabricDmaJob job;
        const uint32_t bank0 = kDdrFramePhysBase;
        expect(makeStagingFabricJob(job, bank0, kLen, /*cmd_seq=*/0x0007u),
               "step2 makeStagingFabricJob src=stagingPhys");
        expect_eq_u32(job.src_phys, stagingPhysBase(), "job.src_phys == stagingPhysBase");
        expect_eq_u32(job.bank_phys, bank0, "job.bank_phys == bank0");
        expect_eq_u32(job.frame_bytes, kLen, "job.frame_bytes");
        expect(job.cmd_seq == 0x0007u, "job.cmd_seq");

        MockFabricKickMem mem;
        FabricKickHostState st;
        expect(programFabricKick(mem, st, job, FabricStartMode::Toggle),
               "step3 programFabricKick (no PLXK)");
        expect(!mem.wrotePlxk(), "helper never writes PLXK");
        expect_eq_u32(mem.read32(mailbox_abi::kPlxgSrcOffset), stagingPhysBase(),
                      "kick SRC == staging phys");
        expect_eq_u32(mem.read32(mailbox_abi::kPlxgFrameBytesOffset), kLen,
                      "kick LEN == frame_bytes");
        // step4 wait + step5 PLXK are caller-owned; not exercised here.
    }

    // ---- makeStagingFabricJob rejects bad lens ----------------------------
    std::cout << "CASE make_job_rejects EXECUTED\n";
    {
        FabricDmaJob job;
        expect(!makeStagingFabricJob(job, kDdrFramePhysBase, 0u, 1u),
               "zero frame reject");
        expect(!makeStagingFabricJob(job, kDdrFramePhysBase, 7u, 1u),
               "misaligned frame reject");
        expect(!makeStagingFabricJob(job, kDdrFramePhysBase + 1u,
                                     stagingFrameBytes720(), 1u),
               "misaligned bank reject");
    }

    if (g_fails) {
        std::cerr << "FAIL test_fabric_staging_fill fails=" << g_fails << "\n";
        return 1;
    }
    std::cout << "PASS test_fabric_staging_fill mock memcpy + research sequence "
                 "src=0x30601000 product_flag=0 no_sendDdrFrame\n";
    return 0;
}
