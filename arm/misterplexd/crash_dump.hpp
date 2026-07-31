#pragma once
// Fatal-signal crash dump for misterplexd.
//
// Async-signal-safe path only: write(2) + backtrace() + backtrace_symbols_fd().
// No malloc, printf, or std::string on the signal path.
//
// Dumps go to:
//   1) a pre-opened persistent crash file on the SD card (survives reboot)
//   2) a pre-duped log/stderr fd (supervisor log)
//
// Static ARM builds: backtrace_symbols_fd often prints bare addresses; the dump
// always includes raw PCs + load_base for offline addr2line.

namespace misterplex {

// Default persistent path (v2 daily-driver bundle). Init may override.
inline constexpr const char* kDefaultCrashPath = "/media/fat/misterplex_v2/misterplexd.crash";
inline constexpr const char* kFallbackCrashPath = "/media/fat/misterplex/misterplexd.crash";

// Dup logFd (or stderr), open persistent crash file, capture load base + build id.
// crashPath may be null → try kDefaultCrashPath then kFallbackCrashPath.
// buildId may be null → use compile-time MISTERPLEXD_BUILD_ID if defined.
void crashDumpInit(int logFd = -1, const char* crashPath = nullptr,
                   const char* buildId = nullptr);

// Best-effort activity breadcrumb (normal threads only — not signal-safe to call
// with heap strings you free immediately; the copy is into a fixed buffer).
void crashDumpNote(const char* msg);
void crashDumpNoteKey(const char* key, const char* sessionId = nullptr);

// Install SA_SIGINFO handlers for SIGSEGV/ABRT/BUS/FPE/ILL/QUIT.
// on_before_reraise must be async-signal-safe (e.g. resume stranded Main).
// After the dump the signal is re-raised with default disposition so exit
// status stays truthful (rc=139 for SIGSEGV).
void crashDumpInstall(void (*on_before_reraise)(int sig) = nullptr);

// Test hook: write a synthetic dump without raising.
void crashDumpWriteNow(int sig, const void* faultAddr, int siCode = 0);

// Path actually opened for the persistent crash file (empty if open failed).
const char* crashDumpPath();

} // namespace misterplex
