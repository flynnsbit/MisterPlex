// Native 480p DDR publish gate (w-geom).
//
// Proves from host ABI alone (no device):
//   1) makeDdrPublishPlan accepts a full 624x480 I420 payload (449280 B) with NO
//      320x240 clamp on the DDR path.
//   2) Plane offsets/strides match the RTL localparam contract exactly.
//   3) Capacity: frame + plane padding fit inside bank_stride 0x80000.
//   4) Full-coded pack origin is (0,0) — no 320-in-624 content pillarbox.
//   5) Wrong-length payloads (115200 = 320x240 I420) are rejected against 480p geom.
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

    // --- Capacity arithmetic (quoted product constants) -------------------------
    // Y = 624*480 = 299520
    // U = V = 312*240 = 74880
    // frame = 449280
    // bank = alignUp(449280, 0x40000) = 0x80000 = 524288
    // pad  = 524288 - 449280 = 75008
    constexpr size_t kY = 624u * 480u;
    constexpr size_t kC = (624u / 2u) * (480u / 2u);
    constexpr size_t kFrame = kY + 2u * kC;
    CHECK(kY == 299520u);
    CHECK(kC == 74880u);
    CHECK(kFrame == 449280u);
    CHECK(kFrame == static_cast<size_t>(kPlex480pYuv420pBytes));
    CHECK(kPlex480pYPlaneOffset == 0);
    CHECK(static_cast<size_t>(kPlex480pUPlaneOffset) == kY);
    CHECK(static_cast<size_t>(kPlex480pVPlaneOffset) == kY + kC);
    CHECK(kPlex480pYuv420pBankStride == 0x80000u);
    CHECK(kFrame <= kPlex480pYuv420pBankStride);
    CHECK(kPlex480pYuv420pBankStride - static_cast<uint32_t>(kFrame) == 75008u);

    // --- Geometry always product canvas (decode tier ignored) -------------------
    const auto gFrom240 = ddrFrameGeometryForFpgaPresent(320, 240);
    const auto gFrom480 = ddrFrameGeometryForFpgaPresent(624, 480);
    const auto gProduct = productDdrFrameStoreGeometry();
    CHECK(gFrom240.coded_width.get() == 624);
    CHECK(gFrom240.coded_height.get() == 480);
    CHECK(gFrom480.coded_width.get() == 624);
    CHECK(gFrom480.coded_height.get() == 480);
    CHECK(gFrom240.coded_width == gProduct.coded_width);
    CHECK(gFrom480.coded_height == gProduct.coded_height);
    CHECK(gProduct.display_width.get() == 618);
    CHECK(gProduct.presented_width.get() == 640);
    CHECK(gProduct.present_x == 11);
    CHECK(gProduct.crop_right == 6);

    const auto layout = makeDdrFrameLayout(gProduct);
    CHECK(ddrFrameLayoutValid(layout));
    CHECK(ddrFrameLayoutMatchesProductSilicon(layout));
    CHECK(layout.frame_bytes == kFrame);
    CHECK(layout.bank_stride == 0x80000u);
    CHECK(layout.doorbell_phys == 0x300FF000u);
    CHECK(layout.phys_base == 0x30000000u);
    CHECK(layout.y_offset == 0u);
    CHECK(layout.u_offset == 299520u);
    CHECK(layout.v_offset == 374400u);
    CHECK(layout.line_bytes == 624);
    CHECK(layout.chroma_line_bytes == 312);
    CHECK(layout.line_qwords == 78);
    CHECK(layout.chroma_line_qwords == 39);
    // Bank1 and doorbell placement.
    CHECK(layout.phys_base + layout.bank_stride == 0x30080000u);
    CHECK(layout.phys_base + layout.frame_bytes <= layout.phys_base + layout.bank_stride);
    CHECK(layout.phys_base + 2u * layout.bank_stride - 0x1000u == layout.doorbell_phys);

    // RTL mirror (ddr_frame_layout_params.svh / ddr_frame_store plane math):
    //   Y_PLANE_QWORDS = (CODED_W*CODED_H)/8
    //   C_PLANE_QWORDS = (CODED_W*CODED_H)/32
    //   U_PLANE_BASE   = Y_PLANE_QWORDS          → bytes *8
    //   V_PLANE_BASE   = Y+C                     → bytes *8
    const uint32_t yQ = static_cast<uint32_t>((624u * 480u) / 8u);
    const uint32_t cQ = static_cast<uint32_t>((624u * 480u) / 32u);
    CHECK(yQ * 8u == layout.u_offset);
    CHECK((yQ + cQ) * 8u == layout.v_offset);
    CHECK(yQ == 37440u);
    CHECK(cQ == 9360u);

    // --- Publish plan: full 624x480 I420 accepted end-to-end ---------------------
    std::vector<uint8_t> yuv480(kFrame, 0x10);
    // Paint a left-edge marker so pack/origin checks have content to inspect.
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
    CHECK(plan0.layout.frame_bytes == kFrame);
    CHECK(plan0.bank_offset == 0u);
    CHECK(plan0.bank_phys == 0x30000000u);
    CHECK(plan1.bank_offset == 0x80000u);
    CHECK(plan1.bank_phys == 0x30080000u);
    CHECK(plan0.bank_offset + plan0.layout.frame_bytes <= plan0.layout.map_bytes);
    CHECK(plan1.bank_offset + plan1.layout.frame_bytes <= plan1.layout.map_bytes);
    // map_bytes = 2 * bank_stride; doorbell page sits at end, past both banks.
    CHECK(plan0.layout.map_bytes == 0x100000u);
    CHECK(plan0.layout.doorbell_phys + 0x1000u <=
          plan0.layout.phys_base + plan0.layout.map_bytes);

    // --- Surviving clamps: wrong length / wrong geom rejected --------------------
    // 320x240 I420 = 115200 must NOT publish as product canvas without pack.
    std::vector<uint8_t> yuv320(115200u, 0x40);
    DdrPublishFrame badLen{yuv320.data(), yuv320.size(), gProduct, DdrFrameFormat::Yuv420p};
    CHECK(!makeDdrPublishPlan(badLen, 0, plan0, &err));
    CHECK(err.find("frame size") != std::string::npos ||
          err.find("does not match") != std::string::npos);

    // Identity-320 geometry is valid math but is NOT product silicon — publish
    // plan may accept it in isolation; product match gate must fail.
    const auto g320 = makeDdrFrameGeometry(320, 240);
    DdrPublishFrame f320{yuv320.data(), yuv320.size(), g320, DdrFrameFormat::Yuv420p};
    CHECK(makeDdrPublishPlan(f320, 0, plan0, &err));
    CHECK(!ddrFrameLayoutMatchesProductSilicon(plan0.layout));
    CHECK(plan0.layout.frame_bytes == 115200u);
    CHECK(plan0.layout.bank_stride == 0x40000u); // NOT product 0x80000

    // Full coded source pack origin = (0,0) — native 480p fills the bank.
    int x0 = -1, y0 = -1;
    CHECK(codedContentOriginCentered(624, 480, gProduct, x0, y0));
    CHECK(x0 == 0);
    CHECK(y0 == 0);
    // Display-box center pack of 320 still pillars (silicon-measured x=152 class).
    CHECK(codedContentOriginCentered(320, 240, gProduct, x0, y0));
    CHECK(x0 == 148);
    CHECK(y0 == 120);

    std::vector<uint8_t> dst(kFrame, 0);
    CHECK(packYuv420pCenteredIntoCodedBank(yuv480.data(), 624, 480, dst.data(), gProduct));
    // Left edge of coded bank carries content (0xEB), not studio black — no pillar.
    CHECK(dst[0] == 0xEB);
    CHECK(dst[static_cast<size_t>(120) * 624u] == 0xEB);
    CHECK(dst[static_cast<size_t>(479) * 624u] == 0xEB);
    // Outside the 16px white marker → source fill 0x10.
    CHECK(dst[617] == 0x10);

    // yuv420pFrameBytes helper matches.
    CHECK(yuv420pFrameBytes(624, 480) == kFrame);
    CHECK(yuv420pFrameBytes(320, 240) == 115200u);

    // Accept-resolution helper: 624x480 and 640x480 OK; 1280x720 not.
    CHECK(ddrFrameStoreAcceptsResolution(624, 480));
    CHECK(ddrFrameStoreAcceptsResolution(640, 480));
    CHECK(ddrFrameStoreAcceptsResolution(320, 240));
    CHECK(!ddrFrameStoreAcceptsResolution(1280, 720));

    if (fails) {
        std::fprintf(stderr, "test_native_480p_ddr_publish: %d fails\n", fails);
        return 1;
    }
    std::printf("PASS test_native_480p_ddr_publish frame_bytes=%zu bank=0x%x "
                "u_off=%u v_off=%u pad=%u full_origin=0,0 NO_320_CLAMP\n",
                kFrame, static_cast<unsigned>(kPlex480pYuv420pBankStride),
                static_cast<unsigned>(kPlex480pUPlaneOffset),
                static_cast<unsigned>(kPlex480pVPlaneOffset), 75008u);
    return 0;
}
