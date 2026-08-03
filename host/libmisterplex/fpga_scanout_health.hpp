#pragma once
// FPGA scanout health vs ARM present counters.
//
// OBSERVED DEFECT (parent HW 2026-08-02, stamped daemon 509b0c75):
//   First cast immediately after load_core: HDMI stayed on idle chevron for 60
//   captured frames while daemon reported frames=699 presents=699 drops=0.
//   Telemetry lines carried fpga_obs=none. Second cast (no other change) was OK.
//
// WHAT fpga_obs=none MEANT (source, not inference):
//   frame_ledger.hpp / supply_bucket.hpp hardcode fpga_obs=none on residual
//   supply-side counters. residual_scope=supply_arm_only. It means
//   "FPGA observation was NOT included in these counters" — NOT "observation
//   ran and found nothing". Seeing none on every line is expected by design
//   until a real sample is attached.
//
// WHY presents can advance with a frozen screen (source):
//   - FpgaSpi::open() mmaps /dev/mem once at initPresent; nothing closes/reopens
//     on an external load_core while the daemon keeps running
//     (media_player.cpp initPresent / stop — stop does NOT call fpga_.close).
//   - sendDdrFrame steady-state after first successful kick (ddrKickMode_==1)
//     memcpy+doorbell without re-checking busy/has_frame (fpga_spi.cpp).
//   - presentCount_++ on sendDdrFrame true (arm publish ok), not on PLXD
//     scanout proof (media_player.cpp presents_src=arm_publish_ok).
//
// This header classifies host-side samples so a session with presents advancing
// and no PLXD bank-identity progress is NEVER "healthy natural_eof".

#include <cstdint>
#include <string>

#include "libmisterplex/frame_ledger.hpp"
#include "libmisterplex/plxd_liveness.hpp"

namespace misterplex {

// Tokens for telemetry fpga_obs=… (greppable).
// kFpgaObsNotSampled ("none") = residual supply-only: FPGA was NOT sampled.
// Reason token kFrameLedgerReasonPresentWithoutScanout lives in frame_ledger.hpp.
inline constexpr const char* kFpgaObsNotSampled = "none";
inline constexpr const char* kFpgaObsPlxdAbsent = "plxd_absent";
inline constexpr const char* kFpgaObsPlxdStale = "plxd_stale";
inline constexpr const char* kFpgaObsPlxdLive = "plxd_live";
inline constexpr const char* kFpgaObsPlxdBaseline = "plxd_baseline";

struct FpgaScanoutSample {
    bool read_ok = false;          // readBankRelease / mailbox decode succeeded
    std::uint8_t bank_sig = 0;     // plxdBankIdentitySig
    int64_t presents = 0;          // ARM presentCount_ at sample time
};

struct FpgaScanoutHealth {
    int samples = 0;
    int live_samples = 0;
    int absent_samples = 0;
    int stale_samples = 0;
    int baseline_samples = 0;
    bool have_prev = false;
    std::uint8_t prev_sig = 0;
    int64_t presents_at_first_sample = -1;
    int64_t presents_last = 0;
    bool reopen_attempted = false;
    bool failure_logged = false;
    // Last classified obs token for the most recent sample.
    const char* last_obs = kFpgaObsNotSampled;
};

// Classify one sample and update counters. Returns obs token for this sample.
inline const char* fpgaScanoutNoteSample(FpgaScanoutHealth& h, const FpgaScanoutSample& s) {
    h.samples += 1;
    h.presents_last = s.presents;
    if (h.presents_at_first_sample < 0)
        h.presents_at_first_sample = s.presents;

    if (!s.read_ok) {
        h.absent_samples += 1;
        h.last_obs = kFpgaObsPlxdAbsent;
        return h.last_obs;
    }

    if (!h.have_prev) {
        h.have_prev = true;
        h.prev_sig = s.bank_sig;
        h.baseline_samples += 1;
        h.last_obs = kFpgaObsPlxdBaseline;
        return h.last_obs;
    }

    if (s.bank_sig != h.prev_sig) {
        h.prev_sig = s.bank_sig;
        h.live_samples += 1;
        h.last_obs = kFpgaObsPlxdLive;
        return h.last_obs;
    }

    // Mailbox readable, identity frozen. Only "stale" once presents have advanced
    // past the first sample — otherwise early quiet is not a defect.
    if (s.presents > h.presents_at_first_sample) {
        h.stale_samples += 1;
        h.last_obs = kFpgaObsPlxdStale;
        return h.last_obs;
    }

    h.last_obs = kFpgaObsPlxdBaseline;
    return h.last_obs;
}

// Failure gate: enough presents, enough samples, never saw bank-identity move.
// Defaults sized for ~1 Hz samples over a short cast open (parent saw 60s freeze).
inline bool fpgaScanoutPresentWithoutProof(const FpgaScanoutHealth& h,
                                           int64_t min_presents = 24,
                                           int min_samples = 3) {
    if (h.presents_last < min_presents)
        return false;
    if (h.samples < min_samples)
        return false;
    if (h.live_samples > 0)
        return false;
    // Need at least one negative observation class (absent or stale-with-progress).
    return (h.absent_samples + h.stale_samples) >= 1;
}

// Should attempt one reopen / kick-reprobe recovery (once per session).
inline bool fpgaScanoutShouldReopen(const FpgaScanoutHealth& h,
                                    int64_t min_presents = 24,
                                    int min_samples = 2) {
    if (h.reopen_attempted)
        return false;
    return fpgaScanoutPresentWithoutProof(h, min_presents, min_samples);
}

// Greppable ERROR line — silent-success class twin of ZERO_FRAME_PLAYBACK.
inline std::string fpgaScanoutPresentWithoutProofErrorLine(const FpgaScanoutHealth& h,
                                                           int64_t presents,
                                                           int64_t frames) {
    return std::string("ERROR media: PRESENT_WITHOUT_SCANOUT") +
           " reason=" + kFrameLedgerReasonPresentWithoutScanout +
           " frames=" + std::to_string(frames) +
           " presents=" + std::to_string(presents) +
           " presents_src=arm_publish_ok" +
           " fpga_obs=" + (h.last_obs ? h.last_obs : kFpgaObsNotSampled) +
           " plxd_live_samples=" + std::to_string(h.live_samples) +
           " plxd_absent_samples=" + std::to_string(h.absent_samples) +
           " plxd_stale_samples=" + std::to_string(h.stale_samples) +
           " plxd_samples=" + std::to_string(h.samples) +
           " note=arm_presents_advanced_without_plxd_bank_identity_progress" +
           " tag=measured";
}

// Build bank_sig from mailbox fields (same derivation as plxd liveness).
inline std::uint8_t fpgaScanoutBankSig(std::uint8_t free_mask, std::uint8_t disp_bank,
                                       bool swap_pending) {
    PlxdLivenessSample s;
    s.free_bank_mask = free_mask;
    s.disp_bank = disp_bank;
    s.swap_pending = swap_pending;
    return plxdBankIdentitySig(s);
}

} // namespace misterplex
