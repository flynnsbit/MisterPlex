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
// Preserves last SA_SIGINFO fields (si_signo/si_code/si_pid) so SUPERVISE_EXIT
// can still attribute the sender after overwriting the signal-safe death line.
// Includes sender_cmd/sender_chain if deathBreadcrumbCaptureSender ran first.
void deathBreadcrumbExit(int code, const char* why);

// Steady-clock seconds since deathBreadcrumbInit (0 if never inited).
int64_t deathBreadcrumbUptimeS();

// Immediately after main observes g_stop (outside signal context): read
// /proc/<si_pid>/{cmdline,comm,status} and walk PPid a few levels. Call BEFORE
// any long teardown (player.stop) — the sender may die within milliseconds.
//
// Results land in misterplexd.death + stderr as:
//   sender_status=LIVE|GONE|NONE  sender_cmd=… sender_comm=… sender_chain=…
// GONE is NO-DATA (pid recycled or already reaped) — never "nobody".
void deathBreadcrumbCaptureSender(int sender_pid);

// Test/observability: last capture status token (LIVE|GONE|NONE|UNSET).
const char* deathBreadcrumbSenderStatus();
const char* deathBreadcrumbSenderCmd();
const char* deathBreadcrumbSenderChain();

// Async-signal-safe: write misterplexd.death with signal number. No heap.
// Prefer deathBreadcrumbOnSigInfo when SA_SIGINFO is available.
// Used by crashGuard (SIGSEGV/etc.) before re-raise — without this, rc=139
// leaves death absent/stale because the crash handler only CONT'd Main.
void deathBreadcrumbOnSignal(int sig);

// Async-signal-safe: record si_signo/si_code/si_pid/si_addr (+ coarse state).
// Distinguishes crash (SEGV_MAPERR/ACCERR) from kill(2) (SI_USER/SI_TKILL).
void deathBreadcrumbOnSigInfo(const siginfo_t* info);

// Host/lab override paths (tests). Empty = default under confDir.
void deathBreadcrumbSetPathsForTest(const std::string& lastPath, const std::string& deathPath);

} // namespace misterplex
