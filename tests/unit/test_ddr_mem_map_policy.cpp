// Red-before-green: cached DDR map must not allow doorbell without flush.
// Sweep-3: host-copy is NOT a bank rate; coherent flush is a penalty.
#include "libmisterplex/ddr_mem_map_policy.hpp"

#include <cstdio>
#include <cstring>

using namespace misterplex;

static int fails = 0;
#define CHECK(cond)                                                                 \
    do {                                                                            \
        if (!(cond)) {                                                              \
            std::fprintf(stderr, "FAIL %s:%d %s\n", __FILE__, __LINE__, #cond);   \
            ++fails;                                                                \
        }                                                                           \
    } while (0)

int main() {
    // RED cases — tearing class if doorbell before visibility.
    CHECK(!ddrMemMayRingDoorbell(DdrMemMapPolicy::CachedExplicitFlush, /*flush=*/false));
    CHECK(!ddrMemMapConfPublishSafe(/*sync=*/false, /*flush=*/false));

    // GREEN ordering
    CHECK(ddrMemMayRingDoorbell(DdrMemMapPolicy::CachedExplicitFlush, true));
    CHECK(ddrMemMayRingDoorbell(DdrMemMapPolicy::StronglyOrderedSync, false));
    CHECK(ddrMemMapConfPublishSafe(true, false));
    CHECK(ddrMemMapConfPublishSafe(false, true));

    const auto s = ddrMemMapOpenSpec(DdrMemMapPolicy::StronglyOrderedSync);
    const auto c = ddrMemMapOpenSpec(DdrMemMapPolicy::CachedExplicitFlush);
    CHECK((s.open_flags & O_SYNC) == O_SYNC);
    CHECK((c.open_flags & O_SYNC) == 0);
    CHECK(!s.requires_dcache_flush_before_doorbell);
    CHECK(c.requires_dcache_flush_before_doorbell);
    CHECK(ddrMemMapPolicyFromConf(true, false) == DdrMemMapPolicy::StronglyOrderedSync);
    CHECK(ddrMemMapPolicyFromConf(false, true) == DdrMemMapPolicy::CachedExplicitFlush);

    // Sweep-3 bank arithmetic (parent true rc=0)
    CHECK(kParentDdrBestBank720pFrameMs == 15.283);
    CHECK(kParentDdrMappedBank720pMibps == 86.262);
    CHECK(kParentDdrCoherentFlush720pFrameMs == 19.861);
    CHECK(ddr720p24CoherentFlushPenaltyMs() > 4.5 &&
          ddr720p24CoherentFlushPenaltyMs() < 4.6);
    CHECK(!ddr720p24MappedPathFitsAt1500k());
    CHECK(!ddr720p24SerialPathFitsAt3500k());
    CHECK(!ddr720p24SerialPathFitsAt4000k());
    CHECK(!ddr720p24HostCopyIsReachableBankRate());
    CHECK(!ddr720p24HostCopyCeilingFitsAt1500k()); // RETRACTED ship claim
    CHECK(ddr720p24MappedToHostCopyMsSaved() == 0.0);
    // Ordinary-RAM figure retained only as non-bank reference.
    CHECK(kParentDdrHostCopyOrdinaryRam720pFrameMs == 2.998);

    // Source-level: product sendDdrFrame must refuse SYNC=0 without FLUSH.
    {
        FILE* f = std::fopen("arm/misterplexd/fpga_spi.cpp", "r");
        CHECK(f != nullptr);
        if (f) {
            char buf[1 << 20];
            const size_t n = std::fread(buf, 1, sizeof(buf) - 1, f);
            buf[n] = 0;
            std::fclose(f);
            CHECK(std::strstr(buf, "DDR_MEM_SYNC=0 requires DDR_MEM_FLUSH=1") != nullptr);
        }
    }

    if (fails) {
        std::fprintf(stderr, "test_ddr_mem_map_policy: %d fails\n", fails);
        return 1;
    }
    std::printf("test_ddr_mem_map_policy: OK best_bank_ms=%.3f flush_penalty=%.3f "
                "serial3500=%d hostcopy_reachable=%d\n",
                kParentDdrBestBank720pFrameMs, ddr720p24CoherentFlushPenaltyMs(),
                ddr720p24SerialPathFitsAt3500k() ? 1 : 0,
                ddr720p24HostCopyIsReachableBankRate() ? 1 : 0);
    return 0;
}
