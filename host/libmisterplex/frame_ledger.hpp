// Cross-restart presented-frame ledger for soak audits (P5).
//
// Session counters (presentCount_/droppedFrames_/presentFailCount_) reset every
// demux; this file is append-only across process lives so a soak can assert:
//   sum(frames) - sum(presents) - sum(drops) - sum(present_fails) == sum(residual)
// with residual==0 when the ledger is closed, and see process_start /
// process_exit rows when a supervisor respawns (w-geom exit RCA + this file).
//
// Paths: <confDir>/misterplexd.frame_ledger (one line per event).
// drops = deliberate A/V-pacer skips only; present_fails = failed FPGA/DDR tx.
#pragma once

#include <cstdint>
#include <cstdio>
#include <string>

namespace misterplex {

void frameLedgerInit(const std::string& confDir);
void frameLedgerSetPathForTest(const std::string& path);

void frameLedgerProcessStart(int64_t lifetimeFrames, int64_t lifetimePresents,
                             int64_t lifetimeDrops, int64_t lifetimePresentFails = 0);

void frameLedgerSessionEnd(uint64_t sessionId, int64_t frames, int64_t presents, int64_t drops,
                           int64_t presentFails, const char* reason);

void frameLedgerProcessExit(int code, const char* why, int64_t lifetimeFrames,
                            int64_t lifetimePresents, int64_t lifetimeDrops,
                            int64_t lifetimePresentFails, int64_t uptimeS);

struct FrameLedgerTotals {
    int64_t frames = 0;
    int64_t presents = 0;
    int64_t drops = 0;
    int64_t present_fails = 0;
    int64_t residual = 0;
    int processStarts = 0;
    int processExits = 0;
    int sessionEnds = 0;
};

bool frameLedgerSumFile(const std::string& path, FrameLedgerTotals* out);

inline int64_t frameLedgerResidual(int64_t frames, int64_t presents, int64_t drops,
                                   int64_t presentFails = 0) {
    return frames - presents - drops - presentFails;
}

inline bool frameLedgerClosed(int64_t frames, int64_t presents, int64_t drops,
                              int64_t presentFails = 0) {
    return frameLedgerResidual(frames, presents, drops, presentFails) == 0;
}

// Hold edge for avDecide: Present requires drift >= -leadMs.
inline int64_t avPresentHoldEdgeMs(int64_t leadMs) { return -leadMs; }

// Instantaneous rate from a 1 Hz tick window (not cumulative session average).
inline double windowRateFps(int64_t dFrames, int64_t dWallMs) {
    if (dWallMs <= 0 || dFrames < 0)
        return 0.0;
    return 1000.0 * static_cast<double>(dFrames) / static_cast<double>(dWallMs);
}

// 3 decimal places — avoids substr(0,4) collapsing 23.90 vs 23.99.
inline std::string formatFps3(double fps) {
    char buf[32];
    std::snprintf(buf, sizeof(buf), "%.3f", fps);
    return std::string(buf);
}

} // namespace misterplex
