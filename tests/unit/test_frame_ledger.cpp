// Unit tests: explicit soak frame ledger + A/V lead deadband edges (P5/P6).
#include "libmisterplex/av_clock.hpp"
#include "libmisterplex/frame_ledger.hpp"

#include <cstdio>
#include <string>

static int fails = 0;
#define CHECK(cond)                                                                              \
    do {                                                                                         \
        if (!(cond)) {                                                                           \
            std::fprintf(stderr, "FAIL %s:%d: %s\n", __FILE__, __LINE__, #cond);                 \
            ++fails;                                                                             \
        }                                                                                        \
    } while (0)

int main() {
    using namespace misterplex;

    // --- closed ledger: every decoded frame is one of present/drop/fail ---
    {
        FrameLedgerSnapshot s;
        s.session_id = 1;
        s.pid = 4242;
        s.decoded = 100;
        s.presented = 97;
        s.pacer_drops = 2;
        s.present_fails = 1;
        CHECK(frameLedgerUnaccounted(s) == 0);
        CHECK(frameLedgerClosed(s));
        const std::string line = formatFrameLedgerLine(s, "ledger");
        CHECK(line.find("session_id=1") != std::string::npos);
        CHECK(line.find("pid=4242") != std::string::npos);
        CHECK(line.find("decoded=100") != std::string::npos);
        CHECK(line.find("presented=97") != std::string::npos);
        CHECK(line.find("pacer_drops=2") != std::string::npos);
        CHECK(line.find("present_fails=1") != std::string::npos);
        CHECK(line.find("unaccounted=0") != std::string::npos);
        CHECK(line.find("closed=1") != std::string::npos);
    }

    // --- open ledger: the soak objection (≈16 missing vs drops=1) ---
    {
        // 24.000 source over wall T with mean presented 23.914 → gap ~0.086*T.
        // At T=186 s that is ~16 frames. drops=1 cannot close it alone.
        FrameLedgerSnapshot s;
        s.session_id = 2;
        s.decoded = 4464;   // 24 * 186
        s.presented = 4447; // ~23.914 * 186
        s.pacer_drops = 1;
        s.present_fails = 0;
        CHECK(frameLedgerUnaccounted(s) == 16);
        CHECK(!frameLedgerClosed(s));
        const std::string line = formatFrameLedgerLine(s, "ledger_tick");
        CHECK(line.find("unaccounted=16") != std::string::npos);
        CHECK(line.find("closed=0") != std::string::npos);
        CHECK(line.find("pacer_drops=1") != std::string::npos);
    }

    // --- over-count is also open (negative unaccounted) ---
    {
        FrameLedgerSnapshot s;
        s.decoded = 10;
        s.presented = 8;
        s.pacer_drops = 3;
        s.present_fails = 0;
        CHECK(frameLedgerUnaccounted(s) == -1);
        CHECK(!frameLedgerClosed(s));
    }

    // --- P6 deadband: hold edge tracks lead setpoint ---
    CHECK(avPresentHoldEdgeMs(40) == -40);
    CHECK(avPresentHoldEdgeMs(20) == -20);
    {
        const int64_t drop = 80;
        // Just inside lead=40 window → Present; just outside → Hold.
        CHECK(avDecide(-40, 40, drop, 0) == AvAction::Present); // drift + lead == 0
        CHECK(avDecide(-41, 40, drop, 0) == AvAction::Hold);
        // Same samples under lead=20: -40 is deep Hold; -20 is edge Present.
        CHECK(avDecide(-40, 20, drop, 0) == AvAction::Hold);
        CHECK(avDecide(-21, 20, drop, 0) == AvAction::Hold);
        CHECK(avDecide(-20, 20, drop, 0) == AvAction::Present);
        CHECK(avDecide(-10, 20, drop, 0) == AvAction::Present);
        // Parent-observed band −21..−38 under lead=40 is inside Present window
        // for lead=40 but mostly Hold for lead=20 — if live drift tracks the
        // setpoint, samples must move toward [−20, 0] after lead=20.
        CHECK(avDecide(-21, 40, drop, 0) == AvAction::Present);
        CHECK(avDecide(-38, 40, drop, 0) == AvAction::Present);
        CHECK(avDecide(-21, 20, drop, 0) == AvAction::Hold);
        CHECK(avDecide(-38, 20, drop, 0) == AvAction::Hold);
    }

    if (fails) {
        std::fprintf(stderr, "test_frame_ledger: %d failures\n", fails);
        return 1;
    }
    std::printf("test_frame_ledger: OK\n");
    return 0;
}
