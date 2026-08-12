// Deterministic product-path model for true-480 pipelineDdr.
//
// The real audio pipeline lets FFmpeg/video burst into a two-slot host ring.
// The product guarantee therefore needs BOTH:
//   1. exact source-rate eligibility from the audible/wall clock, and
//   2. PLXD release before writing/doorbelling another DDR bank.
//
// This test uses the production helpers and proves the old no-pace/best-effort
// policy red before checking the exact-rate/RequireReleased policy green.

#include "libmisterplex/av_clock.hpp"
#include "libmisterplex/input_mailbox.hpp"
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
constexpr int64_t kCyclesPerUs = kSystemClockHz / 1'000'000;
constexpr int64_t kPresentLeadUs = 40'000;
constexpr int64_t kDropUs = 80'000;
constexpr int64_t kQueueBytes = misterplex::kMrAudioBytesPerSec / 10;

struct RateCase {
    int num;
    int den;
    int64_t cycle_frames;
    int64_t beam_ticks;
    int64_t repeats;
    const char* label;
};

constexpr RateCase kRates[] = {
    {24000, 1001, 71424, 89375, 17951, "24000/1001"},
    {24, 1, 62496, 78125, 15629, "24/1"},
    {25, 1, 2604, 3125, 521, "25/1"},
    {30000, 1001, 17856, 17875, 19, "30000/1001"},
    {30, 1, 15624, 15625, 1, "30/1"},
};

int64_t ceilDiv(int64_t value, int64_t divisor) {
    return value / divisor + ((value % divisor) != 0);
}

int64_t firstBeamTickForEligibility(int64_t eligibilityUs) {
    return ceilDiv(eligibilityUs * kCyclesPerUs, kBeamCycles);
}

int64_t audibleBytesAtOrAfter(int64_t targetUs) {
    int64_t bytes = ceilDiv(targetUs * misterplex::kMrAudioBytesPerSec, 1'000'000);
    return (bytes + 3) & ~int64_t(3); // complete stereo s16le sample
}

} // namespace

int main() {
    using namespace misterplex;

    CHECK(kSystemClockHz / kPixelClockDiv == 10'000'000);
    CHECK(kBeamCycles == 666'624);
    CHECK(kSystemClockHz * 2604 == 78'125 * kBeamCycles);

    for (const auto& rate : kRates) {
        constexpr int64_t kBaseFrame = 100;
        int64_t previousTick = 0;
        int64_t firstTick = 0;
        int64_t sameTick = 0;
        int64_t twoTick = 0;
        int64_t otherStep = 0;
        bool phaseRose = false;
        bool phaseFell = false;
        int64_t previousPhase = 0;
        bool havePreviousPhase = false;

        for (int64_t offset = 0; offset <= rate.cycle_frames; ++offset) {
            const int64_t frame = kBaseFrame + offset;
            const int64_t frameUs = frameContentUs(frame, rate.num, rate.den);
            const int64_t eligibilityUs = frameUs - kPresentLeadUs;

            // Stable queued depth must cancel exactly. Audio byte granularity
            // reaches eligibility less than one 48 kHz stereo sample late.
            const int64_t playedBytes = audibleBytesAtOrAfter(eligibilityUs);
            const int64_t clockUs =
                audibleClockUs(playedBytes + kQueueBytes, kQueueBytes);
            CHECK(clockUs >= eligibilityUs);
            CHECK(clockUs - eligibilityUs < 22);
            CHECK(avDecide(clockUs - frameUs, kPresentLeadUs, kDropUs, 0) ==
                  AvAction::Present);
            CHECK(avDecide(eligibilityUs - 1 - frameUs, kPresentLeadUs, kDropUs, 0) ==
                  AvAction::Hold);

            const int64_t tick = firstBeamTickForEligibility(eligibilityUs);
            if (offset == 0) {
                firstTick = tick;
            } else {
                const int64_t step = tick - previousTick;
                if (step == 0)
                    ++sameTick;
                else if (step == 2)
                    ++twoTick;
                else if (step != 1)
                    ++otherStep;
            }
            previousTick = tick;

            // First presentation relative to exact source PTS is bounded by
            // 40 ms lead + <1 us source truncation + one native beam period.
            const int64_t phase =
                tick * kBeamCycles * rate.num -
                frame * kSystemClockHz * rate.den;
            const int64_t lower =
                -(kPresentLeadUs + 1) * kCyclesPerUs * static_cast<int64_t>(rate.num);
            const int64_t upper =
                (kBeamCycles - kPresentLeadUs * kCyclesPerUs) *
                static_cast<int64_t>(rate.num);
            CHECK(phase > lower);
            CHECK(phase < upper);
            if (havePreviousPhase) {
                phaseRose = phaseRose || phase > previousPhase;
                phaseFell = phaseFell || phase < previousPhase;
            }
            previousPhase = phase;
            havePreviousPhase = true;
        }

        CHECK(sameTick == 0);
        CHECK(otherStep == 0);
        CHECK(twoTick == rate.repeats);
        CHECK(previousTick - firstTick == rate.beam_ticks);
        CHECK(phaseRose && phaseFell);

        // RED: pipelineDdr can have two decoded frames ready before one VSync.
        // With no eligibility gate and best-effort PLXD, the second frame is
        // immediately allowed to overwrite the non-display/pending bank.
        BankReleaseStatus pending{};
        pending.free_bank_mask = 0;
        pending.disp_bank = 0;
        pending.swap_pending = true;
        const DdrBankWriteDecision red =
            decideDdrBankWrite(pending, DdrBankWritePolicy::BestEffort);
        CHECK(red.ready);
        CHECK(red.bank == 1);

        // GREEN: at the first frame's eligibility, the second exact-rate frame
        // is still held. If it later becomes eligible before VSync, strict PLXD
        // still waits instead of superseding the pending frame.
        const int64_t frame1Us = frameContentUs(1, rate.num, rate.den);
        const int64_t frame2Us = frameContentUs(2, rate.num, rate.den);
        const int64_t firstEligibilityUs = frame1Us - kPresentLeadUs;
        CHECK(avDecide(firstEligibilityUs - frame2Us, kPresentLeadUs, kDropUs, 0) ==
              AvAction::Hold);
        const DdrBankWriteDecision wait =
            decideDdrBankWrite(pending, DdrBankWritePolicy::RequireReleased);
        CHECK(!wait.ready);
        CHECK(wait.bank == -1);

        BankReleaseStatus released{};
        released.free_bank_mask = 0x02;
        released.disp_bank = 0;
        released.swap_pending = false;
        const DdrBankWriteDecision green =
            decideDdrBankWrite(released, DdrBankWritePolicy::RequireReleased);
        CHECK(green.ready);
        CHECK(green.bank == 1);

        // Recovery remains a separate late-frame mechanism and may never
        // produce two consecutive drops.
        int dropRun = 0;
        int maxDropRun = 0;
        for (int i = 0; i < 40; ++i) {
            const AvAction action = avDecide(200'000, kPresentLeadUs, kDropUs, dropRun);
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
            "%s: exact_eligible source=%lld beam=%lld repeats=%lld "
            "supersede_red=1 strict_pending_green=1 recovery_drop_run=%d\n",
            rate.label, static_cast<long long>(rate.cycle_frames),
            static_cast<long long>(rate.beam_ticks),
            static_cast<long long>(twoTick), maxDropRun);
    }

    if (fails) {
        std::fprintf(stderr, "test_fixed30_host_pacing: %d failures\n", fails);
        return 1;
    }
    std::printf("PASS test_fixed30_host_pacing\n");
    return 0;
}
