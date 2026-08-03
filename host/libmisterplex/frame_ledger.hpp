// Cross-restart presented-frame ledger for soak audits.
// Session counters (presentCount_/droppedFrames_) reset every demux; this file
// is append-only across process lives so a soak can assert:
//   sum(frames) - sum(presents) - sum(drops) == sum(residual)
// and see process_start / process_exit rows when a supervisor respawns.
//
// Paths: <confDir>/misterplexd.frame_ledger (one line per event).
#pragma once

#include <cstdint>
#include <string>

namespace misterplex {

// confDir e.g. /media/fat/misterplex_v2 — creates frame_ledger next to conf.
void frameLedgerInit(const std::string& confDir);

// Host/lab override (tests).
void frameLedgerSetPathForTest(const std::string& path);

// process_start: call once after init. lifetime_* are in-process (usually 0).
void frameLedgerProcessStart(int64_t lifetimeFrames, int64_t lifetimePresents,
                             int64_t lifetimeDrops);

// session_end: one demux/playback finished. residual = frames - presents - drops
// (may be non-zero when paused overlays / skip-present paths apply).
// publishMisses: present attempted but DDR/FPGA publish failed (not A/V drops).
//
// reason tokens (product):
//   stop_or_seek              — user stop / seek restart
//   natural_eof               — content ended with at least one assembled frame OR present
//   zero_frame_playback       — frames=0 AND presents=0 without stop/seek
//   present_without_scanout   — presents advanced but PLXD bank-identity never proved live
// Field defect (parent 2026-08-02): crop=618:480 on fleet 624x350 → ffmpeg emits
// 0 frames, session reported reason=natural_eof. That MUST be zero_frame_playback.
// Field defect (parent 2026-08-02): first cast after load_core → presents>0 while HDMI
// idle froze; residual lines said fpga_obs=none (static supply label). MUST be
// present_without_scanout when scanout health never saw plxd_live.
void frameLedgerSessionEnd(uint64_t sessionId, int64_t frames, int64_t presents, int64_t drops,
                           const char* reason, int64_t publishMisses = 0);

// Stable reason tokens — greppable; do not rename without soak tooling update.
inline constexpr const char* kFrameLedgerReasonStopOrSeek = "stop_or_seek";
inline constexpr const char* kFrameLedgerReasonNaturalEof = "natural_eof";
inline constexpr const char* kFrameLedgerReasonZeroFrame = "zero_frame_playback";
inline constexpr const char* kFrameLedgerReasonPresentWithoutScanout =
    "present_without_scanout";

// Classify session-end reason. Zero-frame total failure is NEVER natural_eof.
// presentWithoutScanout overrides natural_eof when ARM presents advanced without
// PLXD bank-identity proof (see fpga_scanout_health.hpp).
inline const char* frameLedgerClassifyEndReason(bool stopOrSeek, int64_t frames,
                                                int64_t presents,
                                                bool presentWithoutScanout = false) {
    if (stopOrSeek)
        return kFrameLedgerReasonStopOrSeek;
    if (frames == 0 && presents == 0)
        return kFrameLedgerReasonZeroFrame;
    if (presentWithoutScanout && presents > 0)
        return kFrameLedgerReasonPresentWithoutScanout;
    return kFrameLedgerReasonNaturalEof;
}

inline bool frameLedgerIsZeroFrameFailure(const char* reason) {
    return reason != nullptr &&
           std::string(reason) == kFrameLedgerReasonZeroFrame;
}

inline bool frameLedgerIsPresentWithoutScanout(const char* reason) {
    return reason != nullptr &&
           std::string(reason) == kFrameLedgerReasonPresentWithoutScanout;
}

// One greppable ERROR line for zero-frame sessions (field defect class).
// Carries delivered_geom, producer/reader bytes, vf reason for single-line RCA.
inline std::string frameLedgerZeroFrameErrorLine(int delivered_w, int delivered_h,
                                                 size_t producer_input_bytes,
                                                 size_t reader_bytes,
                                                 const std::string& vf_reason) {
    const std::string geom = (delivered_w > 0 && delivered_h > 0)
                                 ? (std::to_string(delivered_w) + "x" + std::to_string(delivered_h))
                                 : "NO-DATA";
    const std::string vfr = vf_reason.empty() ? "NO-DATA" : vf_reason;
    return std::string("ERROR media: ZERO_FRAME_PLAYBACK") +
           " reason=" + kFrameLedgerReasonZeroFrame +
           " frames=0 presents=0" +
           " delivered_geom=" + geom +
           " producer_input_bytes=" + std::to_string(producer_input_bytes) +
           " reader_bytes=" + std::to_string(reader_bytes) +
           " vf_reason=" + vfr +
           " note=total_playback_failure_not_natural_eof" +
           " tag=measured";
}

// process_exit: orderly daemon exit (same moment as deathBreadcrumbExit).
void frameLedgerProcessExit(int code, const char* why, int64_t lifetimeFrames,
                            int64_t lifetimePresents, int64_t lifetimeDrops, int64_t uptimeS);

// Parse helpers for unit tests / soak tools (sum fields from a ledger file).
struct FrameLedgerTotals {
    int64_t frames = 0;
    int64_t presents = 0;
    int64_t drops = 0;
    int64_t publish_misses = 0;
    int64_t residual = 0;
    int processStarts = 0;
    int processExits = 0;
    int sessionEnds = 0;
};

// Returns false if path missing or unreadable; totals zeroed.
bool frameLedgerSumFile(const std::string& path, FrameLedgerTotals* out);

// residual identity: frames - presents - drops (clamped report, not forced 0).
//
// Semantics (product present loop):
//   frames         = pipe frames fully assembled (frameIndex)
//   presents       = successful FPGA/DDR publishes (presentCount_)
//   drops          = deliberate A/V-pacer skips ONLY (droppedFrames_)
//   publish_misses = present attempted, DDR/FPGA publish failed
//
// residual = frames - presents - drops
//   • does NOT include av_drift_ms (drift uses frameIndex content time only)
//   • a failed publish increments residual and publish_misses; drops stays flat
//   • identity when every non-present is either pacedrop or publish-miss:
//       residual == publish_misses
inline int64_t frameLedgerResidual(int64_t frames, int64_t presents, int64_t drops) {
    return frames - presents - drops;
}

// Live snapshot fields emitted on the 1 Hz media telemetry line and at session_end.
struct FrameLedgerLive {
    int64_t frames = 0;
    int64_t presents = 0;
    int64_t drops = 0;
    int64_t publish_misses = 0;
    int64_t residual = 0; // frames - presents - drops
};

inline FrameLedgerLive frameLedgerLiveOf(int64_t frames, int64_t presents, int64_t drops,
                                         int64_t publishMisses = 0) {
    FrameLedgerLive s;
    s.frames = frames;
    s.presents = presents;
    s.drops = drops;
    s.publish_misses = publishMisses;
    s.residual = frameLedgerResidual(frames, presents, drops);
    return s;
}

// True when residual is fully explained by counted publish misses (no other gap).
inline bool frameLedgerResidualExplainedByPublishMiss(const FrameLedgerLive& s) {
    return s.residual == s.publish_misses;
}

// Compact key=value fragment for telemetry (no leading/trailing space).
//
// HONEST LABELS (parent 2026-08-01): every field carries its derivation.
// All counters below are SUPPLY-SIDE (ARM control flow). residual ==
// frames-presents-drops by arithmetic; when the only non-present paths are
// pacer-drop or publish-miss, residual == publish_misses.
//
// fpgaObs (parent 2026-08-02 clarification):
//   Default "none" means residual_scope is supply-only — FPGA was NOT sampled
//   for THIS fragment. It is NOT "observation succeeded and found nothing".
//   Callers that sample PLXD must pass plxd_live / plxd_absent / plxd_stale
//   (see fpga_scanout_health.hpp). Do not treat none as a pass.
inline std::string frameLedgerTelemetryFragment(const FrameLedgerLive& s,
                                                const char* fpgaObs = "none") {
    const char* obs = (fpgaObs && fpgaObs[0]) ? fpgaObs : "none";
    return "frames=" + std::to_string(s.frames) + " frames_src=pipe_assemble" +
           " presents=" + std::to_string(s.presents) + " presents_src=arm_publish_ok" +
           " drops=" + std::to_string(s.drops) + " drops_src=av_pacer" +
           " publish_misses=" + std::to_string(s.publish_misses) +
           " publish_misses_src=arm_publish_fail" +
           " residual=" + std::to_string(s.residual) +
           " residual_eq=frames-presents-drops" +
           " residual_scope=supply_arm_only" +
           " fpga_obs=" + obs +
           " tag=measured";
}

// session_epoch string: process_epoch + stream_seq. Changes on daemon start
// (new process_epoch) AND every new stream (stream_seq++). A soak consumer that
// sees session_epoch change mid-window MUST invalidate that window (P4).
inline std::string sessionEpochString(uint64_t processEpoch, uint64_t streamSeq) {
    return std::to_string(processEpoch) + "." + std::to_string(streamSeq);
}

} // namespace misterplex
