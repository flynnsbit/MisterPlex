#include "libmisterplex/no_margin.hpp"

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

    // NO-DATA must not look like healthy zero.
    {
        NoMarginSample s;
        auto d = classifyNoMargin(s);
        CHECK(d.cls == NoMarginClass::NoData);
        CHECK(std::string(d.name) == "NO-DATA");
    }

    // Parent ladder healthy high bitrate: supply~0.999, goodput near capacity.
    {
        NoMarginSample s;
        s.supply_iv = 0.999;
        s.supply_iv_ok = true;
        s.goodput_mbit_s = 1.177;
        s.goodput_ok = true;
        s.capacity_mbit_s = 1.153;
        s.capacity_ok = true;
        s.drop_delta = 0;
        s.drop_delta_ok = true;
        auto d = classifyNoMargin(s);
        CHECK(d.cls == NoMarginClass::HealthyTight);
        CHECK(std::string(d.action).find("bitrate") == std::string::npos ||
              std::string(d.action).find("do_not") != std::string::npos ||
              std::string(d.action).find("observe") != std::string::npos);
    }

    // Intermittent user wording: realtime + tight + drops.
    {
        NoMarginSample s;
        s.supply_iv = 0.99;
        s.supply_iv_ok = true;
        s.goodput_mbit_s = 1.15;
        s.goodput_ok = true;
        s.capacity_mbit_s = 1.15;
        s.capacity_ok = true;
        s.drop_delta = 12;
        s.drop_delta_ok = true;
        auto d = classifyNoMargin(s);
        CHECK(d.cls == NoMarginClass::IntermittentStress);
        CHECK(std::string(d.action).find("do_not_oscillate") != std::string::npos);
    }

    // True collapse (old retracted story numbers) — still classify starve, no auto bitrate.
    {
        NoMarginSample s;
        s.supply_iv = 0.47;
        s.supply_iv_ok = true;
        auto d = classifyNoMargin(s);
        CHECK(d.cls == NoMarginClass::SustainedStarve);
        CHECK(std::string(d.action).find("no_auto_bitrate") != std::string::npos);
    }

    // Streak: single blip must not be "ready".
    {
        NoMarginStreakState st;
        CHECK(!noMarginStreakReady(st, NoMarginClass::SustainedStarve, 3));
        CHECK(!noMarginStreakReady(st, NoMarginClass::SustainedStarve, 3));
        CHECK(noMarginStreakReady(st, NoMarginClass::SustainedStarve, 3));
        // Class change resets.
        CHECK(!noMarginStreakReady(st, NoMarginClass::HealthyHeadroom, 3));
    }

    if (fails) {
        std::fprintf(stderr, "test_no_margin: %d FAIL\n", fails);
        return 1;
    }
    std::printf("test_no_margin: OK\n");
    return 0;
}
