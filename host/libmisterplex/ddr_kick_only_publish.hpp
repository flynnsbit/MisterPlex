#pragma once
// Zero-copy / fabric-DMA publish path: doorbell ONLY after payload is already
// resident in the free bank. Retires the 14.978 ms ARM memcpy (T_copy_arm) when
// a producer (PL330, fabric writeback, or prior fill) owns the bytes.
//
// Contract mirrors plxd_bank_credit.sv / PLXD ABI:
//   claim free bank → fill (external) → kick doorbell → await display ack
//
// NEGATIVES a naive "always kick" path must fail:
//   - kick while free_mask==0 / swap_pending
//   - kick bank == disp_bank
//   - kick without prior claim of that bank
//   - kick bank that was never marked filled

#include "libmisterplex/ddr_bank_release_select.hpp"
#include "libmisterplex/input_mailbox.hpp"

#include <cstdint>

namespace misterplex {

struct KickOnlyPublishState {
    DdrBankSelectState bank_sel{};
    // Bit i set ⇒ host/DMA has finished writing bank i and may doorbell it.
    uint8_t filled_mask = 0;
    // Bit i set ⇒ bank i was claimed via selectDdrWriteBank Write and not yet kicked.
    uint8_t claimed_mask = 0;
};

enum class KickOnlyAction : uint8_t {
    Wait = 0,
    ClaimOk = 1,   // bank reserved; caller must fill then markFilled
    KickOk = 2,    // safe to ring doorbell for .bank
    Drop = 3,
};

struct KickOnlyResult {
    KickOnlyAction action = KickOnlyAction::Wait;
    int bank = -1;
    const char* reason = "";
};

// Reserve a free bank for an external fill (no memcpy). Uses selectDdrWriteBank.
inline KickOnlyResult claimDdrBankForFill(const BankReleaseStatus& brs,
                                          KickOnlyPublishState& st,
                                          int max_wait_iters = 50) {
    const DdrBankSelectResult sel = selectDdrWriteBank(brs, st.bank_sel, max_wait_iters);
    if (sel.action == DdrBankSelectAction::Wait)
        return {KickOnlyAction::Wait, -1, sel.reason};
    if (sel.action == DdrBankSelectAction::Drop)
        return {KickOnlyAction::Drop, -1, sel.reason};
    // Write
    const int b = sel.bank & 1;
    st.claimed_mask = static_cast<uint8_t>(st.claimed_mask | (1u << b));
    st.filled_mask = static_cast<uint8_t>(st.filled_mask & ~(1u << b));
    return {KickOnlyAction::ClaimOk, b, "claimed"};
}

// Caller finished writing bank (CPU, DMA, or fabric). Does not doorbell.
inline bool markDdrBankFilled(KickOnlyPublishState& st, int bank) {
    const int b = bank & 1;
    if ((st.claimed_mask & (1u << b)) == 0)
        return false;
    st.filled_mask = static_cast<uint8_t>(st.filled_mask | (1u << b));
    return true;
}

// Ring doorbell only — payload must already be in bank. No memcpy.
inline KickOnlyResult kickDdrBankOnly(const BankReleaseStatus& brs,
                                      KickOnlyPublishState& st,
                                      int bank) {
    const int b = bank & 1;

    if (brs.swap_pending || !brs.anyFree())
        return {KickOnlyAction::Drop, -1,
                brs.swap_pending ? "kick_swap_pending" : "kick_no_free"};

    if (b == static_cast<int>(brs.disp_bank & 1u))
        return {KickOnlyAction::Drop, -1, "kick_eq_disp"};

    if ((st.claimed_mask & (1u << b)) == 0)
        return {KickOnlyAction::Drop, -1, "kick_unclaimed"};

    if ((st.filled_mask & (1u << b)) == 0)
        return {KickOnlyAction::Drop, -1, "kick_unfilled"};

    // Match free-mask ownership: free bit for b must still be set in PLXD.
    if ((brs.free_bank_mask & (1u << b)) == 0)
        return {KickOnlyAction::Drop, -1, "kick_free_bit_clear"};

    // Consume claim/fill; record publish for display-ack gate.
    st.claimed_mask = static_cast<uint8_t>(st.claimed_mask & ~(1u << b));
    st.filled_mask = static_cast<uint8_t>(st.filled_mask & ~(1u << b));
    noteDdrBankPublished(st.bank_sel, b);
    return {KickOnlyAction::KickOk, b, "kick_ok"};
}

} // namespace misterplex
