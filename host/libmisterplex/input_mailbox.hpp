#pragma once
// Core -> HPS playback input mailbox constants.
//
// The daemon must read these from DDR; it must not poll keyboard/controller
// state through SPI because MiSTer Main owns the HPS<->FPGA SPI handshake.

#include <cstdint>

namespace misterplex {

constexpr uint32_t kDdrStatusMailboxPhys = 0x3007F100u;
constexpr uint32_t kDdrStatusMailboxMagic = 0x504C5853u; // "PLXS"
constexpr uint32_t kInputMailboxPhys = 0x3007F108u;
constexpr uint32_t kInputMailboxMagic = 0x504C5849u; // "PLXI"
constexpr uint32_t kMemtestMailboxPhys = 0x3007F110u;
constexpr uint32_t kMemtestMailboxMagic = 0x504C584Du; // "PLXM"
constexpr uint32_t kUnderrunMailboxPhys = 0x3007F118u;
constexpr uint32_t kUnderrunMailboxMagic = 0x504C5846u; // "PLXF"
constexpr uint32_t kBankReleaseMailboxPhys = 0x3007F128u;
constexpr uint32_t kBankReleaseMailboxMagic = 0x504C5844u; // "PLXD" (display-bank)
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
// Layout (64 bits at kBankReleaseMailboxPhys = 0x3007F128):
//   [31:0]   magic 0x504C5844 "PLXD"
//   [33:32]  free_bank_mask[1:0] — bit i = 1 means bank i is safe to overwrite
//   [34]     disp_bank           — currently displayed bank (0 or 1)
//   [35]     swap_pending        — a doorbell was received, vsync flip pending
//   [47:36]  reserved
//   [63:48]  frames_done[15:0]   — monotonic bank-swap counter (wraps at 65535)
//
// ARM protocol:
//   1. Read PLXD. If free_bank_mask has a set bit, write to that bank.
//   2. If free_bank_mask == 0, poll at 1ms intervals up to 50ms (~3 vsyncs).
//   3. If timeout: log STALL loudly. Do NOT silently fall back to a delay.
//   4. Ring PLXK doorbell with the bank just written.
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

inline bool decodeBankReleaseWord(uint64_t word, BankReleaseStatus& out) {
    if (static_cast<uint32_t>(word) != kBankReleaseMailboxMagic)
        return false;
    out.free_bank_mask = static_cast<uint8_t>((word >> 32) & 0x03u);
    out.disp_bank = static_cast<uint8_t>((word >> 34) & 1u);
    out.swap_pending = ((word >> 35) & 1u) != 0;
    out.frames_done = static_cast<uint16_t>((word >> 48) & 0xFFFFu);
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
