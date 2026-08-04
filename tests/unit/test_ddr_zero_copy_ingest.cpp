// Red-before-green: zero-copy / overlapped DDR ingest contract (w-path).

#include "libmisterplex/ddr_zero_copy_ingest.hpp"
#include "libmisterplex/misterplex_bank_kabi.hpp"
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

    // NEG: require PLXD credit — must stay AwaitBankCredit (NOT Failed overwrite).
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
        CHECK(s.phase() == DdrIngestPhase::AwaitBankCredit, "sticky AwaitBankCredit");
        CHECK(s.phase() != DdrIngestPhase::Failed, "NEG must not collapse to Failed");
        CHECK(!s.continueAfterBankCredit(false), "NEG still no credit");
        CHECK(s.phase() == DdrIngestPhase::AwaitBankCredit, "still awaiting");
        CHECK(s.continueAfterBankCredit(true), "credit granted");
        CHECK(s.phase() == DdrIngestPhase::PayloadMoving, "moving after credit");
        CHECK(s.completeCpuMemcpy(), "copy after credit");
        CHECK(s.mayRingDoorbell(), "doorbell after barrier");
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

    // Budget arithmetic (parent CLEAN decode 35.94 + copy 14.978)
    CHECK(!ddrIngestSerialDecodePlusCopyFits(kParentDecode720pCleanAloneMs,
                                             kParentBankCopy720pMs),
          "serial clean FAIL");
    CHECK(ddrIngestOverlapMaxFits(kParentDecode720pCleanAloneMs, kParentBankCopy720pMs),
          "overlap max PASS sketch");
    CHECK(ddrIngestRouteABridgeCandidate(kParentDecode720pCleanAloneMs), "route A candidate");
    CHECK(!ddrIngestRouteAIsShipGate(), "route A not ship gate");
    CHECK(!ddrIngestOverlapIsProductShipGate(), "overlap UNSCORED as ship gate");
    CHECK(kParentDecode720pCleanAloneMs == 35.94, "clean alone constant");
    CHECK(kParentBankCopy720pMs == 14.978, "clean copy constant");
    CHECK(kParentDecode720pProduct2600kMs == 35.94, "product alias = clean");
    CHECK(kParentDecode720p2500kMs == 35.87, "historical 2500k anchor");
    // NEG: serial sum must exceed budget
    CHECK(kParentDecode720pCleanAloneMs + kParentBankCopy720pMs > kIngestBudget24fpsMs,
          "NEG serial over budget");

    // rd-duck Sweep-116: faster decode still cannot pay 14.978 ms /dev/mem copy
    CHECK(kParentDecode720pSweep116Ms == 32.705, "sweep116 decode");
    CHECK(kParentSweep116HeadroomMs > 8.96 && kParentSweep116HeadroomMs < 8.97,
          "sweep116 headroom ~8.962");
    CHECK(!ddrIngestHeadroomCoversDevMemCopy(kParentDecode720pSweep116Ms),
          "NEG sweep116 headroom < copy");
    CHECK(!ddrIngestSerialDecodePlusCopyFits(kParentDecode720pSweep116Ms, kParentBankCopy720pMs),
          "NEG sweep116 serial still FAIL");
    // Teeth: if someone "fixes" constants so headroom covers copy, this goes RED
    // only when math is wrong the other way — keep copy > headroom as invariant.
    CHECK(kParentBankCopy720pMs > kParentSweep116HeadroomMs, "copy exceeds sweep116 headroom");

    // True-720p full frame: CpuSerial product-forbidden; DMA/WC required
    CHECK(!ddrIngestCpuSerialAllowedForPayload(1382400u), "NEG no CpuSerial @720p I420");
    CHECK(ddrIngestCpuSerialAllowedForPayload(449280u), "480p CpuSerial ok");
    CHECK(ddrIngestCpuSerialAllowedForPayload(777600u), "540p CpuSerial ok");
    CHECK(ddrIngestModeOkForTrue720pSource(DdrIngestMode::KernelDma), "720p kernel dma");
    CHECK(ddrIngestModeOkForTrue720pSource(DdrIngestMode::CpuWriteCombine), "720p wc");
    CHECK(!ddrIngestModeOkForTrue720pSource(DdrIngestMode::CpuSerial), "NEG 720p CpuSerial");
    CHECK(ddrIngestFabricBwIsNotArmCopyCost(), "fabric BW ≠ ARM copy");

    // Mode conf parse — "dma" means kernel owner; raw pl330 is lab-only alias.
    CHECK(ddrIngestModeFromConf("pl330") == DdrIngestMode::Pl330Userspace, "conf pl330 lab");
    CHECK(ddrIngestModeFromConf("dma") == DdrIngestMode::KernelDma, "conf dma kernel");
    CHECK(ddrIngestModeFromConf("kernel_dma") == DdrIngestMode::KernelDma, "conf kernel_dma");
    CHECK(ddrIngestModeFromConf("wc") == DdrIngestMode::CpuWriteCombine, "conf wc");
    CHECK(ddrIngestModeFromConf(nullptr) == DdrIngestMode::CpuSerial, "conf default");
    CHECK(ddrIngestModeIsLabOnly(DdrIngestMode::Pl330Userspace), "pl330 lab");
    CHECK(ddrIngestModeIsProductCandidate(DdrIngestMode::KernelDma), "kernel product");
    CHECK(ddrIngestModeIsProductCandidate(DdrIngestMode::CpuWriteCombine), "wc product");
    CHECK(kParentCpuBankCopyCeilingIsDevMemOnly, "ceiling scoped to /dev/mem");
    CHECK(!ddrIngestTrue720pSerialCopyRateFits(88.045), "NEG /dev/mem rate insufficient");
    CHECK(ddrIngestTrue720pSerialCopyRateFits(230.2), "WC bar");
    ddrIngestPayloadVisibilityBarrier(); // must compile/link; real DMB on ARM

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

    // CCR builder — default non-secure AxPROT (channel CNS=1).
    CHECK(pl330BuildCcr(0) == 0, "ccr zero");
    CHECK(pl330BuildCcr(4) != 0, "ccr 4");
    CHECK(pl330BuildCcrBurst(16) != 0, "ccr burst16");
    CHECK(pl330BuildCcrBurst(0) == 0, "NEG burst0");
    CHECK(pl330BuildCcrBurst(17) == 0, "NEG burst17");
    {
        const uint32_t ccr_ns = pl330BuildCcrBurst(1, true);
        const uint32_t ccr_s = pl330BuildCcrBurst(1, false);
        CHECK(((ccr_ns >> 8) & 7u) == 2u, "src_prot NS");
        CHECK(((ccr_ns >> 22) & 7u) == 2u, "dst_prot NS");
        CHECK(((ccr_s >> 8) & 7u) == 0u, "src_prot secure");
        CHECK(((ccr_s >> 22) & 7u) == 0u, "dst_prot secure");
        uint8_t prog[64];
        unsigned b = 0;
        uint32_t ccr_out = 0;
        const size_t pn = pl330BuildMem2MemProgramAuto(prog, sizeof(prog), 0x30601000u,
                                                       0x30300000u, 4096, &b, 16, 1, true, &ccr_out);
        CHECK(pn >= 12, "prog min");
        CHECK(prog[0] == 0xbc && prog[1] == 0x00, "SAR at +0");
        CHECK(prog[6] == 0xbc && prog[7] == 0x01, "CCR at +6 parent cpc");
        CHECK(ccr_out == ccr_ns, "ccr_out NS");
        char dline[96];
        CHECK(pl330DisasmProgramLine(prog, pn, 6, dline, sizeof(dline)) == 6, "disasm len");
        CHECK(std::string(dline).find("DMAMOV_CCR") != std::string::npos, "disasm CCR");
    }

    // Linux DMAGO DBGINST0 encode (incident fix) — NOT low-byte opcode form.
    {
        const uint32_t g0 = pl330DbgInst0GoManager(0, 0);
        const uint32_t g1 = pl330DbgInst0GoManager(0, 1);
        const uint32_t g3 = pl330DbgInst0GoManager(3, 1);
        // linux: DBGINST0 = (op<<16)|(chan<<24)
        CHECK(g0 == 0x00A00000u, "DMAGO ch0 ns0");
        CHECK(g1 == 0x00A20000u, "DMAGO ch0 ns1");
        CHECK(g3 == 0x03A20000u, "DMAGO ch3 ns1");
        // NEG: the old buggy encoding must not equal linux form
        const uint32_t buggy = (0u << 16) | (0u << 8) | 0xA0u; // 0x000000A0
        CHECK(buggy != g0, "NEG old encode != linux");
    }

    // Surgical diag: force burst-1 4 KiB factors; MFIFO cap 1 rejects burst16.
    {
        unsigned burst = 0;
        uint32_t inner = 0, outer = 0;
        CHECK(pl330PickBurstAndLoops(4096, &burst, &inner, &outer, 16, 1), "4k burst1 force");
        CHECK(burst == 1 && inner * outer == 1024, "4k = 1024 words");
        CHECK(!pl330PickBurstAndLoops(4096, &burst, &inner, &outer, /*cap*/1, /*force*/16),
              "NEG force16 over mfifo1");
        CHECK(std::string(pl330FtrChannelTag(1u << 0)) == "undef_instr", "ftr undef");
        CHECK(std::string(pl330FtrChannelTag(1u << 1)) == "operand_invalid", "ftr opinv");
        CHECK(std::string(pl330FtrChannelTag(1u << 5)) == "ch_rdwr_err", "ftr rdwr");
        CHECK(std::string(pl330FtrChannelTag(1u << 16)) == "instr_fetch_err", "ftr ifetch");
        CHECK(std::string(pl330FtrChannelTag(1u << 17)) == "data_write_err", "ftr dwr");
        CHECK(std::string(pl330FtrChannelTag(1u << 18)) == "data_read_err", "ftr drd");
        char bits[128];
        pl330FtrChannelBitsStr((1u << 1) | (1u << 5), bits, sizeof(bits));
        CHECK(std::string(bits).find("OPERAND_INVALID") != std::string::npos, "bits opinv");
        CHECK(std::string(bits).find("CH_RDWR_ERR") != std::string::npos, "bits rdwr");
        CHECK(std::string(pl330CsrStateTag(0x2)) == "cache_miss", "csr cache_miss");
        CHECK(pl330MfifoWordsFromCrd(0) == 1, "mfifo dep0 -> 1 word");
    }

    // Throughput ceiling: 0.010 ms @ 1382400 B is impossible
    CHECK(pl330ThroughputImpossible(1382400, 0.010), "NEG 0.01ms impossible");
    CHECK(pl330ThroughputImpossible(1382400, 0.0), "NEG zero ms");
    CHECK(!pl330ThroughputImpossible(1382400, 15.0), "15ms plausible");
    CHECK(pl330MinPlausibleMsForBytes(1382400) > 0.4 &&
              pl330MinPlausibleMsForBytes(1382400) < 0.5,
          "min ms ~0.43");

    // Content sample match
    {
        std::vector<uint8_t> a(256, 1), b(256, 1);
        CHECK(pl330BufferSamplesMatch(a.data(), b.data(), 256), "sample match");
        a[0] = 9;
        CHECK(!pl330BufferSamplesMatch(a.data(), b.data(), 256), "NEG sample mismatch");
        a[0] = 1;
        a[255] = 2;
        CHECK(!pl330BufferFullMatch(a.data(), b.data(), 256), "NEG full mismatch");
    }

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
    {
        Pl330Mem2MemRequest rq;
        CHECK(rq.allow_channel_kill == false, "kill default OFF (kernel owns pdma)");
    }

    // Kernel bank ABI (product DMA/WC — no raw unbind)
    {
        MisterplexBankInfo info{};
        info.api_version = kMisterplexBankApiVersion;
        info.n_banks = 2;
        info.bank0_phys = kMisterplexBank0PhysDefault;
        info.bank1_phys = kMisterplexBank1PhysDefault;
        info.bank_bytes = kMisterplexBankBytesDefault;
        info.map_prot = kMpbMapProtWriteCombine;
        info.dma_capable = 1;
        CHECK(misterplexBankInfoSane(info), "kabi info sane");
        info.bank0_phys = info.bank1_phys;
        CHECK(!misterplexBankInfoSane(info), "NEG kabi same bank phys");
        CHECK(std::strcmp(misterplexBankMapProtName(kMpbMapProtWriteCombine), "write_combine") == 0,
              "prot name");
        CHECK(misterplexBankWcRateIsProductCandidate(230.2), "wc candidate");
        CHECK(!misterplexBankWcRateIsProductCandidate(88.0), "NEG wc below bar");
        CHECK(kMpbIocInfoCmd != 0 && kMpbIocDmaMemcpyCmd != 0, "ioctl cmds nonzero");
    }

    if (g_fails) {
        std::cerr << "test_ddr_zero_copy_ingest: " << g_fails << " fails\n";
        return 1;
    }
    std::cout << "GREEN_ZERO_COPY_INGEST contract+kabi+barrier+credit\n";
    std::cout << "test_ddr_zero_copy_ingest: OK\n";
    return 0;
}
