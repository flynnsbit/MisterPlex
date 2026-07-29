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
