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
void frameLedgerSessionEnd(uint64_t sessionId, int64_t frames, int64_t presents, int64_t drops,
                           const char* reason);

// process_exit: orderly daemon exit (same moment as deathBreadcrumbExit).
void frameLedgerProcessExit(int code, const char* why, int64_t lifetimeFrames,
                            int64_t lifetimePresents, int64_t lifetimeDrops, int64_t uptimeS);

// Parse helpers for unit tests / soak tools (sum fields from a ledger file).
struct FrameLedgerTotals {
    int64_t frames = 0;
    int64_t presents = 0;
    int64_t drops = 0;
    int64_t residual = 0;
    int processStarts = 0;
    int processExits = 0;
    int sessionEnds = 0;
};

// Returns false if path missing or unreadable; totals zeroed.
bool frameLedgerSumFile(const std::string& path, FrameLedgerTotals* out);

// residual identity: frames - presents - drops (clamped report, not forced 0).
inline int64_t frameLedgerResidual(int64_t frames, int64_t presents, int64_t drops) {
    return frames - presents - drops;
}

} // namespace misterplex
