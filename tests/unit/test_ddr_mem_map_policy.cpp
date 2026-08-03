// Red-before-green: cached DDR map must not allow doorbell without flush.
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
    // RED cases first — these encode the tearing bug class.
    CHECK(!ddrMemMayRingDoorbell(DdrMemMapPolicy::CachedExplicitFlush, /*flush=*/false));
    CHECK(!ddrMemMapConfPublishSafe(/*sync=*/false, /*flush=*/false));

    // GREEN
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

    // Parent bandwidth arithmetic
    CHECK(kParentDdrMapped720pFrameMs == 15.210);
    CHECK(kParentDdrHostCopy720pFrameMs == 2.998);
    CHECK(!ddr720p24MappedPathFitsAt1500k());
    CHECK(ddr720p24HostCopyCeilingFitsAt1500k());
    CHECK(ddr720p24MappedToHostCopyMsSaved() > 12.2 &&
          ddr720p24MappedToHostCopyMsSaved() < 12.3);

    // Source-level: product sendDdrFrame must refuse SYNC=0 without FLUSH.
    // (Static string gate — catches regression removing the hard error.)
    {
        FILE* f = std::fopen("arm/misterplexd/fpga_spi.cpp", "r");
        CHECK(f != nullptr);
        if (f) {
            char buf[1 << 20];
            const size_t n = std::fread(buf, 1, sizeof(buf) - 1, f);
            buf[n] = 0;
            std::fclose(f);
            const char* needle =
                "DDR_MEM_SYNC=0 requires DDR_MEM_FLUSH=1";
            CHECK(std::strstr(buf, needle) != nullptr);
        }
    }

    if (fails) {
        std::fprintf(stderr, "test_ddr_mem_map_policy: %d fails\n", fails);
        return 1;
    }
    std::printf("test_ddr_mem_map_policy: OK mapped=%.3f host_ceil=%.3f ms_saved=%.3f\n",
                kParentDdrMappedBank720pMibps, kParentDdrHostCopyCeilingMibps,
                ddr720p24MappedToHostCopyMsSaved());
    return 0;
}
