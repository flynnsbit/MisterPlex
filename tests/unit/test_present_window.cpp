#include "libmisterplex/present_window.hpp"

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

    CHECK(classifyPresentWindow({}) == PresentWindowClass::NoData);

    // H-READ: EAGAIN sleep dominates 1s wall.
    {
        PresentWindowSample s;
        s.wall_us = 1000000;
        s.frames = 20;
        s.presented = 18;
        s.drops = 2;
        s.read_sleep_us = 400000;
        s.ddr_total_us = 50000;
        CHECK(classifyPresentWindow(s) == PresentWindowClass::ReadWait);
    }

    // H-DDR: publish burns wall.
    {
        PresentWindowSample s;
        s.wall_us = 1000000;
        s.frames = 20;
        s.presented = 20;
        s.ddr_total_us = 350000;
        s.read_sleep_us = 10000;
        CHECK(classifyPresentWindow(s) == PresentWindowClass::DdrBound);
    }

    // H-PACER: many deliberate drops, little wait.
    {
        PresentWindowSample s;
        s.wall_us = 1000000;
        s.frames = 24;
        s.presented = 12;
        s.drops = 12;
        s.read_sleep_us = 1000;
        s.ddr_total_us = 50000;
        s.pacing_wait_us = 1000;
        CHECK(classifyPresentWindow(s) == PresentWindowClass::PacerDrop);
    }

    // H-HOLD: waiting for audio clock.
    {
        PresentWindowSample s;
        s.wall_us = 1000000;
        s.frames = 24;
        s.presented = 24;
        s.pacing_wait_us = 400000;
        CHECK(classifyPresentWindow(s) == PresentWindowClass::HoldWait);
    }

    // supply_ratio semantics
    CHECK(std::string(supplyRatioImplies(0.837, 20.0, 24.0)) == "SHARED_FFMPEG_THROTTLE");
    CHECK(std::string(supplyRatioImplies(0.99, 23.8, 24.0)) == "FULL_RATE_SUPPLY");
    CHECK(std::string(supplyRatioImplies(0.0, 20.0, 24.0)) == "NO-DATA");

    const auto line = formatPresentWindowLine(
        PresentWindowSample{20, 18, 2, 5, 10, 1000, 2000, 0, 50000, 40000, 1000, 0, 1000000}, 10,
        100, -24);
    CHECK(line.find("present_window") != std::string::npos);
    CHECK(line.find("class=") != std::string::npos);
    CHECK(line.find("d_drops=2") != std::string::npos);

    if (fails) {
        std::fprintf(stderr, "test_present_window: %d FAIL\n", fails);
        return 1;
    }
    std::printf("test_present_window: OK\n");
    return 0;
}
