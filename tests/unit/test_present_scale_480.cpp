// Regression: DECODE=624x480 vs hybrid 320×240 RGB565 frame store.
//
// Default product policy: CLAMP decode to 320×240 (not silent skip, not 4× scale).
// Opt-in PRESENT_SCALE_TO_STORE=1: keep decode and ScaleToStore at present.
// Legacy equality gate must remain documented as the pfps=0 defect.

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

    // --- Byte bound (parent-verified) ---
    CHECK(rgb565FrameBytes(624, 480) == 599040u);
    CHECK(kRgb565FrameStoreBytes == 153600u);
    CHECK(rgb565FrameBytes(624, 480) > kRgb565FrameStoreBytes);

    // --- Default: clamp, do not scale ---
    {
        const DecodeStorePlan p = planDecodeForHybridStore(624, 480, /*fpga*/ true,
                                                           /*allowScale*/ false);
        CHECK(p.clamped == true);
        CHECK(p.will_scale_at_present == false);
        CHECK(p.decode_w == 320 && p.decode_h == 240);
        CHECK(p.requested_rgb565_bytes == 599040u);
        const std::string line = formatDecodeClampLog(624, 480, p);
        CHECK(line.find("624x480") != std::string::npos);
        CHECK(line.find("599040") != std::string::npos);
        CHECK(line.find("153600") != std::string::npos);
        CHECK(line.find("clamping decode to 320x240") != std::string::npos);
        // Present prep after clamp is Identity
        CHECK(fpgaPresentPrep(p.decode_w, p.decode_h, false) == FpgaPresentPrep::Identity);
    }

    // --- Opt-in scale: keep 624 decode, scale at present ---
    {
        const DecodeStorePlan p = planDecodeForHybridStore(624, 480, /*fpga*/ true,
                                                           /*allowScale*/ true);
        CHECK(p.clamped == false);
        CHECK(p.will_scale_at_present == true);
        CHECK(p.decode_w == 624 && p.decode_h == 480);
        CHECK(fpgaPresentPrep(624, 480, true) == FpgaPresentPrep::ScaleToStore);
        CHECK(fpgaPresentPrep(624, 480, false) == FpgaPresentPrep::Reject);
    }

    // --- fb0 path: no clamp ---
    {
        const DecodeStorePlan p = planDecodeForHybridStore(624, 480, /*fpga*/ false, false);
        CHECK(p.clamped == false);
        CHECK(p.decode_w == 624);
    }

    // --- Identity ---
    CHECK(fpgaPresentPrep(320, 240, false) == FpgaPresentPrep::Identity);
    CHECK(fpgaPresentPrep(0, 240, false) == FpgaPresentPrep::Reject);

    // --- Scaler still works when opted in ---
    {
        std::vector<uint8_t> src(static_cast<size_t>(624) * 480 * 3, 0);
        for (size_t i = 0; i < src.size(); i += 3) {
            src[i] = 255;
        }
        std::vector<uint8_t> dst(kRgb24FrameStoreBytes, 0xA5);
        CHECK(scaleRgb24ToFrameStore(src.data(), 624, 480, dst.data()));
        CHECK(dst[0] == 0 && dst[1] == 0 && dst[2] == 0);
        const size_t cx = (static_cast<size_t>(kRgb565FrameStoreW / 2) +
                           static_cast<size_t>(kRgb565FrameStoreH / 2) * kRgb565FrameStoreW) *
                          3u;
        CHECK(dst[cx] == 255);
    }

    // RED-guard: default must NOT be ScaleToStore for 624 without opt-in
    CHECK(planDecodeForHybridStore(624, 480, true, false).will_scale_at_present == false);
    CHECK(planDecodeForHybridStore(624, 480, true, false).clamped == true);

    if (fails) {
        std::fprintf(stderr, "test_present_scale_480: %d fails\n", fails);
        return 1;
    }
    std::printf("test_present_scale_480: OK\n");
    return 0;
}
