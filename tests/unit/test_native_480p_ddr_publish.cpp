// Native DDR publish gate (w-geom / w-nostub-720p).
//
// Proves from host ABI alone (no device):
//   1) Product silicon canvas is 1280×720 identity I420 (bank 0x180000).
//   2) ddrFrameGeometryForFpgaPresent ignores DECODE and returns product.
//   3) Legacy 480p helper geometry remains valid for non-product math.
//   4) Wrong-length payloads are rejected against product geom.
//   5) 1280×720 is accepted by ddrFrameStoreAcceptsResolution.
//
// Companion RTL gate: tests/unit/test_ddr_frame_store_native_480p.sh (legacy name)
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

    // --- Product 720p capacity --------------------------------------------------
    constexpr size_t kY = 1280u * 720u;
    constexpr size_t kC = (1280u / 2u) * (720u / 2u);
    constexpr size_t kFrame = kY + 2u * kC;
    CHECK(kY == 921600u);
    CHECK(kC == 230400u);
    CHECK(kFrame == 1382400u);
    CHECK(kFrame == static_cast<size_t>(kPlex720pYuv420pBytes));
    CHECK(kPlex720pYPlaneOffset == 0);
    CHECK(static_cast<size_t>(kPlex720pUPlaneOffset) == kY);
    CHECK(static_cast<size_t>(kPlex720pVPlaneOffset) == kY + kC);
    CHECK(kPlex720pYuv420pBankStride == 0x180000u);
    CHECK(kFrame <= kPlex720pYuv420pBankStride);
    CHECK(kPlex720pYuv420pBankStride - static_cast<uint32_t>(kFrame) == 190464u);

    // --- Geometry always product canvas (decode tier ignored) -------------------
    const auto gFrom240 = ddrFrameGeometryForFpgaPresent(320, 240);
    const auto gFrom480 = ddrFrameGeometryForFpgaPresent(624, 480);
    const auto gFrom720 = ddrFrameGeometryForFpgaPresent(1280, 720);
    const auto gProduct = productDdrFrameStoreGeometry();
    CHECK(gFrom240.coded_width.get() == 1280);
    CHECK(gFrom240.coded_height.get() == 720);
    CHECK(gFrom480.coded_width.get() == 1280);
    CHECK(gFrom720.coded_height.get() == 720);
    CHECK(gFrom240.coded_width == gProduct.coded_width);
    CHECK(gFrom720.coded_height == gProduct.coded_height);
    CHECK(gProduct.display_width.get() == 1280);
    CHECK(gProduct.presented_width.get() == 1280);
    CHECK(gProduct.present_x == 0);
    CHECK(gProduct.crop_right == 0);

    const auto layout = makeDdrFrameLayout(gProduct);
    CHECK(ddrFrameLayoutValid(layout));
    CHECK(ddrFrameLayoutMatchesProductSilicon(layout));
    CHECK(layout.frame_bytes == kFrame);
    CHECK(layout.bank_stride == 0x180000u);
    CHECK(layout.doorbell_phys == 0x302FF000u);
    CHECK(layout.phys_base == 0x30000000u);
    CHECK(layout.y_offset == 0u);
    CHECK(layout.u_offset == 921600u);
    CHECK(layout.v_offset == 1152000u);
    CHECK(layout.line_bytes == 1280);
    CHECK(layout.chroma_line_bytes == 640);
    CHECK(layout.line_qwords == 160);
    CHECK(layout.chroma_line_qwords == 80);
    CHECK(layout.phys_base + layout.bank_stride == 0x30180000u);
    CHECK(layout.phys_base + layout.frame_bytes <= layout.phys_base + layout.bank_stride);
    CHECK(layout.phys_base + 2u * layout.bank_stride - 0x1000u == layout.doorbell_phys);

    const uint32_t yQ = static_cast<uint32_t>((1280u * 720u) / 8u);
    const uint32_t cQ = static_cast<uint32_t>((1280u * 720u) / 32u);
    CHECK(yQ * 8u == layout.u_offset);
    CHECK((yQ + cQ) * 8u == layout.v_offset);
    CHECK(yQ == 115200u);
    CHECK(cQ == 28800u);

    // --- Publish plan: full 1280×720 I420 accepted ------------------------------
    std::vector<uint8_t> yuv720(kFrame, 0x10);
    for (int y = 0; y < 720; ++y) {
        for (int x = 0; x < 16; ++x)
            yuv720[static_cast<size_t>(y) * 1280u + static_cast<size_t>(x)] = 0xEB;
    }
    DdrPublishFrame f720{yuv720.data(), yuv720.size(), gProduct, DdrFrameFormat::Yuv420p};
    DdrPublishPlan plan0{};
    DdrPublishPlan plan1{};
    std::string err;
    CHECK(makeDdrPublishPlan(f720, 0, plan0, &err));
    CHECK(makeDdrPublishPlan(f720, 1, plan1, &err));
    CHECK(plan0.layout.frame_bytes == kFrame);
    CHECK(plan0.bank_offset == 0u);
    CHECK(plan0.bank_phys == 0x30000000u);
    CHECK(plan1.bank_offset == 0x180000u);
    CHECK(plan1.bank_phys == 0x30180000u);
    CHECK(plan0.bank_offset + plan0.layout.frame_bytes <= plan0.layout.map_bytes);
    CHECK(plan1.bank_offset + plan1.layout.frame_bytes <= plan1.layout.map_bytes);
    CHECK(plan0.layout.map_bytes == 0x300000u);
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

    // Full coded pack origin = (0,0) on identity product.
    int x0 = -1, y0 = -1;
    CHECK(codedContentOriginCentered(1280, 720, gProduct, x0, y0));
    CHECK(x0 == 0);
    CHECK(y0 == 0);
    CHECK(codedContentOriginCentered(320, 240, gProduct, x0, y0));
    CHECK(x0 == 480);
    CHECK(y0 == 240);

    std::vector<uint8_t> dst(kFrame, 0);
    CHECK(packYuv420pCenteredIntoCodedBank(yuv720.data(), 1280, 720, dst.data(), gProduct));
    CHECK(dst[0] == 0xEB);
    CHECK(dst[static_cast<size_t>(240) * 1280u] == 0xEB);
    CHECK(dst[static_cast<size_t>(719) * 1280u] == 0xEB);
    CHECK(dst[1279] == 0x10);

    CHECK(yuv420pFrameBytes(1280, 720) == kFrame);
    CHECK(yuv420pFrameBytes(320, 240) == 115200u);

    // Accept-resolution helper under product bank ceiling 0x180000.
    CHECK(ddrFrameStoreAcceptsResolution(1280, 720));
    CHECK(ddrFrameStoreAcceptsResolution(624, 480));
    CHECK(ddrFrameStoreAcceptsResolution(640, 480));
    CHECK(ddrFrameStoreAcceptsResolution(320, 240));
    CHECK(!ddrFrameStoreAcceptsResolution(1920, 1080));

    // Legacy 480p helper still declared (not product silicon).
    const auto g480 = plex480pDdrFrameGeometry();
    CHECK(g480.coded_width.get() == 624);
    CHECK(g480.presented_width.get() == 640);
    const auto layout480 = makeDdrFrameLayout(g480);
    CHECK(ddrFrameLayoutValid(layout480));
    CHECK(!ddrFrameLayoutMatchesProductSilicon(layout480));
    CHECK(layout480.bank_stride == 0x80000u);
    CHECK(layout480.doorbell_phys == 0x300FF000u);

    if (fails) {
        std::fprintf(stderr, "test_native_480p_ddr_publish: %d fails\n", fails);
        return 1;
    }
    std::printf("PASS test_native_480p_ddr_publish product_frame=%zu bank=0x%x "
                "doorbell=0x%x u_off=%u legacy480_ok\n",
                kFrame, static_cast<unsigned>(kPlex720pYuv420pBankStride),
                static_cast<unsigned>(kPlex720pYuv420pDoorbellPhys),
                static_cast<unsigned>(kPlex720pUPlaneOffset));
    return 0;
}
