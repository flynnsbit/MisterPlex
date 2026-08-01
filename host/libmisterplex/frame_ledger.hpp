// Cross-restart presented-frame ledger for soak audits.
// Session counters (presentCount_/droppedFrames_) reset every demux; this file
// is append-only across process lives so a soak can assert:
//   sum(frames) - sum(presents) - sum(drops) == sum(residual)
// and see process_start / process_exit rows when a supervisor respawns.
//
// Paths: <confDir>/misterplexd.frame_ledger (one line per event).
#pragma once

#include <cstdint>
#include <cstdio>
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
//
// Three-way measurement (repo rule — never collapse "could not measure" into 0):
//   measured=true  → counters are from an active session that has assembled ≥1 frame
//   measured=false → UNKNOWN in telemetry (not residual=0, which means "accounted")
struct FrameLedgerLive {
    int64_t frames = 0;
    int64_t presents = 0;
    int64_t drops = 0;
    int64_t publish_misses = 0;
    int64_t residual = 0; // frames - presents - drops (only meaningful when measured)
    bool measured = false;
};

inline FrameLedgerLive frameLedgerLiveOf(int64_t frames, int64_t presents, int64_t drops,
                                         int64_t publishMisses = 0) {
    FrameLedgerLive s;
    s.frames = frames;
    s.presents = presents;
    s.drops = drops;
    s.publish_misses = publishMisses;
    s.residual = frameLedgerResidual(frames, presents, drops);
    // A session with zero pipe frames has not measured present/drop/miss yet.
    // residual=0 would falsely read as "healthy soak"; emit UNKNOWN instead.
    s.measured = frames > 0;
    return s;
}

// True when residual is fully explained by counted publish misses (no other gap).
// Unmeasured snapshots are never "explained".
inline bool frameLedgerResidualExplainedByPublishMiss(const FrameLedgerLive& s) {
    return s.measured && s.residual == s.publish_misses;
}

// Compact key=value fragment for telemetry (no leading/trailing space).
// When !measured every field is the literal UNKNOWN (not 0).
inline std::string frameLedgerTelemetryFragment(const FrameLedgerLive& s) {
    if (!s.measured) {
        return "presents=UNKNOWN drops=UNKNOWN publish_misses=UNKNOWN residual=UNKNOWN";
    }
    return "presents=" + std::to_string(s.presents) + " drops=" + std::to_string(s.drops) +
           " publish_misses=" + std::to_string(s.publish_misses) +
           " residual=" + std::to_string(s.residual);
}

// Rate field: value with one decimal, or UNKNOWN when the interval is unusable.
// wallMs<=0 or negative deltas must not collapse to "0.0" (false health).
inline std::string frameRateTelemetryField(const char* key, int64_t countDelta, int64_t wallMs) {
    if (wallMs <= 0 || countDelta < 0)
        return std::string(key) + "=UNKNOWN";
    const double rate =
        1000.0 * static_cast<double>(countDelta) / static_cast<double>(wallMs);
    char buf[32];
    // One decimal is enough for human soak reads (23.9 vs 24.0); keep width stable.
    std::snprintf(buf, sizeof(buf), "%s=%.1f", key, rate);
    return std::string(buf);
}

} // namespace misterplex
