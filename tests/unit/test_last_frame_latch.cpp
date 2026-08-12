#include "libmisterplex/last_frame_latch.hpp"

#include <cstdint>
#include <cstdio>
#include <vector>

static int fails = 0;
static int checks = 0;
#define CHECK(cond)                                                                              \
    do {                                                                                         \
        ++checks;                                                                                \
        if (!(cond)) {                                                                           \
            std::fprintf(stderr, "FAIL %s:%d: %s\n", __FILE__, __LINE__, #cond);                 \
            ++fails;                                                                             \
        }                                                                                        \
    } while (0)

int main() {
    using namespace misterplex;

    // GREEN binary only. Fault macros (LAST_FRAME_LATCH_FAULT_*) are for
    // test_last_frame_latch_red.sh and must NOT be defined here.
    LastFrameLatch latch;
    CHECK(!latch.haveFrame());

    // Differential geometry (not product silicon): proves the latch keeps the
    // *remembered* layout, not a different tier. Product path (media_player)
    // remembers ddrFrameGeometryForFpgaPresent → 1280×720 / stride 0x180000.
    // 320x240 → bank_stride 0x40000, doorbell 0x3007F000 (formula, single source).
    const DdrFrameGeometry playbackGeometry = makeDdrFrameGeometry(320, 240);
    const DdrFrameLayout capturedLayout =
        makeDdrFrameLayout(playbackGeometry, kDdrFramePhysBase, kDdrFrameStrideAlign,
                           DdrFrameFormat::Yuv420p);
    // Legacy 480p tier — valid layout but NOT product silicon after #16.
    const DdrFrameLayout idleLayout = makeDdrFrameLayout(
        plex480pDdrFrameGeometry(), kDdrFramePhysBase, kDdrFrameStrideAlign,
        DdrFrameFormat::Yuv420p);
    CHECK(ddrFrameLayoutValid(capturedLayout));
    CHECK(ddrFrameLayoutValid(idleLayout));
    CHECK(capturedLayout.bank_stride != idleLayout.bank_stride);
    CHECK(capturedLayout.doorbell_phys != idleLayout.doorbell_phys);
    // Pin the formula so a second "product-only" ABI cannot silently win.
    CHECK(capturedLayout.bank_stride == 0x40000u);
    CHECK(capturedLayout.doorbell_phys == 0x3007F000u);
    CHECK(idleLayout.bank_stride == kPlex480pYuv420pBankStride);
    CHECK(idleLayout.doorbell_phys == kPlex480pYuv420pDoorbellPhys);
    CHECK(!ddrFrameLayoutMatchesProductSilicon(idleLayout));
    CHECK(!ddrFrameLayoutMatchesProductSilicon(capturedLayout));

    std::vector<uint8_t> frame(capturedLayout.frame_bytes);
    for (size_t i = 0; i < frame.size(); ++i)
        frame[i] = static_cast<uint8_t>((i * 17u + 3u) & 0xFFu);

    CHECK(latch.remember(frame.data(), frame.size(), playbackGeometry));
    CHECK(latch.haveFrame());
    CHECK(latch.frame().size() == frame.size());
    CHECK(latch.frame().layout().bank_stride == capturedLayout.bank_stride);
    CHECK(latch.frame().layout().doorbell_phys == capturedLayout.doorbell_phys);

    struct Send {
        int bank = -1;
        uint32_t bank_phys = 0;
        DdrFrameLayout frame_layout{};
        size_t len = 0;
        const uint8_t* data = nullptr;
    };
    std::vector<Send> sends;
    int nextBank = 1;
    const bool ok = latch.publishToBothBanks(
        [&](const LastFrameLatch::Publication& pub) {
            sends.push_back({pub.bank, pub.bank_phys, pub.frame.layout(), pub.frame.size(),
                             pub.frame.data()});
            return true;
        },
        nextBank);

    CHECK(ok);
    CHECK(sends.size() == 2);
    CHECK(nextBank == 1);
    if (sends.size() == 2) {
        CHECK(sends[0].bank == 1);
        CHECK(sends[1].bank == 0);
        CHECK(sends[0].bank_phys != sends[1].bank_phys);
        for (const auto& s : sends) {
            CHECK(s.data == latch.frame().data());
            CHECK(s.len == capturedLayout.frame_bytes);
            CHECK(s.frame_layout.bank_stride == capturedLayout.bank_stride);
            CHECK(s.frame_layout.doorbell_phys == capturedLayout.doorbell_phys);
            const uint32_t expectedPhys = s.frame_layout.phys_base +
                                          static_cast<uint32_t>(s.bank) *
                                              s.frame_layout.bank_stride;
            CHECK(s.bank_phys == expectedPhys);
        }
    }

    latch.clear();
    sends.clear();
    nextBank = 0;
    CHECK(!latch.publishToBothBanks(
        [&](const LastFrameLatch::Publication& pub) {
            sends.push_back({pub.bank, pub.bank_phys, pub.frame.layout(), pub.frame.size(),
                             pub.frame.data()});
            return true;
        },
        nextBank));
    CHECK(sends.empty());
    CHECK(nextBank == 0);

    // Product-silicon pin (what media_player actually latches on FPGA path).
    LastFrameLatch productLatch;
    const DdrFrameGeometry productGeom = productDdrFrameStoreGeometry();
    const DdrFrameLayout productLayout = makeDdrFrameLayout(productGeom);
    CHECK(ddrFrameLayoutMatchesProductSilicon(productLayout));
    std::vector<uint8_t> productFrame(productLayout.frame_bytes, 0x10);
    CHECK(productLatch.remember(productFrame.data(), productFrame.size(), productGeom));
    CHECK(productLatch.frame().layout().bank_stride == kPlex720pYuv420pBankStride);
    CHECK(productLatch.frame().layout().doorbell_phys == kPlex720pYuv420pDoorbellPhys);
    int pBank = 0;
    std::vector<Send> pSends;
    CHECK(productLatch.publishToBothBanks(
        [&](const LastFrameLatch::Publication& pub) {
            pSends.push_back({pub.bank, pub.bank_phys, pub.frame.layout(), pub.frame.size(),
                              pub.frame.data()});
            return true;
        },
        pBank));
    CHECK(pSends.size() == 2);
    for (const auto& s : pSends) {
        CHECK(s.frame_layout.bank_stride == kPlex720pYuv420pBankStride);
        CHECK(s.frame_layout.doorbell_phys == kPlex720pYuv420pDoorbellPhys);
        CHECK(s.bank_phys == kDdrFramePhysBase +
                                 static_cast<uint32_t>(s.bank) * kPlex720pYuv420pBankStride);
    }

    if (fails) {
        std::fprintf(stderr, "test_last_frame_latch: FAILED checks=%d failures=%d\n", checks,
                     fails);
        return 1;
    }
    std::printf("test_last_frame_latch: OK checks=%d\n", checks);
    return 0;
}
