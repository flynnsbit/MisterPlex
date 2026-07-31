// Red-before-green: frame ledger residual identity + multi-process visibility.
#include "libmisterplex/frame_ledger.hpp"

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
    char dir_template[] = "build/frame_ledger_test_XXXXXX";
    const char* dir = ::mkdtemp(dir_template);
    CHECK(dir != nullptr);
    if (!dir)
        return 1;
    const std::string path = std::string(dir) + "/misterplexd.frame_ledger";
    misterplex::frameLedgerSetPathForTest(path);

    // Two "process" lives with sessions — restart visible.
    misterplex::frameLedgerProcessStart(0, 0, 0);
    misterplex::frameLedgerSessionEnd(1, 100, 98, 2, "eof");
    CHECK(misterplex::frameLedgerResidual(100, 98, 2) == 0);
    misterplex::frameLedgerProcessExit(0, "signal-g_stop_sig=15", 100, 98, 2, 196);

    misterplex::frameLedgerProcessStart(0, 0, 0);
    misterplex::frameLedgerSessionEnd(1, 50, 40, 5, "stop");
    // residual 5: frames not all presented/dropped (overlay path etc.)
    CHECK(misterplex::frameLedgerResidual(50, 40, 5) == 5);
    misterplex::frameLedgerProcessExit(0, "signal-g_stop_sig=15", 50, 40, 5, 514);

    const std::string txt = slurp(path);
    CHECK(txt.find("event=process_start") != std::string::npos);
    CHECK(txt.find("event=session_end") != std::string::npos);
    CHECK(txt.find("event=process_exit") != std::string::npos);
    CHECK(txt.find("why=signal-g_stop_sig=15") != std::string::npos);
    // Two starts => restart is visible in the record
    int starts = 0;
    for (size_t i = 0; (i = txt.find("event=process_start", i)) != std::string::npos; ++i)
        ++starts;
    CHECK(starts == 2);

    misterplex::FrameLedgerTotals tot{};
    CHECK(misterplex::frameLedgerSumFile(path, &tot));
    CHECK(tot.processStarts == 2);
    CHECK(tot.processExits == 2);
    CHECK(tot.sessionEnds == 2);
    CHECK(tot.frames == 150);
    CHECK(tot.presents == 138);
    CHECK(tot.drops == 7);
    CHECK(tot.residual == 5); // 0 + 5
    // Soak identity over sessions: sum residual == sum(frames-presents-drops)
    CHECK(tot.residual == misterplex::frameLedgerResidual(tot.frames, tot.presents, tot.drops));

    // Missing file is not a silent pass of "balanced"
    misterplex::FrameLedgerTotals miss{};
    CHECK(!misterplex::frameLedgerSumFile(std::string(dir) + "/nope", &miss));
    CHECK(miss.sessionEnds == 0);

    if (fails) {
        std::fprintf(stderr, "test_frame_ledger: %d FAIL(s)\n", fails);
        return 1;
    }
    std::printf("test_frame_ledger: OK\n");
    return 0;
}
