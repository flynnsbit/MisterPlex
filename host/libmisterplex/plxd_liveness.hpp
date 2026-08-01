#pragma once
// PLXD mailbox liveness — swap progress vs counter motion (c5382bee safety).
//
// SAFETY DEFECT (parent-verified on device RBF c5382bee):
//   PLXD[63:48] is labelled frames_done (swap count) but silicon packs
//   bank_vsync_count — increments every vsync whether or not a bank swap
//   occurs. ARM degeneracy defence that treats frames_done advance as
//   "mailbox live / swaps happening" is DEFEATED: a frozen picture with
//   stuck swaps still advances the counter, so [STALE] never fires.
//
// Tip RTL (ddr_frame_store.sv) packs frames_done_d2 (real swaps) and documents
// the freeze class. Until that RBF is fitted, ARM must not trust fd alone.
//
// Derivation (publish name with derivation in the same breath):
//   frames_done_counter_moving  ← Δ PLXD[63:48] ≠ 0
//        proves: some free-running field is written (vsync OR swap)
//        does NOT prove: bank swaps / display progress
//   swap_progress_proven        ← disp_bank changed, or display-ack
//                                 (disp_bank == last_published)
//   swap_pending_stuck          ← swap_pending held across many counter ticks
//   display_ack_stuck           ← publish not seen on disp_bank across ticks
//   residue_counter_stale       ← counter never advances (true cold residue)
//
// Interim on c5382bee: use frames_done ONLY as a timebase (vsync ticks) for
// stuck detectors; require disp_bank / swap_pending for swap health.

#include <cstdint>

namespace misterplex {

enum class PlxdCounterSemantics : uint8_t {
    Unknown = 0,
    SwapCounter = 1,
    VsyncPackedSuspect = 2,
    Other = 3,
};

struct PlxdLivenessState {
    bool have_fd = false;
    uint16_t last_fd = 0;
    bool have_disp = false;
    uint8_t last_disp = 0;

    int pair_n = 0;
    int delta0 = 0;
    int delta1 = 0;
    int delta_ge2 = 0;

    bool counter_moving_proven = false;
    bool swap_progress_proven = false;

    int no_advance_streak = 0;
    int swap_pend_true_ticks = 0;

    bool await_display_ack = false;
    uint8_t await_bank = 0;
    int await_ack_ticks = 0;

    PlxdCounterSemantics semantics = PlxdCounterSemantics::Unknown;
};

struct PlxdLivenessObservation {
    bool counter_advanced = false;
    bool disp_changed = false;
    bool residue_counter_stale = false;
    bool swap_pending_stuck = false;
    bool display_ack_stuck = false;
    bool swap_live = false;
    PlxdCounterSemantics semantics = PlxdCounterSemantics::Unknown;
    const char* semantics_label = "UNKNOWN";
};

inline constexpr int kPlxdResidueNoAdvanceLimit = 10;
inline constexpr int kPlxdSwapPendStuckTicks = 8;
inline constexpr int kPlxdDisplayAckStuckTicks = 45;
inline constexpr int kPlxdSemanticsMinPairs = 30;

inline int plxdFdDelta(uint16_t prev, uint16_t cur) {
    return static_cast<int>((cur - prev) & 0xFFFFu);
}

inline const char* plxdSemanticsLabel(PlxdCounterSemantics s) {
    switch (s) {
    case PlxdCounterSemantics::SwapCounter:
        return "SWAP_COUNTER";
    case PlxdCounterSemantics::VsyncPackedSuspect:
        return "VSYNC_PACKED_SUSPECT";
    case PlxdCounterSemantics::Other:
        return "OTHER";
    default:
        return "UNKNOWN";
    }
}

inline void plxdLivenessClassify(PlxdLivenessState& st) {
    if (st.pair_n < kPlxdSemanticsMinPairs) {
        st.semantics = PlxdCounterSemantics::Unknown;
        return;
    }
    const double p1 = double(st.delta1) / double(st.pair_n);
    const double pge2 = double(st.delta_ge2) / double(st.pair_n);
    if (p1 >= 0.5)
        st.semantics = PlxdCounterSemantics::SwapCounter;
    else if (pge2 >= 0.5)
        st.semantics = PlxdCounterSemantics::VsyncPackedSuspect;
    else
        st.semantics = PlxdCounterSemantics::Other;
}

inline PlxdLivenessObservation plxdLivenessObserve(PlxdLivenessState& st, uint16_t frames_done,
                                                   uint8_t disp_bank, bool swap_pending) {
    PlxdLivenessObservation o{};
    disp_bank = static_cast<uint8_t>(disp_bank & 1u);

    if (st.have_fd) {
        const int d = plxdFdDelta(st.last_fd, frames_done);
        ++st.pair_n;
        if (d == 0)
            ++st.delta0;
        else if (d == 1)
            ++st.delta1;
        else
            ++st.delta_ge2;

        if (d != 0) {
            o.counter_advanced = true;
            st.counter_moving_proven = true;
            st.no_advance_streak = 0;
            st.last_fd = frames_done;

            if (swap_pending)
                ++st.swap_pend_true_ticks;
            else
                st.swap_pend_true_ticks = 0;

            if (st.await_display_ack)
                ++st.await_ack_ticks;
        } else {
            ++st.no_advance_streak;
        }
        plxdLivenessClassify(st);
    } else {
        st.have_fd = true;
        st.last_fd = frames_done;
        st.no_advance_streak = 0;
    }

    if (st.have_disp) {
        if (disp_bank != st.last_disp) {
            o.disp_changed = true;
            st.swap_progress_proven = true;
            st.last_disp = disp_bank;
        }
    } else {
        st.have_disp = true;
        st.last_disp = disp_bank;
    }

    if (st.await_display_ack && disp_bank == st.await_bank) {
        st.await_display_ack = false;
        st.await_ack_ticks = 0;
        st.swap_progress_proven = true;
    }

    o.semantics = st.semantics;
    o.semantics_label = plxdSemanticsLabel(st.semantics);

    if (st.no_advance_streak >= kPlxdResidueNoAdvanceLimit)
        o.residue_counter_stale = true;

    if (st.swap_pend_true_ticks >= kPlxdSwapPendStuckTicks)
        o.swap_pending_stuck = true;

    if (st.await_display_ack && st.await_ack_ticks >= kPlxdDisplayAckStuckTicks)
        o.display_ack_stuck = true;

    o.swap_live = st.swap_progress_proven && !o.swap_pending_stuck && !o.display_ack_stuck &&
                  !o.residue_counter_stale;

    return o;
}

inline void plxdLivenessNotePublished(PlxdLivenessState& st, int bank) {
    st.await_display_ack = true;
    st.await_bank = static_cast<uint8_t>(bank & 1);
    st.await_ack_ticks = 0;
}

inline void plxdLivenessClearStuck(PlxdLivenessState& st) {
    st.swap_pend_true_ticks = 0;
    st.await_ack_ticks = 0;
    st.no_advance_streak = 0;
}

} // namespace misterplex
