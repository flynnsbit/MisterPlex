// PLXG q5 must ride the full 6-qword seqlock (rd-duck BLOCKING).
// Standalone doorbell+0x828 never promotes; Option-C+0x828 is poller-blind.
#include "libmisterplex/ddr_present_bank.hpp"
#include "libmisterplex/mailbox_abi_spec.hpp"
#include "libmisterplex/plxg_record.hpp"

#include <cstdio>
#include <string>
#include <vector>

static int fails = 0;
#define CHECK(c)                                                                                   \
    do {                                                                                           \
        if (!(c)) {                                                                                \
            std::fprintf(stderr, "FAIL %s:%d %s\n", __FILE__, __LINE__, #c);                       \
            ++fails;                                                                               \
        }                                                                                          \
    } while (0)

int main() {
    using namespace misterplex;

    const uint64_t q5 = packPlxgQ5(16, 9, 24, true, true);
    CHECK(plxgQ5ReservedOk(q5));
    CHECK(!plxgRefuseStandaloneQ5ProductWrite(q5));
    CHECK(plxgFaultOptionCStandaloneQ5Phys() == 0x3047F828u);
    CHECK(plxgStandaloneQ5PhysIsPollerBlind(0x3047F828u));
    CHECK(!plxgStandaloneQ5PhysIsPollerBlind(mailbox_abi::kPlxgBootstrapPhys + 40u));

    const int cases[][2] = {{320, 240}, {624, 480}, {960, 540}, {1280, 720}};
    for (const auto& hw : cases) {
        const PlxgRecord base =
            makePlxgRecordFromStorage(hw[0], hw[1], hw[0], hw[1], 0, 0, 1);
        CHECK(base.valid);
        uint16_t committed = 0;
        uint64_t latched = 0;
        CHECK(plxgQ5FullRecordE2E(base.q, q5, 0, &committed, &latched));
        CHECK(latched == q5);
        CHECK(committed != 0);
        CHECK(plxgSeqDoorbellField(committed) != 0);

        std::vector<uint8_t> px(static_cast<size_t>(yuv420pFrameBytes(hw[0], hw[1])), 0);
        DdrPublishFrame fr{px.data(), px.size(), makeDdrFrameGeometry(hw[0], hw[1])};
        DdrPublishPlan plan{};
        std::string err;
        CHECK(makeDdrPublishPlan(fr, 0, plan, &err));
        CHECK(plan.plxg_q[5] == 0);
        CHECK(injectPlxgQ5IntoPublishPlan(plan, q5));
        CHECK(plan.plxg_q[5] == q5);
        CHECK(ddrFrameLayoutMatchesRtlCapacityMap(plan.layout));
    }

    const uint64_t dirty = packPlxgQ5FaultFps1001OnWire(16, 9, 24, true, true, true);
    uint64_t words[6]{};
    CHECK(!injectPlxgQ5IntoRecord(words, dirty));

    if (fails) {
        std::fprintf(stderr, "test_plxg_q5_publish_e2e: %d fails\n", fails);
        return 1;
    }
    std::printf("test_plxg_q5_publish_e2e: OK\n");
    return 0;
}
