// Red-before-green: zero-copy / overlapped DDR ingest contract (w-path).

#include "libmisterplex/ddr_zero_copy_ingest.hpp"
#include "libmisterplex/pl330_mem2mem.hpp"

#include <cstdio>
#include <cstring>
#include <iostream>
#include <vector>

using namespace misterplex;

static int g_fails = 0;

static void CHECK(bool c, const char* m) {
    if (!c) {
        std::cerr << "FAIL: " << m << "\n";
        ++g_fails;
    }
}

int main() {
    // NEG: doorbell before payload must fail
    {
        DdrIngestContract c;
        c.enforce_payload_before_doorbell = true;
        DdrIngestSession s(c);
        std::vector<uint8_t> bank(64, 0), src(64, 0xAB);
        DdrIngestJob j;
        j.src_virt = src.data();
        j.bank_virt = bank.data();
        j.len = 64;
        j.bank = 0;
        CHECK(s.begin(j), "begin ok");
        CHECK(!s.mayRingDoorbell(), "NEG no doorbell while moving");
        CHECK(!s.markDoorbellRung(), "NEG mark doorbell rejected");
        CHECK(s.completeCpuMemcpy(), "memcpy complete");
        CHECK(s.mayRingDoorbell(), "doorbell ok after visible");
        CHECK(bank[0] == 0xAB, "payload landed");
        CHECK(s.markDoorbellRung(), "doorbell rung");
        CHECK(s.phase() == DdrIngestPhase::DoorbellRung, "phase rung");
    }

    // NEG: require PLXD credit
    {
        DdrIngestContract c;
        c.require_bank_credit = true;
        DdrIngestSession s(c);
        std::vector<uint8_t> bank(16, 0), src(16, 1);
        DdrIngestJob j;
        j.src_virt = src.data();
        j.bank_virt = bank.data();
        j.len = 16;
        j.bank = 1;
        j.plxd_credit_held = false;
        CHECK(!s.begin(j), "NEG begin without credit");
        CHECK(s.phase() == DdrIngestPhase::Failed || s.phase() == DdrIngestPhase::AwaitBankCredit,
              "credit fail phase");
    }

    // DecodeIntoBank path
    {
        DdrIngestContract c;
        c.mode = DdrIngestMode::DecodeIntoBank;
        DdrIngestSession s(c);
        std::vector<uint8_t> bank(32, 0);
        DdrIngestJob j;
        j.bank_virt = bank.data();
        j.len = 32;
        j.bank = 0;
        CHECK(s.begin(j), "dib begin");
        uint8_t* p = s.bankWritePtr();
        CHECK(p == bank.data(), "dib ptr");
        std::memset(p, 0x5A, 32);
        CHECK(s.completeDecodeIntoBankBarrier(), "dib barrier");
        CHECK(s.mayRingDoorbell(), "dib doorbell");
    }

    // DMA complete path
    {
        DdrIngestSession s;
        std::vector<uint8_t> bank(8, 0), src(8, 2);
        DdrIngestJob j{src.data(), 0, bank.data(), 0, 8, 0, true};
        CHECK(s.begin(j), "dma begin");
        CHECK(s.completeDmaDone(), "dma done");
        CHECK(s.timing().used_dma, "dma flag");
        CHECK(s.mayRingDoorbell(), "dma doorbell");
    }

    // Budget arithmetic (parent in-session 2600k product tier + bank copy)
    CHECK(!ddrIngestSerialDecodePlusCopyFits(kParentDecode720pProduct2600kMs, 15.283),
          "serial product 2600k FAIL");
    CHECK(ddrIngestOverlapMaxFits(kParentDecode720pProduct2600kMs, 15.283),
          "overlap max PASS sketch");
    CHECK(ddrIngestRouteABridgeCandidate(kParentDecode720pProduct2600kMs), "route A candidate");
    CHECK(!ddrIngestRouteAIsShipGate(), "route A not ship gate");
    CHECK(kParentDecode720pProduct2600kMs == 36.27, "product 2600k constant");
    CHECK(kParentDecode720p2500kMs == 35.87, "in-session 2500k anchor");

    // Mode conf parse
    CHECK(ddrIngestModeFromConf("pl330") == DdrIngestMode::Pl330Overlap, "conf pl330");
    CHECK(ddrIngestModeFromConf(nullptr) == DdrIngestMode::CpuSerial, "conf default");

    // Double-buffer advance
    {
        DdrIngestDoubleBufferPlan p{};
        p = ddrIngestAdvanceOverlap(p, true);
        CHECK(p.decode_slot == 1 && p.move_bank == 1 && p.overlap_armed, "overlap advance");
    }

    // PL330 program encode (host unit — no /dev/mem)
    {
        uint8_t prog[64];
        size_t n = 0;
        CHECK(Pl330Mem2Mem::encodeProgramForTest(prog, sizeof(prog), &n, 0x1000, 0x30000000, 64),
              "pl330 encode");
        CHECK(n > 8 && n < 64, "pl330 prog size");
        // NEG: odd length
        CHECK(!Pl330Mem2Mem::encodeProgramForTest(prog, sizeof(prog), &n, 0x1000, 0x30000000, 3),
              "NEG odd len");
        // Full 720p frame must factor into one nested program (burst 8 or 16).
        unsigned burst = 0;
        uint32_t inner = 0, outer = 0;
        CHECK(pl330PickBurstAndLoops(kPlex720pYuv420pBytes, &burst, &inner, &outer),
              "720p burst+loops");
        CHECK(burst >= 8, "720p prefers burst>=8");
        CHECK(inner >= 1 && inner <= 256 && outer >= 1 && outer <= 256, "loop bounds");
        n = pl330BuildMem2MemProgramAuto(prog, sizeof(prog), kPl330StagingPhys,
                                         kPlex720pDdrFramePhysBase + kPlex720pYuv420pBankStride,
                                         kPlex720pYuv420pBytes, &burst);
        CHECK(n > 20 && n < 64, "720p full-frame prog");
        // NEG: length that cannot factor even with burst1 nested (257 words? 257*4)
        // 257 is prime-ish for factor: 257 > 256 and prime → no factor
        CHECK(!pl330FactorLoops(257, &inner, &outer), "NEG 257 words no factor");
    }

    // CCR builder
    CHECK(pl330BuildCcr(0) == 0, "ccr zero");
    CHECK(pl330BuildCcr(4) != 0, "ccr 4");
    CHECK(pl330BuildCcrBurst(16) != 0, "ccr burst16");
    CHECK(pl330BuildCcrBurst(0) == 0, "NEG burst0");
    CHECK(pl330BuildCcrBurst(17) == 0, "NEG burst17");

    // 720p frame bytes constant still 1382400
    CHECK(kPlex720pYuv420pBytes == 1382400u || kPlex720pYuv420pBytes == 1280 * 720 * 3 / 2,
          "720p bytes");

    // PL330 ABI sits after Option-C triple banks; no overlap
    CHECK(kPl330ProgScratchPhys == 0x30600000u, "scratch phys");
    CHECK(kPl330StagingPhys == 0x30601000u, "staging phys");
    CHECK(kPl330AbiRegionPhys == kPlex720pDdrFramePhysBase + 3u * kPlex720pYuv420pBankStride,
          "after triple end");
    CHECK(!pl330AbiOverlapsOptionCBanks(kPl330AbiRegionPhys, kPl330AbiRegionBytes),
          "NEG no Option-C overlap");
    CHECK(pl330PhysInProgScratch(kPl330ProgScratchPhys, 27), "prog in scratch");
    CHECK(pl330PhysInStaging(kPl330StagingPhys, kPlex720pYuv420pBytes), "frame in staging");
    CHECK(Pl330Mem2Mem::abiProgScratchPhys() == kPl330ProgScratchPhys, "abi helper");

    if (g_fails) {
        std::cerr << "test_ddr_zero_copy_ingest: " << g_fails << " fails\n";
        return 1;
    }
    std::cout << "GREEN_ZERO_COPY_INGEST contract+pl330_encode+budget\n";
    std::cout << "test_ddr_zero_copy_ingest: OK\n";
    return 0;
}
