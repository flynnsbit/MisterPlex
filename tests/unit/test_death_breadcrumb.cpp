// Unit: death breadcrumb files for orderly exit + signal path.
#include "death_breadcrumb.hpp"

#include <cstdio>
#include <cstdlib>
#include <fstream>
#include <string>
#include <unistd.h>

static int fails = 0;
#define CHECK(cond)                                                                              \
    do {                                                                                         \
        if (!(cond)) {                                                                           \
            std::fprintf(stderr, "FAIL %s:%d: %s\n", __FILE__, __LINE__, #cond);                 \
            ++fails;                                                                             \
        }                                                                                        \
    } while (0)

static std::string slurp(const std::string& path) {
    std::ifstream in(path);
    return std::string((std::istreambuf_iterator<char>(in)), std::istreambuf_iterator<char>());
}

int main() {
    char dir_template[] = "build/death_bc_test_XXXXXX";
    const char* dir = ::mkdtemp(dir_template);
    CHECK(dir != nullptr);
    if (!dir) return 1;

    const std::string last = std::string(dir) + "/misterplexd.last";
    const std::string death = std::string(dir) + "/misterplexd.death";
    misterplex::deathBreadcrumbSetPathsForTest(last, death);
    misterplex::deathBreadcrumbInit(dir);
    misterplex::deathBreadcrumbUpdate(misterplex::DeathState::Playing, 12, 3, 4500, true);

    const std::string last_txt = slurp(last);
    CHECK(last_txt.find("state=playing") != std::string::npos);
    CHECK(last_txt.find("frames=12") != std::string::npos);
    CHECK(last_txt.find("pos_ms=4500") != std::string::npos);

    misterplex::deathBreadcrumbExit(0, "unit-clean");
    const std::string death_exit = slurp(death);
    CHECK(death_exit.find("exit_code=0") != std::string::npos);
    CHECK(death_exit.find("why=unit-clean") != std::string::npos);
    CHECK(death_exit.find("state=playing") != std::string::npos);

    // Signal-only path (no full siginfo_t construction portability issues):
    misterplex::deathBreadcrumbOnSignal(11);
    const std::string death_sig = slurp(death);
    CHECK(death_sig.find("death signal=11") != std::string::npos);

    // siginfo path
    siginfo_t info{};
    info.si_signo = SIGSEGV;
    info.si_code = 1; // SEGV_MAPERR on Linux
    info.si_pid = 0;
    info.si_addr = reinterpret_cast<void*>(static_cast<uintptr_t>(0x10));
    misterplex::deathBreadcrumbOnSigInfo(&info);
    const std::string death_info = slurp(death);
    CHECK(death_info.find("death signal=11") != std::string::npos);
    CHECK(death_info.find("si_code=1") != std::string::npos);
    CHECK(death_info.find("si_addr=0x10") != std::string::npos);

    // Crash path (siginfo + optional ucontext regs); null uctx still writes si_*.
    misterplex::deathBreadcrumbOnCrash(&info, nullptr);
    const std::string death_crash = slurp(death);
    CHECK(death_crash.find("death signal=11") != std::string::npos);
    CHECK(death_crash.find("frames=") != std::string::npos);

    // Orderly product-shaped why string (main_loop_g_stop is the soak rc=0 site).
    misterplex::deathBreadcrumbExit(
        0, "site=main.cpp:main_loop_g_stop sig=15 si_code=0 si_pid=1 (handled→WIFEXITED 0; not WIFSIGNALED)");
    const std::string death_term = slurp(death);
    CHECK(death_term.find("exit_code=0") != std::string::npos);
    CHECK(death_term.find("main_loop_g_stop") != std::string::npos);
    CHECK(death_term.find("sig=15") != std::string::npos);

    if (fails) {
        std::fprintf(stderr, "test_death_breadcrumb: %d FAIL(s)\n", fails);
        return 1;
    }
    std::printf("test_death_breadcrumb: OK\n");
    return 0;
}
