#pragma once

// Zero-CPU-copy / overlapped DDR bank ingest (w-path Route A).
//
// Parent 2026-08-03: serial decode+bank-copy is DEAD at every true-720 tier
// (best bank write 15.283 ms/f). Overlap max(decode,copy) is the only ARM-side
// arithmetic that can close 720p24 until fabric owns pixels entirely.
//
// Modes (product default remains CpuSerial via existing sendDdrFrame):
//   CpuSerial       — memcpy then doorbell (today; fails 720p24 budget)
//   DecodeIntoBank  — decoder writes bank virt directly (still CPU stores to
//                     O_SYNC bank; may be slower than RAM+memcpy — measure)
//   Pl330Overlap    — decode into locked RAM; PL330 mem2mem into bank; CPU free
//                     for next decode. Concurrency vs DDR controller UNKNOWN
//                     until parent measures (do not assume max() holds).
//
// Doorbell ordering (absolute — parent tearing class):
//   payload fully FPGA-visible → then exactly one doorbell. Never reverse.
//   PLXD bank credit (when present) gates which bank may be filled.
//
// Coordinate with w-mem: bank phys / stride / doorbell magic = ddr_frame_layout;
// fabric_ddr_writer is the fabric producer path (publish_bytes=0 ship gate).
// This lane fills the *HPS* producer gap: real decoded frames → Option-C banks
// without burning decode-critical CPU on the copy.

#include "libmisterplex/ddr_frame_layout.hpp"

#include <atomic>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <string>

namespace misterplex {

enum class DdrIngestMode : uint8_t {
    CpuSerial = 0,
    DecodeIntoBank = 1,
    Pl330Overlap = 2,
};

enum class DdrIngestPhase : uint8_t {
    Idle = 0,
    AwaitBankCredit = 1,
    PayloadMoving = 2,
    PayloadVisible = 3, // safe to ring doorbell
    DoorbellRung = 4,
    Failed = 5,
};

struct DdrIngestJob {
    const uint8_t* src_virt = nullptr; // CpuSerial / Pl330 source (RAM)
    uint32_t src_phys = 0;             // Pl330: physical source (0 = unresolved)
    uint8_t* bank_virt = nullptr;      // mapped bank window
    uint32_t bank_phys = 0;
    size_t len = 0;
    int bank = 0; // 0/1
    bool plxd_credit_held = false;
};

struct DdrIngestTiming {
    int64_t wait_credit_us = 0;
    int64_t move_us = 0; // CPU copy or DMA wall
    int64_t barrier_us = 0;
    int64_t doorbell_us = 0;
    bool used_dma = false;
    bool decode_into_bank = false;
};

struct DdrIngestContract {
    DdrIngestMode mode = DdrIngestMode::CpuSerial;
    // When true, ring is refused unless phase==PayloadVisible.
    bool enforce_payload_before_doorbell = true;
    // PLXD path: require credit before fill (product when mailbox live).
    bool require_bank_credit = false;
};

// --- Budget helpers (parent-measured constants; do not invent device rates) ---

constexpr double kIngestBudget24fpsMs = 41.667;
constexpr double kParentBankCopy720pMs = 15.283; // best mapped bank, Sweep-3/4
constexpr double kParentDecode720p2500kMs = 36.845;
constexpr double kParentDecode720pApprox2600kMs = 37.0; // PLACEHOLDER — parent remeasures
// Universal geometry floor content ~2585k after maxBR=3100 (w-path fine matrix).

inline bool ddrIngestSerialDecodePlusCopyFits(double decodeMs,
                                              double copyMs = kParentBankCopy720pMs,
                                              double budgetMs = kIngestBudget24fpsMs) {
    return (decodeMs + copyMs) <= budgetMs;
}

// Route A sketch: throughput ~ max(decode, copy). NOT proven under DDR contention.
inline bool ddrIngestOverlapMaxFits(double decodeMs, double copyMs = kParentBankCopy720pMs,
                                    double budgetMs = kIngestBudget24fpsMs) {
    const double m = (decodeMs > copyMs) ? decodeMs : copyMs;
    return m <= budgetMs;
}

inline const char* ddrIngestModeName(DdrIngestMode m) {
    switch (m) {
    case DdrIngestMode::CpuSerial:
        return "cpu_serial";
    case DdrIngestMode::DecodeIntoBank:
        return "decode_into_bank";
    case DdrIngestMode::Pl330Overlap:
        return "pl330_overlap";
    }
    return "unknown";
}

inline DdrIngestMode ddrIngestModeFromConf(const char* s) {
    if (!s || !*s)
        return DdrIngestMode::CpuSerial;
    if (std::strcmp(s, "pl330") == 0 || std::strcmp(s, "pl330_overlap") == 0 ||
        std::strcmp(s, "dma") == 0)
        return DdrIngestMode::Pl330Overlap;
    if (std::strcmp(s, "decode_into_bank") == 0 || std::strcmp(s, "into_bank") == 0)
        return DdrIngestMode::DecodeIntoBank;
    return DdrIngestMode::CpuSerial;
}

// State machine: fill → visible → doorbell. Unit-tested; backends plug in.
class DdrIngestSession {
public:
    explicit DdrIngestSession(DdrIngestContract c = {}) : c_(c) {}

    DdrIngestPhase phase() const { return phase_; }
    const DdrIngestTiming& timing() const { return timing_; }
    const std::string& lastError() const { return err_; }

    bool begin(const DdrIngestJob& job) {
        err_.clear();
        timing_ = {};
        job_ = job;
        if (!job_.bank_virt || job_.len == 0 || (job_.bank != 0 && job_.bank != 1)) {
            fail("begin: bad bank/len");
            return false;
        }
        if (c_.mode != DdrIngestMode::DecodeIntoBank && !job_.src_virt) {
            fail("begin: null src for non-decode-into-bank mode");
            return false;
        }
        if (c_.require_bank_credit && !job_.plxd_credit_held) {
            phase_ = DdrIngestPhase::AwaitBankCredit;
            fail("begin: PLXD bank credit required but not held");
            return false;
        }
        phase_ = DdrIngestPhase::PayloadMoving;
        return true;
    }

    // CpuSerial backend: blocking memcpy + DMB.
    bool completeCpuMemcpy() {
        if (phase_ != DdrIngestPhase::PayloadMoving) {
            fail("completeCpuMemcpy: bad phase");
            return false;
        }
        if (!job_.src_virt) {
            fail("completeCpuMemcpy: null src");
            return false;
        }
        std::memcpy(job_.bank_virt, job_.src_virt, job_.len);
        // Compiler barrier; device uses __sync_synchronize in fpga_spi.
        std::atomic_signal_fence(std::memory_order_seq_cst);
        timing_.move_us = 0; // caller may overwrite with wall time
        timing_.used_dma = false;
        phase_ = DdrIngestPhase::PayloadVisible;
        return true;
    }

    // DecodeIntoBank: decoder already filled bank_virt; mark visible after barrier.
    bool completeDecodeIntoBankBarrier() {
        if (phase_ != DdrIngestPhase::PayloadMoving) {
            fail("completeDecodeIntoBankBarrier: bad phase");
            return false;
        }
        std::atomic_signal_fence(std::memory_order_seq_cst);
        timing_.decode_into_bank = true;
        timing_.used_dma = false;
        phase_ = DdrIngestPhase::PayloadVisible;
        return true;
    }

    // Pl330 backend success path (DMA engine reports done).
    bool completeDmaDone() {
        if (phase_ != DdrIngestPhase::PayloadMoving) {
            fail("completeDmaDone: bad phase");
            return false;
        }
        timing_.used_dma = true;
        phase_ = DdrIngestPhase::PayloadVisible;
        return true;
    }

    // Returns false if doorbell would race payload (tearing class).
    bool mayRingDoorbell() const {
        if (!c_.enforce_payload_before_doorbell)
            return phase_ == DdrIngestPhase::PayloadVisible ||
                   phase_ == DdrIngestPhase::DoorbellRung;
        return phase_ == DdrIngestPhase::PayloadVisible;
    }

    bool markDoorbellRung() {
        if (!mayRingDoorbell()) {
            // Do not destroy session phase — caller may still complete payload.
            err_ = "markDoorbellRung: payload not visible";
            return false;
        }
        err_.clear();
        phase_ = DdrIngestPhase::DoorbellRung;
        return true;
    }

    // Bank virt for DecodeIntoBank producers (ffmpeg custom AVBuffer, etc.).
    uint8_t* bankWritePtr() const {
        return (phase_ == DdrIngestPhase::PayloadMoving ||
                phase_ == DdrIngestPhase::PayloadVisible)
                   ? job_.bank_virt
                   : nullptr;
    }

    size_t jobLen() const { return job_.len; }
    int jobBank() const { return job_.bank; }
    uint32_t jobBankPhys() const { return job_.bank_phys; }

private:
    void fail(const char* m) {
        err_ = m ? m : "ingest failed";
        phase_ = DdrIngestPhase::Failed;
    }

    DdrIngestContract c_{};
    DdrIngestJob job_{};
    DdrIngestPhase phase_ = DdrIngestPhase::Idle;
    DdrIngestTiming timing_{};
    std::string err_;
};

// Double-buffer plan: while DMA/copy moves bank A, decoder may fill RAM slot B.
struct DdrIngestDoubleBufferPlan {
    int decode_slot = 0; // 0/1 RAM slot being decoded into
    int move_bank = 0;   // FPGA bank receiving completed RAM slot
    bool overlap_armed = false;
};

inline DdrIngestDoubleBufferPlan ddrIngestAdvanceOverlap(DdrIngestDoubleBufferPlan p,
                                                         bool move_finished) {
    if (!move_finished)
        return p;
    p.decode_slot ^= 1;
    p.move_bank ^= 1;
    p.overlap_armed = true;
    return p;
}

// Ship vs bridge: fabric publish_bytes=0 is still the only hard ship gate (w-mem).
// Route A is a measured bridge if PL330 concurrency holds.
inline bool ddrIngestRouteAIsShipGate() { return false; }

inline bool ddrIngestRouteABridgeCandidate(double decodeMs, double copyMs = kParentBankCopy720pMs) {
    return !ddrIngestSerialDecodePlusCopyFits(decodeMs, copyMs) &&
           ddrIngestOverlapMaxFits(decodeMs, copyMs);
}

} // namespace misterplex
