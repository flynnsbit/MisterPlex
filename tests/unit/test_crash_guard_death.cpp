// RED→GREEN: fatal SIGSEGV must leave misterplexd.death BEFORE re-raise.
// Proves installCrashGuard + deathBreadcrumbOnCrash path (rc=139 class).
#include "death_breadcrumb.hpp"
#include "fpga_spi.hpp"

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <string>
#include <sys/wait.h>
#include <unistd.h>

static std::string slurp(const std::string& path) {
    std::ifstream in(path);
    return std::string((std::istreambuf_iterator<char>(in)), std::istreambuf_iterator<char>());
}

int main() {
    char dir_template[] = "build/crash_guard_test_XXXXXX";
    const char* dir = ::mkdtemp(dir_template);
    if (!dir) {
        std::fprintf(stderr, "mkdtemp failed\n");
        return 1;
    }
    const std::string last = std::string(dir) + "/misterplexd.last";
    const std::string death = std::string(dir) + "/misterplexd.death";

    const pid_t pid = ::fork();
    if (pid < 0) {
        std::fprintf(stderr, "fork failed\n");
        return 1;
    }
    if (pid == 0) {
        misterplex::deathBreadcrumbSetPathsForTest(last, death);
        misterplex::deathBreadcrumbInit(dir);
        misterplex::deathBreadcrumbUpdate(misterplex::DeathState::Playing, 7, 7, 100, true);
        misterplex::FpgaSpi::installCrashGuard();
        // Deliberate SEGV — must be caught by crashGuardHandler first.
        volatile int* p = nullptr;
        *p = 42;
        _exit(99); // unreachable if SEGV works
    }

    int st = 0;
    if (::waitpid(pid, &st, 0) < 0) {
        std::fprintf(stderr, "waitpid failed\n");
        return 1;
    }
    if (!WIFSIGNALED(st) || WTERMSIG(st) != SIGSEGV) {
        std::fprintf(stderr, "FAIL want WIFSIGNALED SIGSEGV got st=%d WIFEXITED=%d rc=%d WIFSIGNALED=%d sig=%d\n",
                     st, WIFEXITED(st), WIFEXITED(st) ? WEXITSTATUS(st) : -1, WIFSIGNALED(st),
                     WIFSIGNALED(st) ? WTERMSIG(st) : -1);
        return 1;
    }
    const std::string txt = slurp(death);
    if (txt.find("death signal=11") == std::string::npos &&
        txt.find("death signal=SIGSEGV") == std::string::npos) {
        // Linux SIGSEGV == 11
        std::fprintf(stderr, "FAIL death file missing signal=11 content:\n%s\n", txt.c_str());
        return 1;
    }
    if (txt.find("si_code=") == std::string::npos) {
        std::fprintf(stderr, "FAIL death missing si_code:\n%s\n", txt.c_str());
        return 1;
    }
    std::printf("test_crash_guard_death: OK death=%s\n", txt.c_str());
    return 0;
}
