// Kick-only publish: GREEN claim→fill→kick; RED unfilled / free_mask=0 / unclaimed.
#include "libmisterplex/ddr_kick_only_publish.hpp"

#include <cstdio>
#include <cstring>

using namespace misterplex;

static int g_fails = 0;

static void expect(bool cond, const char* msg) {
    if (!cond) {
        std::fprintf(stderr, "FAIL: %s\n", msg);
        ++g_fails;
    }
}

static BankReleaseStatus brsFree1() {
    BankReleaseStatus s{};
    s.disp_bank = 0;
    s.free_bank_mask = 0x2; // bank1 free
    s.swap_pending = false;
    s.frames_done = 0;
    return s;
}

static BankReleaseStatus brsNone() {
    BankReleaseStatus s = brsFree1();
    s.free_bank_mask = 0;
    s.swap_pending = true;
    return s;
}

int main() {
    // PRE-REGISTER: claim bank1 → markFilled → kickOk; three negatives Drop
    std::printf("PRE-REGISTER kick-only: KickOk after fill; "
                "unfilled/unclaimed/no_free → Drop\n");

    {
        KickOnlyPublishState st{};
        auto brs = brsFree1();
        auto c = claimDdrBankForFill(brs, st, 50);
        expect(c.action == KickOnlyAction::ClaimOk && c.bank == 1, "claim bank1");
        expect(markDdrBankFilled(st, 1), "mark filled bank1");
        auto k = kickDdrBankOnly(brs, st, 1);
        expect(k.action == KickOnlyAction::KickOk && k.bank == 1, "kick ok bank1");
        expect(std::strcmp(k.reason, "kick_ok") == 0, "reason kick_ok");
        // second kick same bank without re-claim must Drop
        auto k2 = kickDdrBankOnly(brs, st, 1);
        expect(k2.action == KickOnlyAction::Drop, "second kick without claim → Drop");
        expect(std::strcmp(k2.reason, "kick_unclaimed") == 0, "reason unclaimed");
    }

    // NEG: kick without markFilled
    {
        KickOnlyPublishState st{};
        auto brs = brsFree1();
        auto c = claimDdrBankForFill(brs, st, 50);
        expect(c.action == KickOnlyAction::ClaimOk, "claim for unfilled neg");
        auto k = kickDdrBankOnly(brs, st, c.bank);
        expect(k.action == KickOnlyAction::Drop, "unfilled → Drop");
        expect(std::strcmp(k.reason, "kick_unfilled") == 0, "reason unfilled");
    }

    // NEG: kick with free_mask=0 / swap_pending
    {
        KickOnlyPublishState st{};
        st.claimed_mask = 0x2;
        st.filled_mask = 0x2;
        auto brs = brsNone();
        auto k = kickDdrBankOnly(brs, st, 1);
        expect(k.action == KickOnlyAction::Drop, "no free → Drop");
        expect(std::strcmp(k.reason, "kick_swap_pending") == 0 ||
                   std::strcmp(k.reason, "kick_no_free") == 0,
               "reason no free/swap");
    }

    // NEG: kick unclaimed bank
    {
        KickOnlyPublishState st{};
        st.filled_mask = 0x2; // filled but never claimed via API
        auto brs = brsFree1();
        auto k = kickDdrBankOnly(brs, st, 1);
        expect(k.action == KickOnlyAction::Drop, "unclaimed → Drop");
        expect(std::strcmp(k.reason, "kick_unclaimed") == 0, "reason unclaimed2");
    }

    // NEG: markFilled without claim
    {
        KickOnlyPublishState st{};
        expect(!markDdrBankFilled(st, 0), "mark without claim → false");
    }

    if (g_fails) {
        std::fprintf(stderr, "test_ddr_kick_only_publish: %d failure(s)\n", g_fails);
        return 1;
    }
    std::printf("test_ddr_kick_only_publish: OK (KickOk + 4 negatives)\n");
    return 0;
}
