// RED twin: frozen helper that treats live content O[5:4] change as analog jump.
// Must keep failing the GREEN latch CHECKs. rc=0 means the frozen copy was
// weakened — not a product PASS.
#include <cstdint>
#include <cstdio>

static int fails = 0;
#define CHECK(cond)                                                                              \
    do {                                                                                         \
        if (!(cond)) {                                                                           \
            std::fprintf(stderr, "FAIL %s:%d: %s\n", __FILE__, __LINE__, #cond);                 \
            ++fails;                                                                             \
        }                                                                                        \
    } while (0)

namespace {

constexpr uint8_t kAnalogSel240p15 = 0;
constexpr uint8_t kAnalogSel480p31 = 1;
constexpr uint8_t kAnalogSel480i = 2;

uint8_t analogFromContent(uint8_t content_res_sel) {
    return ((content_res_sel & 3u) == 0u) ? kAnalogSel240p15 : kAnalogSel480p31;
}

uint8_t analogSelRequested(uint8_t analog_menu, uint8_t content_res_sel,
                           bool forced_scandoubler) {
    analog_menu = static_cast<uint8_t>(analog_menu & 3u);
    content_res_sel = static_cast<uint8_t>(content_res_sel & 3u);
    if (forced_scandoubler && analog_menu == 0)
        return kAnalogSel480p31;
    if (analog_menu == 0)
        return analogFromContent(content_res_sel);
    if (analog_menu == 1)
        return kAnalogSel240p15;
    if (analog_menu == 2)
        return kAnalogSel480p31;
    return kAnalogSel480i;
}

// Frozen FAULT: live requested analog_sel hops without reset.
uint8_t analogSelLatch(bool /*reset*/, uint8_t /*latched*/, uint8_t requested) {
    return requested;
}

bool analogLiveContentChangeIsAnalogJump(bool /*reset_pulse*/) { return true; }

} // namespace

int main() {
    CHECK(analogSelRequested(1, 0, false) == 0);
    CHECK(analogSelRequested(2, 0, false) == 1);
    CHECK(analogSelRequested(3, 0, false) == 2);
    CHECK(analogSelRequested(0, 0, false) == 0);
    CHECK(analogSelRequested(0, 1, false) == 1);

    const uint8_t lat240 = analogSelLatch(true, 0xff, analogSelRequested(0, 0, false));
    const uint8_t req480 = analogSelRequested(0, 1, false);
    const uint8_t live = analogSelLatch(false, lat240, req480);
    std::printf("FAULT live-content Follow 240p→480p latched=%u requested=%u jump=%d\n",
                static_cast<unsigned>(live), static_cast<unsigned>(req480),
                analogLiveContentChangeIsAnalogJump(false) ? 1 : 0);
    CHECK(live == kAnalogSel240p15);
    CHECK(live != req480);
    CHECK(!analogLiveContentChangeIsAnalogJump(false));

    if (fails) {
        std::fprintf(stderr,
                     "test_analog_sel_policy_red: %d failure(s) (expected RED: live "
                     "content treated as analog jump)\n",
                     fails);
        return 1;
    }
    std::printf("test_analog_sel_policy_red: unexpectedly OK\n");
    return 0;
}
