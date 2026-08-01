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

// Re-export magics + *legacy example* absolute addrs from the spec.
// Runtime consumers: prefer k*Offset + frameStoreMailboxPhys(doorbell).
constexpr uint32_t kDdrStatusMailboxPhys   = mailbox_abi::kPlxsAddr;
constexpr uint32_t kDdrStatusMailboxMagic  = mailbox_abi::kPlxsMagic;
constexpr uint32_t kInputMailboxPhys       = mailbox_abi::kPlxiAddr;
constexpr uint32_t kInputMailboxMagic      = mailbox_abi::kPlxiMagic;
constexpr uint32_t kMemtestMailboxPhys     = mailbox_abi::kPlxmAddr;
constexpr uint32_t kMemtestMailboxMagic    = mailbox_abi::kPlxmMagic;
constexpr uint32_t kUnderrunMailboxPhys    = mailbox_abi::kPlxfAddr;
constexpr uint32_t kUnderrunMailboxMagic   = mailbox_abi::kPlxfMagic;
// Legacy absolute PLXD (0x3007F128). Do NOT use for product doorbell 0x300FF000.
constexpr uint32_t kBankReleaseMailboxPhys  = mailbox_abi::kPlxdAddr;
constexpr uint32_t kBankReleaseMailboxMagic = mailbox_abi::kPlxdMagic;
constexpr uint8_t kFrameStoreDebugFormatError = 0xE1;

// Offsets from live DOORBELL_PHYS (RTL: DOORBELL_PHYS + offset).
constexpr uint32_t kDdrStatusMailboxOffset = mailbox_abi::kPlxsOffset;
constexpr uint32_t kInputMailboxOffset = mailbox_abi::kPlxiOffset;
constexpr uint32_t kMemtestMailboxOffset = mailbox_abi::kPlxmOffset;
constexpr uint32_t kUnderrunMailboxOffset = mailbox_abi::kPlxfOffset;
constexpr uint32_t kBankReleaseMailboxOffset = mailbox_abi::kPlxdOffset;

// Resolve a frame-store control mailbox against the active doorbell.
inline constexpr uint32_t frameStoreMailboxPhys(uint32_t doorbell_phys, uint32_t offset) {
    return mailbox_abi::frameStoreMailboxPhys(doorbell_phys, offset);
}
inline constexpr uint32_t bankReleaseMailboxPhys(uint32_t doorbell_phys) {
    return frameStoreMailboxPhys(doorbell_phys, kBankReleaseMailboxOffset);
}
inline constexpr uint32_t underrunMailboxPhys(uint32_t doorbell_phys) {
    return frameStoreMailboxPhys(doorbell_phys, kUnderrunMailboxOffset);
}
inline constexpr uint32_t statusMailboxPhys(uint32_t doorbell_phys) {
    return frameStoreMailboxPhys(doorbell_phys, kDdrStatusMailboxOffset);
}
inline constexpr uint32_t inputMailboxPhys(uint32_t doorbell_phys) {
    return frameStoreMailboxPhys(doorbell_phys, kInputMailboxOffset);
}

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
//   1. Read PLXD. If free_bank_mask has a set bit, write to that bank.
//   2. If free_bank_mask == 0, poll at 1ms intervals up to 50ms (~3 vsyncs).
//   3. If timeout: log STALL loudly. Do NOT silently fall back to a delay.
//   4. Ring PLXK doorbell with the bank just written.
struct BankReleaseStatus {
    uint8_t free_bank_mask = 0; // bit 0 = bank 0 free, bit 1 = bank 1 free
    uint8_t disp_bank = 0;     // 0 or 1
    bool swap_pending = false;
    // Derivation depends on fitted RTL pack of PLXD[63:48]:
    //   tip source: frames_done_d2 (real bank swaps) — NOT YET on c5382bee daily RBF
    //   c5382bee:   bank_vsync_count (every vsync) — do NOT treat as swap proof
    uint16_t frames_done = 0;

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
