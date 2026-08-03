#include "libmisterplex/pixel_format.hpp"

#include <cstdint>
#include <cstdio>
#include <vector>

static int checks = 0;
static int fails = 0;

#define CHECK(cond)                                                                              \
    do {                                                                                         \
        ++checks;                                                                                \
        if (!(cond)) {                                                                           \
            std::fprintf(stderr, "FAIL %s:%d: %s\n", __FILE__, __LINE__, #cond);                 \
            ++fails;                                                                             \
        }                                                                                        \
    } while (0)

int main() {
    using namespace misterplex::pixel;

    CHECK(packRgb565(255, 0, 0) == 0xF800);
    CHECK(packRgb565(0, 255, 0) == 0x07E0);
    CHECK(packRgb565(0, 0, 255) == 0x001F);
    CHECK(packRgb565(255, 255, 255) == 0xFFFF);

    const std::vector<uint8_t> rgb = {
        255, 0, 0,     // red
        0,   255, 0,   // green
        0,   0,   255, // blue
        18,  52,  86,  // quantized mixed colour
    };
    std::vector<uint8_t> rgb565(rgb.size() / 3 * 2);
    rgb24ToRgb565Le(rgb.data(), rgb565.data(), rgb.size() / 3);

    CHECK(loadLe16(rgb565.data() + 0) == 0xF800);
    CHECK(loadLe16(rgb565.data() + 2) == 0x07E0);
    CHECK(loadLe16(rgb565.data() + 4) == 0x001F);
    CHECK(loadLe16(rgb565.data() + 6) == packRgb565(18, 52, 86));

    uint8_t r = 0, g = 0, b = 0;
    expandRgb565(0xF800, r, g, b);
    CHECK(r == 255 && g == 0 && b == 0);
    expandRgb565(0x07E0, r, g, b);
    CHECK(r == 0 && g == 255 && b == 0);
    expandRgb565(0x001F, r, g, b);
    CHECK(r == 0 && g == 0 && b == 255);

    std::vector<uint8_t> bgra(3 * 4);
    rgb565LeToBgra8888(rgb565.data(), bgra.data(), 3);
    CHECK((bgra[0] == 0 && bgra[1] == 0 && bgra[2] == 255 && bgra[3] == 255));
    CHECK((bgra[4] == 0 && bgra[5] == 255 && bgra[6] == 0 && bgra[7] == 255));
    CHECK((bgra[8] == 255 && bgra[9] == 0 && bgra[10] == 0 && bgra[11] == 255));

    yuvToRgb(128, 128, 128, r, g, b);
    CHECK(r == 128 && g == 128 && b == 128);
    yuvToRgb(16, 128, 128, r, g, b);
    CHECK(r == 16 && g == 16 && b == 16);
    yuvToRgb(76, 85, 255, r, g, b);
    CHECK(r == 254 && g == 0 && b == 0);

    if (fails) {
        std::fprintf(stderr, "test_pixel_format: FAILED checks=%d failures=%d\n", checks, fails);
        return 1;
    }
    std::printf("test_pixel_format: OK checks=%d\n", checks);
    return 0;
}
