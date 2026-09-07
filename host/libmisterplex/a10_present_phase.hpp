#pragma once
#ifndef MPX_A10_PRESENT_PHASE
#define MPX_A10_PRESENT_PHASE 0
#endif
#if MPX_A10_PRESENT_PHASE != 0 && MPX_A10_PRESENT_PHASE != 1
#error MPX_A10_PRESENT_PHASE must be 0 or 1
#endif

#if MPX_A10_PRESENT_PHASE
#include "libmisterplex/audio_session.hpp"
#include "libmisterplex/ddr_bitstream_ring.hpp"
#include "libmisterplex/input_mailbox.hpp"
#include <array>
#include <cstdint>

namespace misterplex::a10_phase {
constexpr uint32_t kBuild = 0x390fd76b;
// The fitted a10 uses fstore's default mailbox parameters. The +0x128
// DOORBELL-relative override is inside PLEX_PRESENT_720P_L4, which a10 lacks.
constexpr uint32_t kBankAddress = 0x3007f128;
constexpr uint32_t kFrameAddress = 0x3007f118;
constexpr size_t kCapacity = 32768;

enum Valid : uint32_t {
    Caps = 1, Bank = 2, Frame = 4, Mast = 8, Mvps = 16,
    LiveEpoch = 32, BankRefreshObserved = 64, FrozenAck = 128
};
struct Input {
    bool capsRead = false, bankRead = false, frameRead = false;
    bool mastRead = false, mvpsRead = false;
    ddr_bitstream_ring::VideoCapabilities caps{};
    BankReleaseStatus bank{};
    FrameStoreStatus frame{};
    audio_session::Status mast{};
    ddr_bitstream_ring::VideoPresentation mvps{};
};
struct Record {
    int64_t beforeUs = 0, afterUs = 0;
    uint64_t session = 0, nonce = 0, liveConsumed = 0, frozenAtAck = 0;
    int64_t originalPts = 0;
    uint32_t valid = 0, presentationCount = 0, auSequence = 0;
    uint32_t presentationPublication = 0, mastPublication = 0;
    uint32_t timebaseNum = 0, timebaseDen = 0;
    uint16_t refreshCount = 0, underruns = 0;
    uint8_t bankBits = 0, frameState = 0, audioBits = 0, audioError = 0;
};

class Observer {
public:
    Record sample(const Input& in, int64_t before, int64_t after) noexcept {
        Record r;
        r.beforeUs = before; r.afterUs = after;
        if (in.capsRead && in.caps.supportsVideo() && in.caps.build_id == kBuild) {
            r.valid |= Caps;
            r.nonce = in.caps.nonce;
        }
        const bool bankValid = in.bankRead && in.bank.disp_bank <= 1 &&
            in.bank.free_bank_mask == (in.bank.swap_pending ? 0 : (in.bank.disp_bank ? 1 : 2));
        if (bankValid) {
            r.valid |= Bank;
            r.refreshCount = in.bank.frames_done; // a10 RTL: VSYNC count, NOT swaps.
            r.bankBits = in.bank.free_bank_mask | (in.bank.disp_bank << 2) |
                         (unsigned(in.bank.swap_pending) << 3);
        }
        if (in.frameRead) {
            r.valid |= Frame;
            r.frameState = in.frame.debug_state;
            r.underruns = in.frame.underrun_count;
        }
        if (in.mastRead && (r.valid & Caps) && in.mast.supported &&
            in.mast.nonce == r.nonce) {
            r.valid |= Mast;
            r.session = in.mast.session_id;
            r.liveConsumed = in.mast.samples_consumed;
            r.mastPublication = in.mast.publication;
            r.audioBits = unsigned(in.mast.active) | (unsigned(in.mast.paused) << 1) |
                          (unsigned(in.mast.read_pending) << 2) | (unsigned(in.mast.prefetched) << 3);
            r.audioError = in.mast.error;
        }
        const bool active = (r.valid & Mast) && in.mast.active && !in.mast.error && r.session != 0;
        if (!active || r.session != session_ || r.nonce != nonce_) {
            session_ = active ? r.session : 0;
            nonce_ = active ? r.nonce : 0;
            mastSeen_ = false;
            bankSeen_ = false;
            live_ = false;
            bankLive_ = false;
        }
        if (active) {
            if (mastSeen_ && r.mastPublication != lastMast_) live_ = true;
            lastMast_ = r.mastPublication;
            mastSeen_ = true;
            if (live_) r.valid |= LiveEpoch;
            if (bankValid) {
                if (bankSeen_ && r.refreshCount != lastRefresh_) bankLive_ = true;
                lastRefresh_ = r.refreshCount;
                bankSeen_ = true;
                if (live_ && bankLive_) r.valid |= BankRefreshObserved;
            }
        }
        if (in.mvpsRead && active && in.mvps.active && in.mvps.has_frame &&
            !in.mvps.error && in.mvps.session_id == r.session && in.mvps.nonce == r.nonce) {
            r.valid |= Mvps;
            r.presentationCount = in.mvps.presentation_count;
            r.auSequence = in.mvps.seq;
            r.presentationPublication = in.mvps.publication;
            r.originalPts = in.mvps.pts;
            r.timebaseNum = in.mvps.timebase_num;
            r.timebaseDen = in.mvps.timebase_den;
            if (in.mvps.has_audio_clock) {
                r.valid |= FrozenAck;
                r.frozenAtAck = in.mvps.audio_samples_consumed;
            }
        }
        return r;
    }
private:
    uint64_t session_ = 0, nonce_ = 0;
    uint32_t lastMast_ = 0;
    uint16_t lastRefresh_ = 0;
    bool mastSeen_ = false, bankSeen_ = false, live_ = false, bankLive_ = false;
};

template<size_t Capacity = kCapacity>
class Collector {
public:
    void add(const Record& r) noexcept {
        ++attempted;
        // Consumption changes do not flood storage. Retain phase/validity
        // transitions and at least a 10ms heartbeat, independently of AV_TRACE.
        const bool changed = !have_ || r.valid != last_.valid || r.session != last_.session ||
            r.nonce != last_.nonce || r.bankBits != last_.bankBits ||
            r.refreshCount != last_.refreshCount || r.presentationCount != last_.presentationCount ||
            r.presentationPublication != last_.presentationPublication ||
            r.audioBits != last_.audioBits || r.audioError != last_.audioError ||
            r.underruns != last_.underruns;
        if (!changed && r.afterUs - last_.afterUs < 10000) { ++sampledOut; return; }
        last_ = r; have_ = true;
        if (retained == Capacity) { ++dropped; return; }
        records[retained++] = r;
    }
    std::array<Record, Capacity> records{};
    uint64_t attempted = 0, sampledOut = 0, retained = 0, dropped = 0;
private:
    Record last_{};
    bool have_ = false;
};
} // namespace misterplex::a10_phase
#endif
