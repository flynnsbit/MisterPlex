// PLXD bank-select policy — pure host unit test (no FPGA).
//
// Positive: free_mask names a bank != disp → Write that bank.
// NEGATIVE (rd-duck): free_mask==0 / swap_pending timeout → Drop, NEVER
// force-write disp^1. Legacy force path is asserted as the RED baseline.
// Also: free==disp is stale residue → wait/drop; await_display_ack holds.

#include "libmisterplex/ddr_bank_release_select.hpp"
#include "libmisterplex/input_mailbox.hpp"

#include <cstdio>

using namespace misterplex;

static int fails = 0;
#define CHECK(cond)                                                            \
    do {                                                                       \
        if (!(cond)) {                                                         \
            std::fprintf(stderr, "FAIL %s:%d: %s\n", __FILE__, __LINE__,       \
                         #cond);                                               \
            ++fails;                                                           \
        }                                                                      \
    } while (0)

static BankReleaseStatus makeBrs(uint8_t free_mask, uint8_t disp, bool swap,
                                 uint16_t fd = 0) {
    BankReleaseStatus s;
    s.free_bank_mask = free_mask;
    s.disp_bank = disp;
    s.swap_pending = swap;
    s.frames_done = fd;
    return s;
}

int main() {
    // --- Positive: free bank 1 while disp=0, !swap ---
    {
        DdrBankSelectState st{};
        const auto r = selectDdrWriteBank(makeBrs(0b10, 0, false), st, 50);
        CHECK(r.action == DdrBankSelectAction::Write);
        CHECK(r.bank == 1);
        noteDdrBankPublished(st, r.bank);
        CHECK(st.last_published_bank == 1);
        CHECK(st.last_publish_seen_on_display == false);
    }

    // --- NEGATIVE: free_mask=0 + swap_pending, exhaust waits → Drop ---
    {
        DdrBankSelectState st{};
        DdrBankSelectResult last{};
        for (int i = 0; i < 50; ++i)
            last = selectDdrWriteBank(makeBrs(0b00, 0, true, 3), st, 50);
        CHECK(last.action == DdrBankSelectAction::Drop);
        CHECK(last.bank < 0);
        // Must NOT look like a write to disp^1
        CHECK(!(last.action == DdrBankSelectAction::Write && last.bank == 1));
    }

    // --- NEGATIVE: free_mask=0 without swap also Drop at limit ---
    {
        DdrBankSelectState st{};
        DdrBankSelectResult last{};
        for (int i = 0; i < 10; ++i)
            last = selectDdrWriteBank(makeBrs(0b00, 1, false), st, 10);
        CHECK(last.action == DdrBankSelectAction::Drop);
        CHECK(last.bank == -1);
    }

    // --- free == disp is stale residue → wait then Drop (never Write) ---
    {
        DdrBankSelectState st{};
        auto r = selectDdrWriteBank(makeBrs(0b01, 0, false), st, 5);
        CHECK(r.action == DdrBankSelectAction::Wait);
        for (int i = 0; i < 5; ++i)
            r = selectDdrWriteBank(makeBrs(0b01, 0, false), st, 5);
        CHECK(r.action == DdrBankSelectAction::Drop);
        CHECK(r.bank < 0);
    }

    // --- await_display_ack: refuse re-publish of last bank until disp moves ---
    {
        DdrBankSelectState st{};
        noteDdrBankPublished(st, 1); // published bank 1, not yet seen on display
        // free still reports 1 while disp still 0 → wait
        auto r = selectDdrWriteBank(makeBrs(0b10, 0, false), st, 50);
        CHECK(r.action == DdrBankSelectAction::Wait);
        // disp advances to 1 → ack; free becomes bank 0
        r = selectDdrWriteBank(makeBrs(0b01, 1, false), st, 50);
        CHECK(r.action == DdrBankSelectAction::Write);
        CHECK(r.bank == 0);
    }

    // --- Legacy RED baseline: timed_out forces disp^1 (must stay distinct) ---
    {
        const auto bad =
            selectDdrWriteBankLegacyForce(makeBrs(0b00, 0, true), /*last*/ 0,
                                          /*timed_out=*/true);
        CHECK(bad.action == DdrBankSelectAction::Write);
        CHECK(bad.bank == 1); // disp^1 — the ownership violation
        // Product policy must NOT match this for the same brs after timeout.
        DdrBankSelectState st{};
        DdrBankSelectResult prod{};
        for (int i = 0; i < 50; ++i)
            prod = selectDdrWriteBank(makeBrs(0b00, 0, true), st, 50);
        CHECK(prod.action == DdrBankSelectAction::Drop);
        CHECK(prod.bank != bad.bank || prod.action != DdrBankSelectAction::Write);
    }

    // --- Mid-poll Wait does not assign a bank ---
    {
        DdrBankSelectState st{};
        const auto r = selectDdrWriteBank(makeBrs(0b00, 0, true), st, 50);
        CHECK(r.action == DdrBankSelectAction::Wait);
        CHECK(r.bank == -1);
    }

    if (fails) {
        std::fprintf(stderr, "test_ddr_bank_release_select: %d failure(s)\n",
                     fails);
        return 1;
    }
    std::printf("test_ddr_bank_release_select: OK "
                "(drop-on-free0 + legacy-force negative)\n");
    return 0;
}
