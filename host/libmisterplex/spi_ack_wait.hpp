// SPI ACK wait policy + idle poll budgets for misterplexd.
//
// History
// -------
// Sweep 113: bare 1e6-spin spiWord (no yield) burned ~1 core when ACK missing.
// Sweep 115: a 2 ms *wall* cap on the same wait aborted legitimate SPI status
//            transactions during idle DDR paint → colour-band garbage on HDMI
//            (parent capture). Product broken; unit suite green. REVERTED on
//            device to 7cd10b4d.
//
// Contract (this file)
// --------------------
// 1. MUST yield after kSpiAckBusySpinsBeforeYield failed polls (CPU).
// 2. MUST NOT abort earlier than the legacy poll budget (correctness).
//    Legacy abort was `if (++spins > 1000000) timeout` — a POLL COUNT, not a
//    wall-clock. We keep kSpiAckMaxPolls = 1_000_000. A short wall timeout is
//    FORBIDDEN: it trades frame integrity for CPU and is the Sweep 115 defect.
// 3. Worst-case *legitimate* ACK latency is UNKNOWN from in-repo source/datasheet
//    (FPGA strobe is combinational on a healthy user-mode core; under
//    MainSafeWindow SIGSTOP + bus contention no bound is proven here). Therefore
//    we never pick a "better" wall timeout by intuition.
// 4. Idle SPI OSD fallback quiet period stays multi-second.
//
// Call sites of spiWord (fpga_spi.cpp): writeStatusWordRaw, readStatusRaw,
// getConfigString, enableIo path helpers, kickDdrSpi (via write/read status).
// Idle logo paint → sendYuv420pFrameDdr → sendDdrFrame → kickDdrSpi/doorbell
// verify uses those paths; aborting mid-status leaves a partial kick.

#pragma once

#include <chrono>
#include <cstdint>
#include <thread>

namespace misterplex {

// --- SPI ACK phase -----------------------------------------------------------
// Busy polls before a voluntary yield. Small: healthy ACK is near-immediate.
inline constexpr int kSpiAckBusySpinsBeforeYield = 32;
// Legacy-equivalent abort: total failed pred() polls, matching pre-fix
// `spins > 1000000`. This is the ONLY abort criterion.
inline constexpr int kSpiAckMaxPolls = 1000000;
// Yield backoff while waiting (CPU only; does not shrink poll budget).
inline constexpr int kSpiAckYieldFloorUs = 1;
inline constexpr int kSpiAckYieldCapUs = 200;

// --- Idle / OSD / input poll periods (media_player threads) ------------------
inline constexpr int kOsdMailboxQuietMs = 200;
inline constexpr int kOsdSpiPlayingQuietMs = 500;
inline constexpr int kOsdSpiIdleQuietMs = 5000;
inline constexpr int kInputMailboxQuietMs = 100;

// Floors / ceilings the negative tests enforce.
inline constexpr int kOsdSpiIdleQuietMsFloor = 2000;
inline constexpr int kSpiAckBusySpinsCeiling = 64;
// A wall-only abort shorter than this many microseconds is the Sweep 115 bug.
// We do not use wall abort at all; tests assert kSpiAckUseWallTimeout == false.
inline constexpr bool kSpiAckUseWallTimeout = false;
inline constexpr int kSpiAckForbiddenShortWallUs = 5000; // document the bad band

struct SpiAckWaitStats {
    int busy_reads = 0;
    int yields = 0;
    int consecutive_busy_peak = 0;
    bool timed_out = false;
};

// Wait until pred() is true. Returns false only after kSpiAckMaxPolls failed
// polls (legacy cardinality). Always yields per kSpiAckBusySpinsBeforeYield.
template <typename Pred, typename SleepUsFn>
bool spiAckWait(Pred pred, SpiAckWaitStats& st, SleepUsFn sleep_us) {
    st = SpiAckWaitStats{};
    int consecutive = 0;
    int yield_us = kSpiAckYieldFloorUs;

    for (;;) {
        if (pred())
            return true;

        ++st.busy_reads;
        ++consecutive;
        if (consecutive > st.consecutive_busy_peak)
            st.consecutive_busy_peak = consecutive;

        // Abort only on legacy poll budget — never on a short wall clock.
        if (st.busy_reads >= kSpiAckMaxPolls) {
            st.timed_out = true;
            return false;
        }

        if (consecutive >= kSpiAckBusySpinsBeforeYield) {
            sleep_us(yield_us);
            ++st.yields;
            consecutive = 0;
            if (yield_us < kSpiAckYieldCapUs) {
                const int next = yield_us * 2;
                yield_us = next > kSpiAckYieldCapUs ? kSpiAckYieldCapUs : next;
            }
        }
    }
}

inline void spiAckDefaultSleepUs(int us) {
    if (us <= 0) {
        std::this_thread::yield();
        return;
    }
    std::this_thread::sleep_for(std::chrono::microseconds(us));
}

template <typename Pred>
bool spiAckWait(Pred pred, SpiAckWaitStats& st) {
    return spiAckWait(pred, st, spiAckDefaultSleepUs);
}

inline int osdPollQuietMs(bool via_mailbox, bool playing) {
    if (via_mailbox)
        return kOsdMailboxQuietMs;
    return playing ? kOsdSpiPlayingQuietMs : kOsdSpiIdleQuietMs;
}

// --- Multi-word SPI transaction completeness (model + production contract) ---
// A status write is N spiWord phases. If phase k fails, phases k+1..N must not
// be reported as success. Silent partial success is the Sweep 115 defect class
// for the frame/status path (kickDdrSpi used to `return true` unconditionally).
struct SpiTxnPhaseResult {
    bool ok = false;
    const char* err = nullptr;
};

// Simulated multi-word commit: calls issue(i) for i in [0, words). Stops on
// first failure and returns false with failed_at set. Success only if ALL
// words issued OK.
template <typename IssueFn>
bool spiTxnCommitAll(int words, IssueFn issue, int& failed_at, const char*& err) {
    failed_at = -1;
    err = nullptr;
    if (words <= 0)
        return true;
    for (int i = 0; i < words; ++i) {
        SpiTxnPhaseResult r = issue(i);
        if (!r.ok) {
            failed_at = i;
            err = r.err ? r.err : "spi phase failed";
            return false;
        }
    }
    return true;
}

// How many spiWord calls a UIO_SET_STATUS2 status write performs (cmd + 8 words).
inline constexpr int kStatusWriteSpiWords = 1 + 8; // 0x1e + 16 bytes as 8×16-bit

} // namespace misterplex
