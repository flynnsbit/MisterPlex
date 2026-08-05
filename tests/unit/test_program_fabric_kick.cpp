// Red/green gate: host programFabricKick / waitFabricKickDone pack order.
//
// RESEARCH-ONLY helpers (fabric_dma_host.hpp). No device. No PLXK ring.
// Product fabric flag stays false; sendDdrFrame hot path not exercised.

#include "libmisterplex/ddr_frame_layout.hpp"
#include "libmisterplex/ddr_zero_copy_ingest.hpp"
#include "libmisterplex/fabric_dma_host.hpp"
#include "libmisterplex/mailbox_abi_spec.hpp"

#include <cstdio>
#include <cstdlib>
#include <iostream>
#include <string>

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

static void expect_eq_sz(size_t got, size_t want, const char* msg) {
    if (got != want) {
        std::cerr << "FAIL: " << msg << " got=" << got << " want=" << want << "\n";
        ++g_fails;
    } else {
        std::cout << "OK: " << msg << "\n";
    }
}

int main() {
    std::cout << "CASE product_flag_still_off EXECUTED\n";
    expect(!kDdrPublishFabricPathEnabledInProduct,
           "kDdrPublishFabricPathEnabledInProduct remains false");
    expect(!ddrPublishSkipTcopyLegal(), "skip T_copy illegal under product default");

    // ---- Pack order on mock memory map ------------------------------------
    std::cout << "CASE pack_order_src_bank_len_hi_magic_last EXECUTED\n";
    {
        MockFabricKickMem mem;
        FabricKickHostState st;
        FabricDmaJob job;
        job.src_phys = 0x30601000u;   // PL330 staging class PA
        job.bank_phys = 0x30000000u;  // bank0 product
        job.frame_bytes = static_cast<uint32_t>(kPlex720pYuv420pBytes);
        job.bank_sel = false;
        job.use_bank_sel = true;
        job.cmd_seq = 0x0042u;

        expect(fabricKickAlignOk(job.src_phys, job.bank_phys, job.frame_bytes),
               "720 I420 job align_ok");
        expect(programFabricKick(mem, st, job, FabricStartMode::Toggle),
               "programFabricKick toggle ok");

        // Exactly five data writes (SRC,BANK,LEN,HI,LO); barriers around HI/LO.
        expect_eq_sz(mem.write_log.size(), 5u, "five MMIO writes");
        expect(mem.barrier_count >= 3u, "≥3 barriers (pre-HI, pre-magic, post-magic)");
        expect(!mem.wrotePlxk(), "helper never writes PLXK (+0x000)");

        expect_eq_u32(mem.write_log[0].off, kFabricKickPackOffSrc, "write0 off=SRC +0x148");
        expect_eq_u32(mem.write_log[0].value, job.src_phys, "write0 val=src");
        expect_eq_u32(mem.write_log[1].off, kFabricKickPackOffBank, "write1 off=BANK +0x14C");
        expect_eq_u32(mem.write_log[1].value, job.bank_phys, "write1 val=bank");
        expect_eq_u32(mem.write_log[2].off, kFabricKickPackOffLen, "write2 off=LEN +0x150");
        expect_eq_u32(mem.write_log[2].value, job.frame_bytes, "write2 val=len");
        expect_eq_u32(mem.write_log[3].off, kFabricKickPackOffHi, "write3 off=PLXG_HI +0x144");
        expect_eq_u32(mem.write_log[4].off, kFabricKickPackOffLo, "write4 off=PLXG_LO +0x140 magic last");
        expect_eq_u32(mem.write_log[4].value, mailbox_abi::kPlxgMagic, "magic=PLXG last");

        // HI packs cmd_seq + toggled start + use_bank_sel.
        const auto cmd = mailbox_abi::unpackPlxgCmdHi(mem.write_log[3].value);
        expect(cmd.start_toggle, "start_toggle flipped to 1 on first kick");
        expect(!cmd.start_w, "toggle mode leaves start_w=0");
        expect(cmd.use_bank_sel, "use_bank_sel set");
        expect(!cmd.bank_sel, "bank_sel=0");
        expect(cmd.cmd_seq == job.cmd_seq, "cmd_seq in HI");
        expect(st.last_start_toggle, "host state toggle sticky");
        expect(st.last_cmd_seq == job.cmd_seq, "host state last_cmd_seq");

        // Page contents match.
        expect_eq_u32(mem.read32(mailbox_abi::kPlxgSrcOffset), job.src_phys, "mem SRC");
        expect_eq_u32(mem.read32(mailbox_abi::kPlxgBankPhysOffset), job.bank_phys, "mem BANK");
        expect_eq_u32(mem.read32(mailbox_abi::kPlxgFrameBytesOffset), job.frame_bytes,
                      "mem LEN");
        expect_eq_u32(mem.read32(mailbox_abi::kPlxgOffset), mailbox_abi::kPlxgMagic,
                      "mem PLXG magic");
        // PLXK region remains zero.
        expect_eq_u32(mem.read32(0), 0u, "PLXK lo untouched");
        expect_eq_u32(mem.read32(4), 0u, "PLXK hi untouched");
    }

    // ---- Second kick flips toggle again -----------------------------------
    std::cout << "CASE start_toggle_edge_second_kick EXECUTED\n";
    {
        MockFabricKickMem mem;
        FabricKickHostState st;
        FabricDmaJob job;
        job.src_phys = 0x30601000u;
        job.bank_phys = 0x30180000u;
        job.frame_bytes = 1382400u;
        job.cmd_seq = 1;

        expect(programFabricKick(mem, st, job, FabricStartMode::Toggle), "kick1");
        expect(st.last_start_toggle, "toggle after kick1 = 1");
        mem.clearWriteLog();
        job.cmd_seq = 2;
        expect(programFabricKick(mem, st, job, FabricStartMode::Toggle), "kick2");
        expect(!st.last_start_toggle, "toggle after kick2 = 0");
        const auto cmd = mailbox_abi::unpackPlxgCmdHi(mem.write_log[3].value);
        expect(!cmd.start_toggle, "HI start_toggle=0 on second edge");
        expect(cmd.cmd_seq == 2, "cmd_seq=2");
        expect(!mem.wrotePlxk(), "kick2 no PLXK");
    }

    // ---- start_w mode -----------------------------------------------------
    std::cout << "CASE start_w_mode EXECUTED\n";
    {
        MockFabricKickMem mem;
        FabricKickHostState st;
        FabricDmaJob job;
        job.src_phys = 0x30800000u;
        job.bank_phys = 0x30000000u;
        job.frame_bytes = 1382400u;
        job.cmd_seq = 9;
        expect(programFabricKick(mem, st, job, FabricStartMode::StartW), "start_w kick");
        const auto cmd = mailbox_abi::unpackPlxgCmdHi(mem.write_log[3].value);
        expect(cmd.start_w, "start_w=1");
        expect(!cmd.start_toggle, "start_toggle held 0");
        expect(mem.write_log[4].value == mailbox_abi::kPlxgMagic, "magic still last");
        expect(!mem.wrotePlxk(), "start_w path no PLXK");
    }

    // ---- Align reject -----------------------------------------------------
    std::cout << "CASE align_reject EXECUTED\n";
    {
        MockFabricKickMem mem;
        FabricKickHostState st;
        FabricDmaJob job;
        job.src_phys = 0x30601001u; // misaligned
        job.bank_phys = 0x30000000u;
        job.frame_bytes = 1382400u;
        job.cmd_seq = 1;
        expect(!programFabricKick(mem, st, job), "misaligned src rejected");
        expect_eq_sz(mem.write_log.size(), 0u, "no MMIO on align reject");
        job.src_phys = 0x30601000u;
        job.frame_bytes = 0;
        expect(!programFabricKick(mem, st, job), "zero len rejected");
    }

    // ---- waitFabricKickDone success / fail paths --------------------------
    std::cout << "CASE wait_success EXECUTED\n";
    {
        MockFabricKickMem mem;
        mailbox_abi::PlxhStatusHi ok;
        ok.busy = false;
        ok.done_sticky = true;
        ok.done_seq = 0x0042u;
        mem.seedPlxh(mailbox_abi::packPlxhStatusHi(ok));
        const auto r = waitFabricKickDone(mem, 0x0042u, 8);
        expect(r == FabricKickWaitResult::Success, "wait success");
        expect(!mem.wrotePlxk(), "wait does not write PLXK");
        expect_eq_sz(mem.write_log.size(), 0u, "wait is read-only");
    }

    std::cout << "CASE wait_err_align EXECUTED\n";
    {
        MockFabricKickMem mem;
        mailbox_abi::PlxhStatusHi bad;
        bad.done_sticky = true;
        bad.err_align = true;
        bad.done_seq = 7;
        mem.seedPlxh(mailbox_abi::packPlxhStatusHi(bad));
        expect(waitFabricKickDone(mem, 7, 4) == FabricKickWaitResult::ErrAlign,
               "err_align");
    }

    std::cout << "CASE wait_magic_missing_timeout EXECUTED\n";
    {
        MockFabricKickMem mem; // PLXH zero
        expect(waitFabricKickDone(mem, 1, 3) == FabricKickWaitResult::MagicMissing,
               "magic missing → MagicMissing");
    }

    std::cout << "CASE wait_wrong_seq_timeout EXECUTED\n";
    {
        MockFabricKickMem mem;
        mailbox_abi::PlxhStatusHi stale;
        stale.done_sticky = true;
        stale.done_seq = 1; // want 2
        mem.seedPlxh(mailbox_abi::packPlxhStatusHi(stale));
        expect(waitFabricKickDone(mem, 2, 5) == FabricKickWaitResult::Timeout,
               "stale done_seq → Timeout");
    }

    // ---- programAndWait end-to-end on mock (seed after program) -----------
    std::cout << "CASE program_and_wait_mock_e2e EXECUTED\n";
    {
        MockFabricKickMem mem;
        FabricKickHostState st;
        FabricDmaJob job;
        job.src_phys = 0x30601000u;
        job.bank_phys = 0x30000000u;
        job.frame_bytes = 1382400u;
        job.cmd_seq = 0x00AAu;
        expect(programFabricKick(mem, st, job), "program for e2e");
        // Simulate FPGA accept+done: write PLXH success for cmd_seq.
        mailbox_abi::PlxhStatusHi ok;
        ok.done_sticky = true;
        ok.done_seq = job.cmd_seq;
        ok.accepted = true;
        mem.seedPlxh(mailbox_abi::packPlxhStatusHi(ok));
        expect(waitFabricKickDone(mem, job.cmd_seq, 16) == FabricKickWaitResult::Success,
               "e2e wait after program");
        // Still no PLXK in entire session (seedPlxh uses write32? no, direct words).
        expect(!mem.wrotePlxk(), "e2e never PLXK");
    }

    // ---- clearFabricKickDone does not ring PLXK ---------------------------
    std::cout << "CASE clear_done_no_plxk EXECUTED\n";
    {
        MockFabricKickMem mem;
        FabricKickHostState st;
        st.last_cmd_seq = 3;
        st.last_start_toggle = true;
        clearFabricKickDone(mem, st, true);
        expect(!mem.wrotePlxk(), "clearFabricKickDone no PLXK");
        expect(mem.write_log.back().off == mailbox_abi::kPlxgOffset, "clear ends with magic");
        const auto cmd = mailbox_abi::unpackPlxgCmdHi(
            mem.read32(mailbox_abi::kPlxgOffset + 4u));
        expect(cmd.clr_done, "clr_done set");
        expect(cmd.clr_err, "clr_err set");
        expect(!cmd.start_w, "clear is not a start");
    }

    // ---- Offsets match product doorbell map -------------------------------
    std::cout << "CASE product_phys_slots EXECUTED\n";
    {
        const uint32_t db = kPlex720pYuv420pDoorbellPhys;
        expect_eq_u32(db + mailbox_abi::kPlxgSrcOffset, 0x302FF148u, "product SRC");
        expect_eq_u32(db + mailbox_abi::kPlxgBankPhysOffset, 0x302FF14Cu, "product BANK");
        expect_eq_u32(db + mailbox_abi::kPlxgFrameBytesOffset, 0x302FF150u, "product LEN");
        expect_eq_u32(db + mailbox_abi::kPlxgOffset, 0x302FF140u, "product PLXG");
        expect_eq_u32(db + mailbox_abi::kPlxhOffset, 0x302FF158u, "product PLXH");
    }

    if (g_fails) {
        std::cerr << "FAIL test_program_fabric_kick fails=" << g_fails << "\n";
        return 1;
    }
    std::cout << "PASS test_program_fabric_kick pack_order+mock_mem "
                 "no_PLXK product_flag=0\n";
    return 0;
}
