#pragma once
// PLXD mailbox liveness for sendDdrFrame degeneracy defence.
//
// Derivation (publish name + derivation together — fleet standing rule):
//   "frames_done" field in PLXD[63:48]:
//     - tip RTL (ddr_frame_store.sv): packs frames_done_d2 = swap counter
//     - deployed RBF c5382bee: packs bank_vsync_count (advances every vsync)
//       HISTORICAL FAULT still LIVE on silicon — not a past-only comment.
//
// Using frames_done *advance alone* as liveness means on c5382bee a frozen
// picture (no bank swap) still looks "live", so [STALE] fallback never fires
// (playback-freeze class). Source comment in ddr_frame_store.sv pack site.
//
// Liveness progress = change in bank-identity signature:
//   free_bank_mask[1:0] | disp_bank<<2 | swap_pending<<3
// Those bits are a pure function of swap/disp state on both tip and c5382bee
// packs — they do not free-run on vsync. frames_done is logged only.
//
// Residue / wrong-address magic: identity never moves → stale limit → fallback.

#include <cstdint>

namespace misterplex {

struct PlxdLivenessSample {
    std::uint16_t frames_done = 0;
    std::uint8_t free_bank_mask = 0;
    std::uint8_t disp_bank = 0;
    bool swap_pending = false;
};

// Bank-identity signature (not frames_done).
inline std::uint8_t plxdBankIdentitySig(const PlxdLivenessSample& s) {
    return static_cast<std::uint8_t>((s.free_bank_mask & 0x3u) |
                                     ((s.disp_bank & 0x1u) << 2) |
                                     ((s.swap_pending ? 1u : 0u) << 3));
}

struct PlxdLivenessState {
    std::uint16_t last_frames_done = 0;
    std::uint8_t last_sig = 0;
    bool have_sample = false;
    int stale_count = 0;
    bool proven = false;
    // Diagnostics (not used for the stale decision):
    bool last_tick_fd_advanced = false;
    bool last_tick_sig_advanced = false;
};

// One observation at sendDdrFrame entry (not every 1ms wait poll).
// Returns true if this tick counts as mailbox progress (resets stale).
inline bool plxdLivenessTick(PlxdLivenessState& st, const PlxdLivenessSample& s) {
    const std::uint8_t sig = plxdBankIdentitySig(s);
    const bool had = st.have_sample;
    const bool fd_adv = had && (s.frames_done != st.last_frames_done);
    const bool sig_adv = had && (sig != st.last_sig);

    st.last_frames_done = s.frames_done;
    st.last_sig = sig;
    st.have_sample = true;
    st.last_tick_fd_advanced = fd_adv;
    st.last_tick_sig_advanced = sig_adv;

    if (!had) {
        // Baseline only — do not prove or stale on first sight.
        return false;
    }
    if (sig_adv) {
        st.proven = true;
        st.stale_count = 0;
        return true;
    }
    // frames_done-only advance (c5382bee vsync pack while banks frozen): NOT progress.
    ++st.stale_count;
    return false;
}

// Wait-loop observe: may reset stale on identity move; never increments stale
// (poll is sub-frame; counting here would false-STALE during swap_pending).
inline void plxdLivenessObserveWait(PlxdLivenessState& st, const PlxdLivenessSample& s) {
    const std::uint8_t sig = plxdBankIdentitySig(s);
    const bool had = st.have_sample;
    const bool sig_adv = had && (sig != st.last_sig);
    st.last_frames_done = s.frames_done;
    st.last_sig = sig;
    st.have_sample = true;
    if (sig_adv) {
        st.proven = true;
        st.stale_count = 0;
    }
}

inline bool plxdLivenessShouldFallback(const PlxdLivenessState& st, int limit_before_proven,
                                       int limit_after_proven) {
    const int lim = st.proven ? limit_after_proven : limit_before_proven;
    return st.stale_count >= lim;
}

} // namespace misterplex
