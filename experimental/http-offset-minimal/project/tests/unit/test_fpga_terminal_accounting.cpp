#include "libmisterplex/fpga_terminal.hpp"

#include <cstdio>
#include <stdexcept>
#include <vector>

using namespace misterplex;

static void require(bool value, const char* message) {
    if (!value) throw std::runtime_error(message);
}

int main() {
    try {
        for (unsigned mask = 0; mask < 128; ++mask) {
            const bool current = mask & 1, stop = mask & 2, eof = mask & 4;
            const bool drained = mask & 8, released = mask & 16, content = mask & 32;
            const bool begun = mask & 64;
            std::vector<int> calls;
            unsigned captures = 0, records = 0, reports = 0;
            bool reset = false;
            FpgaTerminalReceipt saved;
            const auto terminal = finishFpgaPlayback({begun, eof, drained, content},
                [&] {
                    require(!reset, "terminal snapshot occurred after reset");
                    calls.push_back(++captures == 1 ? 1 : 3);
                    return std::string("original_pts=987654321 pcm_bytes=1234");
                },
                [&] { calls.push_back(2); },
                [&] { calls.push_back(4); reset = true; return released; },
                [&] { return current; }, [&] { return stop; },
                [&](const FpgaTerminalReceipt& record) {
                    calls.push_back(5); ++records; saved = record;
                });
            require(calls == std::vector<int>({1, 2, 3, 4, 5}) && records == 1,
                    "production finalizer lost or duplicated terminal accounting");
            const auto expected = classifyFpgaPlaybackTerminalState(
                current, stop, eof, drained, released, content);
            require(terminal == expected && saved.classification == expected,
                    "instrumentation changed terminal policy");
            require(saved.beforeReset && saved.beforeReset->find("987654321") != std::string::npos,
                    "pre-reset data was replaced by cleared hardware state");
            reportFpgaPlaybackTerminal(terminal, [&] { return current; }, [&] { return stop; },
                [&](const char*, int64_t pts, int64_t duration) {
                    ++reports;
                    require(pts == 10969 && duration == 16036, "terminal padded or falsified time");
                }, 10969, 16036);
            require(reports == unsigned(current), "current-session progress policy changed");
        }
        for (unsigned failedStage = 0; failedStage < 3; ++failedStage) {
            unsigned records = 0, captures = 0, releases = 0;
            bool caught = false;
            try {
                finishFpgaPlayback({true, true, true, true},
                    [&]() -> std::string {
                        ++captures;
                        if (failedStage == 0) throw std::runtime_error("snapshot");
                        return "known-before-reset";
                    },
                    [&] { if (failedStage == 1) throw std::runtime_error("quiesce"); },
                    [&] { ++releases; throw std::runtime_error("release"); return false; },
                    [] { return true; }, [] { return false; },
                    [&](const FpgaTerminalReceipt& receipt) {
                        ++records;
                        require(!receipt.released && receipt.classification == PlaybackTerminalState::Stopped,
                                "failed cleanup invented a successful release");
                        if (failedStage == 0) {
                            require(!receipt.beforeQuiesce && !receipt.beforeReset,
                                    "failed snapshot invented zero-valued evidence");
                            require(formatFpgaTerminal(receipt).find("before_reset={unavailable}") !=
                                    std::string::npos, "unavailable snapshot not explicit");
                        }
                    });
            } catch (const std::runtime_error&) { caught = true; }
            require(caught && records == 1, "exception bypassed terminal receipt");
            require(releases == unsigned(failedStage != 1), "reset followed failed quiescence");
        }
        for (bool supersede : {false, true}) {
            bool current = true, stopped = false;
            finishFpgaPlayback({true, true, true, true}, [] { return std::string("retained"); },
                [] {}, [&] { current = !supersede; stopped = !supersede; return true; },
                [&] { return current; }, [&] { return stopped; },
                [&](const FpgaTerminalReceipt& receipt) {
                    require(receipt.classification == (supersede ? PlaybackTerminalState::None :
                              PlaybackTerminalState::Stopped), "late retirement falsely reported ended");
                });
        }
        require(fpgaTerminalText("read HTTP://host/private?token=secret\nfailed") ==
                "\"read [URL] failed\"", "terminal detail leaked URL or multiple lines");
        std::puts("terminal accounting:128 states, pre-reset ordering, failures, retirement and reporting passed");
        return 0;
    } catch (const std::exception& error) {
        std::fprintf(stderr, "FAIL terminal accounting: %s\n", error.what());
        return 1;
    }
}
