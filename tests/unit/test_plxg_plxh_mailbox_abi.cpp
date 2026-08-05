// Red/green gate: host PLXG/PLXH fabric-kick ABI reservation.
//
// PHASE2 host SSOT only (DESIGN_CARD_HOST_FABRIC_KICK_MAILBOX):
//   - Magics PLXG/PLXH unique vs kAllMagics + ring in-band magics
//   - Doorbell-relative offsets +0x140..+0x15C no collision with
//     PLXK/PLXD/PLXF/PLXC/glass reserved slots
//   - pack/unpack HI words round-trip
//
// FORBID: product fabric path ON; sendDdrFrame hot-path change; RTL apply.

#include "libmisterplex/ddr_frame_layout.hpp"
#include "libmisterplex/ddr_zero_copy_ingest.hpp"
#include "libmisterplex/input_mailbox.hpp"
#include "libmisterplex/mailbox_abi_spec.hpp"

#include <cstdio>
#include <cstdlib>
#include <iostream>
#include <set>
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
    std::cout << "CASE plxg_plxh_offsets EXECUTED\n";
    expect_eq_u32(mailbox_abi::kPlxgOffset, 0x140u, "kPlxgOffset=0x140");
    expect_eq_u32(mailbox_abi::kPlxgSrcOffset, 0x148u, "kPlxgSrcOffset=0x148");
    expect_eq_u32(mailbox_abi::kPlxgBankPhysOffset, 0x14Cu, "kPlxgBankPhysOffset=0x14C");
    expect_eq_u32(mailbox_abi::kPlxgFrameBytesOffset, 0x150u,
                  "kPlxgFrameBytesOffset=0x150");
    expect_eq_u32(mailbox_abi::kPlxgReservedPadOffset, 0x154u,
                  "kPlxgReservedPadOffset=0x154");
    expect_eq_u32(mailbox_abi::kPlxhOffset, 0x158u, "kPlxhOffset=0x158");
    expect_eq_u32(mailbox_abi::kPlxgMagic, 0x504C5847u, "kPlxgMagic='PLXG'");
    expect_eq_u32(mailbox_abi::kPlxhMagic, 0x504C5848u, "kPlxhMagic='PLXH'");
    expect_eq_u32(mailbox_abi::kPlxgAddr, 0x3007F140u, "legacy kPlxgAddr");
    expect_eq_u32(mailbox_abi::kPlxhAddr, 0x3007F158u, "legacy kPlxhAddr");

    // Product 720p doorbell-relative absolutes (never hardcode at runtime).
    std::cout << "CASE product_doorbell_relative EXECUTED\n";
    {
        const uint32_t db = kPlex720pYuv420pDoorbellPhys;
        expect_eq_u32(db, 0x302FF000u, "product doorbell 0x302FF000");
        expect_eq_u32(fabricKickMailboxPhys(db), 0x302FF140u, "product PLXG phys");
        expect_eq_u32(fabricStatusMailboxPhys(db), 0x302FF158u, "product PLXH phys");
        expect_eq_u32(frameStoreMailboxPhys(db, mailbox_abi::kPlxgSrcOffset), 0x302FF148u,
                      "product SRC_PHYS slot");
        expect_eq_u32(frameStoreMailboxPhys(db, mailbox_abi::kPlxgFrameBytesOffset),
                      0x302FF150u, "product FRAME_BYTES slot");
        // PLXH_HI lives at +0x15C (qword +4).
        expect_eq_u32(frameStoreMailboxPhys(db, mailbox_abi::kPlxhOffset + 4u),
                      0x302FF15Cu, "product PLXH_HI at +0x15C");
    }

    // Offset non-collision with existing control slots + reserved PLXC/glass.
    std::cout << "CASE offset_no_collision EXECUTED\n";
    {
        struct Slot {
            const char* name;
            uint32_t off;
            unsigned size;
        };
        const Slot occupied[] = {
            {"PLXK", mailbox_abi::kPlxkOffset, 8},
            {"PLXS", mailbox_abi::kPlxsOffset, 8},
            {"PLXI", mailbox_abi::kPlxiOffset, 8},
            {"PLXM", mailbox_abi::kPlxmOffset, 8},
            {"PLXF", mailbox_abi::kPlxfOffset, 8},
            {"DIAG", mailbox_abi::kSdramDiagOffset, 8},
            {"PLXD", mailbox_abi::kPlxdOffset, 8},
            {"PLXC", mailbox_abi::kPlxcReservedOffset, 8},
            {"GLASS", mailbox_abi::kGlassExtReservedOffset, 8},
            {"PLXG", mailbox_abi::kPlxgOffset, 24}, // cmd+src+bank+len+pad
            {"PLXH", mailbox_abi::kPlxhOffset, 8},
        };
        for (size_t i = 0; i < sizeof(occupied) / sizeof(occupied[0]); ++i) {
            for (size_t j = i + 1; j < sizeof(occupied) / sizeof(occupied[0]); ++j) {
                const uint32_t a0 = occupied[i].off;
                const uint32_t a1 = a0 + occupied[i].size;
                const uint32_t b0 = occupied[j].off;
                const uint32_t b1 = b0 + occupied[j].size;
                const bool overlap = !(a1 <= b0 || b1 <= a0);
                if (overlap) {
                    std::cerr << "FAIL: offset collision " << occupied[i].name << " ["
                              << std::hex << a0 << ".." << a1 << ") vs "
                              << occupied[j].name << " [" << b0 << ".." << b1 << ")\n"
                              << std::dec;
                    ++g_fails;
                }
            }
        }
        // Explicit task checks vs PLXK/PLXD/PLXF/PLXC.
        expect(mailbox_abi::kPlxgOffset != mailbox_abi::kPlxkOffset &&
                   mailbox_abi::kPlxgOffset != mailbox_abi::kPlxdOffset &&
                   mailbox_abi::kPlxgOffset != mailbox_abi::kPlxfOffset &&
                   mailbox_abi::kPlxgOffset != mailbox_abi::kPlxcReservedOffset,
               "PLXG offset distinct from PLXK/PLXD/PLXF/PLXC");
        expect(mailbox_abi::kPlxhOffset != mailbox_abi::kPlxkOffset &&
                   mailbox_abi::kPlxhOffset != mailbox_abi::kPlxdOffset &&
                   mailbox_abi::kPlxhOffset != mailbox_abi::kPlxfOffset &&
                   mailbox_abi::kPlxhOffset != mailbox_abi::kPlxcReservedOffset,
               "PLXH offset distinct from PLXK/PLXD/PLXF/PLXC");
        expect(mailbox_abi::kPlxgOffset >= 0x140u &&
                   mailbox_abi::kPlxhOffset + 8u <= mailbox_abi::kPlxgPlxhSpanEndExclusive,
               "fabric block stays in +0x140..+0x15F");
        if (g_fails == 0)
            std::cout << "OK: no doorbell-relative offset collisions in control page\n";
    }

    // Magic uniqueness vs kAllMagics + bitstream ring + PLXQ.
    std::cout << "CASE magics_unique EXECUTED\n";
    {
        std::set<uint32_t> seen;
        for (const auto& e : mailbox_abi::kAllMagics) {
            if (seen.count(e.magic)) {
                std::cerr << "FAIL: duplicate kAllMagics magic for " << e.name << "\n";
                ++g_fails;
            }
            seen.insert(e.magic);
        }
        expect(seen.count(mailbox_abi::kPlxgMagic) == 1, "PLXG present in kAllMagics");
        expect(seen.count(mailbox_abi::kPlxhMagic) == 1, "PLXH present in kAllMagics");
        for (const auto& e : mailbox_abi::kBitstreamRingMagics) {
            if (seen.count(e.magic)) {
                std::cerr << "FAIL: ring magic " << e.name
                          << " collides with kAllMagics\n";
                ++g_fails;
            }
            seen.insert(e.magic);
        }
        if (seen.count(mailbox_abi::kPlxqMagic_entry.magic)) {
            std::cerr << "FAIL: PLXQ collides with kAllMagics/ring\n";
            ++g_fails;
        } else {
            seen.insert(mailbox_abi::kPlxqMagic_entry.magic);
        }
        expect(seen.size() >= 9u + 9u + 1u, "full magic universe counted");
        expect(mailbox_abi::kPlxgMagic != mailbox_abi::kPlxkMagic &&
                   mailbox_abi::kPlxgMagic != mailbox_abi::kPlxdMagic &&
                   mailbox_abi::kPlxgMagic != mailbox_abi::kPlxfMagic &&
                   mailbox_abi::kPlxgMagic != mailbox_abi::kPlxbMagic,
               "PLXG magic != PLXK/PLXD/PLXF/PLXB");
        expect(mailbox_abi::kPlxhMagic != mailbox_abi::kPlxgMagic,
               "PLXH magic != PLXG magic");
    }

    // kAllMailboxes address range collision (legacy example base).
    std::cout << "CASE kAllMailboxes_ranges EXECUTED\n";
    {
        for (size_t i = 0; i < mailbox_abi::kAllMailboxes.size(); ++i) {
            for (size_t j = i + 1; j < mailbox_abi::kAllMailboxes.size(); ++j) {
                const auto& a = mailbox_abi::kAllMailboxes[i];
                const auto& b = mailbox_abi::kAllMailboxes[j];
                const uint64_t a0 = a.phys_addr;
                const uint64_t a1 = a0 + a.size_bytes;
                const uint64_t b0 = b.phys_addr;
                const uint64_t b1 = b0 + b.size_bytes;
                if (!(a1 <= b0 || b1 <= a0)) {
                    std::cerr << "FAIL: kAllMailboxes range collision " << a.name
                              << " vs " << b.name << "\n";
                    ++g_fails;
                }
            }
        }
        if (g_fails == 0)
            std::cout << "OK: kAllMailboxes ranges non-overlapping\n";
        // PLXG size covers multi-word job params.
        bool found_g = false, found_h = false;
        for (const auto& m : mailbox_abi::kAllMailboxes) {
            if (std::string(m.name) == "PLXG") {
                found_g = true;
                expect(m.size_bytes == 24u, "PLXG size_bytes=24 (cmd+params)");
                expect(m.has_magic && m.magic == mailbox_abi::kPlxgMagic,
                       "PLXG entry magic");
            }
            if (std::string(m.name) == "PLXH") {
                found_h = true;
                expect(m.size_bytes == 8u, "PLXH size_bytes=8");
                expect(m.has_magic && m.magic == mailbox_abi::kPlxhMagic,
                       "PLXH entry magic");
            }
        }
        expect(found_g && found_h, "PLXG+PLXH registered in kAllMailboxes");
    }

    // pack/unpack HI words.
    std::cout << "CASE pack_unpack_hi EXECUTED\n";
    {
        mailbox_abi::PlxgCmdHi cmd{};
        cmd.start_toggle = true;
        cmd.clr_done = true;
        cmd.bank_sel = true;
        cmd.use_bank_sel = false;
        cmd.cmd_seq = 0xA5C3u;
        const uint32_t ghi = mailbox_abi::packPlxgCmdHi(cmd);
        expect((ghi & (1u << mailbox_abi::kPlxgStartToggleBit)) != 0,
               "PLXG_HI start_toggle bit set");
        expect((ghi & (1u << mailbox_abi::kPlxgClrDoneBit)) != 0,
               "PLXG_HI clr_done bit set");
        expect((ghi & (1u << mailbox_abi::kPlxgBankSelBit)) != 0,
               "PLXG_HI bank_sel bit set");
        expect_eq_u32((ghi >> mailbox_abi::kPlxgCmdSeqBit) & 0xFFFFu, 0xA5C3u,
                      "PLXG_HI cmd_seq field");
        const auto cmd2 = mailbox_abi::unpackPlxgCmdHi(ghi);
        expect(cmd2.start_toggle && cmd2.clr_done && cmd2.bank_sel && !cmd2.use_bank_sel &&
                   !cmd2.start_w && !cmd2.abort && cmd2.cmd_seq == 0xA5C3u,
               "PLXG_HI unpack round-trip");
        expect(mailbox_abi::packPlxgCmdHi(cmd2) == ghi, "PLXG_HI pack idempotent");

        mailbox_abi::PlxhStatusHi st{};
        st.done_sticky = true;
        st.accepted = true;
        st.done_seq = 0xA5C3u;
        const uint32_t hhi = mailbox_abi::packPlxhStatusHi(st);
        expect_eq_u32((hhi >> mailbox_abi::kPlxhDoneSeqBit) & 0xFFFFu, 0xA5C3u,
                      "PLXH_HI done_seq field");
        const auto st2 = mailbox_abi::unpackPlxhStatusHi(hhi);
        expect(st2.done_sticky && st2.accepted && !st2.busy && !st2.err_align &&
                   st2.done_seq == 0xA5C3u,
               "PLXH_HI unpack round-trip");
        expect(mailbox_abi::packPlxhStatusHi(st2) == hhi, "PLXH_HI pack idempotent");
        expect(mailbox_abi::plxhStatusSuccess(st2, 0xA5C3u),
               "success predicate matches cmd_seq");
        expect(!mailbox_abi::plxhStatusSuccess(st2, 0x0001u),
               "success fails on seq mismatch");
        mailbox_abi::PlxhStatusHi bad = st2;
        bad.err_align = true;
        expect(!mailbox_abi::plxhStatusSuccess(bad, 0xA5C3u),
               "success fails on err_align");
    }

    // Product safety: fabric path must remain OFF; this ABI land does not flip it.
    std::cout << "CASE product_fabric_flag_off EXECUTED\n";
    expect(!kDdrPublishFabricPathEnabledInProduct,
           "kDdrPublishFabricPathEnabledInProduct remains false");
    expect(kDdrPublishProductWire == 0, "PRODUCT_WIRE product default 0");

    if (g_fails) {
        std::cerr << "REPRO_OR_FAIL test_plxg_plxh_mailbox_abi fails=" << g_fails << "\n";
        return 1;
    }
    std::cout << "PASS test_plxg_plxh_mailbox_abi PLXG@+0x140 PLXH@+0x158 "
                 "magics unique pack/unpack OK product_fabric=OFF\n";
    return 0;
}
