// Sanity checks for Phase 3 frame_store sizing / RGB565 packing.
#include "libmisterplex/ddr_frame_layout.hpp"
#include "libmisterplex/pixel_format.hpp"

#include <array>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <vector>

static int fails = 0;
#define CHECK(c)                                                                                 \
    do {                                                                                         \
        if (!(c)) {                                                                              \
            std::fprintf(stderr, "FAIL %s:%d %s\n", __FILE__, __LINE__, #c);                     \
            ++fails;                                                                             \
        }                                                                                        \
    } while (0)

static uint16_t rgb565(unsigned r, unsigned g, unsigned b) {
    return static_cast<uint16_t>(((r & 0xF8) << 8) | ((g & 0xFC) << 3) | (b >> 3));
}

static void checkLayout(int w, int h, size_t bytes, uint32_t stride, uint32_t doorbell,
                        int lineQwords,
                        misterplex::DdrFrameFormat fmt = misterplex::DdrFrameFormat::Rgb565,
                        int chromaLineQwords = 0) {
    const auto l = misterplex::makeDdrFrameLayout(w, h, 0x30000000u, 0x40000u, fmt);
    CHECK(misterplex::ddrFrameLayoutValid(l));
    CHECK(l.frame_bytes == bytes);
    CHECK(l.line_bytes == (fmt == misterplex::DdrFrameFormat::Rgb565 ? w * 2 : w));
    CHECK(l.line_qwords == lineQwords);
    CHECK(l.chroma_line_qwords == chromaLineQwords);
    CHECK(l.bank_stride == stride);
    CHECK(l.phys_base + l.bank_stride >= l.phys_base + l.frame_bytes);
    CHECK(l.phys_base + l.bank_stride + l.frame_bytes <= l.doorbell_phys);
    CHECK(l.doorbell_phys == doorbell);
    CHECK(l.map_bytes == l.bank_stride * 2u);
}

static void checkConversion(int w, int h) {
    const size_t pixels = static_cast<size_t>(w) * static_cast<size_t>(h);
    std::vector<uint8_t> rgb(pixels * 3);
    for (size_t i = 0; i < pixels; ++i) {
        rgb[i * 3 + 0] = static_cast<uint8_t>(i);
        rgb[i * 3 + 1] = static_cast<uint8_t>(i >> 3);
        rgb[i * 3 + 2] = static_cast<uint8_t>(255 - i);
    }
    std::vector<uint8_t> out(pixels * 2);
    misterplex::pixel::rgb24ToRgb565Le(rgb.data(), out.data(), pixels);
    const size_t probes[] = {0, pixels / 2, pixels - 1};
    for (size_t i : probes) {
        const uint16_t got = misterplex::pixel::loadLe16(out.data() + i * 2);
        const uint16_t want = misterplex::pixel::packRgb565(rgb[i * 3], rgb[i * 3 + 1],
                                                            rgb[i * 3 + 2]);
        CHECK(got == want);
    }
}

int main() {
    constexpr int W = 320, H = 240;
    constexpr int PIXELS = W * H;
    constexpr int BYTES = PIXELS * 2;
    CHECK(PIXELS == 76800);
    CHECK(BYTES == 153600);
    // Dual bank ~307200 bytes
    CHECK(BYTES * 2 == 307200);
    checkLayout(320, 240, 153600, 0x40000, 0x3007F000, 80);
    checkLayout(640, 480, 614400, 0xC0000, 0x3017F000, 160);
    checkLayout(640, 480, 460800, 0x80000, 0x300FF000, 80,
                misterplex::DdrFrameFormat::Yuv420p, 40);
    checkConversion(320, 240);
    checkConversion(640, 480);

    // LE pack as frame_ingest: lo then hi
    uint16_t p = rgb565(255, 0, 0); // red-ish
    uint8_t lo = static_cast<uint8_t>(p & 0xFF);
    uint8_t hi = static_cast<uint8_t>(p >> 8);
    uint16_t recon = static_cast<uint16_t>((hi << 8) | lo);
    CHECK(recon == p);

    // Expand back rough red dominance
    unsigned r8 = (p >> 11) << 3;
    CHECK(r8 >= 240);

    if (fails) {
        std::fprintf(stderr, "test_frame_store_math: %d fails\n", fails);
        return 1;
    }
    std::printf("test_frame_store_math: OK\n");
    return 0;
}
