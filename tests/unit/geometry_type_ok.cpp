// Positive companion to geometry_type_mismatch_*: typed call sites still compile
// and preserve the plex480p coded/presented contract numerically.
#include "libmisterplex/ddr_frame_layout.hpp"
#include "libmisterplex/osd_menu.hpp"

#include <cstdio>
#include <string_view>
#include <type_traits>

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

    static_assert(!std::is_same<CodedWidth, PresentedWidth>::value, "types collapsed");
    static_assert(!std::is_convertible<PresentedWidth, CodedWidth>::value, "presented->coded");
    static_assert(!std::is_convertible<CodedWidth, int>::value, "coded->int implicit");

    const auto g = plex480pDdrFrameGeometry();
    CHECK(g.coded_width.get() == 624);
    CHECK(g.presented_width.get() == 640);
    CHECK(g.display_width.get() == 618);
    CHECK(g.crop_right == 6);
    CHECK(g.present_x == 11);

    // Correct typed construction still works.
    const auto g2 = makeDdrFrameGeometry(kPlex480pCodedWidth, kPlex480pCodedHeight,
                                         kPlex480pDisplayWidth, kPlex480pDisplayHeight,
                                         kPlex480pPresentedWidth, kPlex480pPresentedHeight,
                                         DdrFramePlacement::Pillarbox);
    CHECK(g2.coded_width == kPlex480pCodedWidth);
    CHECK(g2.presented_width == kPlex480pPresentedWidth);

    const auto fromPresented =
        ddrFrameGeometryForPresentedSize(kPlex480pPresentedWidth, kPlex480pPresentedHeight);
    CHECK(fromPresented.coded_width == kPlex480pCodedWidth);
    CHECK(fromPresented.presented_width == kPlex480pPresentedWidth);

    // Source-native storage: DECODE=320x240 keeps 320×240 content geometry
    // (fabric upscales). Bank window is still LEG/Option-C only after pin —
    // raw makeDdrFrameLayout is geometry-derived and is NOT the publish map.
    const auto from240 = ddrFrameGeometryForFpgaPresent(CodedWidth{320}, CodedHeight{240});
    CHECK(from240.coded_width.get() == 320);
    CHECK(from240.coded_height.get() == 240);
    CHECK(from240.presented_width.get() == 320);
    CHECK(productDdrFrameStoreGeometry().coded_width == kPlex480pCodedWidth);
    CHECK(ddrFrameLayoutMatchesProductSilicon(makeDdrFrameLayout(productDdrFrameStoreGeometry())));
    {
        auto lay240 = makeDdrFrameLayout(from240);
        CHECK(ddrLayoutBankMapIsGeometryDerived(lay240)); // raw 0x40000 trap
        CHECK(ddrPinLayoutToBankMap(lay240, DdrBankMap::Legacy480p));
        CHECK(!ddrLayoutBankMapIsGeometryDerived(lay240));
        CHECK(lay240.bank_stride == kPlex480pYuv420pBankStride);
        CHECK(lay240.doorbell_phys == kPlex480pYuv420pDoorbellPhys);
        CHECK(lay240.line_bytes == 320);
        CHECK(lay240.frame_bytes == 115200u);
    }

    CHECK(weakBitrateKbpsForCodedSize(kPlex480pCodedWidth, kPlex480pCodedHeight) ==
          kPlex480pWeakBitrateKbps);
    CHECK(std::string_view(contentResolutionFor480p().label) == "624x480");
    CHECK(contentResolutionFor480p().width == kPlex480pCodedWidth);

    // Doorbell remains geometry-derived from coded bank layout, not presented width.
    const auto layout = makeDdrFrameLayout(g);
    CHECK(ddrFrameLayoutValid(layout));
    CHECK(layout.doorbell_phys == kPlex480pYuv420pDoorbellPhys);
    CHECK(layout.bank_stride == kPlex480pYuv420pBankStride);
    CHECK(layout.line_bytes == kPlex480pCodedWidth.get());
    CHECK(layout.line_bytes != kPlex480pPresentedWidth.get());

    if (fails) {
        std::fprintf(stderr, "test_geometry_type_ok: %d fails\n", fails);
        return 1;
    }
    std::printf("test_geometry_type_ok: OK\n");
    return 0;
}
