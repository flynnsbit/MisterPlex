// COMPILE-FAIL probe: presented width must not bind where coded width is required.
// Built by tests/unit/test_geometry_type_safety.sh — must NOT successfully compile.
#include "libmisterplex/ddr_frame_layout.hpp"
#include "libmisterplex/osd_menu.hpp"

namespace {

using misterplex::kPlex480pCodedHeight;
using misterplex::kPlex480pPresentedHeight;
using misterplex::kPlex480pPresentedWidth;
using misterplex::makeDdrFrameGeometry;
using misterplex::weakBitrateKbpsForCodedSize;

// Intentional bad program: pass presented scanout width as the coded argument.
void should_not_compile_presented_as_coded_geometry() {
    // makeDdrFrameGeometry(CodedWidth, CodedHeight, ...) — PresentedWidth must fail.
    auto g = makeDdrFrameGeometry(kPlex480pPresentedWidth, kPlex480pCodedHeight);
    (void)g;
}

void should_not_compile_presented_as_coded_bitrate() {
    // weakBitrateKbpsForCodedSize(CodedWidth, CodedHeight) — PresentedWidth must fail.
    int br = weakBitrateKbpsForCodedSize(kPlex480pPresentedWidth, kPlex480pPresentedHeight);
    (void)br;
}

} // namespace

int main() {
    should_not_compile_presented_as_coded_geometry();
    should_not_compile_presented_as_coded_bitrate();
    return 0;
}
