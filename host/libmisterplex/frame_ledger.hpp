// Cross-restart presented-frame ledger for soak audits.
//
// SCOPE (parent 2026-08-01 PLXD audit): this ledger is ARM-side only.
//   frames/presents/drops/publish_misses do NOT read PLXD[63:48] frames_done.
//   presents = successful sendDdrFrame / present path (presentCount_).
//   drops    = A/V-pacer deliberate skips (droppedFrames_).
//   They are NOT display-swap counts. On c5382bee, PLXD[63:48] packs
//   bank_vsync_count while still labelled frames_done — a closed ARM ledger
//   (unaccounted=0) does NOT prove zero display skips. tag scope below.
//
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
void frameLedgerSessionEnd(uint64_t sessionId, int64_t frames, int64_t presents, int64_t drops,
                           const char* reason, int64_t publishMisses = 0);

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
// Parent P5: unaccounted is the free ledger identity — print every term so a
// soak never requires hand arithmetic. residual is kept as a synonym.
inline std::string frameLedgerTelemetryFragment(const FrameLedgerLive& s) {
    return "frames=" + std::to_string(s.frames) + " presents=" + std::to_string(s.presents) +
           " drops=" + std::to_string(s.drops) +
           " publish_misses=" + std::to_string(s.publish_misses) +
           " unaccounted=" + std::to_string(s.residual) +
           " residual=" + std::to_string(s.residual) +
           " unaccounted_eq=frames-presents-drops" +
           " scope=ARM_PUBLISH_NOT_DISPLAY" +
           " tag=measured";
}

// session_epoch string: process_epoch + stream_seq. Changes on daemon start
// (new process_epoch) AND every new stream (stream_seq++). A soak consumer that
// sees session_epoch change mid-window MUST invalidate that window (P4).
inline std::string sessionEpochString(uint64_t processEpoch, uint64_t streamSeq) {
    return std::to_string(processEpoch) + "." + std::to_string(streamSeq);
}

} // namespace misterplex
