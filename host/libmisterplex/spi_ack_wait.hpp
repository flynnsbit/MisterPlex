// SPI ACK wait policy + idle poll budgets for misterplexd.
//
// History (Sweep 113, parent-measured on DE10-Nano):
//   misterplexd RUNNING idle: system idle 0.0%, native 720p decode 0.917x
//   misterplexd STOPPED:      system idle 49.4%, native 720p decode 1.31x
// The idle tax was not "physics" — it was host busy-work.
//
// Root cause in source (fpga_spi.cpp spiWord, pre-fix):
//   do { gpi = gpiRead(); if (++spins > 1000000) timeout; }
//   while (!(gpi & SSPI_STROBE));
// Two phases, no yield. On a missing/slow ACK each phase burned up to ~1e6
// uncached /dev/mem loads. getCoreStatus issues 9 spiWords → worst case ~0.9 s
// of one core per call. Pre-mailbox RBFs (e.g. G-VID1) take the SPI OSD path
// once per quiet period; at 1 Hz that alone can zero system idle%.
//
// Contract:
//   - After every kSpiAckBusySpinsBeforeYield failed polls, MUST yield/sleep.
//   - Hard wall kSpiAckMaxWallUs; timeout is failure, not infinite spin.
//   - Idle SPI OSD fallback quiet period is multi-second (SIGSTOP Main is not free).
// Unit tests pin the constants so a hot loop cannot reappear as a silent edit.

#pragma once

#include <chrono>
#include <cstdint>
#include <thread>

namespace misterplex {

// --- SPI ACK phase -----------------------------------------------------------
// Cap consecutive busy gpiRead polls before a voluntary yield. Keep this small:
// uncached FPGA register reads dominate; a few dozen is plenty for a healthy ACK
// which arrives in tens of nanoseconds on a live core.
inline constexpr int kSpiAckBusySpinsBeforeYield = 32;
// Hard wall-clock budget per ACK phase (set or clr). 2 ms is far above a good
// handshake and far below the old ~0.1–1 s 1e6-spin burn.
inline constexpr int kSpiAckMaxWallUs = 2000;
inline constexpr int kSpiAckYieldFloorUs = 1;
inline constexpr int kSpiAckYieldCapUs = 50;

// --- Idle / OSD / input poll periods (media_player threads) ------------------
// Mailbox path is a pair of uncached loads — cheap; keep snappy for OSD.
inline constexpr int kOsdMailboxQuietMs = 200;
// SPI fallback parks Main (SIGSTOP + /proc task scan). Rare when idle.
inline constexpr int kOsdSpiPlayingQuietMs = 500;
inline constexpr int kOsdSpiIdleQuietMs = 5000;
// Input mailbox is DDR-only; 100 ms is fine for remote/key edge detect.
inline constexpr int kInputMailboxQuietMs = 100;

// Static floors the negative test enforces (must stay >= these).
inline constexpr int kOsdSpiIdleQuietMsFloor = 2000;
inline constexpr int kSpiAckBusySpinsCeiling = 64;
inline constexpr int kSpiAckMaxWallUsCeiling = 5000;

struct SpiAckWaitStats {
    int busy_reads = 0;
    int yields = 0;
    int consecutive_busy_peak = 0;
    bool timed_out = false;
};

// Wait until pred() returns true. On success returns true.
// On wall-clock timeout returns false and sets st.timed_out.
// sleep_us(us) is invoked on every backoff; tests inject a counter.
//
// Invariant: consecutive failed pred() calls without a sleep_us invocation
// never exceeds kSpiAckBusySpinsBeforeYield (captured in consecutive_busy_peak).
template <typename Pred, typename SleepUsFn>
bool spiAckWait(Pred pred, SpiAckWaitStats& st, SleepUsFn sleep_us) {
    st = SpiAckWaitStats{};
    const auto t0 = std::chrono::steady_clock::now();
    int consecutive = 0;
    int yield_us = kSpiAckYieldFloorUs;

    for (;;) {
        if (pred())
            return true;

        ++st.busy_reads;
        ++consecutive;
        if (consecutive > st.consecutive_busy_peak)
            st.consecutive_busy_peak = consecutive;

        const auto elapsed = std::chrono::duration_cast<std::chrono::microseconds>(
                                 std::chrono::steady_clock::now() - t0)
                                 .count();
        if (elapsed >= kSpiAckMaxWallUs) {
            st.timed_out = true;
            return false;
        }

        if (consecutive >= kSpiAckBusySpinsBeforeYield) {
            sleep_us(yield_us);
            ++st.yields;
            consecutive = 0;
            // Progressive backoff: 1,2,4,... us up to cap. Keeps total wall short
            // while giving the FPGA / bus a real gap under load.
            if (yield_us < kSpiAckYieldCapUs) {
                const int next = yield_us * 2;
                yield_us = next > kSpiAckYieldCapUs ? kSpiAckYieldCapUs : next;
            }
        }
    }
}

// Production sleep: yield for 0, else nanosleep via this_thread.
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

// Quiet period for the OSD poller given path + play state.
inline int osdPollQuietMs(bool via_mailbox, bool playing) {
    if (via_mailbox)
        return kOsdMailboxQuietMs;
    return playing ? kOsdSpiPlayingQuietMs : kOsdSpiIdleQuietMs;
}

} // namespace misterplex
