// Survives process death: last known daemon state + fatal-signal note.
// Hot path: no-op except rare state transitions (not per-frame).
// Async-signal-safe writer used from crash handlers (open/write/close only).
//
// LIMIT (hard): SIGKILL and OOM-killer do not run any handler. In those cases
// misterplexd.death is absent or STALE; only the supervising parent (waitpid /
// SUPERVISE_EXIT) and kernel logs can explain the death. Do not treat handler
// silence as "not a signal death".
#pragma once

#include <atomic>
#include <cstdint>
#include <string>

#include <signal.h>

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
// Prefer deathBreadcrumbOnCrash / OnSigInfo when SA_SIGINFO is available.
void deathBreadcrumbOnSignal(int sig);

// Async-signal-safe: record si_signo/si_code/si_pid/si_addr (+ coarse state).
// Distinguishes crash (SEGV_MAPERR/ACCERR) from kill(2) (SI_USER/SI_TKILL).
void deathBreadcrumbOnSigInfo(const siginfo_t* info);

// Async-signal-safe crash path: siginfo + best-effort PC/LR from ucontext
// (void* is ucontext_t* from sa_sigaction). No libc backtrace (not AS-safe).
// Writes misterplexd.death then returns — caller must re-raise / _exit.
void deathBreadcrumbOnCrash(const siginfo_t* info, void* ucontext);

// Host/lab override paths (tests). Empty = default under confDir.
void deathBreadcrumbSetPathsForTest(const std::string& lastPath, const std::string& deathPath);

} // namespace misterplex
