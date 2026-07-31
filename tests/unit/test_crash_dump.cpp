// Unit test: crash dump produces a non-empty persistent file with frames.
//
// Two checks:
//  1) crashDumpWriteNow writes required fields (build, si_addr, raw_frames).
//  2) A forked child installs the real signal handler, raises SIGSEGV, and the
//     parent asserts the crash file exists, is non-empty, and reports nframes>=1.
//
// A test that only checks "handler installed" is not sufficient.

#include "crash_dump.hpp"

#include <cerrno>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fcntl.h>
#include <signal.h>
#include <string>
#include <sys/stat.h>
#include <sys/wait.h>
#include <unistd.h>

static void die(const char* msg) {
    std::fprintf(stderr, "FAIL: %s\n", msg);
    std::exit(1);
}

static std::string readFile(const char* path) {
    int fd = ::open(path, O_RDONLY | O_CLOEXEC);
    if (fd < 0)
        return {};
    std::string out;
    char buf[4096];
    for (;;) {
        ssize_t n = ::read(fd, buf, sizeof(buf));
        if (n < 0) {
            if (errno == EINTR)
                continue;
            break;
        }
        if (n == 0)
            break;
        out.append(buf, static_cast<size_t>(n));
    }
    ::close(fd);
    return out;
}

static void requireContains(const std::string& s, const char* frag) {
    if (s.find(frag) == std::string::npos) {
        std::fprintf(stderr, "missing %s in dump (%zu bytes):\n%.800s\n", frag, s.size(),
                     s.c_str());
        die("missing field");
    }
}

static int countRawFrames(const std::string& s) {
    int n = 0;
    size_t pos = 0;
    while ((pos = s.find("  #", pos)) != std::string::npos) {
        ++n;
        pos += 3;
    }
    return n;
}

// Deliver a real fatal signal to this process. Prefer raise(SIGSEGV) so the
// compiler cannot optimize the fault away under -O2 (a null store sometimes
// becomes a trap instruction that never runs if the block is proven dead).
__attribute__((noinline, noclone)) static void boom() {
    ::raise(SIGSEGV);
    // Fallback: if raise is blocked/ignored, force a faulting store.
    volatile int* p = reinterpret_cast<volatile int*>(static_cast<uintptr_t>(1));
    *p = 0xbad;
    _exit(3);
}

int main() {
    const char* dir = "build/crash_dump_unit";
    ::mkdir("build", 0755);
    ::mkdir(dir, 0755);

    // --- 1) synthetic write (no raise) ----------------------------------------
    std::string synthPath = std::string(dir) + "/synth.crash";
    ::unlink(synthPath.c_str());
    int logFd = ::open((std::string(dir) + "/synth.log").c_str(),
                       O_CREAT | O_TRUNC | O_RDWR | O_CLOEXEC, 0644);
    if (logFd < 0)
        die("open synth log");

    misterplex::crashDumpInit(logFd, synthPath.c_str(), "unit-test-build");
    misterplex::crashDumpNoteKey("/library/metadata/42", "42");
    misterplex::crashDumpWriteNow(11, reinterpret_cast<void*>(static_cast<uintptr_t>(0xdeadbeefUL)),
                                  1);
    ::close(logFd);

    std::string synth = readFile(synthPath.c_str());
    if (synth.empty())
        die("synth crash file empty");
    requireContains(synth, "===== misterplexd FATAL =====");
    requireContains(synth, "build=unit-test-build");
    requireContains(synth, "signal=11");
    requireContains(synth, "si_code=1");
    requireContains(synth, "si_addr=0xdeadbeef");
    requireContains(synth, "tid=");
    requireContains(synth, "load_base=0x");
    requireContains(synth, "context=key=/library/metadata/42 session=42");
    requireContains(synth, "raw_frames:");
    requireContains(synth, "nframes=");
    {
        int nf = countRawFrames(synth);
        if (nf < 1) {
            std::fprintf(stderr, "synth nframes raw lines=%d\n", nf);
            die("synth expected >=1 raw frame");
        }
    }

    // --- 2) real SIGSEGV in a child -------------------------------------------
    std::string realPath = std::string(dir) + "/real.crash";
    ::unlink(realPath.c_str());

    pid_t child = ::fork();
    if (child < 0)
        die("fork");

    if (child == 0) {
        // Child: install handler pointing at realPath, then fault.
        int cLog = ::open((std::string(dir) + "/real.log").c_str(),
                          O_CREAT | O_TRUNC | O_RDWR | O_CLOEXEC, 0644);
        misterplex::crashDumpInit(cLog >= 0 ? cLog : STDERR_FILENO, realPath.c_str(),
                                  "unit-fork-build");
        misterplex::crashDumpNote("test=fork-segv");
        misterplex::crashDumpInstall(nullptr);
        boom();
        _exit(2); // should not reach
    }

    int st = 0;
    if (::waitpid(child, &st, 0) != child)
        die("waitpid");
    if (!WIFSIGNALED(st) || WTERMSIG(st) != SIGSEGV) {
        std::fprintf(stderr, "child status=0x%x expected SIGSEGV\n", st);
        die("child did not die of SIGSEGV");
    }

    // Allow fsync/close to settle on slow FS.
    for (int i = 0; i < 50; ++i) {
        struct stat sb {};
        if (::stat(realPath.c_str(), &sb) == 0 && sb.st_size > 0)
            break;
        usleep(10000);
    }

    std::string real = readFile(realPath.c_str());
    if (real.empty())
        die("real crash file empty after SIGSEGV child");
    requireContains(real, "===== misterplexd FATAL =====");
    requireContains(real, "build=unit-fork-build");
    requireContains(real, "signal=11");
    requireContains(real, "si_addr=");
    requireContains(real, "si_code=");
    requireContains(real, "context=test=fork-segv");
    requireContains(real, "raw_frames:");
    requireContains(real, "nframes=");
    {
        // Parse nframes=N
        auto p = real.find("nframes=");
        if (p == std::string::npos)
            die("no nframes field");
        int nframes = std::atoi(real.c_str() + p + 8);
        int rawLines = countRawFrames(real);
        if (nframes < 1) {
            std::fprintf(stderr, "nframes=%d\n%s\n", nframes, real.c_str());
            die("nframes < 1");
        }
        if (rawLines < 1) {
            std::fprintf(stderr, "raw frame lines=%d nframes=%d\n", rawLines, nframes);
            die("no raw frame lines");
        }
        std::printf("fork-segv nframes=%d raw_lines=%d crash_bytes=%zu\n", nframes, rawLines,
                    real.size());
    }

    // Path accessor reflects last init in this process (synth path).
    if (!misterplex::crashDumpPath() || !misterplex::crashDumpPath()[0])
        die("crashDumpPath empty after init");

    std::printf("PASS test_crash_dump\n");
    return 0;
}
