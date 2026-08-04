// Pins parent-measured 720p24 CPU-copy budget. RED if someone "fits" serial path
// by editing constants without new hardware evidence.
#include "libmisterplex/p720_e2e_budget.hpp"

#include <cmath>
#include <cstdio>
#include <cstdlib>

#define CHECK(cond, msg)                                                                           \
    do {                                                                                           \
        if (!(cond)) {                                                                             \
            std::fprintf(stderr, "FAIL %s:%d: %s\n", __FILE__, __LINE__, msg);                     \
            ++fails;                                                                               \
        }                                                                                          \
    } while (0)

int main() {
    using namespace misterplex::p720_budget;
    int fails = 0;

    CHECK(kFrameBytes720pI420 == 1382400u, "720p I420 byte count");
    CHECK(std::fabs(kDeadline24Ms - 41.666666) < 0.001, "24fps deadline ~41.667");

    // Archive Sweep 9 pins must remain the named measured copy cost.
    CHECK(std::fabs(kCpuCopyMsPerFrame - 14.978) < 1e-9, "Sweep9 copy ms pin");
    CHECK(std::fabs(kDecodeOnlyMsPerFrameSweep116 - 32.705) < 1e-9, "Sweep116 decode ms pin");

    const double serial =
        serialDecodePlusCopyMs(kDecodeOnlyMsPerFrameSweep116, kCpuCopyMsPerFrame);
    std::printf("measured_serial_ms=%.3f deadline_ms=%.3f headroom_ms=%.3f\n", serial,
                kDeadline24Ms, headroomAfterDecodeMs(kDecodeOnlyMsPerFrameSweep116));
    std::printf("copy_ms=%.3f decode_ms=%.3f\n", kCpuCopyMsPerFrame,
                kDecodeOnlyMsPerFrameSweep116);

    // Primary: serial CPU path does NOT meet 24 fps with measured pins.
    CHECK(!kSerialSweep116Meets24, "serial Sweep116+copy must NOT meet 24fps");
    CHECK(serial > kDeadline24Ms, "serial sum exceeds deadline");
    CHECK(kCopyExceedsSweep116Headroom, "copy exceeds decode-only headroom");

    // Headroom arithmetic: 41.667 - 32.705 = 8.962 < 14.978
    const double head = headroomAfterDecodeMs(kDecodeOnlyMsPerFrameSweep116);
    CHECK(head < kCpuCopyMsPerFrame, "8.962 headroom < 14.978 copy");
    CHECK(std::fabs(head - 8.962) < 0.01, "headroom ~8.962");

    // Negative (naive wrong impl would pass if only decode checked):
    // decode-only alone DOES meet 24 — so a test that only checked decode
    // would be green while E2E is red. We require the copy term.
    CHECK(kDecodeOnlyMsPerFrameSweep116 < kDeadline24Ms, "decode-only fits (trap)");
    CHECK(!serialCpuPathMeets24(kDecodeOnlyMsPerFrameSweep116, kCpuCopyMsPerFrame),
          "decode-only fit must not imply serial fit");

    // Counterfactual: if copy were free, serial would meet — proves the copy
    // pin is load-bearing (not a tautology that always fails).
    CHECK(serialCpuPathMeets24(kDecodeOnlyMsPerFrameSweep116, 0.0),
          "counterfactual zero-copy would meet 24");
    CHECK(serialCpuPathMeets24(kDecodeOnlyMsPerFrameSweep116, 8.0),
          "counterfactual copy<=headroom would meet 24");
    CHECK(!serialCpuPathMeets24(kDecodeOnlyMsPerFrameSweep116, 9.0),
          "copy just above headroom fails");

    // Legacy 35.94 decode is even worse serially.
    CHECK(!serialCpuPathMeets24(kDecodeOnlyMsPerFrameLegacy, kCpuCopyMsPerFrame),
          "legacy decode+copy serial fail");

    if (fails) {
        std::printf("test_p720_e2e_budget: %d FAIL(s)\n", fails);
        return 1;
    }
    std::printf("test_p720_e2e_budget: OK serial=%.3f>deadline (CPU copy structural)\n", serial);
    return 0;
}
