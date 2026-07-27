#include "libmisterplex/pixel_format.hpp"

#include <cassert>
#include <array>
#include <cstdint>
#include <vector>

namespace {

uint8_t expand5(unsigned v) {
    return static_cast<uint8_t>((v << 3) | (v >> 2));
}

uint8_t expand6(unsigned v) {
    return static_cast<uint8_t>((v << 2) | (v >> 4));
}

uint16_t badGreenShiftPack(uint8_t r, uint8_t g, uint8_t b) {
    return static_cast<uint16_t>(((r & 0xF8) << 8) | ((g & 0xFC) << 2) | (b >> 3));
}

} // namespace

int main() {
    using namespace misterplex::pixel;

    assert(packRgb565(255, 0, 0) == 0xF800);
    assert(packRgb565(0, 255, 0) == 0x07E0);
    assert(packRgb565(0, 0, 255) == 0x001F);
    assert(packRgb565(255, 255, 255) == 0xFFFF);
    assert(packRgb565(0, expand6(1), 0) == 0x0020);
    assert(packRgb565(0, expand6(32), 0) == 0x0400);
    assert(packRgb565(0, expand6(63), 0) == 0x07E0);
    assert(badGreenShiftPack(0, expand6(1), 0) != packRgb565(0, expand6(1), 0));
    assert(badGreenShiftPack(0, expand6(32), 0) != packRgb565(0, expand6(32), 0));

    const std::vector<uint8_t> rgb = {
        255, 0, 0,     // red
        0,   255, 0,   // green
        0,   0,   255, // blue
        18,  52,  86,  // quantized mixed colour
    };
    std::vector<uint8_t> rgb565(rgb.size() / 3 * 2);
    rgb24ToRgb565Le(rgb.data(), rgb565.data(), rgb.size() / 3);

    assert(loadLe16(rgb565.data() + 0) == 0xF800);
    assert(loadLe16(rgb565.data() + 2) == 0x07E0);
    assert(loadLe16(rgb565.data() + 4) == 0x001F);
    assert(loadLe16(rgb565.data() + 6) == packRgb565(18, 52, 86));

    uint8_t r = 0, g = 0, b = 0;
    expandRgb565(0xF800, r, g, b);
    assert(r == 255 && g == 0 && b == 0);
    expandRgb565(0x07E0, r, g, b);
    assert(r == 0 && g == 255 && b == 0);
    expandRgb565(0x001F, r, g, b);
    assert(r == 0 && g == 0 && b == 255);

    std::vector<uint8_t> bgra(3 * 4);
    rgb565LeToBgra8888(rgb565.data(), bgra.data(), 3);
    assert((bgra[0] == 0 && bgra[1] == 0 && bgra[2] == 255 && bgra[3] == 255));
    assert((bgra[4] == 0 && bgra[5] == 255 && bgra[6] == 0 && bgra[7] == 255));
    assert((bgra[8] == 255 && bgra[9] == 0 && bgra[10] == 0 && bgra[11] == 255));

    std::vector<uint8_t> exactRgb;
    exactRgb.reserve(65536 * 3);
    for (unsigned p = 0; p <= 0xFFFF; ++p) {
        exactRgb.push_back(expand5((p >> 11) & 0x1F));
        exactRgb.push_back(expand6((p >> 5) & 0x3F));
        exactRgb.push_back(expand5(p & 0x1F));
    }
    std::vector<uint8_t> exact565(exactRgb.size() / 3 * 2);
    std::vector<uint8_t> exactBgra(exactRgb.size() / 3 * 4);
    rgb24ToRgb565Le(exactRgb.data(), exact565.data(), exactRgb.size() / 3);
    rgb565LeToBgra8888(exact565.data(), exactBgra.data(), exactRgb.size() / 3);
    for (size_t i = 0; i < exactRgb.size() / 3; ++i) {
        const uint16_t packed = loadLe16(exact565.data() + i * 2);
        assert(packed == i);
        assert(exactBgra[i * 4 + 0] == exactRgb[i * 3 + 2]);
        assert(exactBgra[i * 4 + 1] == exactRgb[i * 3 + 1]);
        assert(exactBgra[i * 4 + 2] == exactRgb[i * 3 + 0]);
        assert(exactBgra[i * 4 + 3] == 0xFF);
    }
    const std::array<unsigned, 4> greenProbe = {1, 2, 32, 63};
    for (unsigned g6 : greenProbe) {
        const uint16_t correct = packRgb565(0, expand6(g6), 0);
        const uint16_t shifted = badGreenShiftPack(0, expand6(g6), 0);
        uint8_t cr = 0, cg = 0, cb = 0, sr = 0, sg = 0, sb = 0;
        expandRgb565(correct, cr, cg, cb);
        expandRgb565(shifted, sr, sg, sb);
        assert(cg == expand6(g6));
        assert(sg != cg || sr != cr || sb != cb);
    }

    yuvToRgb(128, 128, 128, r, g, b);
    assert(r == 128 && g == 128 && b == 128);
    yuvToRgb(16, 128, 128, r, g, b);
    assert(r == 16 && g == 16 && b == 16);
    yuvToRgb(76, 85, 255, r, g, b);
    assert(r == 254 && g == 0 && b == 0);

    return 0;
}
