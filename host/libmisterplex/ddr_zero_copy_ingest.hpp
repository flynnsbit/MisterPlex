#pragma once

// HPS bank ingest (w-path). Parent 2026-08-03 architecture lock:
//
// STRUCTURAL: bank at 0x30xx_xxxx is OUTSIDE kernel System RAM (cmdline
// mem=511M memmap=513M$511M; iomem System RAM ends 0x1fefffff). /dev/mem maps
// it uncached/device regardless of O_SYNC. Measured CPU store ceiling ~88 MiB/s
// (~14.97 ms/f for 720p I420). --no-sync/--flush do NOT help (0/5 pre-reg).
// ⇒ decode(35.94)+CPU full-frame move(>=14.97) >= 50.9 ms vs 41.667 — CLOSED FAIL.
//
// Modes (product default remains CpuSerial via existing sendDdrFrame):
//   CpuSerial       — memcpy then doorbell (DEAD for 720p24; 480p only)
//   DecodeIntoBank  — SUSPECT not a win: decoder would store+reload refs from
//                     same uncached bank. Do NOT productize until measured.
//   Pl330Overlap    — CRITICAL PATH for any ARM-side 720p24: PL330 via L3 is
//                     not subject to CPU uncached-store stall. Concurrency with
//                     decode still UNMEASURED (bench c4cf0392 must verify bytes).
//
// Endgame (mandate): fabric owns pixels / h264_decode_top — stop crossing the
// uncached boundary with frame payloads at all.
//
// Doorbell ordering (absolute): payload FPGA-visible → then one doorbell.
// Coordinate w-mem: bank/doorbell ABI; fabric_ddr_writer = fabric producer.

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
// Parent CLEAN budget 2026-08-03 (post-awk; nosync 0/5; anomaly CLOSED):
//   decode alone 35.94 (margin 5.73); CPU bank copy 14.978 STRUCTURAL uncached
//   serial 50.9+ FAIL closed; DMA verified sustained = THE open ARM question
//   DecodeIntoBank suspect (same uncached stores) — do not build further yet
constexpr double kParentBankCopy720pMs = 14.978;
constexpr double kParentBankCopy720pMiBps = 88.045; // --sync control, structural
constexpr double kParentDecode720pCleanAloneMs = 35.94;
// true: CPU full-frame bank move cannot be tuned past uncached ceiling on this map
constexpr bool kParentCpuBankCopyIsStructuralCeiling = true;
constexpr double kParentDecode720p2500kMs = 35.87; // earlier same-session arm
constexpr double kParentDecode720pProduct2600kMs = kParentDecode720pCleanAloneMs;
constexpr double kParentDecode720pApprox2600kMs = kParentDecode720pProduct2600kMs;
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
