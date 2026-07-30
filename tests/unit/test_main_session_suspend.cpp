// Session-level Main suspend (SUSPEND_MAIN_DURING_PLAY): once per playback,
// not per SPI frame. Pins locate-by-cmdline, STOP/CONT, and that
// resumeStrandedMain() does not fight an intentional hold.

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

static std::string makeFakeMain(const char* dir) {
    ::mkdir(dir, 0777);
    std::string path = std::string(dir) + "/MiSTer";
    ::unlink(path.c_str());
    const char* target = ::access("/bin/sleep", X_OK) == 0 ? "/bin/sleep" : "/usr/bin/sleep";
    if (::symlink(target, path.c_str()) != 0)
        die("cannot symlink fake MiSTer");
    return path;
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

int main() {
    if (FpgaSpi::mainAlive())
        die("a process named MiSTer is already running — cannot test cleanly");

    const char* dir = "build/mplex_session_suspend_fixture";
    std::string fake = makeFakeMain(dir);
    pid_t pid = fork();
    if (pid < 0)
        die("fork");
    if (pid == 0) {
        execl(fake.c_str(), fake.c_str(), "3600", static_cast<char*>(nullptr));
        _exit(127);
    }

    for (int i = 0; i < 40 && !FpgaSpi::mainAlive(); ++i)
        usleep(50000);
    if (!FpgaSpi::mainAlive()) {
        kill(pid, SIGKILL);
        waitpid(pid, nullptr, 0);
        die("mainAlive did not see fake MiSTer");
    }

    // Default OFF: suspend is a no-op.
    FpgaSpi::setSuspendMainDuringPlay(false);
    if (FpgaSpi::suspendMainForPlayback()) {
        kill(pid, SIGKILL);
        waitpid(pid, nullptr, 0);
        die("suspend with flag off should return false");
    }
    if (procState(pid) == 'T') {
        kill(pid, SIGCONT);
        kill(pid, SIGKILL);
        waitpid(pid, nullptr, 0);
        die("flag off must not STOP Main");
    }

    FpgaSpi::setSuspendMainDuringPlay(true);
    if (!FpgaSpi::suspendMainForPlayback()) {
        // On host without /dev/mem GPO sample still succeeds (gpoOk default true).
        kill(pid, SIGKILL);
        waitpid(pid, nullptr, 0);
        die("suspendMainForPlayback failed with flag on");
    }
    if (!waitForState(pid, 'T', 40)) {
        FpgaSpi::resumeMainAfterPlayback();
        kill(pid, SIGKILL);
        waitpid(pid, nullptr, 0);
        die("Main not in state T after suspend");
    }
    if (!FpgaSpi::mainSuspendedForPlayback()) {
        FpgaSpi::resumeMainAfterPlayback();
        kill(pid, SIGKILL);
        waitpid(pid, nullptr, 0);
        die("mainSuspendedForPlayback false while held");
    }

    // Watchdog must not CONT an intentional session hold.
    FpgaSpi::resumeStrandedMain();
    if (procState(pid) != 'T') {
        kill(pid, SIGKILL);
        waitpid(pid, nullptr, 0);
        die("resumeStrandedMain fought session hold");
    }

    // Idempotent second suspend.
    if (!FpgaSpi::suspendMainForPlayback()) {
        FpgaSpi::resumeMainAfterPlayback();
        kill(pid, SIGKILL);
        waitpid(pid, nullptr, 0);
        die("second suspend should stay held");
    }

    FpgaSpi::resumeMainAfterPlayback();
    if (!waitForState(pid, 'S', 40) && procState(pid) == 'T') {
        kill(pid, SIGCONT);
        kill(pid, SIGKILL);
        waitpid(pid, nullptr, 0);
        die("resumeMainAfterPlayback left Main stopped");
    }
    if (FpgaSpi::mainSuspendedForPlayback()) {
        kill(pid, SIGKILL);
        waitpid(pid, nullptr, 0);
        die("flag still held after resume");
    }

    // Idempotent resume.
    FpgaSpi::resumeMainAfterPlayback();

    kill(pid, SIGKILL);
    waitpid(pid, nullptr, 0);
    ::unlink(fake.c_str());
    ::rmdir(dir);
    std::printf("test_main_session_suspend: OK\n");
    return 0;
}
