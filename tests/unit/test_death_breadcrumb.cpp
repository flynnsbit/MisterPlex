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

    // siginfo path — SEGV with non-user code
    siginfo_t info{};
    info.si_signo = SIGSEGV;
    info.si_code = 1; // SEGV_MAPERR on Linux
    info.si_pid = 0;
    info.si_addr = reinterpret_cast<void*>(static_cast<uintptr_t>(0x10));
    misterplex::deathBreadcrumbOnSigInfo(&info);
    const std::string death_info = slurp(death);
    CHECK(death_info.find("death signal=11") != std::string::npos);
    CHECK(death_info.find("si_code=1") != std::string::npos);
    CHECK(death_info.find("si_code_name=OTHER") != std::string::npos);
    CHECK(death_info.find("si_addr=0x10") != std::string::npos);

    // SI_USER (kill from a process) — highest-value race-free discriminator
    siginfo_t user{};
    user.si_signo = SIGTERM;
    user.si_code = 0; // SI_USER
    user.si_pid = 4242;
    user.si_uid = 0;
    misterplex::deathBreadcrumbOnSigInfo(&user);
    const std::string death_user = slurp(death);
    CHECK(death_user.find("death signal=15") != std::string::npos);
    CHECK(death_user.find("si_code=0") != std::string::npos);
    CHECK(death_user.find("si_code_name=SI_USER") != std::string::npos);
    CHECK(death_user.find("si_pid=4242") != std::string::npos);
    CHECK(death_user.find("si_uid=0") != std::string::npos);

    if (fails) {
        std::fprintf(stderr, "test_death_breadcrumb: %d FAIL(s)\n", fails);
        return 1;
    }
    std::printf("test_death_breadcrumb: OK\n");
    return 0;
}
