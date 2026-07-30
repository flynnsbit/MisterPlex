// Survives process death: last known daemon state + fatal-signal note.
// Hot path: no-op except rare state transitions (not per-frame).
// Async-signal-safe writer used from crash handlers (open/write/close only).
#pragma once

#include <atomic>
#include <cstdint>
#include <string>

namespace misterplex {

// confDir e.g. /media/fat/misterplex — files:
//   misterplexd.last   — last state (updated on transitions, throttled)
//   misterplexd.death  — written only on fatal signal / orderly exit note
void deathBreadcrumbInit(const std::string& confDir);

// Coarse state for the next death. Cheap atomics; disk write throttled (≥5s)
// unless force=true (play/stop/shutdown).
enum class DeathState : int {
    Boot = 0,
    Idle = 1,
    Playing = 2,
    Paused = 3,
    Stopping = 4,
    Seeking = 5,
};

void deathBreadcrumbUpdate(DeathState st, int64_t frames, int64_t presents, int64_t posMs,
                           bool force = false);

// Orderly exit (SIGTERM path / main return). Not async-signal-safe.
void deathBreadcrumbExit(int code, const char* why);

// Async-signal-safe: write misterplexd.death with signal number. No heap.
void deathBreadcrumbOnSignal(int sig);

// Host/lab override paths (tests). Empty = default under confDir.
void deathBreadcrumbSetPathsForTest(const std::string& lastPath, const std::string& deathPath);

} // namespace misterplex
