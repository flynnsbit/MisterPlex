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

static void checkLayout(const misterplex::DdrFrameGeometry& g, size_t bytes, uint32_t stride,
                        uint32_t doorbell, int lineQwords,
                        misterplex::DdrFrameFormat fmt = misterplex::DdrFrameFormat::Rgb565,
                        int chromaLineQwords = 0) {
    const auto l = misterplex::makeDdrFrameLayout(g, 0x30000000u, 0x40000u, fmt);
    CHECK(misterplex::ddrFrameLayoutValid(l));
    CHECK(l.frame_bytes == bytes);
    CHECK(l.width == g.coded_width);
    CHECK(l.height == g.coded_height);
    CHECK(l.coded_width == g.coded_width);
    CHECK(l.display_width == g.display_width);
    CHECK(l.presented_width == g.presented_width);
    CHECK(l.crop_right == g.crop_right);
    CHECK(l.present_x == g.present_x);
    CHECK(l.line_bytes ==
          (fmt == misterplex::DdrFrameFormat::Rgb565 ? g.coded_width * 2 : g.coded_width));
    CHECK(l.line_qwords == lineQwords);
    CHECK(l.chroma_line_qwords == chromaLineQwords);
    CHECK(l.y_offset == 0);
    if (fmt == misterplex::DdrFrameFormat::Yuv420p) {
        CHECK(l.u_offset == static_cast<uint32_t>(g.coded_width * g.coded_height));
        CHECK(l.v_offset == static_cast<uint32_t>(g.coded_width * g.coded_height +
                                                  (g.coded_width / 2) * (g.coded_height / 2)));
    } else {
        CHECK(l.u_offset == 0);
        CHECK(l.v_offset == 0);
    }
    CHECK(l.bank_stride == stride);
    CHECK(l.phys_base + l.bank_stride >= l.phys_base + l.frame_bytes);
    CHECK(l.phys_base + l.bank_stride + l.frame_bytes <= l.doorbell_phys);
    CHECK(l.doorbell_phys == doorbell);
    CHECK(l.map_bytes == l.bank_stride * 2u);
    CHECK(l.doorbell_format == misterplex::ddrFrameFormatCode(fmt));
}

static void checkLayout(int w, int h, size_t bytes, uint32_t stride, uint32_t doorbell,
                        int lineQwords,
                        misterplex::DdrFrameFormat fmt = misterplex::DdrFrameFormat::Rgb565,
                        int chromaLineQwords = 0) {
    checkLayout(misterplex::makeDdrFrameGeometry(w, h), bytes, stride, doorbell, lineQwords, fmt,
                chromaLineQwords);
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
    const auto p480 = misterplex::plex480pDdrFrameGeometry();
    CHECK(p480.coded_width == 624);
    CHECK(p480.display_width == 618);
    CHECK(p480.presented_width == 640);
    CHECK(p480.crop_right == 6);
    CHECK(p480.present_x == 11);
    CHECK(p480.placement == misterplex::DdrFramePlacement::Pillarbox);
    checkLayout(p480, 599040, 0xC0000, 0x3017F000, 156);
    checkLayout(p480, 449280, 0x80000, 0x300FF000, 78,
                misterplex::DdrFrameFormat::Yuv420p, 39);
    const auto yuv480 =
        misterplex::makeDdrFrameLayout(p480, 0x30000000u, 0x40000u,
                                       misterplex::DdrFrameFormat::Yuv420p);
    CHECK(yuv480.y_offset == misterplex::kPlex480pYPlaneOffset);
    CHECK(yuv480.u_offset == misterplex::kPlex480pUPlaneOffset);
    CHECK(yuv480.v_offset == misterplex::kPlex480pVPlaneOffset);
    CHECK(yuv480.line_bytes == misterplex::kPlex480pYStrideBytes);
    CHECK(yuv480.chroma_line_bytes == misterplex::kPlex480pChromaStrideBytes);
    CHECK(misterplex::kYuv420BlackY == 16);
    CHECK(misterplex::kYuv420BlackU == 128);
    CHECK(misterplex::kYuv420BlackV == 128);
    CHECK(misterplex::ddrFrameFormatCode(misterplex::DdrFrameFormat::Rgb565) == 0);
    CHECK(misterplex::ddrFrameFormatCode(misterplex::DdrFrameFormat::Yuv420p) == 1);
    CHECK(misterplex::ddrDoorbellHi(0x1234, 0, misterplex::DdrFrameFormat::Rgb565) == 0x1234u);
    CHECK(misterplex::ddrDoorbellHi(0x1234, 1, misterplex::DdrFrameFormat::Rgb565) ==
          0x80001234u);
    CHECK(misterplex::ddrDoorbellHi(0x1234, 0, misterplex::DdrFrameFormat::Yuv420p) ==
          0x20001234u);
    CHECK(misterplex::ddrDoorbellHi(0x1234, 1, misterplex::DdrFrameFormat::Yuv420p) ==
          0xA0001234u);
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
