#pragma once
// Fatal-signal crash dump for misterplexd.
// Async-signal-safe path: write(2) to a pre-opened fd + backtrace() only.
// Static ARM builds: backtrace_symbols_fd() degrades to bare addresses; the dump
// always prints raw PCs and the load base so the parent can addr2line offline.

#include <cstddef>

namespace misterplex {

// Dup stderr (or take ownership of fd) and capture the executable load base.
// Call once early in main before installCrashGuard().
void crashDumpInit(int logFd = -1);

// Best-effort activity breadcrumb for the next crash dump.
// Safe to call from normal threads only (not from a signal handler).
// Copies into a fixed buffer; a concurrent crash may see a torn string.
void crashDumpNote(const char* msg);

// Convenience: format "key=... session=..." style notes without heap churn beyond
// a stack buffer. Truncates at 240 bytes.
void crashDumpNoteKey(const char* key, const char* sessionId = nullptr);

// Install SA_SIGINFO handlers for SIGSEGV/SIGABRT/SIGBUS/SIGFPE/SIGILL/SIGQUIT.
// on_before_reraise is optional and must itself be async-signal-safe (e.g. resume
// stranded Main). After the dump, the signal is re-raised with the default
// disposition so the supervisor still sees rc=139.
void crashDumpInstall(void (*on_before_reraise)(int sig) = nullptr);

// Test hook: write a synthetic dump without raising (host unit tests).
void crashDumpWriteNow(int sig, const void* faultAddr);

} // namespace misterplex
