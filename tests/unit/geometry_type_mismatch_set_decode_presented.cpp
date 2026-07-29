// COMPILE-FAIL probe: PresentedWidth must not bind where CodedWidth is required
// on the decode-size boundary (setDecodeSize).
#include "libmisterplex/coded_size.hpp"
#include "libmisterplex/ddr_frame_layout.hpp"

namespace misterplex {

struct DecodeSizeBoundary {
    void setDecodeSize(CodedWidth w, CodedHeight h);
    void setDecodeSize(CodedSize size) { setDecodeSize(size.width, size.height); }
};

} // namespace misterplex

int main() {
    misterplex::DecodeSizeBoundary sink;
    // Presented scanout width smuggled into decode path — must not compile.
    sink.setDecodeSize(misterplex::kPlex480pPresentedWidth, misterplex::kPlex480pCodedHeight);
    return 0;
}
