// Session-level Main suspend (SUSPEND_MAIN_DURING_PLAY).
// Product locator requires argv[0] == "/media/fat/MiSTer" exactly.
// Multi-match refuses; vanishing /proc entries are skipped (no abort).

#include "fpga_spi.hpp"

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fcntl.h>
#include <signal.h>
#include <string>
#include <sys/stat.h>
#include <sys/wait.h>
#include <unistd.h>

using misterplex::FpgaSpi;

static void die(const char* msg) {
    std::fprintf(stderr, "FAIL: %s\n", msg);
    std::exit(1);
}

static char procState(pid_t p) {
    char path[64];
    std::snprintf(path, sizeof(path), "/proc/%d/stat", static_cast<int>(p));
    int fd = ::open(path, O_RDONLY);
    if (fd < 0)
        return 0;
    char buf[256]{};
    ssize_t n = ::read(fd, buf, sizeof(buf) - 1);
    ::close(fd);
    if (n <= 0)
        return 0;
    const char* cp = std::strrchr(buf, ')');
    if (!cp)
        return 0;
    ++cp;
    while (*cp == ' ')
        ++cp;
    return *cp;
}

static bool waitForState(pid_t p, char want, int tries) {
    for (int i = 0; i < tries; ++i) {
        if (procState(p) == want)
            return true;
        usleep(50000);
    }
    return false;
}

// Craft argv0 without needing the path to exist on disk.
static pid_t spawnArgv0(const char* argv0) {
    pid_t pid = fork();
    if (pid < 0)
        die("fork");
    if (pid == 0) {
        const char* sleepBin =
            ::access("/bin/sleep", X_OK) == 0 ? "/bin/sleep" : "/usr/bin/sleep";
        execl(sleepBin, argv0, "3600", static_cast<char*>(nullptr));
        _exit(127);
    }
    return pid;
}

static void reap(pid_t pid) {
    if (pid > 0) {
        kill(pid, SIGCONT);
        kill(pid, SIGKILL);
        waitpid(pid, nullptr, 0);
    }
}

int main() {
    FpgaSpi::setSuspendMainDuringPlay(false);

    // --- 1) flag off: no-op ---
    pid_t one = spawnArgv0("/media/fat/MiSTer");
    usleep(100000);
    if (FpgaSpi::suspendMainForPlayback()) {
        reap(one);
        die("suspend with flag off must return false");
    }
    if (procState(one) == 'T') {
        reap(one);
        die("flag off must not STOP");
    }

    // --- 2) unique product Main: suspend + resume ---
    FpgaSpi::setSuspendMainDuringPlay(true);
    if (!FpgaSpi::suspendMainForPlayback()) {
        reap(one);
        die("unique product Main should suspend");
    }
    if (!waitForState(one, 'T', 40)) {
        FpgaSpi::resumeMainAfterPlayback();
        reap(one);
        die("Main not T after suspend");
    }
    if (!FpgaSpi::mainSuspendedForPlayback()) {
        FpgaSpi::resumeMainAfterPlayback();
        reap(one);
        die("held flag false");
    }
    FpgaSpi::resumeStrandedMain(); // must not fight hold
    if (procState(one) != 'T') {
        reap(one);
        die("resumeStrandedMain fought session hold");
    }
    // Idempotent second suspend stays held.
    if (!FpgaSpi::suspendMainForPlayback()) {
        FpgaSpi::resumeMainAfterPlayback();
        reap(one);
        die("second suspend should stay held");
    }
    FpgaSpi::resumeMainAfterPlayback();
    if (!waitForState(one, 'S', 40) && procState(one) == 'T') {
        reap(one);
        die("resume left Main stopped");
    }
    if (FpgaSpi::mainSuspendedForPlayback()) {
        reap(one);
        die("flag still held after resume");
    }
    FpgaSpi::resumeMainAfterPlayback(); // idempotent
    reap(one);
    one = -1;

    // --- 3) multi-match: refuse, leave both running (not T) ---
    pid_t a = spawnArgv0("/media/fat/MiSTer");
    pid_t b = spawnArgv0("/media/fat/MiSTer");
    usleep(150000);
    FpgaSpi::setSuspendMainDuringPlay(true);
    if (FpgaSpi::suspendMainForPlayback()) {
        reap(a);
        reap(b);
        die("multi-match must refuse suspend");
    }
    if (FpgaSpi::mainSuspendedForPlayback()) {
        reap(a);
        reap(b);
        die("multi-match must not set held flag");
    }
    if (procState(a) == 'T' || procState(b) == 'T') {
        reap(a);
        reap(b);
        die("multi-match must not SIGSTOP either pid");
    }
    reap(a);
    reap(b);

    // --- 4) basename-only argv0 is ignored by product suspend locator ---
    pid_t baseOnly = spawnArgv0("MiSTer");
    usleep(100000);
    FpgaSpi::setSuspendMainDuringPlay(true);
    if (FpgaSpi::suspendMainForPlayback()) {
        reap(baseOnly);
        die("basename-only argv0 must not suspend");
    }
    if (procState(baseOnly) == 'T') {
        reap(baseOnly);
        die("basename-only must not be stopped by product locator");
    }
    // mainAlive still sees basename fixtures (SPI path).
    if (!FpgaSpi::mainAlive()) {
        reap(baseOnly);
        die("mainAlive should still see basename MiSTer");
    }
    reap(baseOnly);

    // --- 5) vanishing pid: kill before suspend — skip, no abort ---
    pid_t vanish = spawnArgv0("/media/fat/MiSTer");
    usleep(50000);
    kill(vanish, SIGKILL);
    waitpid(vanish, nullptr, 0);
    FpgaSpi::setSuspendMainDuringPlay(true);
    if (FpgaSpi::suspendMainForPlayback())
        die("vanished Main must not report held");
    FpgaSpi::resumeMainAfterPlayback();

    std::printf("test_main_session_suspend: OK\n");
    return 0;
}
