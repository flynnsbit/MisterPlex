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

// residual identities (clamped report, not forced 0).
//
// Semantics (product present loop — quote media_player.cpp this tree):
//   frames         = pipe frames fully assembled (frameIndex)
//   presents       = successful FPGA/DDR publishes (presentCount_ ++ only on ok)
//   drops          = deliberate A/V-pacer skips ONLY (droppedFrames_.fetch_add ~:4185)
//   publish_misses = present attempted, DDR/FPGA publish failed (~:3641)
//   resets         = play-path store(0) ~:3010/:3011 (NOT silence-scan)
//
// residual_arm = frames - presents - drops
//   • a failed publish increments residual_arm and publish_misses; drops stays flat
//   • when every non-present is pacedrop or publish-miss: residual_arm == publish_misses
//
// residual_unexplained = frames - presents - drops - publish_misses
//   • PARENT/user finding: if non-zero, frames went missing on a path we do NOT
//     instrument (neither pacer Drop nor counted publish fail). That is the
//     "frames being dropped" complaint the drops= counter alone cannot settle.
//   • does NOT include av_drift_ms; does NOT observe FPGA scanout/HDMI glass
inline int64_t frameLedgerResidual(int64_t frames, int64_t presents, int64_t drops) {
    return frames - presents - drops;
}

inline int64_t frameLedgerUnexplained(int64_t frames, int64_t presents, int64_t drops,
                                      int64_t publishMisses) {
    return frames - presents - drops - publishMisses;
}

// Live snapshot fields emitted on the 1 Hz media telemetry line and at session_end.
struct FrameLedgerLive {
    int64_t frames = 0;
    int64_t presents = 0;
    int64_t drops = 0;
    int64_t publish_misses = 0;
    int64_t residual = 0;             // frames - presents - drops
    int64_t residual_unexplained = 0; // frames - presents - drops - publish_misses
};

inline FrameLedgerLive frameLedgerLiveOf(int64_t frames, int64_t presents, int64_t drops,
                                         int64_t publishMisses = 0) {
    FrameLedgerLive s;
    s.frames = frames;
    s.presents = presents;
    s.drops = drops;
    s.publish_misses = publishMisses;
    s.residual = frameLedgerResidual(frames, presents, drops);
    s.residual_unexplained =
        frameLedgerUnexplained(frames, presents, drops, publishMisses);
    return s;
}

// True when residual_arm is fully explained by counted publish misses (no other gap).
inline bool frameLedgerResidualExplainedByPublishMiss(const FrameLedgerLive& s) {
    return s.residual == s.publish_misses;
}

// Compact key=value fragment for telemetry (no leading/trailing space).
//
// HONEST LABELS: every field carries its derivation.
// All counters below are SUPPLY-SIDE (ARM control flow). None observe the FPGA
// scanout/swap. residual_unexplained!=0 is the user-facing uninstrumented gap.
inline std::string frameLedgerTelemetryFragment(const FrameLedgerLive& s) {
    return "frames=" + std::to_string(s.frames) + " frames_src=pipe_assemble" +
           " presents=" + std::to_string(s.presents) + " presents_src=arm_publish_ok" +
           " drops=" + std::to_string(s.drops) + " drops_src=av_pacer" +
           " publish_misses=" + std::to_string(s.publish_misses) +
           " publish_misses_src=arm_publish_fail" +
           " residual=" + std::to_string(s.residual) +
           " residual_eq=frames-presents-drops" +
           " residual_unexplained=" + std::to_string(s.residual_unexplained) +
           " residual_unexplained_eq=frames-presents-drops-publish_misses" +
           " residual_scope=supply_arm_only" +
           " fpga_obs=none" +
           " tag=measured";
}

// session_epoch string: process_epoch + stream_seq. Changes on daemon start
// (new process_epoch) AND every new stream (stream_seq++). A soak consumer that
// sees session_epoch change mid-window MUST invalidate that window (P4).
inline std::string sessionEpochString(uint64_t processEpoch, uint64_t streamSeq) {
    return std::to_string(processEpoch) + "." + std::to_string(streamSeq);
}

} // namespace misterplex
