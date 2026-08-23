// analog_menu 1/2/3 → analog_sel 0/1/2. Follow+240p → 0; Follow+480p → 1.
// Live content change without reset is DECODE, not an analog H-class jump.
#include "libmisterplex/analog_sel_policy.hpp"

#include <cstdio>

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

    CHECK(analogSelRequested(1, 0, false) == kAnalogSel240p15);
    CHECK(analogSelRequested(2, 0, false) == kAnalogSel480p31);
    CHECK(analogSelRequested(3, 0, false) == kAnalogSel480i);
    CHECK(analogSelRequested(1, 1, false) == 0);
    CHECK(analogSelRequested(2, 1, false) == 1);
    CHECK(analogSelRequested(3, 1, false) == 2);

    CHECK(analogSelRequested(0, 0, false) == kAnalogSel240p15);
    CHECK(analogSelRequested(0, 1, false) == kAnalogSel480p31);
    CHECK(analogSelRequested(0, 2, false) == kAnalogSel480p31);
    CHECK(analogSelRequested(0, 3, false) == kAnalogSel480p31);

    CHECK(analogSelRequested(0, 0, true) == kAnalogSel480p31);
    CHECK(analogSelRequested(1, 0, true) == kAnalogSel240p15);

    const uint8_t req240 = analogSelRequested(0, 0, false);
    const uint8_t lat240 = analogSelLatch(true, 0xff, req240);
    CHECK(lat240 == kAnalogSel240p15);
    const uint8_t req480 = analogSelRequested(0, 1, false);
    CHECK(req480 == kAnalogSel480p31);
    const uint8_t live = analogSelLatch(false, lat240, req480);
    CHECK(live == kAnalogSel240p15);
    CHECK(live != req480);
    CHECK(!analogLiveContentChangeIsAnalogJump(false));
    CHECK(!analogLiveContentChangeIsAnalogJump(true));
    const uint8_t after_reset = analogSelLatch(true, live, req480);
    CHECK(after_reset == kAnalogSel480p31);

    if (fails) {
        std::fprintf(stderr, "test_analog_sel_policy: %d failure(s)\n", fails);
        return 1;
    }
    std::printf("test_analog_sel_policy: OK analog_menu 1/2/3 → sel 0/1/2 "
                "Follow+240p=0 Follow+480p=1 live-content not analog jump\n");
    return 0;
}
