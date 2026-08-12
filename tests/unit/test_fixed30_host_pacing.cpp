// Current-host presentation audit against the fixed true-480 native beam.
//
// This intentionally uses production frameContentMs(), audibleClockMs(), and
// avDecide(). The companion Python model covers ideal exact-rational cadence;
// this test exposes what the current integer-millisecond host release schedule
// can actually queue before a 20 MHz/(2*672*496) VSync.

#include "libmisterplex/av_clock.hpp"
#include "libmisterplex/mraudio_status.hpp"

#include <cstdint>
#include <cstdio>

static int fails = 0;
#define CHECK(cond)                                                                              \
    do {                                                                                         \
        if (!(cond)) {                                                                           \
            std::fprintf(stderr, "FAIL %s:%d: %s\n", __FILE__, __LINE__, #cond);                 \
            ++fails;                                                                             \
        }                                                                                        \
    } while (0)

namespace {

constexpr int64_t kSystemClockHz = 20'000'000;
constexpr int64_t kPixelClockDiv = 2;
constexpr int64_t kHTotal = 672;
constexpr int64_t kVTotal = 496;
constexpr int64_t kBeamCycles = kPixelClockDiv * kHTotal * kVTotal;
constexpr int64_t kCyclesPerMs = kSystemClockHz / 1000;
constexpr int64_t kPresentLeadMs = 40;
constexpr int64_t kDropMs = 80;
constexpr int64_t kQueueBytes = misterplex::kMrAudioBytesPerSec / 10;

struct RateCase {
    int num;
    int den;
    int64_t host_cycle_frames;
    int64_t beam_ticks;
    int64_t same_tick_frames;
    int64_t two_tick_gaps;
    int64_t same_tick_clusters;
    const char* label;
};

// 30000/1001 needs five ideal beam cycles before frameContentMs() returns to
// the same sub-millisecond phase. Counts use beam phase zero; phase probes below
// prove the near-30 collision class is not a single lucky/unlucky alignment.
constexpr RateCase kRates[] = {
    {24000, 1001, 71424, 89375, 0, 17951, 0, "24000/1001"},
    {24, 1, 62496, 78125, 0, 15629, 0, "24/1"},
    {25, 1, 2604, 3125, 0, 521, 0, "25/1"},
    {30000, 1001, 89280, 89375, 563, 658, 95, "30000/1001"},
    {30, 1, 15624, 15625, 103, 104, 1, "30/1"},
};

int64_t ceilDiv(int64_t value, int64_t divisor) {
    return value / divisor + ((value % divisor) != 0);
}

int64_t firstBeamTick(int64_t releaseMs, int64_t beamPhaseCycles = 0) {
    return ceilDiv(releaseMs * kCyclesPerMs - beamPhaseCycles, kBeamCycles);
}

struct StepCounts {
    int64_t same = 0;
    int64_t one = 0;
    int64_t two = 0;
    int64_t other = 0;
    int64_t same_clusters = 0;
    int64_t tick_span = 0;
};

StepCounts countHostSteps(const RateCase& rate, int64_t beamPhaseCycles) {
    constexpr int64_t kBaseFrame = 100;
    StepCounts out{};
    int64_t firstTick = 0;
    int64_t previousTick = 0;
    int64_t previousSameOffset = -10;
    for (int64_t offset = 0; offset <= rate.host_cycle_frames; ++offset) {
        const int64_t frame = kBaseFrame + offset;
        const int64_t frameMs = misterplex::frameContentMs(frame, rate.num, rate.den);
        const int64_t tick =
            firstBeamTick(frameMs - kPresentLeadMs, beamPhaseCycles);
        if (offset == 0) {
            firstTick = tick;
        } else {
            const int64_t step = tick - previousTick;
            if (step == 0) {
                ++out.same;
                if (offset - previousSameOffset > 5)
                    ++out.same_clusters;
                previousSameOffset = offset;
            } else if (step == 1)
                ++out.one;
            else if (step == 2)
                ++out.two;
            else
                ++out.other;
        }
        previousTick = tick;
    }
    out.tick_span = previousTick - firstTick;
    return out;
}

} // namespace

int main() {
    using namespace misterplex;

    CHECK(kSystemClockHz / kPixelClockDiv == 10'000'000);
    CHECK(kBeamCycles == 666'624);
    CHECK(kSystemClockHz * 2604 == 78'125 * kBeamCycles);

    for (const auto& rate : kRates) {
        constexpr int64_t kBaseFrame = 100;
        bool phaseRose = false;
        bool phaseFell = false;
        bool phaseBounded = true;
        bool steadyPresent = true;
        int64_t previousError = 0;
        bool havePreviousError = false;

        for (int64_t offset = 0; offset <= rate.host_cycle_frames; ++offset) {
            const int64_t frame = kBaseFrame + offset;
            const int64_t frameMs = frameContentMs(frame, rate.num, rate.den);
            const int64_t releaseMs = frameMs - kPresentLeadMs;

            // Model a stable 100 ms MrAudio queue. Subtracting that exact queue
            // recovers the audible release time, so normal cadence is Present,
            // not an avDecide recovery drop.
            const int64_t writtenBytes =
                releaseMs * (kMrAudioBytesPerSec / 1000) + kQueueBytes;
            const int64_t audibleMs = audibleClockMs(writtenBytes, kQueueBytes);
            steadyPresent =
                steadyPresent && audibleMs == releaseMs &&
                avDecide(avDriftMs(audibleMs, frameMs), kPresentLeadMs, kDropMs, 0) ==
                    AvAction::Present &&
                avDecide(avDriftMs(audibleMs - 1, frameMs), kPresentLeadMs, kDropMs, 0) ==
                    AvAction::Hold;

            const int64_t tick = firstBeamTick(releaseMs);
            // Error numerator relative to exact source PTS, in
            // (20 MHz cycles * source-rate numerator) units.
            const int64_t error =
                tick * kBeamCycles * rate.num - frame * kSystemClockHz * rate.den;
            const int64_t lower =
                -(kPresentLeadMs + 1) * kCyclesPerMs * static_cast<int64_t>(rate.num);
            const int64_t upper =
                (kBeamCycles - kPresentLeadMs * kCyclesPerMs) *
                static_cast<int64_t>(rate.num);
            phaseBounded = phaseBounded && error > lower && error < upper;
            if (havePreviousError) {
                phaseRose = phaseRose || error > previousError;
                phaseFell = phaseFell || error < previousError;
            }
            previousError = error;
            havePreviousError = true;
        }

        const StepCounts phase0 = countHostSteps(rate, 0);
        CHECK(phase0.other == 0);
        CHECK(phase0.tick_span == rate.beam_ticks);
        CHECK(phase0.same == rate.same_tick_frames);
        CHECK(phase0.two == rate.two_tick_gaps);
        CHECK(phase0.same_clusters == rate.same_tick_clusters);
        CHECK(phase0.two - phase0.same == rate.beam_ticks - rate.host_cycle_frames);
        CHECK(steadyPresent);
        CHECK(phaseBounded);
        CHECK(phaseRose && phaseFell);

        const int64_t phaseProbes[] = {1, 1000, 100000, 300000, kBeamCycles - 1};
        for (const int64_t phase : phaseProbes) {
            const StepCounts probe = countHostSteps(rate, phase);
            CHECK(probe.other == 0);
            if (rate.same_tick_frames > 0) {
                CHECK(probe.same > 0);
                CHECK(probe.two > probe.same);
            } else {
                CHECK(probe.same == 0);
            }
        }

        // A sustained >80 ms decode/transport stall is the only modeled host
        // drop class. The production cap must keep it to one consecutive frame.
        int dropRun = 0;
        int maxDropRun = 0;
        for (int i = 0; i < 20; ++i) {
            const AvAction action = avDecide(200, kPresentLeadMs, kDropMs, dropRun);
            if (action == AvAction::Drop) {
                ++dropRun;
                if (dropRun > maxDropRun)
                    maxDropRun = dropRun;
            } else {
                dropRun = 0;
            }
        }
        CHECK(maxDropRun == 1);

        std::printf(
            "%s: host_frames=%lld beam_ticks=%lld same_tick=%lld "
            "two_tick=%lld net_duplicates=%lld steady_host_drops=0\n",
            rate.label, static_cast<long long>(rate.host_cycle_frames),
            static_cast<long long>(rate.beam_ticks),
            static_cast<long long>(phase0.same),
            static_cast<long long>(phase0.two),
            static_cast<long long>(phase0.two - phase0.same));
    }

    if (fails) {
        std::fprintf(stderr, "test_fixed30_host_pacing: %d failures\n", fails);
        return 1;
    }
    std::printf("PASS test_fixed30_host_pacing\n");
    return 0;
}
