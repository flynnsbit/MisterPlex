#include "Vtrue480_shared_ddr_tb.h"
#include "verilated.h"

#include "true480_i420_test_support.hpp"

#include <algorithm>
#include <array>
#include <cstdint>
#include <cstdlib>
#include <iostream>
#include <set>
#include <stdexcept>
#include <string>
#include <vector>

namespace {

constexpr uint32_t kM1BasePhys = 0x30100000u;
constexpr uint32_t kModelBytes = 0x00200000u;
constexpr uint64_t kYLineQwords = true480::kCodedW / 8;
constexpr uint64_t kCLineQwords = 2 * (true480::kCodedW / 16);
constexpr uint64_t kExactUniqueM0Payload =
    true480::kCodedH * kYLineQwords +
    (true480::kCodedH / 2) * kCLineQwords;
constexpr uint64_t kPhaseTolerantM0Floor = 54912;
constexpr uint64_t kM0PayloadCeiling = 70000;
constexpr uint64_t kHarnessSharedPayloadCeiling = 100000;
constexpr uint32_t kCalibratedM1ReadsMin = 20000;
constexpr uint32_t kCalibratedM1ReadsMax = 30000;
constexpr uint32_t kCalibratedM1WantMin = 400000;
constexpr uint32_t kCalibratedM1WantMax = 520000;
// Frozen from the first clean product-fallback run against FPGA 4c4667ca.
constexpr uint32_t kCleanReferenceM1Reads = 25665;
constexpr uint32_t kCleanReferenceM1WantCycles = 435636;
constexpr uint32_t kRequiredLineCount = 8;
constexpr uint32_t kExactLinebufBits = 159744;
constexpr uint32_t kExactM10Ks = 96;
constexpr uint32_t kProductStaleDoorbellFallbackPolls = 4096;
constexpr uint32_t kAcceleratedStaleDoorbellFallbackPolls = 256;
constexpr uint32_t kFallbackCadenceScale =
    kProductStaleDoorbellFallbackPolls /
    kAcceleratedStaleDoorbellFallbackPolls;
constexpr uint32_t kFallbackPrepLinesPerFire =
    kRequiredLineCount + kRequiredLineCount / 2;
constexpr uint32_t kProductFallbackFiresMax = 1;
constexpr uint32_t kStressFallbackFiresMin = 15;
constexpr uint32_t kStressFallbackFiresMax = 16;
constexpr uint32_t kStressBoundaryLineAllowance = 12;
constexpr uint64_t kStressRedundantQwordCeiling =
    kStressFallbackFiresMax * kFallbackPrepLinesPerFire *
    kYLineQwords;

static_assert(kYLineQwords == 78 && kCLineQwords == 78);
static_assert(kExactUniqueM0Payload == 56160);
static_assert(kCleanReferenceM1Reads >= kCalibratedM1ReadsMin &&
              kCleanReferenceM1Reads <= kCalibratedM1ReadsMax);
static_assert(kCleanReferenceM1WantCycles >= kCalibratedM1WantMin &&
              kCleanReferenceM1WantCycles <= kCalibratedM1WantMax);
static_assert(kExactLinebufBits == 159744 && kExactM10Ks == 96);
static_assert(kFallbackCadenceScale == 16);
static_assert(kFallbackPrepLinesPerFire == 12);
static_assert(kStressRedundantQwordCeiling == 14976);

struct ModelConfig {
    int baseLatency = 24;
    int latencyJitter = 32;
    int refreshPeriod = 702;
    int refreshCycles = 9;
    int beatGapPeriod = 17;
    int beatGapCycles = 2;
    bool ideal = false;
};

struct DdrStats {
    uint64_t cycles = 0;
    uint64_t commands = 0;
    uint64_t m0Reads = 0;
    uint64_t m1Reads = 0;
    uint64_t writes = 0;
    uint64_t m0Beats = 0;
    uint64_t m1Beats = 0;
    uint64_t m0ExpectedBeats = 0;
    uint64_t m1ExpectedBeats = 0;
    uint64_t refreshStallCycles = 0;
    uint64_t burstGapCycles = 0;
    uint64_t protocolErrors = 0;
    uint64_t doorbellReads = 0;
    uint64_t doorbellMagicBeats = 0;
    uint64_t lastDoorbellData = 0;
    uint64_t programmedDoorbellData = 0;
    uint64_t doorbellWrites = 0;
    uint64_t lastReadByteAddress = 0;
    uint32_t maxBurst = 0;
    uint32_t minObservedLatency = UINT32_MAX;
    uint32_t maxObservedLatency = 0;
};

struct RefillCounters {
    std::array<uint64_t, 2> issues{};
    std::array<uint64_t, 2> completions{};
    std::array<uint64_t, 2> firstFills{};
    std::array<uint64_t, 2> residentDuplicates{};
    std::array<uint64_t, 2> otherSlotCopies{};
    std::array<uint64_t, 2> inflightDuplicates{};
    std::array<uint64_t, 2> notNeeded{};
    std::array<uint64_t, 2> notNewlyNeeded{};
    std::array<uint64_t, 2> stalePipelineReplays{};
    std::array<uint64_t, 2> sameWindowReloads{};
    std::array<uint64_t, 2> legitimateSlidingReloads{};
    std::array<uint64_t, 2> schedReplayIssues{};
    std::array<uint64_t, 2> comboStillNeeded{};
    std::array<uint64_t, 2> currentIssues{};
    std::array<uint64_t, 2> pendingIssues{};
    std::array<uint64_t, 2> scheduledForPending{};
    uint64_t fallbackFires = 0;
    uint64_t completionWithoutInflight = 0;
    uint64_t wrapperNeedMismatch = 0;
    uint64_t invalidLineId = 0;
};

RefillCounters subtract(const RefillCounters& after,
                        const RefillCounters& before) {
    RefillCounters result;
    for (int p = 0; p < 2; ++p) {
#define REFILL_SUB(field) result.field[p] = after.field[p] - before.field[p]
        REFILL_SUB(issues);
        REFILL_SUB(completions);
        REFILL_SUB(firstFills);
        REFILL_SUB(residentDuplicates);
        REFILL_SUB(otherSlotCopies);
        REFILL_SUB(inflightDuplicates);
        REFILL_SUB(notNeeded);
        REFILL_SUB(notNewlyNeeded);
        REFILL_SUB(stalePipelineReplays);
        REFILL_SUB(sameWindowReloads);
        REFILL_SUB(legitimateSlidingReloads);
        REFILL_SUB(schedReplayIssues);
        REFILL_SUB(comboStillNeeded);
        REFILL_SUB(currentIssues);
        REFILL_SUB(pendingIssues);
        REFILL_SUB(scheduledForPending);
#undef REFILL_SUB
    }
    result.fallbackFires = after.fallbackFires - before.fallbackFires;
    result.completionWithoutInflight =
        after.completionWithoutInflight - before.completionWithoutInflight;
    result.wrapperNeedMismatch =
        after.wrapperNeedMismatch - before.wrapperNeedMismatch;
    result.invalidLineId = after.invalidLineId - before.invalidLineId;
    return result;
}

struct RefillLineStats {
    uint64_t issues = 0;
    uint64_t completions = 0;
    uint64_t firstFills = 0;
    uint64_t residentDuplicates = 0;
    uint64_t inflightDuplicates = 0;
    uint64_t stalePipelineReplays = 0;
    uint64_t sameWindowReloads = 0;
    uint64_t legitimateSlidingReloads = 0;
    uint64_t notNeeded = 0;
};

struct RefillCoverage {
    uint64_t issuedYLines = 0;
    uint64_t issuedCLines = 0;
    uint64_t issuedPayloadBeats = 0;
    uint64_t yLines = 0;
    uint64_t cLines = 0;
    uint64_t payloadBeats = 0;
    uint64_t displayBanks = 0;
    uint64_t swapPendingSamples = 0;
    uint64_t settledSamples = 0;
};

struct RefillLineState {
    bool needed = false;
    bool inflight = false;
    uint64_t needEpoch = 0;
    uint64_t completions = 0;
    uint64_t lastCompletionNeedEpoch = 0;
};

struct RefillEvent {
    uint64_t sequence = 0;
    bool issue = false;
    bool bank = false;
    bool chroma = false;
    uint16_t line = 0;
    uint8_t slot = 0;
    std::string classification;
};

class RefillTracker {
public:
    void observe(const Vtrue480_shared_ddr_tb& top) {
        updateDemand(top);
        if (detailActive) {
            detailDisplayBanks[top.telem_disp_bank ? 1 : 0] = true;
            ++detailSettledSamples;
            if (top.telem_swap_pending)
                ++detailSwapPendingSamples;
        }
        if (top.telem_fallback_fire)
            ++counters.fallbackFires;
        if (top.telem_fill_issue)
            recordIssue(top);
        if (top.telem_fill_complete)
            recordCompletion(top);
    }

    void beginDetailWindow() {
        detailActive = true;
        detailEvents.clear();
        detailLines.fill(RefillLineStats{});
        detailDisplayBanks.fill(false);
        detailSwapPendingSamples = 0;
        detailSettledSamples = 0;
    }

    void endDetailWindow() { detailActive = false; }

    const RefillCounters& getCounters() const { return counters; }

    RefillCoverage detailCoverage() const {
        RefillCoverage coverage;
        for (size_t i = 0; i < detailLines.size(); ++i) {
            const int group = static_cast<int>(i / kLinesPerGroup);
            const bool chroma = (group & 1) != 0;
            const auto& line = detailLines[i];
            if (line.issues) {
                if (chroma)
                    ++coverage.issuedCLines;
                else
                    ++coverage.issuedYLines;
            }
            if (line.completions) {
                if (chroma)
                    ++coverage.cLines;
                else
                    ++coverage.yLines;
            }
        }
        coverage.payloadBeats =
            coverage.yLines * kYLineQwords +
            coverage.cLines * kCLineQwords;
        coverage.issuedPayloadBeats =
            coverage.issuedYLines * kYLineQwords +
            coverage.issuedCLines * kCLineQwords;
        coverage.displayBanks =
            static_cast<uint64_t>(detailDisplayBanks[0]) +
            static_cast<uint64_t>(detailDisplayBanks[1]);
        coverage.swapPendingSamples = detailSwapPendingSamples;
        coverage.settledSamples = detailSettledSamples;
        return coverage;
    }

    void printDetail(size_t limitPerPlane = 8) const {
        for (int wantedPlane = 0; wantedPlane < 2; ++wantedPlane) {
            std::vector<size_t> order;
            for (size_t i = 0; i < detailLines.size(); ++i) {
                const int group = static_cast<int>(i / kLinesPerGroup);
                const auto& line = detailLines[i];
                if ((group & 1) == wantedPlane &&
                    (line.issues || line.completions))
                    order.push_back(i);
            }
            std::sort(order.begin(), order.end(), [this](size_t a, size_t b) {
                const auto score = [](const RefillLineStats& line) {
                    return line.residentDuplicates +
                           line.inflightDuplicates +
                           line.sameWindowReloads + line.notNeeded;
                };
                const uint64_t sa = score(detailLines[a]);
                const uint64_t sb = score(detailLines[b]);
                if (sa != sb)
                    return sa > sb;
                if (detailLines[a].issues != detailLines[b].issues)
                    return detailLines[a].issues > detailLines[b].issues;
                return a < b;
            });
            for (size_t rank = 0;
                 rank < std::min(limitPerPlane, order.size()); ++rank) {
                const size_t lineKey = order[rank];
                const auto& line = detailLines[lineKey];
                const int group =
                    static_cast<int>(lineKey / kLinesPerGroup);
                const int lineId =
                    static_cast<int>(lineKey % kLinesPerGroup);
                std::cout << "TRUE480_REFILL_TOP rank=" << rank + 1
                          << " bank=" << group / 2
                          << " plane=" << (wantedPlane ? "C" : "Y")
                          << " line=" << lineId
                          << " issues=" << line.issues
                          << " completions=" << line.completions
                          << " resident_dup=" << line.residentDuplicates
                          << " inflight_dup=" << line.inflightDuplicates
                          << " stale_replay=" << line.stalePipelineReplays
                          << " same_window_reload="
                          << line.sameWindowReloads
                          << " legit_sliding_reload="
                          << line.legitimateSlidingReloads
                          << " not_needed=" << line.notNeeded << "\n";
            }
        }
        for (const auto& event : detailEvents) {
            std::cout << "TRUE480_REFILL_EVENT seq=" << event.sequence
                      << " kind=" << (event.issue ? "ISSUE" : "COMPLETE")
                      << " bank=" << event.bank
                      << " plane=" << (event.chroma ? "C" : "Y")
                      << " line=" << event.line
                      << " slot=" << static_cast<int>(event.slot)
                      << " class=" << event.classification << "\n";
        }
    }

private:
    static constexpr size_t kLinesPerGroup = 480;
    static constexpr size_t kGroups = 4;
    static constexpr size_t kStateCount = kLinesPerGroup * kGroups;
    std::array<RefillLineState, kStateCount> states{};
    std::array<RefillLineStats, kStateCount> detailLines{};
    std::array<bool, 2> detailDisplayBanks{};
    RefillCounters counters;
    std::vector<RefillEvent> detailEvents;
    bool demandValid = false;
    bool detailActive = false;
    uint64_t detailSwapPendingSamples = 0;
    uint64_t detailSettledSamples = 0;
    uint16_t lastDesiredY0 = 0;
    uint16_t lastDesiredY7 = 0;
    bool lastDispBank = false;
    bool lastSwapPending = false;
    bool lastPendingBank = false;
    uint64_t eventSequence = 0;

    static size_t key(bool bank, bool chroma, uint16_t line) {
        return (static_cast<size_t>(bank) * 2 +
                static_cast<size_t>(chroma)) *
                   kLinesPerGroup +
               line;
    }

    bool neededFor(const Vtrue480_shared_ddr_tb& top, bool bank,
                   bool chroma, uint16_t line) const {
        const uint16_t y0 = top.telem_desired_y0;
        const uint16_t y7 = top.telem_desired_y7;
        bool needed = false;
        if (bank == static_cast<bool>(top.telem_disp_bank)) {
            if (chroma)
                needed = line >= y0 / 2 && line <= y7 / 2;
            else
                needed = line >= y0 && line <= y7;
        }
        if (top.telem_swap_pending &&
            bank == static_cast<bool>(top.telem_pending_bank)) {
            if (chroma)
                needed = needed || line <= 3;
            else
                needed = needed || line <= 7;
        }
        return needed;
    }

    void updateDemand(const Vtrue480_shared_ddr_tb& top) {
        const uint16_t y0 = top.telem_desired_y0;
        const uint16_t y7 = top.telem_desired_y7;
        const bool dispBank = top.telem_disp_bank;
        const bool swapPending = top.telem_swap_pending;
        const bool pendingBank = top.telem_pending_bank;
        if (demandValid && y0 == lastDesiredY0 && y7 == lastDesiredY7 &&
            dispBank == lastDispBank && swapPending == lastSwapPending &&
            pendingBank == lastPendingBank)
            return;
        for (bool bank : {false, true}) {
            for (bool chroma : {false, true}) {
                const uint16_t lineLimit = chroma ? 240 : 480;
                for (uint16_t line = 0; line < lineLimit; ++line) {
                    auto& state = states[key(bank, chroma, line)];
                    const bool now = neededFor(top, bank, chroma, line);
                    if (!state.needed && now)
                        ++state.needEpoch;
                    state.needed = now;
                }
            }
        }
        demandValid = true;
        lastDesiredY0 = y0;
        lastDesiredY7 = y7;
        lastDispBank = dispBank;
        lastSwapPending = swapPending;
        lastPendingBank = pendingBank;
    }

    bool validLine(bool chroma, uint16_t line) const {
        return line < (chroma ? 240 : 480);
    }

    void rememberEvent(bool issue, bool bank, bool chroma, uint16_t line,
                       uint8_t slot, const std::string& classification) {
        if (!detailActive || detailEvents.size() >= 24)
            return;
        detailEvents.push_back(
            {eventSequence, issue, bank, chroma, line, slot, classification});
    }

    void recordIssue(const Vtrue480_shared_ddr_tb& top) {
        ++eventSequence;
        const bool bank = top.telem_fill_bank;
        const bool chroma = top.telem_fill_chroma;
        const uint16_t line = top.telem_fill_line;
        const int plane = chroma ? 1 : 0;
        if (!validLine(chroma, line)) {
            ++counters.invalidLineId;
            rememberEvent(true, bank, chroma, line, top.telem_fill_slot,
                          "INVALID_LINE");
            return;
        }
        auto& state = states[key(bank, chroma, line)];
        auto& detail = detailLines[key(bank, chroma, line)];
        const bool resident = top.telem_issue_resident;
        const bool anyResident = top.telem_issue_any_resident;
        const bool inflight = state.inflight;
        const bool needed =
            top.telem_issue_needed_current || top.telem_issue_needed_pending;
        const bool trackerNeeded = state.needed;
        const bool seenCompleted = state.completions != 0;
        const bool demandAdvanced =
            seenCompleted &&
            state.needEpoch > state.lastCompletionNeedEpoch;
        const bool issuedEarlierThisWindow =
            detailActive && detail.issues != 0;
        const bool staleReplay =
            resident && top.telem_issue_sched_replay;
        const bool sameWindowReload =
            !resident && !inflight && needed && seenCompleted &&
            (detailActive ? issuedEarlierThisWindow : !demandAdvanced);
        const bool legitimateReload =
            !resident && !inflight && needed && seenCompleted &&
            (detailActive ? !issuedEarlierThisWindow : demandAdvanced);
        const bool notNewlyNeeded =
            !needed || resident || inflight || sameWindowReload;
        std::string classification;

        ++counters.issues[plane];
        if (detailActive)
            ++detail.issues;
        if (top.telem_issue_sched_replay)
            ++counters.schedReplayIssues[plane];
        if (top.telem_issue_need_combo)
            ++counters.comboStillNeeded[plane];
        if (top.telem_issue_needed_current)
            ++counters.currentIssues[plane];
        if (top.telem_issue_needed_pending)
            ++counters.pendingIssues[plane];
        if (top.telem_issue_for_pending)
            ++counters.scheduledForPending[plane];
        if (anyResident && !resident)
            ++counters.otherSlotCopies[plane];
        if (needed != trackerNeeded)
            ++counters.wrapperNeedMismatch;
        if (notNewlyNeeded)
            ++counters.notNewlyNeeded[plane];

        if (inflight) {
            ++counters.inflightDuplicates[plane];
            if (detailActive)
                ++detail.inflightDuplicates;
            classification = "INFLIGHT_DUP";
        } else if (resident) {
            ++counters.residentDuplicates[plane];
            if (detailActive)
                ++detail.residentDuplicates;
            if (staleReplay) {
                ++counters.stalePipelineReplays[plane];
                if (detailActive)
                    ++detail.stalePipelineReplays;
                classification = "STALE_PIPELINE_REPLAY";
            } else {
                classification = "RESIDENT_DUP";
            }
        } else if (!needed) {
            ++counters.notNeeded[plane];
            if (detailActive)
                ++detail.notNeeded;
            classification = "NOT_NEEDED";
        } else if (!seenCompleted) {
            ++counters.firstFills[plane];
            if (detailActive)
                ++detail.firstFills;
            classification = "FIRST_FILL";
        } else if (legitimateReload) {
            ++counters.legitimateSlidingReloads[plane];
            if (detailActive)
                ++detail.legitimateSlidingReloads;
            classification = "LEGIT_SLIDING_RELOAD";
        } else if (sameWindowReload) {
            ++counters.sameWindowReloads[plane];
            if (detailActive)
                ++detail.sameWindowReloads;
            classification = "SAME_WINDOW_RELOAD";
        } else {
            classification = "UNCLASSIFIED";
        }
        state.inflight = true;
        rememberEvent(true, bank, chroma, line, top.telem_fill_slot,
                      classification);
    }

    void recordCompletion(const Vtrue480_shared_ddr_tb& top) {
        ++eventSequence;
        const bool bank = top.telem_fill_bank;
        const bool chroma = top.telem_fill_chroma;
        const uint16_t line = top.telem_fill_line;
        const int plane = chroma ? 1 : 0;
        if (!validLine(chroma, line)) {
            ++counters.invalidLineId;
            rememberEvent(false, bank, chroma, line, top.telem_fill_slot,
                          "INVALID_LINE");
            return;
        }
        auto& state = states[key(bank, chroma, line)];
        auto& detail = detailLines[key(bank, chroma, line)];
        ++counters.completions[plane];
        if (detailActive)
            ++detail.completions;
        if (!state.inflight)
            ++counters.completionWithoutInflight;
        state.inflight = false;
        ++state.completions;
        state.lastCompletionNeedEpoch = state.needEpoch;
        rememberEvent(false, bank, chroma, line, top.telem_fill_slot,
                      "COMPLETE");
    }
};

class SharedDdrModel {
public:
    SharedDdrModel(Vtrue480_shared_ddr_tb& topRef, ModelConfig config)
        : top(topRef), cfg(config), memory(kModelBytes / 8, 0) {}

    void loadBank(int bank, const std::vector<uint8_t>& frame) {
        if (bank < 0 || bank > 1 || frame.size() != true480::kFrameBytes)
            throw std::runtime_error("invalid shared-DDR frame load");
        const size_t base =
            static_cast<size_t>(bank) * true480::kBankStrideBytes / 8;
        for (size_t byte = 0; byte < frame.size(); byte += 8)
            memory[base + byte / 8] = true480::pack8(frame.data() + byte);
    }

    void seedM1Ring() {
        const size_t first = (kM1BasePhys - true480::kBasePhys) / 8;
        for (size_t i = 0; i < 0x10000 / 8; ++i)
            memory[first + i] = 0xcafe000000000000ull | i;
    }

    void ringDoorbell(int bank, uint32_t sequence) {
        const size_t qword =
            (true480::kDoorbellPhys - true480::kBasePhys) / 8;
        memory[qword] =
            (static_cast<uint64_t>(true480::doorbellHigh(sequence, bank)) << 32) |
            true480::kDoorbellMagic;
        stats.programmedDoorbellData = memory[qword];
    }

    void driveBeforePosedge() {
        top.DDRAM_DOUT_READY = 0;
        bool refresh = false;
        if (!cfg.ideal && cfg.refreshPeriod > 0) {
            const int phase = static_cast<int>(stats.cycles % cfg.refreshPeriod);
            refresh = phase < cfg.refreshCycles;
            if (refresh)
                ++stats.refreshStallCycles;
        }

        if (busyHold > 0)
            --busyHold;
        top.DDRAM_BUSY = (busyHold > 0) || refresh;

        if (transaction.active && transaction.read) {
            ++transaction.age;
            if (transaction.delay > 0) {
                --transaction.delay;
            } else if (!refresh) {
                if (gapLeft > 0) {
                    --gapLeft;
                    ++stats.burstGapCycles;
                } else {
                    top.DDRAM_DOUT =
                        readQword(transaction.addr + transaction.beat);
                    if (static_cast<uint64_t>(transaction.addr +
                                              transaction.beat) *
                            8 ==
                        true480::kDoorbellPhys) {
                        ++stats.doorbellMagicBeats;
                        stats.lastDoorbellData = top.DDRAM_DOUT;
                    }
                    top.DDRAM_DOUT_READY = 1;
                    if (transaction.ownerM1)
                        ++stats.m1Beats;
                    else
                        ++stats.m0Beats;
                    ++transaction.beat;
                    if (!cfg.ideal && cfg.beatGapPeriod > 0 &&
                        transaction.beat < transaction.burst &&
                        transaction.beat % cfg.beatGapPeriod == 0)
                        gapLeft = cfg.beatGapCycles;
                    if (transaction.beat == transaction.burst) {
                        noteLatency();
                        transaction = {};
                    }
                }
            }
        }
        ++stats.cycles;
    }

    void sampleCommandAtPosedge() {
        const bool command = top.DDRAM_RD || top.DDRAM_WE;
        if (!command) {
            commandLatched = false;
            return;
        }
        const bool sameCommand =
            commandLatched && latchedAddr == top.DDRAM_ADDR &&
            latchedBurst == top.DDRAM_BURSTCNT &&
            latchedRead == static_cast<bool>(top.DDRAM_RD) &&
            latchedWrite == static_cast<bool>(top.DDRAM_WE);
        if (sameCommand)
            return;
        if (transaction.active || top.DDRAM_BUSY)
            return;
        commandLatched = true;
        latchedAddr = top.DDRAM_ADDR;
        latchedBurst = top.DDRAM_BURSTCNT;
        latchedRead = top.DDRAM_RD;
        latchedWrite = top.DDRAM_WE;
        const uint32_t burst = std::max<uint32_t>(1, top.DDRAM_BURSTCNT);
        transaction.active = true;
        transaction.read = top.DDRAM_RD;
        transaction.ownerM1 =
            static_cast<uint64_t>(top.DDRAM_ADDR) * 8 >= kM1BasePhys;
        transaction.addr = top.DDRAM_ADDR;
        transaction.burst = burst;
        transaction.beat = 0;
        transaction.age = 0;
        transaction.delay =
            cfg.ideal ? 0
                      : cfg.baseLatency +
                            static_cast<int>((stats.commands * 13) %
                                             (cfg.latencyJitter + 1));
        gapLeft = 0;
        busyHold = cfg.ideal ? 1 : 3;
        ++stats.commands;
        stats.maxBurst = std::max(stats.maxBurst, burst);

        if (top.DDRAM_RD) {
            stats.lastReadByteAddress =
                static_cast<uint64_t>(top.DDRAM_ADDR) * 8;
            if (stats.lastReadByteAddress == true480::kDoorbellPhys)
                ++stats.doorbellReads;
            if (transaction.ownerM1) {
                ++stats.m1Reads;
                stats.m1ExpectedBeats += burst;
            } else {
                ++stats.m0Reads;
                stats.m0ExpectedBeats += burst;
            }
        } else {
            ++stats.writes;
            writeQword(top.DDRAM_ADDR, top.DDRAM_DIN, top.DDRAM_BE);
            transaction = {};
        }
    }

    bool idle() const { return !transaction.active; }
    const DdrStats& getStats() const { return stats; }

private:
    struct Transaction {
        bool active = false;
        bool read = false;
        bool ownerM1 = false;
        uint32_t addr = 0;
        uint32_t burst = 0;
        uint32_t beat = 0;
        uint32_t age = 0;
        int delay = 0;
    };

    Vtrue480_shared_ddr_tb& top;
    ModelConfig cfg;
    std::vector<uint64_t> memory;
    Transaction transaction;
    DdrStats stats;
    int busyHold = 0;
    int gapLeft = 0;
    bool commandLatched = false;
    uint32_t latchedAddr = 0;
    uint8_t latchedBurst = 0;
    bool latchedRead = false;
    bool latchedWrite = false;

    void noteLatency() {
        stats.minObservedLatency =
            std::min(stats.minObservedLatency, transaction.age);
        stats.maxObservedLatency =
            std::max(stats.maxObservedLatency, transaction.age);
    }

    uint64_t readQword(uint32_t qwordAddr) {
        const uint64_t byteAddr = static_cast<uint64_t>(qwordAddr) * 8;
        if (byteAddr < true480::kBasePhys ||
            byteAddr >= true480::kBasePhys + kModelBytes) {
            ++stats.protocolErrors;
            return 0;
        }
        return memory[(byteAddr - true480::kBasePhys) / 8];
    }

    void writeQword(uint32_t qwordAddr, uint64_t value, uint8_t be) {
        const uint64_t byteAddr = static_cast<uint64_t>(qwordAddr) * 8;
        if (byteAddr < true480::kBasePhys ||
            byteAddr >= true480::kBasePhys + kModelBytes) {
            ++stats.protocolErrors;
            return;
        }
        uint64_t& word = memory[(byteAddr - true480::kBasePhys) / 8];
        if (byteAddr == true480::kDoorbellPhys)
            ++stats.doorbellWrites;
        for (int i = 0; i < 8; ++i) {
            if (be & (1u << i)) {
                const uint64_t mask = 0xffull << (i * 8);
                word = (word & ~mask) | (value & mask);
            }
        }
    }
};

struct FrameMetrics {
    uint64_t active = 0;
    uint64_t visible = 0;
    uint64_t yHits = 0;
    uint64_t cHits = 0;
    uint64_t softC = 0;
    uint64_t misses = 0;
    uint64_t orange = 0;
    uint64_t dark = 0;
    uint64_t black = 0;
    uint64_t geometryErrors = 0;
    uint64_t sourceErrors = 0;
    std::set<int> rows;
    std::set<int> visibleXs;
    uint16_t underrunBefore = 0;
    uint16_t underrunAfter = 0;
    uint32_t m1ReadsBefore = 0;
    uint32_t m1ReadsAfter = 0;
    uint32_t m1ResponsesBefore = 0;
    uint32_t m1ResponsesAfter = 0;
    uint32_t m1WantBefore = 0;
    uint32_t m1WantAfter = 0;
    DdrStats ddrBefore;
    DdrStats ddrAfter;
    RefillCounters refillBefore;
    RefillCounters refillAfter;
};

class Sim {
public:
    explicit Sim(ModelConfig cfg) : ddr(top, cfg) {
        top.clk_sys = 0;
        top.clk_ddr = 0;
        top.reset = 0;
        top.m1_run = 0;
        top.DDRAM_BUSY = 0;
        top.DDRAM_DOUT = 0;
        top.DDRAM_DOUT_READY = 0;
        top.eval();
    }

    void reset() {
        top.reset = 1;
        runSysCycles(24);
        top.reset = 0;
        runSysCycles(24);
    }

    void runSysCycles(uint64_t count) {
        const uint64_t target = sysPosedges + count;
        while (sysPosedges < target)
            event();
    }

    void runUntilFrameStart() {
        bool sawLow = !top.beam_frame_start;
        const uint64_t start = sysPosedges;
        while (sysPosedges - start < 800000) {
            event();
            if (!top.beam_frame_start)
                sawLow = true;
            if (sawLow && lastSysPosedge && top.beam_frame_start)
                return;
        }
        throw std::runtime_error("native 672x496 beam did not wrap");
    }

    bool presentFrame() {
        ddr.ringDoorbell(0, 1);
        top.m1_run = 1;
        for (int frame = 0; frame < 5; ++frame) {
            runUntilFrameStart();
            if (top.has_frame && top.doorbell_ok)
                return true;
        }
        return false;
    }

    FrameMetrics captureFrame(bool recordRefillDetails = false) {
        runUntilFrameStart();
        if (recordRefillDetails)
            refill.beginDetailWindow();
        FrameMetrics m;
        m.underrunBefore = top.underrun_count;
        m.m1ReadsBefore = top.m1_reads_issued;
        m.m1ResponsesBefore = top.m1_responses_seen;
        m.m1WantBefore = top.m1_want_cycles;
        m.ddrBefore = ddr.getStats();
        m.refillBefore = refill.getCounters();
        bool leftStart = false;
        const uint64_t start = sysPosedges;
        while (sysPosedges - start < 800000) {
            event();
            if (!lastSysPosedge)
                continue;
            if (!top.beam_frame_start)
                leftStart = true;
            if (leftStart && top.beam_frame_start)
                break;
            if (!top.pixel_step || !top.beam_active)
                continue;
            ++m.active;
            const int x = top.beam_x;
            const int y = top.beam_y;
            const bool expectedVisible =
                x >= true480::kPillarLeft &&
                x < true480::kPillarLeft + true480::kDisplayW;
            if (static_cast<bool>(top.obs_visible_now) != expectedVisible)
                ++m.geometryErrors;
            if (top.obs_visible_now) {
                m.rows.insert(top.obs_src_y_now);
                m.visibleXs.insert(x);
                if (top.obs_src_x_now != x - true480::kPillarLeft ||
                    top.obs_src_y_now != y)
                    ++m.sourceErrors;
            }
            if (!top.obs_visible_pipe)
                continue;
            ++m.visible;
            m.yHits += top.obs_y_hit;
            m.cHits += top.obs_c_hit;
            m.softC += top.obs_y_hit && !top.obs_c_hit;
            m.misses += top.obs_miss;
            const true480::Rgb p{top.rd_r, top.rd_g, top.rd_b};
            m.orange += true480::isOrange(p);
            m.dark += true480::isDark(p);
            m.black += p.r <= 2 && p.g <= 2 && p.b <= 2;
        }
        m.underrunAfter = top.underrun_count;
        m.m1ReadsAfter = top.m1_reads_issued;
        m.m1ResponsesAfter = top.m1_responses_seen;
        m.m1WantAfter = top.m1_want_cycles;
        m.ddrAfter = ddr.getStats();
        m.refillAfter = refill.getCounters();
        if (recordRefillDetails)
            refill.endDetailWindow();
        return m;
    }

    void stopM1AndDrain() {
        top.m1_run = 0;
        for (int i = 0; i < 2000; ++i) {
            event();
            if (top.m1_reads_issued == top.m1_responses_seen && ddr.idle())
                return;
        }
    }

    Vtrue480_shared_ddr_tb top{};
    SharedDdrModel ddr;
    RefillTracker refill;

private:
    uint64_t now = 0;
    uint64_t nextDdrEdge = 2;
    uint64_t nextSysEdge = 9;
    uint64_t sysPosedges = 0;
    bool lastSysPosedge = false;

    void event() {
        now = std::min(nextDdrEdge, nextSysEdge);
        const bool ddrEdge = now == nextDdrEdge;
        const bool sysEdge = now == nextSysEdge;
        const bool ddrRise = ddrEdge && !top.clk_ddr;
        const bool sysRise = sysEdge && !top.clk_sys;
        if (ddrRise) {
            ddr.driveBeforePosedge();
            // The f2sdram bridge samples commands at this edge. In
            // particular, the arbiter can drop grant_m1 in the NBA update,
            // so sampling its post-edge combinational mux loses the pulse.
            ddr.sampleCommandAtPosedge();
        }
        if (ddrEdge) {
            top.clk_ddr = !top.clk_ddr;
            nextDdrEdge += 2;
        }
        if (sysEdge) {
            top.clk_sys = !top.clk_sys;
            nextSysEdge += 9;
        }
        top.eval();
        if (ddrRise)
            refill.observe(top);
        if (sysRise)
            ++sysPosedges;
        lastSysPosedge = sysRise;
    }
};

int checkResourceContract(const Vtrue480_shared_ddr_tb& top) {
    bool ok = true;
    if (top.cfg_line_count != kRequiredLineCount) {
        std::cerr << "FAIL true480 shared M10K_depth line_count="
                  << static_cast<int>(top.cfg_line_count)
                  << " required=" << kRequiredLineCount
                  << " (four lines cannot cover modeled stalls; "
                     "sixteen exceeds the product budget)\n";
        ok = false;
    }
    if (top.cfg_linebuf_bits != kExactLinebufBits) {
        std::cerr << "FAIL true480 shared M10K_bits got=" << top.cfg_linebuf_bits
                  << " required=" << kExactLinebufBits << "\n";
        ok = false;
    }
    if (top.cfg_m10k_estimate != kExactM10Ks) {
        std::cerr << "FAIL true480 shared M10K_budget estimate="
                  << top.cfg_m10k_estimate << " required=" << kExactM10Ks
                  << " maximum=" << kExactM10Ks << "\n";
        ok = false;
    }
    return ok ? 0 : 1;
}

int runProof(bool idealModel, bool resourceOnly, bool requireActiveConfig,
             bool acceleratedFallbackStress,
             bool faultUnboundedFallback) {
    ModelConfig cfg;
    if (idealModel) {
        cfg.ideal = true;
        cfg.baseLatency = 0;
        cfg.latencyJitter = 0;
        cfg.refreshPeriod = 0;
        cfg.refreshCycles = 0;
        cfg.beatGapPeriod = 0;
        cfg.beatGapCycles = 0;
    }
    Sim sim(cfg);
    sim.top.eval();
    const bool activeConfig = sim.top.cfg_active_config;
    const bool nativeBeam = sim.top.cfg_native_beam_source;
    const int fillStride = sim.top.cfg_y_fill_stride;
    const uint32_t fallbackPolls =
        sim.top.cfg_stale_doorbell_fallback_polls;
    const bool refillTelemetry = sim.top.cfg_refill_telemetry;
    const uint32_t requiredFallbackPolls = acceleratedFallbackStress
        ? kAcceleratedStaleDoorbellFallbackPolls
        : kProductStaleDoorbellFallbackPolls;
    std::cout << "TRUE480_SHARED_BUILD_CONFIG active_define=" << activeConfig
              << " native_beam_source=" << nativeBeam
              << " y_fill_stride=" << fillStride
              << " stale_doorbell_fallback_polls=" << fallbackPolls
              << " proof_mode="
              << (acceleratedFallbackStress ? "fallback_stress" : "product")
              << " refill_telemetry=" << refillTelemetry
              << " required=" << requireActiveConfig << "\n";
    if (requireActiveConfig &&
        (!activeConfig || !nativeBeam || fillStride != 1 ||
         !refillTelemetry)) {
        std::cerr << "FAIL true480 shared active configuration disappeared: "
                     "define/native beam/fill stride/telemetry contract "
                     "is not active\n";
        return 1;
    }
    if (requireActiveConfig &&
        fallbackPolls != requiredFallbackPolls) {
        std::cerr << "FAIL true480 shared "
                  << (acceleratedFallbackStress ? "stress" : "product")
                  << " fallback polls="
                  << fallbackPolls << " required="
                  << requiredFallbackPolls << "\n";
        return 1;
    }
    const int resourceRc = checkResourceContract(sim.top);
    if (resourceOnly)
        return resourceRc;
    if (resourceRc != 0)
        return resourceRc;
    if (idealModel) {
        std::cerr << "FAIL true480 shared idealized_DDR_refused latency=0 "
                     "refresh_stalls=0 burst_gaps=0\n";
        return 1;
    }

    const auto frame = true480::makeIdleI420();
    sim.ddr.loadBank(0, frame);
    sim.ddr.loadBank(1, frame);
    sim.ddr.seedM1Ring();
    sim.reset();
    // Let the frame store observe the reset/empty doorbell first. Its strict
    // sequence protocol intentionally primes before accepting a new token.
    sim.runSysCycles(5000);
    if (!sim.presentFrame()) {
        const auto& s = sim.ddr.getStats();
        std::cerr << "FAIL true480 shared frame did not swap within five native frames"
                  << " doorbell_ok=" << static_cast<int>(sim.top.doorbell_ok)
                  << " frames_done=" << sim.top.frames_done
                  << " underrun=" << sim.top.underrun_count
                  << " commands=" << s.commands
                  << " m0_reads=" << s.m0Reads
                  << " m1_reads=" << s.m1Reads
                  << " m0_beats=" << s.m0Beats
                  << " m1_beats=" << s.m1Beats
                  << " writes=" << s.writes
                  << " store_state=" << static_cast<int>(sim.top.store_debug_state)
                  << " m0_rd=" << static_cast<int>(sim.top.store_m0_rd)
                  << " m0_we=" << static_cast<int>(sim.top.store_m0_we)
                  << " m0_busy=" << static_cast<int>(sim.top.store_m0_busy)
                  << " m1_state=" << static_cast<int>(sim.top.test_m1_state)
                  << " m1_want=" << static_cast<int>(sim.top.test_m1_want)
                  << " m1_busy=" << static_cast<int>(sim.top.test_m1_busy)
                  << " m1_rd=" << static_cast<int>(sim.top.test_m1_rd)
                  << " m1_we=" << static_cast<int>(sim.top.test_m1_we)
                  << " m1_issued=" << sim.top.m1_reads_issued
                  << " m1_seen=" << sim.top.m1_responses_seen
                  << " doorbell_reads=" << s.doorbellReads
                  << " doorbell_beats=" << s.doorbellMagicBeats
                  << " last_doorbell_data=0x" << std::hex
                  << s.lastDoorbellData
                  << " programmed_doorbell=0x" << s.programmedDoorbellData
                  << " doorbell_writes=" << std::dec << s.doorbellWrites
                  << " last_read_byte=0x" << std::hex
                  << s.lastReadByteAddress << std::dec
                  << " protocol_errors=" << s.protocolErrors << "\n";
        return 1;
    }
    for (int i = 0; i < 3; ++i)
        sim.captureFrame();
    const FrameMetrics m = sim.captureFrame(true);
    sim.stopM1AndDrain();

    const uint64_t expectedActive =
        static_cast<uint64_t>(true480::kOutW) * true480::kOutH;
    const uint64_t expectedVisible =
        static_cast<uint64_t>(true480::kDisplayW) * true480::kOutH;
    const uint64_t m0Beats = m.ddrAfter.m0Beats - m.ddrBefore.m0Beats;
    const uint64_t m1Beats = m.ddrAfter.m1Beats - m.ddrBefore.m1Beats;
    const uint64_t refreshCycles =
        m.ddrAfter.refreshStallCycles - m.ddrBefore.refreshStallCycles;
    const uint64_t gapCycles =
        m.ddrAfter.burstGapCycles - m.ddrBefore.burstGapCycles;
    const uint32_t m1Reads = m.m1ReadsAfter - m.m1ReadsBefore;
    const uint32_t m1Responses =
        m.m1ResponsesAfter - m.m1ResponsesBefore;
    const uint32_t m1WantCycles = m.m1WantAfter - m.m1WantBefore;
    const RefillCounters refill =
        subtract(m.refillAfter, m.refillBefore);
    const RefillCoverage refillCoverage = sim.refill.detailCoverage();
    const uint64_t totalIssues =
        refill.issues[0] + refill.issues[1];
    const uint64_t legitimate =
        refill.legitimateSlidingReloads[0] +
        refill.legitimateSlidingReloads[1] +
        refill.firstFills[0] + refill.firstFills[1];
    const uint64_t redundant =
        refill.notNewlyNeeded[0] + refill.notNewlyNeeded[1];
    const uint64_t stale =
        refill.stalePipelineReplays[0] +
        refill.stalePipelineReplays[1];
    const uint64_t sameWindow =
        refill.sameWindowReloads[0] +
        refill.sameWindowReloads[1];
    const uint64_t effectiveFallbackFires =
        faultUnboundedFallback ? kStressFallbackFiresMax + 1
                               : refill.fallbackFires;
    const uint64_t fallbackAttributedLines =
        effectiveFallbackFires * kFallbackPrepLinesPerFire;
    const uint64_t fallbackAttributedQwordBeats =
        fallbackAttributedLines * kYLineQwords;
    const uint64_t scaledFallbackQwordBeats =
        (fallbackAttributedQwordBeats + kFallbackCadenceScale - 1) /
        kFallbackCadenceScale;
    const uint64_t scaledM0Beats =
        acceleratedFallbackStress &&
                m0Beats >= fallbackAttributedQwordBeats
            ? m0Beats - fallbackAttributedQwordBeats +
                  scaledFallbackQwordBeats
            : m0Beats;
    const uint64_t scaledSharedBeats =
        acceleratedFallbackStress &&
                m0Beats + m1Beats >= fallbackAttributedQwordBeats
            ? m0Beats + m1Beats - fallbackAttributedQwordBeats +
                  scaledFallbackQwordBeats
            : m0Beats + m1Beats;

    bool ok = true;
    auto fail = [&ok](const std::string& what) {
        std::cerr << "FAIL true480 shared " << what << "\n";
        ok = false;
    };
    if (m.active != expectedActive)
        fail("active_pixels got=" + std::to_string(m.active) +
             " expected=" + std::to_string(expectedActive));
    if (m.visible + 8 < expectedVisible || m.visible > expectedVisible + 8)
        fail("visible_pixels got=" + std::to_string(m.visible) +
             " expected=" + std::to_string(expectedVisible));
    if (m.geometryErrors || m.sourceErrors || m.rows.size() != 480 ||
        m.visibleXs.size() != 618)
        fail("geometry crop=11+618+11 rows=" +
             std::to_string(m.rows.size()) + " visible_x=" +
             std::to_string(m.visibleXs.size()) + " geom_errors=" +
             std::to_string(m.geometryErrors) + " source_errors=" +
             std::to_string(m.sourceErrors));
    if (m.yHits < expectedVisible * 999 / 1000 ||
        m.cHits < expectedVisible * 999 / 1000)
        fail("sustained_hits Y=" + std::to_string(m.yHits) +
             " C=" + std::to_string(m.cHits) +
             " visible=" + std::to_string(m.visible));
    if (m.softC != 0)
        fail("settled_visible_soft_c_fallback count=" +
             std::to_string(m.softC));
    if (m.misses != 0)
        fail("settled_visible_miss count=" + std::to_string(m.misses));
    if (m.underrunAfter != m.underrunBefore ||
        m.underrunAfter == UINT16_MAX)
        fail("steady_underrun before=" +
             std::to_string(m.underrunBefore) + " after=" +
             std::to_string(m.underrunAfter));
    if (m.orange < 5000 || m.dark < 200000 || m.black > 16)
        fail("orange_on_dark orange=" + std::to_string(m.orange) +
             " dark=" + std::to_string(m.dark) +
             " black=" + std::to_string(m.black));
    if (m1Reads < kCalibratedM1ReadsMin ||
        m1Reads > kCalibratedM1ReadsMax ||
        m1Responses + 1 < m1Reads ||
        m1Beats < kCalibratedM1ReadsMin ||
        m1Beats > kCalibratedM1ReadsMax ||
        m1WantCycles < kCalibratedM1WantMin ||
        m1WantCycles > kCalibratedM1WantMax)
        fail("m1_stream_service reads=" + std::to_string(m1Reads) +
             " responses=" + std::to_string(m1Responses) +
             " physical_beats=" + std::to_string(m1Beats) +
             " want_cycles=" + std::to_string(m1WantCycles) +
             " calibrated_bands=reads/beats:20000..30000,"
             "want:400000..520000");
    if (sim.top.m1_reads_issued != sim.top.m1_responses_seen ||
        sim.top.m1_protocol_errors != 0)
        fail("m1_beat_conservation issued=" +
             std::to_string(sim.top.m1_reads_issued) + " seen=" +
             std::to_string(sim.top.m1_responses_seen) + " errors=" +
             std::to_string(sim.top.m1_protocol_errors));
    if (!acceleratedFallbackStress) {
        if (m0Beats < kPhaseTolerantM0Floor ||
            m0Beats > kM0PayloadCeiling || m.ddrAfter.maxBurst < 39)
            fail("m0_burst_traffic beats=" + std::to_string(m0Beats) +
                 " phase_floor=" +
                 std::to_string(kPhaseTolerantM0Floor) +
                 " ceiling=" + std::to_string(kM0PayloadCeiling) +
                 " max_burst=" + std::to_string(m.ddrAfter.maxBurst));
        if (m0Beats + m1Beats > kHarnessSharedPayloadCeiling)
            fail("harness_shared_payload_ceiling shared_beats=" +
                 std::to_string(m0Beats + m1Beats) +
                 " harness_only_ceiling=" +
                 std::to_string(kHarnessSharedPayloadCeiling));
        if (refill.fallbackFires > kProductFallbackFiresMax)
            fail("product_fallback_fires got=" +
                 std::to_string(refill.fallbackFires) +
                 " ceiling=1");
    } else {
        if (m.ddrAfter.maxBurst < 39)
            fail("stress_m0_burst max_burst=" +
                 std::to_string(m.ddrAfter.maxBurst));
        if (effectiveFallbackFires < kStressFallbackFiresMin ||
            effectiveFallbackFires > kStressFallbackFiresMax)
            fail("stress_fallback_fires got=" +
                 std::to_string(effectiveFallbackFires) +
                 " required=15..16");
        if (stale != 0)
            fail("stress_stale_replay count=" + std::to_string(stale));
        if (sameWindow > fallbackAttributedLines ||
            fallbackAttributedLines - sameWindow >
                kStressBoundaryLineAllowance ||
            redundant != sameWindow)
            fail("stress_redundant_decomposition fallback_fires=" +
                 std::to_string(effectiveFallbackFires) +
                 " fallback_lines=" +
                 std::to_string(fallbackAttributedLines) +
                 " same_window=" + std::to_string(sameWindow) +
                 " redundant=" + std::to_string(redundant));
        if (redundant * kYLineQwords >
            kStressRedundantQwordCeiling)
            fail("stress_redundant_qword_beats got=" +
                 std::to_string(redundant * kYLineQwords) +
                 " ceiling=" +
                 std::to_string(kStressRedundantQwordCeiling));
        if (m0Beats < fallbackAttributedQwordBeats ||
            scaledM0Beats < kPhaseTolerantM0Floor ||
            scaledM0Beats > kM0PayloadCeiling)
            fail("stress_scaled_m0 raw=" + std::to_string(m0Beats) +
                 " fallback_attributed=" +
                 std::to_string(fallbackAttributedQwordBeats) +
                 " scaled=" + std::to_string(scaledM0Beats) +
                 " bounds=54912..70000");
        if (m0Beats + m1Beats < fallbackAttributedQwordBeats ||
            scaledSharedBeats > kHarnessSharedPayloadCeiling)
            fail("stress_scaled_shared raw=" +
                 std::to_string(m0Beats + m1Beats) +
                 " fallback_attributed=" +
                 std::to_string(fallbackAttributedQwordBeats) +
                 " scaled=" + std::to_string(scaledSharedBeats) +
                 " ceiling=100000");
    }
    if (refreshCycles < 1000 || gapCycles < 1000)
        fail("nonideal_stalls refresh_cycles=" +
             std::to_string(refreshCycles) +
             " burst_gap_cycles=" + std::to_string(gapCycles));
    if (m.ddrAfter.protocolErrors != 0)
        fail("DDR_protocol_errors=" +
             std::to_string(m.ddrAfter.protocolErrors));
    if (m.ddrAfter.minObservedLatency < 25 ||
        m.ddrAfter.maxObservedLatency < 60)
        fail("DDR_latency_range min=" +
             std::to_string(m.ddrAfter.minObservedLatency) + " max=" +
             std::to_string(m.ddrAfter.maxObservedLatency));
    if (sim.ddr.getStats().m1Reads != sim.ddr.getStats().m1Beats)
        fail("physical_m1_conservation reads=" +
             std::to_string(sim.ddr.getStats().m1Reads) + " beats=" +
             std::to_string(sim.ddr.getStats().m1Beats));
    if (sim.ddr.getStats().m0ExpectedBeats != sim.ddr.getStats().m0Beats ||
        sim.ddr.getStats().m1ExpectedBeats != sim.ddr.getStats().m1Beats)
        fail("physical_burst_conservation m0_expected=" +
             std::to_string(sim.ddr.getStats().m0ExpectedBeats) +
             " m0_seen=" + std::to_string(sim.ddr.getStats().m0Beats) +
             " m1_expected=" +
             std::to_string(sim.ddr.getStats().m1ExpectedBeats) +
             " m1_seen=" + std::to_string(sim.ddr.getStats().m1Beats));
    if (activeConfig) {
        if (refillCoverage.issuedYLines != 480 ||
            refillCoverage.issuedCLines != 240 ||
            refillCoverage.issuedPayloadBeats != kExactUniqueM0Payload)
            fail("settled_unique_m0_issues y_lines=" +
                 std::to_string(refillCoverage.issuedYLines) +
                 " c_lines=" +
                 std::to_string(refillCoverage.issuedCLines) +
                 " beats=" +
                 std::to_string(refillCoverage.issuedPayloadBeats) +
                 " expected=480/240/56160");
        if (refillCoverage.yLines != 480 ||
            refillCoverage.cLines != 240 ||
            refillCoverage.payloadBeats != kExactUniqueM0Payload)
            fail("settled_unique_m0_completions y_lines=" +
                 std::to_string(refillCoverage.yLines) +
                 " c_lines=" + std::to_string(refillCoverage.cLines) +
                 " beats=" +
                 std::to_string(refillCoverage.payloadBeats) +
                 " expected=480/240/56160");
        // swap_pending remains asserted during same-token preparation. A
        // stable display bank, not the pending level, defines this window.
        if (refillCoverage.displayBanks != 1 ||
            refillCoverage.settledSamples == 0)
            fail("settled_refill_window display_banks=" +
                 std::to_string(refillCoverage.displayBanks) +
                 " swap_pending_samples=" +
                 std::to_string(refillCoverage.swapPendingSamples) +
                 " samples=" +
                 std::to_string(refillCoverage.settledSamples));
        for (int plane = 0; plane < 2; ++plane) {
            const uint64_t classified =
                refill.firstFills[plane] +
                refill.residentDuplicates[plane] +
                refill.inflightDuplicates[plane] +
                refill.notNeeded[plane] +
                refill.sameWindowReloads[plane] +
                refill.legitimateSlidingReloads[plane];
            const uint64_t issueCompleteDelta =
                refill.issues[plane] > refill.completions[plane]
                    ? refill.issues[plane] - refill.completions[plane]
                    : refill.completions[plane] - refill.issues[plane];
            if (refill.issues[plane] == 0 ||
                classified != refill.issues[plane] ||
                issueCompleteDelta > 1)
                fail(std::string("refill_telemetry plane=") +
                     (plane ? "C" : "Y") +
                     " issues=" + std::to_string(refill.issues[plane]) +
                     " completions=" +
                     std::to_string(refill.completions[plane]) +
                     " classified=" + std::to_string(classified));
        }
        if (refill.invalidLineId != 0 ||
            refill.completionWithoutInflight != 0)
            fail("refill_telemetry_protocol invalid_line=" +
                 std::to_string(refill.invalidLineId) +
                 " completion_without_inflight=" +
                 std::to_string(refill.completionWithoutInflight));
    }

    if (activeConfig) {
        std::cout
            << "TRUE480_REFILL_TELEMETRY"
            << " proof_mode="
            << (acceleratedFallbackStress ? "fallback_stress" : "product")
            << " fallback_fires=" << refill.fallbackFires
            << " effective_fallback_fires=" << effectiveFallbackFires
            << " fault_unbounded_fallback=" << faultUnboundedFallback
            << " fallback_attributed_lines=" << fallbackAttributedLines
            << " fallback_attributed_qword_beats="
            << fallbackAttributedQwordBeats
            << " total_issues=" << totalIssues
            << " legitimate=" << legitimate
            << " unique_y_issued=" << refillCoverage.issuedYLines
            << " unique_c_issued=" << refillCoverage.issuedCLines
            << " unique_issued_payload_beats="
            << refillCoverage.issuedPayloadBeats
            << " unique_y_lines=" << refillCoverage.yLines
            << " unique_c_lines=" << refillCoverage.cLines
            << " unique_payload_beats=" << refillCoverage.payloadBeats
            << " settled_display_banks=" << refillCoverage.displayBanks
            << " settled_swap_pending_samples="
            << refillCoverage.swapPendingSamples
            << " settled_samples=" << refillCoverage.settledSamples
            << " redundant=" << redundant
            << " redundant_permille="
            << (totalIssues ? redundant * 1000 / totalIssues : 0)
            << " redundant_qword_beats=" << redundant * 78
            << " stale_total=" << stale
            << " same_window_total=" << sameWindow
            << " y_issues=" << refill.issues[0]
            << " y_completions=" << refill.completions[0]
            << " c_issues=" << refill.issues[1]
            << " c_completions=" << refill.completions[1]
            << " y_first=" << refill.firstFills[0]
            << " c_first=" << refill.firstFills[1]
            << " y_resident_dup=" << refill.residentDuplicates[0]
            << " c_resident_dup=" << refill.residentDuplicates[1]
            << " y_other_slot_copy=" << refill.otherSlotCopies[0]
            << " c_other_slot_copy=" << refill.otherSlotCopies[1]
            << " y_inflight_dup=" << refill.inflightDuplicates[0]
            << " c_inflight_dup=" << refill.inflightDuplicates[1]
            << " y_not_needed=" << refill.notNeeded[0]
            << " c_not_needed=" << refill.notNeeded[1]
            << " y_not_newly_needed=" << refill.notNewlyNeeded[0]
            << " c_not_newly_needed=" << refill.notNewlyNeeded[1]
            << " y_stale_replay=" << refill.stalePipelineReplays[0]
            << " c_stale_replay=" << refill.stalePipelineReplays[1]
            << " y_same_window_reload=" << refill.sameWindowReloads[0]
            << " c_same_window_reload=" << refill.sameWindowReloads[1]
            << " y_legit_sliding_reload="
            << refill.legitimateSlidingReloads[0]
            << " c_legit_sliding_reload="
            << refill.legitimateSlidingReloads[1]
            << " y_sched_replay=" << refill.schedReplayIssues[0]
            << " c_sched_replay=" << refill.schedReplayIssues[1]
            << " y_combo_need=" << refill.comboStillNeeded[0]
            << " c_combo_need=" << refill.comboStillNeeded[1]
            << " y_current=" << refill.currentIssues[0]
            << " c_current=" << refill.currentIssues[1]
            << " y_pending=" << refill.pendingIssues[0]
            << " c_pending=" << refill.pendingIssues[1]
            << " y_sched_for_pending=" << refill.scheduledForPending[0]
            << " c_sched_for_pending=" << refill.scheduledForPending[1]
            << " need_snapshot_mismatch=" << refill.wrapperNeedMismatch
            << "\n";
        sim.refill.printDetail();
    }

    std::cout
        << "TRUE480_SHARED_DDR line_count="
        << static_cast<int>(sim.top.cfg_line_count)
        << " linebuf_bits=" << sim.top.cfg_linebuf_bits
        << " m10k_estimate=" << sim.top.cfg_m10k_estimate
        << " active=" << m.active << " visible=" << m.visible
        << " unique_rows=" << m.rows.size()
        << " y_hits=" << m.yHits << " c_hits=" << m.cHits
        << " soft_c=" << m.softC
        << " underrun_delta=" << (m.underrunAfter - m.underrunBefore)
        << " orange=" << m.orange << " dark=" << m.dark
        << " m0_beats=" << m0Beats << " m1_reads=" << m1Reads
        << " m1_responses=" << m1Responses << " m1_beats=" << m1Beats
        << " m1_want_cycles=" << m1WantCycles
        << " m1_band=CALIBRATED_CLEAN_4C4667CA_PRODUCT4096"
        << " m1_reference_reads=" << kCleanReferenceM1Reads
        << " m1_reference_want_cycles=" << kCleanReferenceM1WantCycles
        << " m0_phase_floor=" << kPhaseTolerantM0Floor
        << " m0_ceiling=" << kM0PayloadCeiling
        << " m0_payload_overhead="
        << (m0Beats >= kExactUniqueM0Payload
                ? m0Beats - kExactUniqueM0Payload
                : 0)
        << " shared_beats=" << m0Beats + m1Beats
        << " proof_mode="
        << (acceleratedFallbackStress ? "fallback_stress" : "product")
        << " fallback_fires=" << refill.fallbackFires
        << " fallback_attributed_qword_beats="
        << fallbackAttributedQwordBeats
        << " scaled_m0_beats=" << scaledM0Beats
        << " scaled_shared_beats=" << scaledSharedBeats
        << " shared_ceiling=" << kHarnessSharedPayloadCeiling
        << " shared_ceiling_scope=HARNESS_ONLY"
        << " lc8_contract=EXACT"
        << " refresh_stall_cycles=" << refreshCycles
        << " burst_gap_cycles=" << gapCycles
        << " latency_min=" << m.ddrAfter.minObservedLatency
        << " latency_max=" << m.ddrAfter.maxObservedLatency
        << "\n";
    if (ok)
        std::cout << "PASS true480 shared real_arbiter stride1_480 "
                     "periodic_STREAM nonideal_DDR no_steady_underrun\n";
    return ok ? 0 : 1;
}

} // namespace

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    bool ideal = false;
    bool resourceOnly = false;
    bool requireActiveConfig = false;
    bool acceleratedFallbackStress = false;
    bool faultUnboundedFallback = false;
    for (int i = 1; i < argc; ++i) {
        const std::string arg = argv[i];
        if (arg == "--ideal-ddr")
            ideal = true;
        else if (arg == "--resource-only")
            resourceOnly = true;
        else if (arg == "--require-active-config")
            requireActiveConfig = true;
        else if (arg == "--accelerated-fallback-stress")
            acceleratedFallbackStress = true;
        else if (arg == "--fault-unbounded-fallback")
            faultUnboundedFallback = true;
        else {
            std::cerr << "unknown argument: " << arg << "\n";
            return 2;
        }
    }
    if (acceleratedFallbackStress && !requireActiveConfig) {
        std::cerr << "accelerated fallback stress requires active config\n";
        return 2;
    }
    if (faultUnboundedFallback && !acceleratedFallbackStress) {
        std::cerr << "unbounded fallback fault requires stress mode\n";
        return 2;
    }
    try {
        return runProof(ideal, resourceOnly, requireActiveConfig,
                        acceleratedFallbackStress,
                        faultUnboundedFallback);
    } catch (const std::exception& e) {
        std::cerr << "FAIL true480 shared exception: " << e.what() << "\n";
        return 1;
    }
}
