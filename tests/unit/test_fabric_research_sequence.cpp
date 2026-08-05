// Pure unit/mock integration sequence: research fabric bring-up order.
//
// OFFLINE — no device, no FPGA, no /dev/mem.
//
// Sequence under test (RESEARCH-ONLY):
//   1) fillStagingFromPayload mock buffer  — host payload → Rank2 staging VA
//   2) programFabricKick MockFabricKickMem — PLXG pack order, SRC=stagingPhys
//   3) waitFabricKickDone Success          — PLXH done sticky for cmd_seq
//   4) assert PLXK never written           — helpers must not ring present
//   5) (document only) caller would kickDdrDoorbell AFTER done + payload barrier
//
// Uses: fabric_src_staging.hpp fill helpers, fabric_dma_host.hpp
//       MockFabricKickMem, fabric_src_phys.hpp staging SSOT.
// Product path stays OFF (kDdrPublishFabricPathEnabledInProduct=false).

#include "libmisterplex/ddr_frame_layout.hpp"
#include "libmisterplex/ddr_zero_copy_ingest.hpp"
#include "libmisterplex/fabric_dma_host.hpp"
#include "libmisterplex/fabric_src_phys.hpp"
#include "libmisterplex/fabric_src_staging.hpp"
#include "libmisterplex/mailbox_abi_spec.hpp"

#include <cstdint>
#include <cstring>
#include <iostream>
#include <string>
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

    // ---- Preconditions: Rank2 staging SSOT --------------------------------
    std::cout << "CASE staging_constants EXECUTED\n";
    expect_eq_u32(stagingPhysBase(), 0x30601000u, "stagingPhysBase() OPT-A");
    expect_eq_u32(stagingPhysBase(), kFabricSrcStagingPhys, "staging SSOT alias");
    expect(stagingDefault720AlignOk(kDdrFramePhysBase),
           "default 720 bank0 align_ok");
    expect(stagingFrameBytesOk(64u), "64B mock payload frame_bytes ok");

    // Compact research payload (8B aligned). Full 720 I420 also legal; sequence
    // contract does not require painting every plane byte.
    constexpr uint32_t kPayloadBytes = 64u;
    constexpr uint16_t kCmdSeq = 0x00BEu;

    // =====================================================================
    // FULL RESEARCH SEQUENCE (single continuous mock session)
    // =====================================================================
    std::cout << "CASE research_sequence_end_to_end EXECUTED\n";

    // (1) fillStaging mock — host VA of staging (unit mock buffer, no mmap)
    std::vector<uint8_t> staging_map(stagingRegionBytes(), 0u);
    std::vector<uint8_t> host_payload(kPayloadBytes, 0u);
    for (uint32_t i = 0; i < kPayloadBytes; ++i)
        host_payload[i] = static_cast<uint8_t>(0xA0u + (i & 0x1Fu));

    expect(fillStagingFromPayload(staging_map.data(), host_payload.data(),
                                  kPayloadBytes) == true,
           "1) fillStagingFromPayload mock ok");
    expect(fillStagingFromPayloadEx(staging_map.data(), host_payload.data(),
                                    kPayloadBytes) == StagingFillResult::Ok,
           "1) fillStagingFromPayloadEx → Ok");
    expect(std::memcmp(staging_map.data(), host_payload.data(), kPayloadBytes) == 0,
           "1) staging bytes match host payload");

    // (1b) Build job with SRC = stagingPhysBase() (PA of filled region)
    FabricDmaJob job;
    expect(makeStagingFabricJob(job, kDdrFramePhysBase, kPayloadBytes,
                                kCmdSeq),
           "1b) makeStagingFabricJob");
    expect_eq_u32(job.src_phys, stagingPhysBase(), "job.src_phys == stagingPhysBase()");
    expect_eq_u32(job.bank_phys, kDdrFramePhysBase, "job.bank_phys bank0");
    expect_eq_u32(job.frame_bytes, kPayloadBytes, "job.frame_bytes");
    expect(job.cmd_seq == kCmdSeq, "job.cmd_seq");

    // (2) programFabricKick on MockFabricKickMem — never rings PLXK
    MockFabricKickMem mem;
    FabricKickHostState kick_st;
    expect(programFabricKick(mem, kick_st, job, FabricStartMode::Toggle),
           "2) programFabricKick toggle ok");
    expect_eq_u32(mem.write_log.size() >= 5u ? mem.write_log[0].off : 0u,
                  kFabricKickPackOffSrc, "2) write0 SRC +0x148");
    expect_eq_u32(mem.read32(mailbox_abi::kPlxgSrcOffset), stagingPhysBase(),
                  "2) mem SRC == stagingPhysBase()");
    expect_eq_u32(mem.read32(mailbox_abi::kPlxgBankPhysOffset), job.bank_phys,
                  "2) mem BANK");
    expect_eq_u32(mem.read32(mailbox_abi::kPlxgFrameBytesOffset), kPayloadBytes,
                  "2) mem LEN");
    expect_eq_u32(mem.read32(mailbox_abi::kPlxgOffset), mailbox_abi::kPlxgMagic,
                  "2) PLXG magic last");
    expect(!mem.wrotePlxk(), "2) programFabricKick never writes PLXK");

    // (3) waitFabricKickDone Success — seed PLXH as FPGA done sticky
    // seedPlxh writes words[] directly (not write_log) so wrotePlxk stays false.
    mailbox_abi::PlxhStatusHi ok;
    ok.busy = false;
    ok.done_sticky = true;
    ok.done_seq = job.cmd_seq;
    ok.accepted = true;
    mem.seedPlxh(mailbox_abi::packPlxhStatusHi(ok));

    const auto wait_r = waitFabricKickDone(mem, job.cmd_seq, 16);
    expect(wait_r == FabricKickWaitResult::Success,
           "3) waitFabricKickDone Success");
    expect(std::string(fabricKickWaitResultName(wait_r)) == "Success",
           "3) wait result name Success");

    // (4) assert PLXK never written across entire sequence
    expect(!mem.wrotePlxk(),
           "4) sequence write_log never touches PLXK (+0x000..+0x007)");
    expect_eq_u32(mem.read32(0), 0u, "4) PLXK lo still zero");
    expect_eq_u32(mem.read32(4), 0u, "4) PLXK hi still zero");
    expect_eq_u32(mem.read32(mailbox_abi::kPlxhOffset), mailbox_abi::kPlxhMagic,
                  "4) PLXH magic present");

    // (5) DOCUMENT only: caller would kickDdrDoorbell after done + barrier
    // Contract (fabric_dma_host.hpp / fabric_src_staging.hpp): after
    // waitFabricKickDone(Success) and a payload barrier, the CALLER owns
    // present — FpgaSpi::kickDdrDoorbell(bank) / PLXK ring. Research helpers
    // deliberately omit that step so this gate can prove PLXK stays zero
    // through fill → program → wait.
    std::cout << "CASE document_caller_kickDdrDoorbell EXECUTED\n";
    std::cout
        << "DOC: after waitFabricKickDone(Success)+payload barrier, "
           "caller would kickDdrDoorbell(bank) to ring PLXK present doorbell; "
           "NOT invoked in this research sequence (helpers forbid PLXK).\n";
    expect(!mem.wrotePlxk(),
           "5) post-doc: still no PLXK (caller doorbell not simulated)");
    expect(std::memcmp(staging_map.data(), host_payload.data(), kPayloadBytes) == 0,
           "5) staging payload still held for would-be present");

    // ---- Convenience path: programAndWait still no PLXK -------------------
    std::cout << "CASE programAndWait_convenience_no_PLXK EXECUTED\n";
    {
        MockFabricKickMem mem2;
        FabricKickHostState st2;
        FabricDmaJob job2;
        expect(makeStagingFabricJob(job2, kDdrFramePhysBase, kPayloadBytes,
                                    0x00C1u),
               "make job for programAndWait");
        // Seed success before wait loop (mock has no FPGA thread).
        mailbox_abi::PlxhStatusHi ok2;
        ok2.done_sticky = true;
        ok2.done_seq = job2.cmd_seq;
        ok2.accepted = true;
        mem2.seedPlxh(mailbox_abi::packPlxhStatusHi(ok2));
        // program first so pack order still exercised, then wait (same as
        // programAndWait but seed is already live for the poll).
        expect(programFabricKick(mem2, st2, job2), "program before convenience wait");
        expect(waitFabricKickDone(mem2, job2.cmd_seq, 8) ==
                   FabricKickWaitResult::Success,
               "convenience wait Success");
        expect(!mem2.wrotePlxk(), "programAndWait-class path never PLXK");
        expect_eq_u32(mem2.read32(0), 0u, "PLXK lo zero on mem2");
        expect_eq_u32(mem2.read32(4), 0u, "PLXK hi zero on mem2");
    }

    // ---- Second kick edge still never PLXK --------------------------------
    std::cout << "CASE clear_then_reprogram_no_PLXK EXECUTED\n";
    clearFabricKickDone(mem, kick_st, true);
    expect(!mem.wrotePlxk(), "clearFabricKickDone no PLXK");
    job.cmd_seq = 0x00BFu;
    expect(programFabricKick(mem, kick_st, job, FabricStartMode::Toggle),
           "second program after clear");
    ok.done_seq = job.cmd_seq;
    mem.seedPlxh(mailbox_abi::packPlxhStatusHi(ok));
    expect(waitFabricKickDone(mem, job.cmd_seq, 8) == FabricKickWaitResult::Success,
           "second wait success");
    expect(!mem.wrotePlxk(), "full two-kick sequence never PLXK");

    if (g_fails) {
        std::cerr << "FAIL test_fabric_research_sequence fails=" << g_fails << "\n";
        return 1;
    }
    std::cout << "PASS test_fabric_research_sequence "
                 "fillStaging→program→wait→no_PLXK "
                 "caller_would_kickDdrDoorbell product_flag=0\n";
    return 0;
}
