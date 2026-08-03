#pragma once
// Shared bank producer ordering (w-mem fabric ↔ w-path PL330/HPS).
// Absolute: credit → fill → payload_visible → ONE doorbell. Never reverse.
// Mirrors ddr_zero_copy_ingest.hpp phases; fabric_bank_credit.sv + host_bank_ingest_credit.sv
// enforce the same scoreboard on the fabric side.

#include "libmisterplex/ddr_frame_layout.hpp"
#include "libmisterplex/ddr_publish_barrier.hpp"
#include "libmisterplex/fabric_bank_credit.hpp"

#include <cstdint>
#include <string>

namespace misterplex {

enum class BankProducerPhase : uint8_t {
    Idle = 0,
    AwaitCredit = 1,
    Filling = 2,         // exclusive claim held; mid-fill (DMA chunks OK)
    PayloadVisible = 3,  // all bytes in bank; safe to doorbell
    DoorbellRung = 4,    // commit/PLXK done; wait retire/vsync
    Failed = 5,
};

struct BankProducerContract {
    bool enforce_payload_before_doorbell = true;
    bool require_credit = true;
};

// Software scoreboard for unit tests and HPS/DMA callers.
class BankProducerOrder {
public:
    explicit BankProducerOrder(BankProducerContract c = {}) : c_(c) {}

    BankProducerPhase phase() const { return phase_; }
    const std::string& lastError() const { return err_; }
    int bank() const { return bank_; }

    bool beginFill(int bank, uint8_t free_mask) {
        err_.clear();
        if (bank != 0 && bank != 1) {
            fail("beginFill: bad bank");
            return false;
        }
        if (c_.require_credit && !fabricBankWritable(free_mask, static_cast<unsigned>(bank))) {
            phase_ = BankProducerPhase::AwaitCredit;
            fail("beginFill: no credit for bank");
            return false;
        }
        bank_ = bank;
        bytes_expected_ = 0;
        bytes_written_ = 0;
        barrier_done_ = false;
        phase_ = BankProducerPhase::Filling;
        return true;
    }

    // Async/chunked producer (PL330): report progress. Doorbell stays illegal until done.
    bool noteChunk(size_t n) {
        if (phase_ != BankProducerPhase::Filling) {
            fail("noteChunk: not filling");
            return false;
        }
        bytes_written_ += n;
        return true;
    }

    bool markPayloadVisible(size_t expected_len) {
        if (phase_ != BankProducerPhase::Filling) {
            fail("markPayloadVisible: not filling");
            return false;
        }
        bytes_expected_ = expected_len;
        if (expected_len > 0 && bytes_written_ < expected_len) {
            fail("markPayloadVisible: incomplete payload");
            return false;
        }
        // Real store barrier before PayloadVisible (not atomic_signal_fence).
        ddrPublishPayloadBarrier();
        barrier_done_ = true;
        phase_ = BankProducerPhase::PayloadVisible;
        return true;
    }

    // Fabric writer path: drain fence implies visible (no byte count).
    bool markFabricDrainDone() {
        if (phase_ != BankProducerPhase::Filling) {
            fail("markFabricDrainDone: not filling");
            return false;
        }
        ddrPublishPayloadBarrier();
        barrier_done_ = true;
        phase_ = BankProducerPhase::PayloadVisible;
        return true;
    }

    bool mayRingDoorbell() const {
        if (!c_.enforce_payload_before_doorbell)
            return phase_ == BankProducerPhase::PayloadVisible ||
                   phase_ == BankProducerPhase::DoorbellRung;
        // Visible phase requires barrier; doorbel without barrier is tear class.
        return phase_ == BankProducerPhase::PayloadVisible && barrier_done_;
    }

    bool markDoorbellRung() {
        if (!mayRingDoorbell()) {
            err_ = "markDoorbellRung: payload not visible";
            return false;
        }
        err_.clear();
        phase_ = BankProducerPhase::DoorbellRung;
        return true;
    }

    bool barrierDone() const { return barrier_done_; }

    // After vsync retire of this bank (credit returns via free_mask).
    bool markRetired() {
        if (phase_ != BankProducerPhase::DoorbellRung) {
            fail("markRetired: not rung");
            return false;
        }
        phase_ = BankProducerPhase::Idle;
        bank_ = -1;
        barrier_done_ = false;
        return true;
    }

private:
    void fail(const char* m) {
        err_ = m;
        phase_ = BankProducerPhase::Failed;
    }

    BankProducerContract c_{};
    BankProducerPhase phase_ = BankProducerPhase::Idle;
    int bank_ = -1;
    size_t bytes_written_ = 0;
    size_t bytes_expected_ = 0;
    bool barrier_done_ = false;
    std::string err_;
};

// Option-C bank alignment facts (geometry only). Rate A/B retracted 2026-08-03.
struct OptionCBankAlignFacts {
    uint32_t bank0 = kFabric720pPhysBase;
    uint32_t bank1 = kFabric720pPhysBase + kFabric720pBankStride;
    uint32_t stride = kFabric720pBankStride;
    uint32_t frame_bytes = static_cast<uint32_t>(kPlex720pYuv420pBytes);
};

inline OptionCBankAlignFacts optionCBankAlignFacts() { return {}; }

inline uint32_t alignMod(uint32_t addr, uint32_t a) { return a ? (addr % a) : 0; }

// True if [addr, addr+len) crosses a boundary of size `boundary`.
inline bool rangeCrossesBoundary(uint32_t addr, uint32_t len, uint32_t boundary) {
    if (boundary == 0 || len == 0)
        return false;
    const uint32_t start_idx = addr / boundary;
    const uint32_t end_addr = addr + len - 1u;
    const uint32_t end_idx = end_addr / boundary;
    return end_idx != start_idx;
}

} // namespace misterplex
