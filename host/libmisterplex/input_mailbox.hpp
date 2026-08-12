#pragma once
// Core -> HPS playback input mailbox constants.
//
// The daemon must read these from DDR; it must not poll keyboard/controller
// state through SPI because MiSTer Main owns the HPS<->FPGA SPI handshake.
//
// Mailbox addresses and magics are defined ONCE in mailbox_abi_spec.hpp.
// This file re-exports them under the legacy names for backward compatibility,
// and provides the decoders for each mailbox.

#include <cstdint>
#include "mailbox_abi_spec.hpp"

namespace misterplex {

// Re-export from the single-source-of-truth spec.
constexpr uint32_t kDdrStatusMailboxPhys   = mailbox_abi::kPlxsAddr;
constexpr uint32_t kDdrStatusMailboxMagic  = mailbox_abi::kPlxsMagic;
constexpr uint32_t kInputMailboxPhys       = mailbox_abi::kPlxiAddr;
constexpr uint32_t kInputMailboxMagic      = mailbox_abi::kPlxiMagic;
constexpr uint32_t kMemtestMailboxPhys     = mailbox_abi::kPlxmAddr;
constexpr uint32_t kMemtestMailboxMagic    = mailbox_abi::kPlxmMagic;
constexpr uint32_t kUnderrunMailboxPhys    = mailbox_abi::kPlxfAddr;
constexpr uint32_t kUnderrunMailboxMagic   = mailbox_abi::kPlxfMagic;
constexpr uint32_t kBankReleaseMailboxPhys  = mailbox_abi::kPlxdAddr;
constexpr uint32_t kBankReleaseMailboxMagic = mailbox_abi::kPlxdMagic;
constexpr uint8_t kFrameStoreDebugFormatError = 0xE1;

enum class PlaybackCommand : uint8_t {
    None = 0,
    PlayPause = 1,
    Stop = 2,
    SkipForward = 3,
    SkipBack = 4,
};

struct InputMailboxSample {
    uint16_t seq = 0;
    uint8_t cmdSeq = 0;
    PlaybackCommand command = PlaybackCommand::None;
};

struct FrameStoreStatus {
    uint8_t seq = 0;
    uint8_t debug_state = 0;
    uint16_t underrun_count = 0;

    bool nonYuvDoorbellRejected() const {
        return debug_state == kFrameStoreDebugFormatError;
    }
};

inline const char* frameStoreDebugDescription(uint8_t debug) {
    if (debug == kFrameStoreDebugFormatError)
        return "frame store refused non-YUV doorbell (0xE1)";
    return "frame store debug state";
}

inline const char* frameStoreStatusUnavailableDescription() {
    return "frame store status unavailable (PLXF mailbox absent/unwritten)";
}

// PLXD — FPGA→ARM bank-release acknowledgement.
//
// The FPGA publishes which DDR frame bank the ARM may safely overwrite.
// Without this, the ARM must use a fixed delay to avoid overwriting a bank
// the FPGA is still reading — which is a timing-based MITIGATION, not a
// handshake. PLXD makes it a real handshake.
//
// Layout: see mailbox_abi_spec.hpp (SINGLE SOURCE OF TRUTH).
//
// ARM protocol:
//   1. First strict write may use the current free_bank_mask.
//   2. Retain the swap counter from the release sample that authorized the
//      payload copy, then publish it as the baseline only after PLXK succeeds.
//   3. Before each later strict write, require anyFree and frames_done != the
//      pre-kick release baseline; poll at 1ms intervals up to 50ms.
//   4. If timeout: log STALL loudly. Do NOT silently fall back to a delay.
struct BankReleaseStatus {
    uint8_t free_bank_mask = 0; // bit 0 = bank 0 free, bit 1 = bank 1 free
    uint8_t disp_bank = 0;     // 0 or 1
    bool swap_pending = false;
    uint16_t frames_done = 0;  // monotonic swap count

    bool bank0Free() const { return free_bank_mask & 1u; }
    bool bank1Free() const { return (free_bank_mask >> 1) & 1u; }
    bool anyFree() const { return free_bank_mask != 0; }
    // Pick the lowest-numbered free bank, or -1 if none free.
    int freeBank() const {
        if (free_bank_mask & 1u) return 0;
        if (free_bank_mask & 2u) return 1;
        return -1;
    }
};

inline uint16_t frameCounterDelta(uint16_t newer, uint16_t older) {
    return static_cast<uint16_t>(newer - older);
}

inline bool hardwarePresentCountMatches(uint16_t startFrames, uint16_t endFrames,
                                        int64_t startArmPresents,
                                        int64_t endArmPresents,
                                        int64_t tolerance = 2) {
    const int64_t hardware = frameCounterDelta(endFrames, startFrames);
    const int64_t arm = endArmPresents - startArmPresents;
    const int64_t difference = hardware > arm ? hardware - arm : arm - hardware;
    return arm >= 0 && tolerance >= 0 && difference <= tolerance;
}

inline bool hardwarePresentTotalsMatch(uint64_t hardwarePresents,
                                       int64_t armPresents,
                                       int64_t tolerance = 2) {
    if (armPresents < 0 || tolerance < 0)
        return false;
    const uint64_t arm = static_cast<uint64_t>(armPresents);
    const uint64_t difference =
        hardwarePresents > arm ? hardwarePresents - arm : arm - hardwarePresents;
    return difference <= static_cast<uint64_t>(tolerance);
}

enum class DdrBankWritePolicy {
    BestEffort,      // legacy/diagnostic paths may reuse the non-display bank
    RequireReleased, // true480 waits for free bank + prior frames_done advance
};

struct DdrBankWriteDecision {
    bool ready = false;
    int bank = -1;
};

struct DdrStrictReleaseState {
    bool baseline_valid = false;
    bool baseline_pending = false;
    uint16_t frames_done = 0;

    void reset() {
        baseline_valid = false;
        baseline_pending = false;
        frames_done = 0;
    }

    void beginWrite() { baseline_pending = true; }

    void noteWrite(const BankReleaseStatus& status) {
        baseline_valid = true;
        baseline_pending = false;
        frames_done = status.frames_done;
    }

    bool acknowledgesPreviousWrite(const BankReleaseStatus& status) const {
        // frames_done is 16-bit. Any different value is a newer acknowledgement,
        // including 0 after 0xffff wrap; equality is the stale-mailbox case.
        return !baseline_pending && (!baseline_valid || status.frames_done != frames_done);
    }
};

inline DdrBankWriteDecision decideDdrBankWrite(const BankReleaseStatus& status,
                                                DdrBankWritePolicy policy,
                                                const DdrStrictReleaseState& strictState) {
    if (status.anyFree()) {
        if (policy == DdrBankWritePolicy::RequireReleased &&
            !strictState.acknowledgesPreviousWrite(status))
            return {false, -1};
        return {true, status.freeBank()};
    }
    if (policy == DdrBankWritePolicy::RequireReleased)
        return {false, -1};
    return {true, status.disp_bank ^ 1};
}

inline bool decodeBankReleaseWord(uint64_t word, BankReleaseStatus& out) {
    if (static_cast<uint32_t>(word) != kBankReleaseMailboxMagic)
        return false;
    const uint32_t hi = static_cast<uint32_t>(word >> 32);
    out.free_bank_mask = static_cast<uint8_t>(
        (hi >> mailbox_abi::kPlxdFreeBankMaskBit) &
        ((1u << mailbox_abi::kPlxdFreeBankMaskWidth) - 1u));
    out.disp_bank = static_cast<uint8_t>(
        (hi >> mailbox_abi::kPlxdDispBankBit) & 1u);
    out.swap_pending = ((hi >> mailbox_abi::kPlxdSwapPendingBit) & 1u) != 0;
    out.frames_done = static_cast<uint16_t>(
        (hi >> mailbox_abi::kPlxdFramesDoneBit) &
        ((1u << mailbox_abi::kPlxdFramesDoneWidth) - 1u));
    return true;
}

inline bool decodeStableBankRelease(uint32_t lo, uint32_t hi, uint32_t verifyLo,
                                    uint32_t verifyHi, BankReleaseStatus& out) {
    if (lo != verifyLo || hi != verifyHi)
        return false;
    const uint64_t word = static_cast<uint64_t>(lo) | (static_cast<uint64_t>(hi) << 32);
    return decodeBankReleaseWord(word, out);
}

enum class PlaybackActionKind {
    None,
    Pause,
    Resume,
    Stop,
    Seek,
};

struct PlaybackAction {
    PlaybackActionKind kind = PlaybackActionKind::None;
    int64_t seekTargetMs = 0;
};

struct PlaybackTransportState {
    bool playing = false;
    bool paused = false;
    int64_t positionMs = 0;
    int64_t durationMs = 0;
};

inline bool decodeInputMailboxWord(uint64_t word, InputMailboxSample& out) {
    if (static_cast<uint32_t>(word) != kInputMailboxMagic)
        return false;
    const uint8_t cmd = static_cast<uint8_t>((word >> 32) & 0xFFu);
    if (cmd > static_cast<uint8_t>(PlaybackCommand::SkipBack))
        return false;
    out.command = static_cast<PlaybackCommand>(cmd);
    out.cmdSeq = static_cast<uint8_t>((word >> 40) & 0xFFu);
    out.seq = static_cast<uint16_t>((word >> 48) & 0xFFFFu);
    return true;
}

inline bool decodeStableInputMailbox(uint32_t lo, uint32_t hi, uint32_t verifyLo,
                                     uint32_t verifyHi, InputMailboxSample& out) {
    if (lo != verifyLo || hi != verifyHi)
        return false;
    const uint64_t word = static_cast<uint64_t>(lo) | (static_cast<uint64_t>(hi) << 32);
    return decodeInputMailboxWord(word, out);
}

inline bool decodeFrameStoreStatusWord(uint64_t word, FrameStoreStatus& out) {
    if (static_cast<uint32_t>(word) != kUnderrunMailboxMagic)
        return false;
    out.seq = static_cast<uint8_t>((word >> 32) & 0xFFu);
    out.debug_state = static_cast<uint8_t>((word >> 40) & 0xFFu);
    out.underrun_count = static_cast<uint16_t>((word >> 48) & 0xFFFFu);
    return true;
}

inline bool decodeStableFrameStoreStatus(uint32_t lo, uint32_t hi, uint32_t verifyLo,
                                         uint32_t verifyHi, FrameStoreStatus& out) {
    if (lo != verifyLo || hi != verifyHi)
        return false;
    const uint64_t word = static_cast<uint64_t>(lo) | (static_cast<uint64_t>(hi) << 32);
    return decodeFrameStoreStatusWord(word, out);
}

class InputMailboxEdgeDetector {
public:
    void reset() {
        seen_ = false;
        sawEmpty_ = false;
        seq_ = 0;
        cmdSeq_ = 0;
    }

    void noteNoValidWord() {
        if (!seen_)
            sawEmpty_ = true;
    }

    bool accept(const InputMailboxSample& sample, PlaybackCommand& command) {
        command = PlaybackCommand::None;
        if (!seen_) {
            seen_ = true;
            seq_ = sample.seq;
            cmdSeq_ = sample.cmdSeq;
            if (sawEmpty_ && sample.command != PlaybackCommand::None) {
                command = sample.command;
                return true;
            }
            return false;
        }

        const bool seqChanged = sample.seq != seq_;
        const bool cmdSeqChanged = sample.cmdSeq != cmdSeq_;
        seq_ = sample.seq;
        cmdSeq_ = sample.cmdSeq;
        if (!seqChanged || !cmdSeqChanged || sample.command == PlaybackCommand::None)
            return false;

        command = sample.command;
        return true;
    }

private:
    bool seen_ = false;
    bool sawEmpty_ = false;
    uint16_t seq_ = 0;
    uint8_t cmdSeq_ = 0;
};

inline PlaybackAction mapPlaybackCommand(PlaybackCommand command, bool playing, bool paused,
                                         int64_t positionMs, int64_t durationMs,
                                         int64_t skipForwardMs, int64_t skipBackMs) {
    PlaybackAction action;
    if (!playing)
        return action;
    if (positionMs < 0)
        positionMs = 0;

    switch (command) {
    case PlaybackCommand::PlayPause:
        action.kind = paused ? PlaybackActionKind::Resume : PlaybackActionKind::Pause;
        return action;
    case PlaybackCommand::Stop:
        action.kind = PlaybackActionKind::Stop;
        return action;
    case PlaybackCommand::SkipForward:
        action.kind = PlaybackActionKind::Seek;
        action.seekTargetMs = positionMs + (skipForwardMs > 0 ? skipForwardMs : 0);
        if (durationMs > 0 && action.seekTargetMs > durationMs)
            action.seekTargetMs = durationMs;
        if (action.seekTargetMs == positionMs)
            action.kind = PlaybackActionKind::None;
        return action;
    case PlaybackCommand::SkipBack:
        action.kind = PlaybackActionKind::Seek;
        action.seekTargetMs = positionMs - (skipBackMs > 0 ? skipBackMs : 0);
        if (action.seekTargetMs < 0)
            action.seekTargetMs = 0;
        if (action.seekTargetMs == positionMs)
            action.kind = PlaybackActionKind::None;
        return action;
    case PlaybackCommand::None:
        return action;
    }
    return action;
}

inline bool playbackInputSuppressed(int64_t nowMs, int64_t ignoreUntilMs) {
    return nowMs < ignoreUntilMs;
}

template <typename Transport>
inline PlaybackAction dispatchPlaybackCommand(PlaybackCommand command,
                                              const PlaybackTransportState& state,
                                              int64_t skipForwardMs, int64_t skipBackMs,
                                              int64_t nowMs, int64_t ignoreUntilMs,
                                              Transport& transport) {
    PlaybackAction action;
    if (playbackInputSuppressed(nowMs, ignoreUntilMs))
        return action;

    action = mapPlaybackCommand(command, state.playing, state.paused, state.positionMs,
                                state.durationMs, skipForwardMs, skipBackMs);
    switch (action.kind) {
    case PlaybackActionKind::Pause:
        transport.pause();
        break;
    case PlaybackActionKind::Resume:
        transport.resume();
        break;
    case PlaybackActionKind::Stop:
        transport.stop();
        break;
    case PlaybackActionKind::Seek:
        transport.seekMs(action.seekTargetMs);
        break;
    case PlaybackActionKind::None:
        break;
    }
    return action;
}

} // namespace misterplex
