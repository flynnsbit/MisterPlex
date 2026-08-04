// Native DDR publish gate (w-geom / dual-header compose).
//
// Proves from host ABI alone (no device):
//   1) Default product silicon is 480p (624×480, bank 0x80000, doorbell 0x300FF000).
//   2) ddrFrameGeometryForFpgaPresent ignores DECODE and returns product.
//   3) Explicit L4 720p (plex720p*) is 1280×720 I420 @ 0x30180000 / 0x3047F000.
//   4) Wrong-length payloads are rejected against product geom.
//   5) Accept-resolution helper covers both tiers; 1080p rejected.
//
// Companion RTL gate: tests/unit/test_ddr_frame_store_native_480p.sh
#include "libmisterplex/ddr_frame_layout.hpp"
#include "libmisterplex/ddr_present_bank.hpp"

#include <cstdint>
#include <cstdio>
#include <cstring>
#include <string>
#include <vector>

static int fails = 0;
#define CHECK(c)                                                                                 \
    do {                                                                                         \
        if (!(c)) {                                                                              \
            std::fprintf(stderr, "FAIL %s:%d %s\n", __FILE__, __LINE__, #c);                     \
            ++fails;                                                                             \
        }                                                                                        \
    } while (0)

int main() {
    using namespace misterplex;

    // --- L4 720p capacity (explicit tier, not default product) ------------------
    constexpr size_t kY720 = 1280u * 720u;
    constexpr size_t kC720 = (1280u / 2u) * (720u / 2u);
    constexpr size_t kFrame720 = kY720 + 2u * kC720;
    CHECK(kFrame720 == 1382400u);
    CHECK(kFrame720 == static_cast<size_t>(kPlex720pYuv420pBytes));
    CHECK(kPlex720pYuv420pBankStride == 0x180000u);
    CHECK(kPlex720pYuv420pDoorbellPhys == 0x3047F000u);
    CHECK(kPlex720pPhysBase == 0x30180000u);

    // --- Default product = 480p (dual-header primary) ---------------------------
    constexpr size_t kFrame480 = 449280u;
    CHECK(kFrame480 == static_cast<size_t>(kPlex480pYuv420pBytes));

    const auto gFrom240 = ddrFrameGeometryForFpgaPresent(320, 240);
    const auto gFrom480 = ddrFrameGeometryForFpgaPresent(624, 480);
    const auto gFrom720 = ddrFrameGeometryForFpgaPresent(1280, 720);
    const auto gProduct = productDdrFrameStoreGeometry();
    CHECK(gFrom240.coded_width.get() == 624);
    CHECK(gFrom240.coded_height.get() == 480);
    CHECK(gFrom480.coded_width.get() == 624);
    CHECK(gFrom720.coded_height.get() == 480);
    CHECK(gFrom240.coded_width == gProduct.coded_width);
    CHECK(gFrom720.coded_height == gProduct.coded_height);
    CHECK(gProduct.display_width.get() == 618);
    CHECK(gProduct.presented_width.get() == 640);
    CHECK(gProduct.present_x == 11);
    CHECK(gProduct.crop_right == 6);

    const auto layout = productDdrFrameStoreLayout();
    CHECK(ddrFrameLayoutValid(layout));
    CHECK(ddrFrameLayoutMatchesProductSilicon(layout));
    CHECK(!ddrFrameLayoutMatchesL4Silicon(layout));
    CHECK(layout.frame_bytes == kFrame480);
    CHECK(layout.bank_stride == 0x80000u);
    CHECK(layout.doorbell_phys == 0x300FF000u);
    CHECK(layout.phys_base == 0x30000000u);
    CHECK(layout.line_bytes == 624);
    CHECK(layout.chroma_line_bytes == 312);
    CHECK(layout.u_offset == 299520u);
    CHECK(layout.v_offset == 374400u);
    CHECK(layout.phys_base + 2u * layout.bank_stride - 0x1000u == layout.doorbell_phys);

    // Explicit L4 layout
    const auto l720 = plex720pDdrFrameStoreLayout();
    CHECK(ddrFrameLayoutMatchesL4Silicon(l720));
    CHECK(l720.frame_bytes == kFrame720);
    CHECK(l720.bank_stride == 0x180000u);
    CHECK(l720.doorbell_phys == 0x3047F000u);
    CHECK(l720.phys_base == 0x30180000u);
    CHECK(l720.u_offset == 921600u);
    CHECK(l720.v_offset == 1152000u);

    // --- Publish plan: full 624×480 I420 accepted on product --------------------
    std::vector<uint8_t> yuv480(kFrame480, 0x10);
    for (int y = 0; y < 480; ++y) {
        for (int x = 0; x < 16; ++x)
            yuv480[static_cast<size_t>(y) * 624u + static_cast<size_t>(x)] = 0xEB;
    }
    DdrPublishFrame f480{yuv480.data(), yuv480.size(), gProduct, DdrFrameFormat::Yuv420p};
    DdrPublishPlan plan0{};
    DdrPublishPlan plan1{};
    std::string err;
    CHECK(makeDdrPublishPlan(f480, 0, plan0, &err));
    CHECK(makeDdrPublishPlan(f480, 1, plan1, &err));
    CHECK(plan0.layout.frame_bytes == kFrame480);
    CHECK(plan0.bank_offset == 0u);
    CHECK(plan0.bank_phys == 0x30000000u);
    CHECK(plan1.bank_offset == 0x80000u);
    CHECK(plan1.bank_phys == 0x30080000u);
    CHECK(plan0.bank_offset + plan0.layout.frame_bytes <= plan0.layout.map_bytes);
    CHECK(plan1.bank_offset + plan1.layout.frame_bytes <= plan1.layout.map_bytes);
    CHECK(plan0.layout.map_bytes == 0x100000u);
    CHECK(plan0.layout.doorbell_phys + 0x1000u <=
          plan0.layout.phys_base + plan0.layout.map_bytes);

    // 320x240 I420 must NOT publish as product canvas without pack.
    std::vector<uint8_t> yuv320(115200u, 0x40);
    DdrPublishFrame badLen{yuv320.data(), yuv320.size(), gProduct, DdrFrameFormat::Yuv420p};
    CHECK(!makeDdrPublishPlan(badLen, 0, plan0, &err));
    CHECK(err.find("frame size") != std::string::npos ||
          err.find("does not match") != std::string::npos);

    const auto g320 = makeDdrFrameGeometry(320, 240);
    DdrPublishFrame f320{yuv320.data(), yuv320.size(), g320, DdrFrameFormat::Yuv420p};
    CHECK(makeDdrPublishPlan(f320, 0, plan0, &err));
    CHECK(!ddrFrameLayoutMatchesProductSilicon(plan0.layout));
    CHECK(plan0.layout.frame_bytes == 115200u);
    CHECK(plan0.layout.bank_stride == 0x40000u);

    // Center-pack origins on each canvas.
    int x0 = -1, y0 = -1;
    CHECK(codedContentOriginCentered(624, 480, gProduct, x0, y0));
    CHECK(x0 == 0);
    CHECK(y0 == 0);
    CHECK(codedContentOriginCentered(320, 240, gProduct, x0, y0));
    // display box 618×480: x0 = crop_left + (618-320)/2 = 149 → even 148; y0 = 120
    CHECK(x0 == 148);
    CHECK(y0 == 120);

    const auto gL4 = plex720pDdrFrameGeometry();
    CHECK(codedContentOriginCentered(1280, 720, gL4, x0, y0));
    CHECK(x0 == 0 && y0 == 0);
    CHECK(codedContentOriginCentered(320, 240, gL4, x0, y0));
    CHECK(x0 == 480 && y0 == 240);

    std::vector<uint8_t> yuv720(kFrame720, 0x10);
    for (int y = 0; y < 720; ++y) {
        for (int x = 0; x < 16; ++x)
            yuv720[static_cast<size_t>(y) * 1280u + static_cast<size_t>(x)] = 0xEB;
    }
    std::vector<uint8_t> dst(kFrame720, 0);
    CHECK(packYuv420pCenteredIntoCodedBank(yuv720.data(), 1280, 720, dst.data(), gL4));
    CHECK(dst[0] == 0xEB);
    CHECK(dst[static_cast<size_t>(719) * 1280u] == 0xEB);
    CHECK(dst[1279] == 0x10);

    CHECK(yuv420pFrameBytes(1280, 720) == kFrame720);
    CHECK(yuv420pFrameBytes(320, 240) == 115200u);
    CHECK(yuv420pFrameBytes(624, 480) == kFrame480);

    // Default product bank ceiling is 480p stride (0x80000). 720p I420 needs 0x180000.
    CHECK(!ddrFrameStoreAcceptsResolution(1280, 720));
    CHECK(ddrFrameStoreAcceptsResolution(624, 480));
    CHECK(ddrFrameStoreAcceptsResolution(640, 480));
    CHECK(ddrFrameStoreAcceptsResolution(320, 240));
    CHECK(!ddrFrameStoreAcceptsResolution(1920, 1080));
    // L4 layout itself remains valid math for the compose path.
    CHECK(ddrFrameLayoutMatchesL4Silicon(plex720pDdrFrameStoreLayout()));

    // Legacy 480p helper IS product silicon under dual-header default.
    const auto g480 = plex480pDdrFrameGeometry();
    CHECK(g480.coded_width.get() == 624);
    CHECK(g480.presented_width.get() == 640);
    const auto layout480 = makeDdrFrameLayout(g480);
    CHECK(ddrFrameLayoutValid(layout480));
    CHECK(ddrFrameLayoutMatchesProductSilicon(layout480));
    CHECK(layout480.bank_stride == 0x80000u);
    CHECK(layout480.doorbell_phys == 0x300FF000u);

    if (fails) {
        std::fprintf(stderr, "test_native_480p_ddr_publish: %d fails\n", fails);
        return 1;
    }
    std::printf("PASS test_native_480p_ddr_publish product_frame=%zu bank=0x%x "
                "doorbell=0x%x L4_frame=%zu L4_doorbell=0x%x\n",
                kFrame480, static_cast<unsigned>(kPlex480pYuv420pBankStride),
                static_cast<unsigned>(kPlex480pYuv420pDoorbellPhys), kFrame720,
                static_cast<unsigned>(kPlex720pYuv420pDoorbellPhys));
    return 0;
}
