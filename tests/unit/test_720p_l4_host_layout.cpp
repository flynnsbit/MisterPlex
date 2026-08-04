// L4 720p host layout composition (w-nostub).
// Positive: plex720pDdrFrameStoreLayout matches silicon constants.
// Negative: 480p product layout must NOT match L4 silicon; identity-DECODE
//           1280 layout at wrong phys must NOT match L4.

#include "libmisterplex/ddr_frame_layout.hpp"

#include <cstdio>
#include <cstdlib>

using namespace misterplex;

static int g_fails = 0;

#define CHECK(cond)                                                                              \
    do {                                                                                         \
        if (!(cond)) {                                                                           \
            std::fprintf(stderr, "FAIL %s:%d: %s\n", __FILE__, __LINE__, #cond);                 \
            ++g_fails;                                                                           \
        }                                                                                        \
    } while (0)

int main() {
    const auto g720 = plex720pDdrFrameGeometry();
    CHECK(g720.coded_width.get() == 1280);
    CHECK(g720.coded_height.get() == 720);
    CHECK(g720.display_width.get() == 1280);
    CHECK(g720.presented_width.get() == 1280);
    CHECK(g720.crop_left == 0 && g720.crop_right == 0);
    CHECK(g720.present_x == 0);

    const auto l720 = plex720pDdrFrameStoreLayout();
    CHECK(ddrFrameLayoutValid(l720));
    CHECK(ddrFrameLayoutMatchesL4Silicon(l720));
    CHECK(l720.phys_base == kPlex720pPhysBase);
    CHECK(l720.phys_base == 0x30180000u);
    CHECK(l720.bank_stride == kPlex720pYuv420pBankStride);
    CHECK(l720.bank_stride == 0x180000u);
    CHECK(l720.doorbell_phys == kPlex720pYuv420pDoorbellPhys);
    CHECK(l720.doorbell_phys == 0x3047F000u);
    CHECK(l720.line_bytes == 1280);
    CHECK(l720.chroma_line_bytes == 640);
    CHECK(l720.line_qwords == 160);
    CHECK(l720.chroma_line_qwords == 80);
    CHECK(l720.frame_bytes == 1382400u);
    CHECK(l720.y_offset == 0u);
    CHECK(l720.u_offset == 921600u);
    CHECK(l720.v_offset == 1152000u);
    CHECK(l720.doorbell_phys == l720.phys_base + 2u * l720.bank_stride - 0x1000u);

    // Presented-size map routes 1280x720 to L4 identity.
    const auto fromPres =
        ddrFrameGeometryForPresentedSize(PresentedWidth{1280}, PresentedHeight{720});
    CHECK(fromPres.coded_width.get() == 1280);
    CHECK(fromPres.coded_height.get() == 720);

    // Default product (this TU without MISTERPLEX_PRODUCT_720P_L4) stays 480p.
    const auto gProd = productDdrFrameStoreGeometry();
    CHECK(gProd.coded_width == kPlex480pCodedWidth);
    const auto lProd = productDdrFrameStoreLayout();
    CHECK(ddrFrameLayoutMatchesProductSilicon(lProd));
    CHECK(!ddrFrameLayoutMatchesL4Silicon(lProd)); // negative: 480p ≠ L4

    // Negative: correct 720p geometry but 480p phys base → not L4 silicon.
    const auto wrongPhys =
        makeDdrFrameLayout(plex720pDdrFrameGeometry(), kDdrFramePhysBase, kDdrFrameStrideAlign);
    CHECK(wrongPhys.phys_base == 0x30000000u);
    CHECK(!ddrFrameLayoutMatchesL4Silicon(wrongPhys));

    // Negative: 480p doorbell must never equal L4 doorbell.
    CHECK(kPlex480pYuv420pDoorbellPhys != kPlex720pYuv420pDoorbellPhys);
    CHECK(kDdrFramePhysBase != kPlex720pPhysBase);

    if (g_fails != 0) {
        std::fprintf(stderr, "test_720p_l4_host_layout: %d failure(s)\n", g_fails);
        return 1;
    }
    std::puts("PASS test_720p_l4_host_layout");
    return 0;
}
