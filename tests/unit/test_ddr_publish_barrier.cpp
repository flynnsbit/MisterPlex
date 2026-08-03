// Publish visibility barrier (w-mem). NEG: doorbell before barrier tears.
// atomic_signal_fence is NOT a hardware barrier (rd-duck).
#include "libmisterplex/bank_producer_order.hpp"
#include "libmisterplex/ddr_mem_map_policy.hpp"
#include "libmisterplex/ddr_publish_barrier.hpp"

#include <atomic>
#include <cstdio>

using namespace misterplex;
static int fails = 0;
#define CHECK(c)                                                                                   \
    do {                                                                                           \
        if (!(c)) {                                                                                \
            std::fprintf(stderr, "FAIL %s:%d %s\n", __FILE__, __LINE__, #c);                       \
            ++fails;                                                                               \
        }                                                                                          \
    } while (0)

int main() {
    // Contract: signal_fence must never count as DMB.
    CHECK(!ddrPublishSignalFenceIsHardwareBarrier());
    // Sanity: signal_fence compiles but is documented insufficient.
    std::atomic_signal_fence(std::memory_order_seq_cst);

    // Happy path: stores → barrier → doorbell.
    {
        DdrPublishVisibility v{};
        CHECK(ddrPublishMarkStoresDone(v));
        CHECK(ddrPublishMarkBarrier(v));
        CHECK(ddrPublishMarkDoorbell(v, DdrMemMapPolicy::StronglyOrderedSync, true));
        CHECK(v.barrier_done && v.doorbell_rung && !v.tore);
    }

    // NEG: doorbell before barrier → tear.
    {
        DdrPublishVisibility v{};
        CHECK(ddrPublishMarkStoresDone(v));
        CHECK(!ddrPublishMarkDoorbell(v, DdrMemMapPolicy::StronglyOrderedSync, true));
        CHECK(v.tore);
        CHECK(!v.doorbell_rung);
    }

    // NEG: doorbell before stores → tear.
    {
        DdrPublishVisibility v{};
        CHECK(!ddrPublishMarkDoorbell(v, DdrMemMapPolicy::WriteCombineDriver, true));
        CHECK(v.tore);
    }

    // NEG: barrier before stores → tear.
    {
        DdrPublishVisibility v{};
        CHECK(!ddrPublishMarkBarrier(v));
        CHECK(v.tore);
    }

    // WC / Cached policies require explicit visibility.
    CHECK(ddrPublishRequiresExplicitVisibility(DdrMemMapPolicy::WriteCombineDriver));
    CHECK(ddrPublishRequiresExplicitVisibility(DdrMemMapPolicy::CachedExplicitFlush));
    CHECK(!ddrPublishRequiresExplicitVisibility(DdrMemMapPolicy::StronglyOrderedSync));

    CHECK(ddrPublishOrderedBytes(777600u) == 777600u);

    // Bank producer: markPayloadVisible embeds real barrier.
    {
        BankProducerOrder o;
        CHECK(o.beginFill(0, 0x3));
        CHECK(o.noteChunk(777600u));
        CHECK(o.markPayloadVisible(777600u));
        CHECK(o.barrierDone());
        CHECK(o.mayRingDoorbell());
        CHECK(o.markDoorbellRung());
    }
    // NEG mid-fill doorbell still blocked.
    {
        BankProducerOrder o;
        CHECK(o.beginFill(0, 0x3));
        CHECK(o.noteChunk(100));
        CHECK(!o.mayRingDoorbell());
        CHECK(!o.markDoorbellRung());
        CHECK(!o.barrierDone());
    }

    if (fails) {
        std::fprintf(stderr, "test_ddr_publish_barrier: %d fails\n", fails);
        return 1;
    }
    std::printf("test_ddr_publish_barrier: OK neg_doorbell_before_barrier=1 "
                "signal_fence_not_dmb=1 producer_barrier=1\n");
    return 0;
}
