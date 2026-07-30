// Present-stall detector: loud when F1 publish is attempted and keeps failing.
// Deliberate skips (e.g. STREAM recon owns F1) must NOT count as failures.
#pragma once

namespace misterplex {

// Threshold ~3s @24fps. Exposed for tests.
inline constexpr int kPresentStallThreshold = 72;

struct PresentStallTracker {
    int consecutive_fail = 0;
    bool stall_logged = false;

    // F1 write was attempted (DDR publish or hybrid compose that decided to hold)
    // and did not land a new frame on the present bank.
    void onAttemptFailed() { ++consecutive_fail; }

    // Successful F1 publish — clear fail run and re-arm so a later stall can warn again.
    void onAttemptOk() {
        consecutive_fail = 0;
        stall_logged = false;
    }

    // Deliberate non-attempt (reconOwnsF1 hold, PRESENT path not wanted). No-op.
    void onDeliberateSkip() {}

    // True once per stall episode when threshold crossed; false while already logged
    // until onAttemptOk re-arms.
    bool shouldLogStall() {
        if (!stall_logged && consecutive_fail >= kPresentStallThreshold) {
            stall_logged = true;
            return true;
        }
        return false;
    }
};

// Parent-defect twin helpers (for mutation tests only).
// FAULT_COUNT_SKIP: counts deliberate skips as failures (f1128b0 bug).
// FAULT_NO_REARM: never clears stall_logged on recovery (f1128b0 bug).
struct PresentStallTrackerFaultyCountSkip {
    int consecutive_fail = 0;
    bool stall_logged = false;
    void onAttemptFailed() { ++consecutive_fail; }
    void onAttemptOk() {
        consecutive_fail = 0;
        stall_logged = false;
    }
    void onDeliberateSkip() { ++consecutive_fail; } // BUG
    bool shouldLogStall() {
        if (!stall_logged && consecutive_fail >= kPresentStallThreshold) {
            stall_logged = true;
            return true;
        }
        return false;
    }
};

struct PresentStallTrackerFaultyNoRearm {
    int consecutive_fail = 0;
    bool stall_logged = false;
    void onAttemptFailed() { ++consecutive_fail; }
    void onAttemptOk() {
        consecutive_fail = 0;
        // BUG: stall_logged left true — later stalls silent
    }
    void onDeliberateSkip() {}
    bool shouldLogStall() {
        if (!stall_logged && consecutive_fail >= kPresentStallThreshold) {
            stall_logged = true;
            return true;
        }
        return false;
    }
};

} // namespace misterplex
