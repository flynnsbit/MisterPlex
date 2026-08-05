// Red/green gate: Rank2 fabric_src_staging PA layout constants + align.
//
// RESEARCH-ONLY layout SSOT (fabric_src_phys.hpp). No device. No mmap.
// Product fabric flag stays false; sendDdrFrame hot path not wired.

#include "libmisterplex/ddr_frame_layout.hpp"
#include "libmisterplex/ddr_zero_copy_ingest.hpp"
#include "libmisterplex/fabric_src_phys.hpp"

#include <cstdint>
#include <iostream>

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

    // ---- Preferred lab staging phys (OPT-A SoT) --------------------------
    std::cout << "CASE lab_staging_phys_opt_a EXECUTED\n";
    expect_eq_u32(stagingPhysBase(), 0x30601000u, "stagingPhysBase()==0x30601000");
    expect_eq_u32(kFabricSrcStagingPhys, kPl330StagingPhys,
                  "fabric staging SSOT aliases PL330 staging fence");
    expect_eq_u32(kFabricSrcStagingPhysLab, 0x30601000u, "Lab OPT-A phys");
    expect_eq_u32(kFabricSrcStagingBytes, 0x00180000u, "region 0x180000");
    expect_eq_u32(kFabricSrcStagingBytes, kPl330StagingBytes,
                  "region size == PL330 staging bytes");
    expect_eq_u32(kFabricSrcStagingBytes, kPlex720pYuv420pBankStride,
                  "region size == 720 bank stride");
    expect(kFabricSrcStagingBytes >= stagingFrameBytes720(),
           "region fits one 720 I420 frame");

    // ---- Free-region sketches documented (OPT-B, not default) ------------
    std::cout << "CASE free_region_opt_b_documented EXECUTED\n";
    expect_eq_u32(kFabricSrcStagingPhysFreeAfterPl330, 0x30781000u,
                  "OPT-B free after PL330 end");
    expect_eq_u32(kFabricSrcStagingPhysFreeAfterPl330, kPl330AbiRegionEndPhys,
                  "OPT-B == kPl330AbiRegionEndPhys");
    expect_eq_u32(kFabricSrcStagingPhysFreeNice, 0x30800000u, "OPT-B nice base");
    expect(stagingPhysBase() != kFabricSrcStagingPhysFreeAfterPl330,
           "lab default is OPT-A not free carve");
    expect(stagingPhysBase() != kFabricSrcStagingPhysFreeNice,
           "lab default is OPT-A not nice free");

    // ---- frame_bytes 720 + align 8 ---------------------------------------
    std::cout << "CASE frame_bytes_720_align8 EXECUTED\n";
    expect_eq_u32(stagingFrameBytes720(), 1382400u, "stagingFrameBytes720()==1382400");
    expect_eq_u32(stagingFrameBytes720(),
                  static_cast<uint32_t>(kPlex720pYuv420pBytes),
                  "frame_bytes == kPlex720pYuv420pBytes");
    expect((stagingFrameBytes720() % kFabricFrameBytesAlign) == 0u,
           "1382400 % 8 == 0");
    expect(stagingFrameBytesOk(stagingFrameBytes720()), "720 frame_bytes ok");
    expect(stagingFrameBytesOk(8u), "min 8B ok");
    expect(!stagingFrameBytesOk(0u), "zero len reject");
    expect(!stagingFrameBytesOk(7u), "misaligned 7 reject");
    expect(!stagingFrameBytesOk(1382401u), "misaligned 1382401 reject");
    expect(!stagingFrameBytesOk(kFabricSrcStagingBytes + 8u),
           "over capacity reject");

    // ---- Helpers: region membership + default 720 align ------------------
    std::cout << "CASE staging_region_and_align EXECUTED\n";
    {
        const uint32_t bank0 = kDdrFramePhysBase; // 0x30000000
        const uint32_t bank1 = kDdrFramePhysBase + kPlex720pYuv420pBankStride;
        expect(stagingPhysInRegion(stagingPhysBase(), stagingFrameBytes720()),
               "720 payload fits staging region");
        expect(stagingPhysInRegion(stagingPhysBase(), 1u), "base in region");
        expect(!stagingPhysInRegion(stagingPhysBase() - 1u, 1u),
               "byte before base out");
        expect(!stagingPhysInRegion(kFabricSrcStagingPhys + kFabricSrcStagingBytes,
                                    1u),
               "end exclusive out");
        expect(stagingFabricAlignOk(stagingPhysBase(), bank0, stagingFrameBytes720()),
               "align_ok staging→bank0 720");
        expect(stagingDefault720AlignOk(bank0), "default 720 bank0 align");
        expect(stagingDefault720AlignOk(bank1), "default 720 bank1 align");
        expect(!stagingFabricAlignOk(stagingPhysBase() + 1u, bank0,
                                     stagingFrameBytes720()),
               "src misalign reject");
        expect(!stagingFabricAlignOk(stagingPhysBase(), bank0 + 1u,
                                     stagingFrameBytes720()),
               "bank misalign reject");
        expect(!stagingFabricAlignOk(stagingPhysBase(), bank0, 0u),
               "zero frame_bytes reject");
    }

    // ---- Collision fence: staging must not land on banks/doorbell/scratch -
    std::cout << "CASE no_overlap_banks_doorbell_scratch EXECUTED\n";
    {
        const uint32_t st0 = kFabricSrcStagingPhys;
        const uint32_t st1 = kFabricSrcStagingPhys + kFabricSrcStagingBytes;
        const uint32_t bank0 = kDdrFramePhysBase;
        const uint32_t bank_end =
            kDdrFramePhysBase + 2u * kPlex720pYuv420pBankStride; // dual banks
        const uint32_t db0 = kPlex720pYuv420pDoorbellPhys;
        const uint32_t db1 = db0 + 0x1000u;
        const uint32_t scratch0 = kPl330ProgScratchPhys;
        const uint32_t scratch1 = kPl330ProgScratchPhys + kPl330ProgScratchBytes;

        auto overlaps = [](uint32_t a0, uint32_t a1, uint32_t b0, uint32_t b1) {
            return a0 < b1 && b0 < a1;
        };
        expect(!overlaps(st0, st1, bank0, bank_end),
               "staging not over product dual banks");
        expect(!overlaps(st0, st1, db0, db1), "staging not over doorbell page");
        expect(!overlaps(st0, st1, scratch0, scratch1),
               "staging not over PL330 prog scratch");
        // OPT-A intentionally IS the PL330 staging region (role rename / mutex).
        expect(st0 == kPl330StagingPhys && st1 == kPl330StagingPhys + kPl330StagingBytes,
               "OPT-A is PL330 staging (lab mutex vs PL330 benches)");
        // Free OPT-B sits after PL330 ABI entirely.
        expect(kFabricSrcStagingPhysFreeAfterPl330 >= kPl330AbiRegionEndPhys,
               "OPT-B free after PL330 ABI end");
    }

    // ---- Reserved window membership --------------------------------------
    std::cout << "CASE reserved_window EXECUTED\n";
    expect(kFabricSrcStagingPhys >= kPlexDdrReservedWindowStart, "staging >= window start");
    expect(kFabricSrcStagingPhys + kFabricSrcStagingBytes <= kPlexDdrReservedWindowEnd,
           "staging end <= window end");

    if (g_fails) {
        std::cerr << "FAIL test_fabric_staging_phys fails=" << g_fails << "\n";
        return 1;
    }
    std::cout << "PASS test_fabric_staging_phys constants+align "
                 "phys=0x30601000 frame_bytes=1382400 product_flag=0\n";
    return 0;
}
