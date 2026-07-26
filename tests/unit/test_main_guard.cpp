// Guards the two ways misterplexd can leave a MiSTer with no usable Main:
//
//   1. SPI exclusivity SIGSTOPs Main for the critical section. If the daemon dies
//      inside that window nothing sends SIGCONT and Main stays stopped forever —
//      no F12, no OSD, no /dev/MiSTer_cmd.
//   2. /etc/inittab starts Main with `::sysinit:/media/fat/MiSTer &` — sysinit,
//      not respawn — so if Main exits, nothing on the board restarts it.
//
// Both are unrecoverable for the user without a power cycle, so the detection
// side is pinned here. We deliberately do NOT exercise ensureMainAlive(): it
// execs /media/fat/MiSTer, which does not exist on the build host.

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

// findMisterPids() matches on argv[0]'s basename. A shell script will not do —
// the kernel puts the interpreter in argv[0] — so symlink a real binary and exec
// it under the name "MiSTer".
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
    const char* dir = "/tmp/mplex_guard_fixture";
    std::string fake = makeFakeMain(dir);

    if (FpgaSpi::mainAlive())
        die("a process named MiSTer is already running — cannot test cleanly");

    pid_t pid = fork();
    if (pid < 0)
        die("fork");
    if (pid == 0) {
        execl(fake.c_str(), fake.c_str(), "3600", static_cast<char*>(nullptr));
        _exit(127);
    }

    // 1. liveness detection
    bool seen = false;
    for (int i = 0; i < 40 && !seen; ++i) {
        if (FpgaSpi::mainAlive())
            seen = true;
        else
            usleep(50000);
    }
    if (!seen) {
        kill(pid, SIGKILL);
        waitpid(pid, nullptr, 0);
        die("mainAlive() did not see the running MiSTer");
    }

    // 2. a stranded (SIGSTOPped) Main is detected and resumed
    kill(pid, SIGSTOP);
    if (!waitForState(pid, 'T', 40)) {
        kill(pid, SIGKILL);
        waitpid(pid, nullptr, 0);
        die("fake MiSTer did not reach state T");
    }
    if (FpgaSpi::mainPaused()) {
        kill(pid, SIGKILL);
        waitpid(pid, nullptr, 0);
        die("mainPaused() true with no SpiExclusive held");
    }

    FpgaSpi::resumeStrandedMain();
    if (!waitForState(pid, 'S', 40) && procState(pid) == 'T') {
        kill(pid, SIGCONT);
        kill(pid, SIGKILL);
        waitpid(pid, nullptr, 0);
        die("resumeStrandedMain() left MiSTer stopped");
    }

    // 3. resumeStrandedMain() is idempotent on a healthy Main
    FpgaSpi::resumeStrandedMain();
    if (procState(pid) == 'T') {
        kill(pid, SIGCONT);
        kill(pid, SIGKILL);
        waitpid(pid, nullptr, 0);
        die("second resumeStrandedMain() stopped a healthy MiSTer");
    }

    kill(pid, SIGKILL);
    waitpid(pid, nullptr, 0);

    // 4. death is detected
    for (int i = 0; i < 40 && FpgaSpi::mainAlive(); ++i)
        usleep(50000);
    if (FpgaSpi::mainAlive())
        die("mainAlive() still true after MiSTer exited");

    ::unlink(fake.c_str());
    ::rmdir(dir);
    std::printf("test_main_guard: OK\n");
    return 0;
}
