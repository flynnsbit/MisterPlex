// Regression: DECODE=624x480 must not silent-skip FPGA present (pfps=0.00 defect).
// Fails if prep rejects 624x480 the way the legacy `outW==320 && outH==240` gate did.
// Passes when fpgaPresentPrep scales into the hybrid 320×240 RGB565 store.

#include "libmisterplex/frame_store_present.hpp"

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <vector>

using namespace misterplex;

static int fails = 0;
#define CHECK(c)                                                                                 \
    do {                                                                                         \
        if (!(c)) {                                                                              \
            std::fprintf(stderr, "FAIL %s:%d %s\n", __FILE__, __LINE__, #c);                     \
            ++fails;                                                                             \
        }                                                                                        \
    } while (0)

int main() {
    // --- Document the measured defect predicate ---
    CHECK(legacySilentSkipFpgaPresent(624, 480) == true);
    CHECK(legacySilentSkipFpgaPresent(320, 240) == false);

    // --- Production must NOT reject 624×480 (this is the pfps=0 root cause) ---
    CHECK(fpgaPresentPrep(624, 480) == FpgaPresentPrep::ScaleToStore);
    CHECK(fpgaPresentPrep(320, 240) == FpgaPresentPrep::Identity);
    CHECK(fpgaPresentPrep(640, 480) == FpgaPresentPrep::ScaleToStore);
    CHECK(fpgaPresentPrep(0, 240) == FpgaPresentPrep::Reject);
    CHECK(fpgaPresentPrep(320, 0) == FpgaPresentPrep::Reject);

    // If someone reintroduces equality-only present, this fails:
    const bool wouldPresent624 =
        fpgaPresentPrep(624, 480) != FpgaPresentPrep::Reject;
    CHECK(wouldPresent624);

    // --- Scale 624×480 solid red into store; center must be red-ish, corners black ---
    std::vector<uint8_t> src(static_cast<size_t>(624) * 480 * 3, 0);
    for (size_t i = 0; i < src.size(); i += 3) {
        src[i + 0] = 255;
        src[i + 1] = 0;
        src[i + 2] = 0;
    }
    std::vector<uint8_t> dst(kRgb24FrameStoreBytes, 0xA5);
    CHECK(scaleRgb24ToFrameStore(src.data(), 624, 480, dst.data()));

    // Corner (0,0) should be letterbox black
    CHECK(dst[0] == 0 && dst[1] == 0 && dst[2] == 0);

    // Center pixel should sample source red
    const size_t cx = (static_cast<size_t>(kRgb565FrameStoreW / 2) +
                       static_cast<size_t>(kRgb565FrameStoreH / 2) * kRgb565FrameStoreW) *
                      3u;
    CHECK(dst[cx] == 255);
    CHECK(dst[cx + 1] == 0);
    CHECK(dst[cx + 2] == 0);

    // Store byte budget matches DDR path (153600 RGB565 after pack)
    CHECK(kRgb565FrameStoreBytes == 153600u);
    CHECK(kRgb24FrameStoreBytes == 230400u);

    // Identity path: 320×240 needs no scale for prep
    CHECK(fpgaPresentPrep(kRgb565FrameStoreW, kRgb565FrameStoreH) == FpgaPresentPrep::Identity);

    if (fails) {
        std::fprintf(stderr, "test_present_scale_480: %d fails\n", fails);
        return 1;
    }
    std::printf("test_present_scale_480: OK\n");
    return 0;
}
