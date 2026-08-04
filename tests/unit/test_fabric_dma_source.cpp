// Fabric DMA source contract gates (no /dev/mem, no device).
//
// rd-duck NACK: std::vector frame is not a legal ddr_frame_dma src_phys.
// Positive: heap → reserved staging PA via loadCpuBytes + visibility + armKick.
// Negative cases a naive "cast vector.data() to phys" implementation fails.

#include "libmisterplex/ddr_frame_layout.hpp"
#include "libmisterplex/fabric_dma_source.hpp"

#include <cstdint>
#include <cstdio>
#include <cstring>
#include <string>
#include <vector>

#define CHECK(cond, msg)                                                                           \
    do {                                                                                           \
        if (!(cond)) {                                                                             \
            std::fprintf(stderr, "FAIL %s:%d: %s\n", __FILE__, __LINE__, msg);                     \
            ++fails;                                                                               \
        }                                                                                          \
    } while (0)

int main() {
    using namespace misterplex;
    int fails = 0;

    // --- ABI aliases match PL330 / RTL staging ---
    CHECK(kFabricDmaStagingPhys == 0x30601000u, "staging phys 0x30601000");
    CHECK(kFabricDmaStagingPhys == kPl330StagingPhys, "fabric==PL330 phys");
    CHECK(kFabricDmaStagingBytes == kPl330StagingBytes, "fabric==PL330 size");
    CHECK(kFabricDmaStagingBytes == kPlex720pYuv420pBankStride, "staging=720p bank stride");
    CHECK(kFabricDmaStagingBytes == 0x00180000u, "staging bytes 0x180000");
    CHECK(kFabricDmaScratchPhys == 0x30600000u, "scratch phys");
    CHECK(fabricDmaSrcPhysLegal(kFabricDmaStagingPhys, 1382400u), "720p payload legal");
    CHECK(fabricDmaSrcPhysLegal(kFabricDmaStagingPhys, 8u), "min beat legal");

    // --- NEGATIVE: unresolved / heap-as-phys / oversize / misalign ---
    CHECK(fabricDmaRejectsUnresolvedPhys(0), "phys=0 rejected");
    CHECK(!fabricDmaSrcPhysLegal(0, 1382400u), "src_phys 0 illegal");
    CHECK(!fabricDmaSrcPhysLegal(kFabricDmaStagingPhys, kFabricDmaStagingBytes + 8u),
          "oversize staging reject");
    CHECK(!fabricDmaSrcPhysLegal(kFabricDmaStagingPhys, 7u), "non-multiple-of-8 reject");
    CHECK(!fabricDmaSrcPhysLegal(kFabricDmaStagingPhys + 1u, 8u), "unaligned phys reject");
    CHECK(!fabricDmaSrcPhysLegal(kPlex720pDdrFramePhysBase, 1382400u),
          "bank base is not staging src");
    CHECK(fabricDmaRejectsOutsideStagingWindow(0x10000000u, 64u), "low VA window reject");

    // Classic bug: reinterpret_cast vector.data() → uint32_t as src_phys.
    {
        std::vector<uint8_t> frame(256, 0xA5);
        const void* heap = frame.data();
        CHECK(fabricDmaMustStageHostPointer(heap, frame.size()),
              "vector.data() must stage (not direct PA)");
        const uint32_t truncated = static_cast<uint32_t>(reinterpret_cast<uintptr_t>(heap));
        CHECK(fabricDmaRejectsOutsideStagingWindow(truncated, frame.size()) ||
                  fabricDmaRejectsUnresolvedPhys(truncated),
              "truncated heap VA not legal src_phys");
        CHECK(!fabricDmaSrcPhysLegal(truncated, frame.size()),
              "naive heap→phys cast fails legal gate");
    }

    // --- POSITIVE: test-double map + load + barrier + armKick ---
    {
        std::vector<uint8_t> staging(kFabricDmaStagingBytes, 0);
        std::vector<uint8_t> frame(4096, 0);
        for (size_t i = 0; i < frame.size(); ++i)
            frame[i] = static_cast<uint8_t>(i & 0xff);

        FabricDmaStagingMap map;
        std::string err;
        CHECK(map.openTestDouble(staging.data(), staging.size(), &err), "open test double");
        CHECK(map.phase() == FabricDmaSourcePhase::MappedEmpty, "phase mapped empty");
        CHECK(map.phys() == kFabricDmaStagingPhys, "map reports staging PA");

        // NEGATIVE: kick before fill
        uint32_t phys = 0;
        size_t len = 0;
        CHECK(!map.armKick(&phys, &len, &err), "kick before fill rejected");

        CHECK(map.loadCpuBytes(frame.data(), frame.size(), &err), "loadCpuBytes");
        CHECK(map.phase() == FabricDmaSourcePhase::PayloadVisible, "phase payload visible");
        CHECK(map.filledBytes() == frame.size(), "filled bytes");
        CHECK(std::memcmp(staging.data(), frame.data(), frame.size()) == 0, "staging content");

        CHECK(map.armKick(&phys, &len, &err), "armKick");
        CHECK(phys == kFabricDmaStagingPhys, "kick phys is staging");
        CHECK(len == frame.size(), "kick len");
        CHECK(map.phase() == FabricDmaSourcePhase::KickArmed, "phase kick armed");
        CHECK(fabricDmaSrcPhysLegal(phys, len), "armed src legal for RTL");
    }

    // --- POSITIVE: one-shot prepare helper ---
    {
        std::vector<uint8_t> staging(kFabricDmaStagingBytes, 0);
        std::vector<uint8_t> frame(64, 0x3C);
        FabricDmaStagingMap map;
        std::string err;
        CHECK(map.openTestDouble(staging.data(), staging.size(), &err), "prepare open");
        uint32_t phys = 0;
        size_t len = 0;
        CHECK(fabricDmaPrepareFromCpuBuffer(map, frame.data(), frame.size(), &phys, &len, &err),
              "prepare from cpu buffer");
        CHECK(phys == kFabricDmaStagingPhys && len == 64u, "prepare outputs");
        CHECK(std::memcmp(staging.data(), frame.data(), 64) == 0, "prepare content");
    }

    // --- NEGATIVE: oversize load fails (does not silently truncate) ---
    {
        std::vector<uint8_t> staging(kFabricDmaStagingBytes, 0);
        std::vector<uint8_t> huge(static_cast<size_t>(kFabricDmaStagingBytes) + 8u, 0x11);
        FabricDmaStagingMap map;
        std::string err;
        CHECK(map.openTestDouble(staging.data(), staging.size(), &err), "oversize open");
        CHECK(!map.loadCpuBytes(huge.data(), huge.size(), &err), "oversize load rejected");
        CHECK(map.phase() == FabricDmaSourcePhase::Failed, "phase failed after oversize");
    }

    // --- NEGATIVE: unmapped load fails ---
    {
        FabricDmaStagingMap map;
        std::vector<uint8_t> frame(32, 0);
        std::string err;
        CHECK(!map.loadCpuBytes(frame.data(), frame.size(), &err), "unmapped load rejected");
    }

    // --- Contract honesty: staging fill is still a CPU copy (not bank retire) ---
    // Documented so a naive "loadCpuBytes == copy retired" claim fails review.
    CHECK(kFabricDmaStagingPhys != kPlex720pDdrFramePhysBase, "staging != bank0");
    CHECK(kFabricDmaStagingPhys != kDdrFramePhysBase, "staging != 480p bank base");

    if (fails != 0) {
        std::fprintf(stderr, "test_fabric_dma_source: %d FAIL\n", fails);
        return 1;
    }
    std::printf("test_fabric_dma_source: OK checks_passed\n");
    return 0;
}
