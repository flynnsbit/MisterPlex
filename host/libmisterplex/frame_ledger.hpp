#pragma once
// Explicit frame ledger for soak integrity (promotion blocker P5).
//
// Product path (STREAM=0 rawvideo + A/V pacer) consumes every decoded frame in
// exactly one of:
//   presented      — FPGA present succeeded (countPresent)
//   pacer_drops    — avDecide(Drop); deliberate A/V resync skip
//   present_fails  — present attempted, FPGA/DDR tx failed
//
// Identity (must hold for a single ledger session):
//   decoded == presented + pacer_drops + present_fails + unaccounted
// with unaccounted == 0 when the ledger is closed.
//
// droppedFrames_ historically counted ONLY pacer drops. Frames lost any other
// way were invisible — that is the free variable behind "vfps 23.914 vs 24.000
// with drops=1". present_fails + unaccounted make the remainder explicit.
//
// Resets: counters are zeroed per stream/play. A monotonic session_id must bump
// on every reset so a mid-soak daemon respawn cannot be mistaken for one
// continuous ledger (w-geom owns exit RCA; this only makes restarts visible).

#include <cstdint>
#include <string>

namespace misterplex {

struct FrameLedgerSnapshot {
    uint64_t session_id = 0;
    int64_t decoded = 0;       // frameIndex: frames taken from the pipe and paced
    int64_t presented = 0;     // successful countPresent FPGA presents
    int64_t pacer_drops = 0;   // avDecide Drop only
    int64_t present_fails = 0; // present attempted, tx failed
    int32_t pid = 0;           // process id at last reset (restart visibility)
};

// decoded - presented - pacer_drops - present_fails. Negative is also open
// (over-count — a bug, not a soft zero).
inline int64_t frameLedgerUnaccounted(const FrameLedgerSnapshot& s) {
    return s.decoded - s.presented - s.pacer_drops - s.present_fails;
}

inline bool frameLedgerClosed(const FrameLedgerSnapshot& s) {
    return frameLedgerUnaccounted(s) == 0;
}

// Single-line token set for logs and soak parsers. Stable key=value order.
inline std::string formatFrameLedgerLine(const FrameLedgerSnapshot& s, const char* tag) {
    const int64_t u = frameLedgerUnaccounted(s);
    const int closed = (u == 0) ? 1 : 0;
    std::string out;
    out.reserve(192);
    out += "media: ";
    out += (tag && tag[0]) ? tag : "ledger";
    out += " session_id=";
    out += std::to_string(s.session_id);
    out += " pid=";
    out += std::to_string(s.pid);
    out += " decoded=";
    out += std::to_string(s.decoded);
    out += " presented=";
    out += std::to_string(s.presented);
    out += " pacer_drops=";
    out += std::to_string(s.pacer_drops);
    out += " present_fails=";
    out += std::to_string(s.present_fails);
    out += " unaccounted=";
    out += std::to_string(u);
    out += " closed=";
    out += std::to_string(closed);
    return out;
}

// Hold edge for avDecide: Present requires drift >= -leadMs.
// Steady-state samples under forced CFR therefore live in [-leadMs, dropMs]
// (or more negative only transiently while Hold loops before the 1 Hz log).
inline int64_t avPresentHoldEdgeMs(int64_t leadMs) { return -leadMs; }

} // namespace misterplex
