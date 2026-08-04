// 720p host layout composition (w-nostub on integ/720p-compose).
// Default TU (no MISTERPLEX_PRODUCT_DDR_720P): product stays 480p.
// plex720pDdrFrameStoreLayout always matches 720p silicon constants.
// Negative: 480p product ≠ L4; 720p geom @ 480p phys ≠ L4.

#include "libmisterplex/ddr_frame_layout.hpp"

#include <cstdio>

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
    CHECK(g720.crop_left == 0 && g720.crop_right == 0);

    const auto l720 = plex720pDdrFrameStoreLayout();
    CHECK(ddrFrameLayoutValid(l720));
    CHECK(ddrFrameLayoutMatchesL4Silicon(l720));
    CHECK(l720.phys_base == 0x30180000u);
    CHECK(l720.bank_stride == 0x180000u);
    CHECK(l720.doorbell_phys == 0x3047F000u);
    CHECK(l720.line_bytes == 1280 && l720.chroma_line_bytes == 640);
    CHECK(l720.line_qwords == 160 && l720.chroma_line_qwords == 80);
    CHECK(l720.frame_bytes == 1382400u);
    CHECK(l720.u_offset == 921600u && l720.v_offset == 1152000u);
    CHECK(l720.doorbell_phys == l720.phys_base + 2u * l720.bank_stride - 0x1000u);

    const auto fromPres =
        ddrFrameGeometryForPresentedSize(PresentedWidth{1280}, PresentedHeight{720});
    CHECK(fromPres.coded_width.get() == 1280);

    // Default product (this TU) = 480p silicon.
    const auto gProd = productDdrFrameStoreGeometry();
    CHECK(gProd.coded_width == kPlex480pCodedWidth);
    const auto lProd = productDdrFrameStoreLayout();
    CHECK(ddrFrameLayoutMatchesProductSilicon(lProd));
    CHECK(!ddrFrameLayoutMatchesL4Silicon(lProd));

    const auto wrongPhys =
        makeDdrFrameLayout(plex720pDdrFrameGeometry(), kDdrFramePhysBase, kDdrFrameStrideAlign);
    CHECK(wrongPhys.phys_base == 0x30000000u);
    CHECK(!ddrFrameLayoutMatchesL4Silicon(wrongPhys));

    CHECK(kPlex480pYuv420pDoorbellPhys != kPlex720pYuv420pDoorbellPhys);
    CHECK(kDdrFramePhysBase != kPlex720pPhysBase);

    if (g_fails != 0) {
        std::fprintf(stderr, "test_720p_l4_host_layout: %d failure(s)\n", g_fails);
        return 1;
    }
    std::puts("PASS test_720p_l4_host_layout");
    return 0;
}
