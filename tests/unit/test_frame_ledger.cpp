// Frame ledger: residual identity, multi-process visibility, lead deadband, window rates.
#include "libmisterplex/av_clock.hpp"
#include "libmisterplex/frame_ledger.hpp"

#include <cmath>
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
    using namespace misterplex;

    char dir_template[] = "build/frame_ledger_test_XXXXXX";
    const char* dir = ::mkdtemp(dir_template);
    CHECK(dir != nullptr);
    if (!dir)
        return 1;
    const std::string path = std::string(dir) + "/misterplexd.frame_ledger";
    frameLedgerSetPathForTest(path);

    frameLedgerProcessStart(0, 0, 0, 0);
    frameLedgerSessionEnd(1, 100, 97, 2, 1, "eof");
    CHECK(frameLedgerResidual(100, 97, 2, 1) == 0);
    CHECK(frameLedgerClosed(100, 97, 2, 1));
    frameLedgerProcessExit(0, "signal-g_stop_sig=15", 100, 97, 2, 1, 196);

    frameLedgerProcessStart(0, 0, 0, 0);
    frameLedgerSessionEnd(1, 4464, 4447, 1, 0, "stop");
    CHECK(frameLedgerResidual(4464, 4447, 1, 0) == 16);
    CHECK(!frameLedgerClosed(4464, 4447, 1, 0));
    frameLedgerProcessExit(0, "signal-g_stop_sig=15", 50, 40, 5, 0, 514);

    const std::string txt = slurp(path);
    CHECK(txt.find("event=process_start") != std::string::npos);
    CHECK(txt.find("event=session_end") != std::string::npos);
    CHECK(txt.find("event=process_exit") != std::string::npos);
    CHECK(txt.find("why=signal-g_stop_sig=15") != std::string::npos);
    CHECK(txt.find("present_fails=1") != std::string::npos);
    CHECK(txt.find("closed=1") != std::string::npos);
    CHECK(txt.find("closed=0") != std::string::npos);
    int starts = 0;
    for (size_t i = 0; (i = txt.find("event=process_start", i)) != std::string::npos; ++i)
        ++starts;
    CHECK(starts == 2);

    FrameLedgerTotals tot{};
    CHECK(frameLedgerSumFile(path, &tot));
    CHECK(tot.processStarts == 2);
    CHECK(tot.processExits == 2);
    CHECK(tot.sessionEnds == 2);
    CHECK(tot.frames == 100 + 4464);
    CHECK(tot.presents == 97 + 4447);
    CHECK(tot.drops == 2 + 1);
    CHECK(tot.present_fails == 1);
    CHECK(tot.residual == 0 + 16);
    CHECK(tot.residual ==
          frameLedgerResidual(tot.frames, tot.presents, tot.drops, tot.present_fails));

    FrameLedgerTotals miss{};
    CHECK(!frameLedgerSumFile(std::string(dir) + "/nope", &miss));
    CHECK(miss.sessionEnds == 0);

    CHECK(avPresentHoldEdgeMs(40) == -40);
    CHECK(avPresentHoldEdgeMs(20) == -20);
    {
        const int64_t drop = 80;
        CHECK(avDecide(-40, 40, drop, 0) == AvAction::Present);
        CHECK(avDecide(-41, 40, drop, 0) == AvAction::Hold);
        CHECK(avDecide(-40, 20, drop, 0) == AvAction::Hold);
        CHECK(avDecide(-21, 20, drop, 0) == AvAction::Hold);
        CHECK(avDecide(-20, 20, drop, 0) == AvAction::Present);
        CHECK(avDecide(-38, 40, drop, 0) == AvAction::Present);
        CHECK(avDecide(-38, 20, drop, 0) == AvAction::Hold);
    }

    CHECK(std::fabs(windowRateFps(24, 1000) - 24.0) < 1e-9);
    CHECK(windowRateFps(10, 0) == 0.0);
    CHECK(formatFps3(23.976) == "23.976");

    if (fails) {
        std::fprintf(stderr, "test_frame_ledger: %d FAIL(s)\n", fails);
        return 1;
    }
    std::printf("test_frame_ledger: OK\n");
    return 0;
}
