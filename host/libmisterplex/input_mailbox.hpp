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
//   1. Read PLXD. If free_bank_mask has a set bit, write to that bank.
//   2. If free_bank_mask == 0, poll for a bounded vsync window.
//   3. If frames_done advances but free_bank_mask stays 0, the current RTL is
//      the known stale-release silicon; fall back to host-timed bank reuse.
//   4. If the timeout expires without proving stale-release silicon, skip the
//      frame rather than guessing a bank that future fixed RTL says is in use.
//   5. Ring PLXK doorbell with the bank just written.
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

enum class BankReleaseDecisionKind {
    UseFreeBank,
    UseTimedFallback,
    SkipFrame,
};

struct BankReleaseDecision {
    BankReleaseDecisionKind kind = BankReleaseDecisionKind::SkipFrame;
    int bank = -1;
    bool release_stuck = false;
};

struct BankReleasePolicyState {
    bool release_stuck = false;
};

inline int displayAvoidingFallbackBank(const BankReleaseStatus& status) {
    return (static_cast<int>(status.disp_bank) ^ 1) & 1;
}

// Which bank the fabric is scanning, derived from host state alone.
//
// RTL contract (fpga/Plex_MiSTer/rtl/ddr_frame_store.sv): line 208 resets
// disp_bank to 1'b0, and line 238 is the only assignment that changes it —
// disp_bank <= pending_bank on swap, where pending_bank is what the host
// commanded in the doorbell. So the scanned bank is the last bank the host
// successfully doorbelled, or bank 0 before any doorbell has been issued.
//
// This deliberately does NOT read BankReleaseStatus::disp_bank. On a
// permanently silent fabric that field is boot residue or zero, so a policy
// derived from it is a true statement about a dead instrument. Host doorbell
// history stays correct whether the mailbox is live, stale, or never written.
inline int scannedBankFromHostDoorbell(int lastDoorbelledBank) {
    return (lastDoorbelledBank < 0) ? 0 : (lastDoorbelledBank & 1);
}

// Structural interlock for the timed fallback: never write the bank that is
// currently being scanned out. Unlike the same-bank reuse floor this is not a
// timing guess — no elapsed time makes it safe to overwrite the live bank.
inline int silentFabricFallbackBank(int plannedBank, int lastDoorbelledBank) {
    const int scanned = scannedBankFromHostDoorbell(lastDoorbelledBank);
    const int planned = plannedBank & 1;
    return (planned == scanned) ? (scanned ^ 1) : planned;
}

inline BankReleaseDecision chooseDdrPresentBankFromRelease(BankReleasePolicyState& state,
                                                           int plannedBank,
                                                           const BankReleaseStatus& initial,
                                                           const BankReleaseStatus& final) {
    (void)plannedBank;
    BankReleaseDecision out{};
    out.release_stuck = state.release_stuck;

    if (state.release_stuck) {
        if (initial.anyFree()) {
            state.release_stuck = false;
            out.kind = BankReleaseDecisionKind::UseFreeBank;
            out.bank = initial.freeBank();
            out.release_stuck = false;
            return out;
        }
        out.kind = BankReleaseDecisionKind::UseTimedFallback;
        out.bank = displayAvoidingFallbackBank(initial);
        out.release_stuck = true;
        return out;
    }

    if (initial.anyFree()) {
        out.kind = BankReleaseDecisionKind::UseFreeBank;
        out.bank = initial.freeBank();
        out.release_stuck = false;
        return out;
    }
    if (final.anyFree()) {
        out.kind = BankReleaseDecisionKind::UseFreeBank;
        out.bank = final.freeBank();
        out.release_stuck = false;
        return out;
    }

    if (final.frames_done != initial.frames_done) {
        state.release_stuck = true;
        out.kind = BankReleaseDecisionKind::UseTimedFallback;
        out.bank = displayAvoidingFallbackBank(final);
        out.release_stuck = true;
        return out;
    }

    out.kind = BankReleaseDecisionKind::SkipFrame;
    out.bank = -1;
    out.release_stuck = false;
    return out;
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
