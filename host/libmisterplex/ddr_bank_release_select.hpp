#pragma once
// PLXD bank-select protocol for ARM DDR publish.
//
// Silicon (c5382bee + e9f79de2): idle animates; playback freezes with presents
// still climbing. Product RTL sustained gate PASSES when the TB only doorbells
// on !swap_pending — so the scanout sticky/recycle path is not the defect under
// correct free-bank pacing.
//
// Root class: PLXD free_bank_mask is refreshed on vsync/heartbeat, not on the
// doorbell edge. After a swap, a *stale* free mask still names the bank that
// just became the display bank. Legacy ARM freeBank()+force(disp^1) then
// overwrites the live display / same-as-disp pending bank under rate, and the
// frames_done field is actually bank_vsync_count so liveness never detects a
// stuck swap.
//
// Protocol:
//   1. Never write free_bank == disp_bank (stale/residue).
//   2. Never re-write last_published until PLXD disp_bank has shown it
//      (display-ack), unless free is clearly the other bank.
//   3. On free_mask=0 timeout: DROP the frame — do not force-write disp^1.
//   4. frames_done advancing is not required for bank select (RTL may pack
//      vsync count); free/disp identity is authoritative.

#include "libmisterplex/input_mailbox.hpp"

#include <cstdint>

namespace misterplex {

struct DdrBankSelectState {
    int last_published_bank = 0;
    // True before the first publish and after PLXD disp_bank matches last publish.
    bool last_publish_seen_on_display = true;
    int consecutive_wait = 0;
};

enum class DdrBankSelectAction : uint8_t {
    Write = 0,
    Wait = 1,
    Drop = 2,
};

struct DdrBankSelectResult {
    DdrBankSelectAction action = DdrBankSelectAction::Wait;
    int bank = -1;
    const char* reason = "";
};

// max_wait_iters: caller increments once per poll (e.g. 1 ms). At limit → Drop.
inline DdrBankSelectResult selectDdrWriteBank(const BankReleaseStatus& brs,
                                              DdrBankSelectState& st,
                                              int max_wait_iters) {
    if (max_wait_iters < 1)
        max_wait_iters = 1;

    if (static_cast<int>(brs.disp_bank & 1u) == (st.last_published_bank & 1))
        st.last_publish_seen_on_display = true;

    auto wait_or_drop = [&](const char* why) -> DdrBankSelectResult {
        ++st.consecutive_wait;
        if (st.consecutive_wait >= max_wait_iters)
            return {DdrBankSelectAction::Drop, -1, why};
        return {DdrBankSelectAction::Wait, -1, why};
    };

    if (brs.swap_pending || !brs.anyFree())
        return wait_or_drop(brs.swap_pending ? "swap_pending" : "no_free");

    const int fb = brs.freeBank();
    if (fb < 0)
        return wait_or_drop("no_free");

    // Invariant from RTL: free is ~disp when !swap_pending. Equality ⇒ stale/residue.
    if (fb == static_cast<int>(brs.disp_bank & 1u))
        return wait_or_drop("free_eq_disp_stale");

    // After we publish bank B, stale free often still reports B (now display).
    // Refuse until PLXD has shown disp_bank == B at least once.
    if (fb == (st.last_published_bank & 1) && !st.last_publish_seen_on_display)
        return wait_or_drop("await_display_ack");

    st.consecutive_wait = 0;
    return {DdrBankSelectAction::Write, fb & 1, "plxd_free"};
}

inline void noteDdrBankPublished(DdrBankSelectState& st, int bank) {
    st.last_published_bank = bank & 1;
    st.last_publish_seen_on_display = false;
    st.consecutive_wait = 0;
}

// Legacy policy (RED): freeBank() immediately; on timeout force disp^1.
inline DdrBankSelectResult selectDdrWriteBankLegacyForce(const BankReleaseStatus& brs,
                                                         int /*last_published*/,
                                                         bool timed_out) {
    if (brs.anyFree() && !brs.swap_pending) {
        const int fb = brs.freeBank();
        if (fb >= 0)
            return {DdrBankSelectAction::Write, fb & 1, "legacy_free"};
    }
    if (timed_out)
        return {DdrBankSelectAction::Write, static_cast<int>(brs.disp_bank & 1u) ^ 1,
                "legacy_force_disp_xor"};
    return {DdrBankSelectAction::Wait, -1, "legacy_wait"};
}

} // namespace misterplex
