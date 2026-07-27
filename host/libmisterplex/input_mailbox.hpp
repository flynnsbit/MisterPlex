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
constexpr uint32_t kBankReleaseMailboxMagic = 0x504C5841u; // "PLXA" (PLX Ack)
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

// PLXA — FPGA→ARM bank-release acknowledgement.
//
// The FPGA publishes which DDR frame bank the ARM may safely overwrite.
// Without this, the ARM must use a fixed delay to avoid overwriting a bank
// the FPGA is still reading — which is a timing-based MITIGATION, not a
// handshake. PLXA makes it a real handshake.
//
// Layout (64 bits at kBankReleaseMailboxPhys = 0x3007F128):
//   [31:0]   magic 0x504C5841 "PLXA"
//   [32]     free_bank index (0 or 1) — the bank NOT being read
//   [39]     free_bank valid (1 = safe to write; 0 = both banks in use)
//   [38:33]  reserved (0)
//   [40]     disp_bank index (currently displayed)
//   [47:41]  reserved (0)
//   [63:48]  vsync_count[15:0] — monotonic, increments every vsync_pulse
//
// Semantics:
//   !swap_pending → valid=1, free_bank=~disp_bank
//   swap_pending  → valid=0 (both banks in use)
//   On vsync swap: old disp_bank becomes free, valid=1, vsync_count++
//   On idle vsync: vsync_count++ still increments (forward-progress)
//
// ARM protocol:
//   1. Read PLXA. If valid=1, write frame to free_bank.
//   2. If valid=0, poll at 1ms intervals up to 50ms (~3 vsyncs at 60Hz).
//   3. If timeout: log STALL loudly. Do NOT silently fall back to a delay.
//   4. Ring PLXK doorbell with the bank just written.
struct BankReleaseStatus {
    uint8_t free_bank = 0;     // 0 or 1
    bool free_bank_valid = false;
    uint8_t disp_bank = 0;    // 0 or 1
    uint16_t vsync_count = 0;
};

inline bool decodeBankReleaseWord(uint64_t word, BankReleaseStatus& out) {
    if (static_cast<uint32_t>(word) != kBankReleaseMailboxMagic)
        return false;
    const uint8_t fb = static_cast<uint8_t>((word >> 32) & 0xFFu);
    out.free_bank = fb & 1u;
    out.free_bank_valid = ((fb >> 7) & 1u) != 0;
    out.disp_bank = static_cast<uint8_t>((word >> 40) & 1u);
    out.vsync_count = static_cast<uint16_t>((word >> 48) & 0xFFFFu);
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
