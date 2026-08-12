// Sanity checks for the C3 YUV420 DDR frame-store sizing / ABI.
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
                        misterplex::DdrFrameFormat fmt = misterplex::DdrFrameFormat::Yuv420p,
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
    CHECK(l.line_bytes == g.coded_width);
    CHECK(l.line_qwords == lineQwords);
    CHECK(l.chroma_line_qwords == chromaLineQwords);
    CHECK(l.y_offset == 0);
    CHECK(l.u_offset == static_cast<uint32_t>(g.coded_width * g.coded_height));
    CHECK(l.v_offset == static_cast<uint32_t>(g.coded_width * g.coded_height +
                                              (g.coded_width / 2) * (g.coded_height / 2)));
    CHECK(l.bank_stride == stride);
    CHECK(l.phys_base + l.bank_stride >= l.phys_base + l.frame_bytes);
    CHECK(l.phys_base + l.bank_stride + l.frame_bytes <= l.doorbell_phys);
    CHECK(l.doorbell_phys == doorbell);
    CHECK(l.map_bytes == l.bank_stride * 2u);
    CHECK(l.doorbell_format == misterplex::ddrFrameFormatCode(fmt));
}

static void checkLayout(int w, int h, size_t bytes, uint32_t stride, uint32_t doorbell,
                        int lineQwords,
                        misterplex::DdrFrameFormat fmt = misterplex::DdrFrameFormat::Yuv420p,
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

static void checkTrue480CoordinateMap(const misterplex::DdrFrameGeometry& g,
                                      const misterplex::DdrFrameLayout& l) {
    uint64_t checked = 0;
    uint64_t content = 0;
    uint64_t border = 0;
    uint64_t mapMismatches = 0;
    uint64_t sampleMismatches = 0;
    std::array<int, misterplex::kPlex480pPresentedHeight> sourceRowHits{};
    for (int y = 0; y < misterplex::kPlex480pPresentedHeight; ++y) {
        for (int x = 0; x < misterplex::kPlex480pPresentedWidth; ++x) {
            const bool wantContent =
                x >= misterplex::kPlex480pPillarboxLeft &&
                x < misterplex::kPlex480pPillarboxLeft + misterplex::kPlex480pDisplayWidth;
            const auto map = misterplex::mapDdrFramePresentedPixel(g, x, y);
            if (wantContent) {
                ++content;
                const int wantX = x - misterplex::kPlex480pPillarboxLeft;
                if (map.region != misterplex::DdrFramePixelRegion::Content ||
                    map.coded_x != wantX || map.coded_y != y) {
                    ++mapMismatches;
                } else {
                    ++sourceRowHits[static_cast<size_t>(map.coded_y)];
                }
                const auto sample = misterplex::ddrFramePresentedSampleOffsets(l, x, y);
                const uint32_t wantY =
                    static_cast<uint32_t>(y * misterplex::kPlex480pYStrideBytes + wantX);
                const uint32_t chromaIndex =
                    static_cast<uint32_t>((y / 2) * misterplex::kPlex480pChromaStrideBytes +
                                          (wantX / 2));
                if (!sample.valid || sample.y != wantY ||
                    sample.u != misterplex::kPlex480pUPlaneOffset + chromaIndex ||
                    sample.v != misterplex::kPlex480pVPlaneOffset + chromaIndex)
                    ++sampleMismatches;
            } else {
                ++border;
                if (map.region != misterplex::DdrFramePixelRegion::Border || map.coded_x != -1 ||
                    map.coded_y != -1 ||
                    misterplex::ddrFramePresentedSampleOffsets(l, x, y).valid)
                    ++mapMismatches;
            }
            ++checked;
        }
    }
    CHECK(checked == 640u * 480u);
    CHECK(content == 618u * 480u);
    CHECK(border == 22u * 480u);
    CHECK(mapMismatches == 0);
    CHECK(sampleMismatches == 0);
    for (int y = 0; y < misterplex::kPlex480pPresentedHeight; ++y)
        CHECK(sourceRowHits[static_cast<size_t>(y)] == misterplex::kPlex480pDisplayWidth);

    const auto first = misterplex::mapDdrFramePresentedPixel(g, 11, 0);
    const auto last = misterplex::mapDdrFramePresentedPixel(g, 628, 479);
    CHECK(first.region == misterplex::DdrFramePixelRegion::Content);
    CHECK(first.coded_x == 0 && first.coded_y == 0);
    CHECK(last.region == misterplex::DdrFramePixelRegion::Content);
    CHECK(last.coded_x == 617 && last.coded_y == 479);
    CHECK(misterplex::mapDdrFramePresentedPixel(g, 10, 0).region ==
          misterplex::DdrFramePixelRegion::Border);
    CHECK(misterplex::mapDdrFramePresentedPixel(g, 629, 479).region ==
          misterplex::DdrFramePixelRegion::Border);
    CHECK(misterplex::mapDdrFramePresentedPixel(g, 640, 479).region ==
          misterplex::DdrFramePixelRegion::Outside);
    CHECK(misterplex::mapDdrFramePresentedPixel(g, 11, 480).region ==
          misterplex::DdrFramePixelRegion::Outside);

    const auto lastSample = misterplex::ddrFramePresentedSampleOffsets(l, 628, 479);
    CHECK(lastSample.valid);
    CHECK(lastSample.y == 299513u);
    CHECK(lastSample.u == 374396u);
    CHECK(lastSample.v == 449276u);
    CHECK(lastSample.y + 6u == misterplex::kPlex480pUPlaneOffset - 1u);
    CHECK(lastSample.u + 3u == misterplex::kPlex480pVPlaneOffset - 1u);
    CHECK(lastSample.v + 3u == misterplex::kPlex480pYuv420pBytes - 1u);

    uint64_t legacyEvenRowMismatches = 0;
    for (int y = 0; y < misterplex::kPlex480pPresentedHeight; ++y) {
        const int legacyY = (y >> 1) << 1;
        if (legacyY != y)
            ++legacyEvenRowMismatches;
    }
    CHECK(legacyEvenRowMismatches == 240);
    CHECK(((479 >> 1) << 1) == 478);
}

int main() {
    constexpr int W = 320, H = 240;
    constexpr int PIXELS = W * H;
    constexpr int BYTES = PIXELS * 3 / 2;
    CHECK(PIXELS == 76800);
    CHECK(BYTES == 115200);
    checkLayout(320, 240, 115200, 0x40000, 0x3007F000, 40,
                misterplex::DdrFrameFormat::Yuv420p, 20);
    const auto coded640 = misterplex::makeDdrFrameGeometry(640, 480);
    checkLayout(coded640, 460800, 0x80000, 0x300FF000, 80,
                misterplex::DdrFrameFormat::Yuv420p, 40);
    const auto p480 = misterplex::plex480pDdrFrameGeometry();
    CHECK(p480.coded_width == 624);
    CHECK(p480.display_width == 618);
    CHECK(p480.presented_width == 640);
    CHECK(p480.crop_right == 6);
    CHECK(p480.present_x == 11);
    CHECK(p480.placement == misterplex::DdrFramePlacement::Pillarbox);
    CHECK(misterplex::isPlex480pDdrFrameGeometry(p480));
    auto almostP480 = p480;
    almostP480.present_x += 1;
    CHECK(!misterplex::isPlex480pDdrFrameGeometry(almostP480));
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
    CHECK(yuv480.phys_base == 0x30000000u);
    CHECK(yuv480.phys_base + yuv480.bank_stride == 0x30080000u);
    CHECK(yuv480.phys_base + yuv480.frame_bytes == 0x3006DB00u);
    CHECK(yuv480.phys_base + yuv480.bank_stride + yuv480.frame_bytes == 0x300EDB00u);
    CHECK(yuv480.doorbell_phys == 0x300FF000u);
    CHECK(yuv480.phys_base + yuv480.map_bytes == 0x30100000u);
    CHECK(yuv480.doorbell_phys + 0x1000u == yuv480.phys_base + yuv480.map_bytes);
    CHECK(misterplex::ddrFrameGeometryMatchesDelivered(p480, 624, 480, 618, 480, 0, 6,
                                                       0, 0));
    CHECK(!misterplex::ddrFrameGeometryMatchesDelivered(p480, 640, 480, 618, 480, 0, 22,
                                                        0, 0));
    CHECK(!misterplex::ddrFrameGeometryMatchesDelivered(p480, 624, 480, 620, 480, 0, 4,
                                                        0, 0));
    CHECK(!misterplex::ddrFrameGeometryMatchesDelivered(p480, 624, 480, 616, 480, 0, 8,
                                                        0, 0));
    CHECK(!misterplex::ddrFrameGeometryMatchesDelivered(p480, 624, 464, 618, 464, 0, 6,
                                                        0, 0));
    CHECK(!misterplex::ddrFrameGeometryMatchesDelivered(p480, coded640.coded_width,
                                                        coded640.coded_height,
                                                        coded640.display_width,
                                                        coded640.display_height, 0, 0, 0, 0));
    checkTrue480CoordinateMap(p480, yuv480);

    auto drift = yuv480;
    drift.u_offset += 8;
    CHECK(!misterplex::ddrFrameLayoutValid(drift));
    drift = yuv480;
    drift.v_offset -= 8;
    CHECK(!misterplex::ddrFrameLayoutValid(drift));
    drift = yuv480;
    drift.line_bytes = 640;
    CHECK(!misterplex::ddrFrameLayoutValid(drift));
    drift = yuv480;
    drift.chroma_line_bytes = 320;
    CHECK(!misterplex::ddrFrameLayoutValid(drift));
    drift = yuv480;
    drift.bank_stride += 0x40000u;
    CHECK(!misterplex::ddrFrameLayoutValid(drift));
    drift = yuv480;
    drift.doorbell_phys -= 0x1000u;
    CHECK(!misterplex::ddrFrameLayoutValid(drift));

    auto badGeometry = p480;
    badGeometry.present_x = 10;
    CHECK(misterplex::ddrFrameGeometryValid(badGeometry));
    CHECK(misterplex::mapDdrFramePresentedPixel(badGeometry, 10, 0).region ==
          misterplex::DdrFramePixelRegion::Content);
    CHECK(misterplex::mapDdrFramePresentedPixel(p480, 10, 0).region ==
          misterplex::DdrFramePixelRegion::Border);
    badGeometry = p480;
    badGeometry.present_x = 12;
    CHECK(misterplex::ddrFrameGeometryValid(badGeometry));
    CHECK(misterplex::mapDdrFramePresentedPixel(badGeometry, 11, 0).region ==
          misterplex::DdrFramePixelRegion::Border);
    badGeometry = p480;
    badGeometry.crop_right = -1;
    CHECK(!misterplex::ddrFrameGeometryValid(badGeometry));
    CHECK(misterplex::kYuv420BlackY == 16);
    CHECK(misterplex::kYuv420BlackU == 128);
    CHECK(misterplex::kYuv420BlackV == 128);
    CHECK(misterplex::ddrFrameFormatCode(misterplex::DdrFrameFormat::Yuv420p) == 1);
    CHECK(misterplex::ddrDoorbellHi(0x1234, 0, misterplex::DdrFrameFormat::Yuv420p) ==
          0x20001234u);
    CHECK(misterplex::ddrDoorbellHi(0x1234, 1, misterplex::DdrFrameFormat::Yuv420p) ==
          0xA0001234u);
    CHECK(misterplex::ddrDoorbellHi(0x3FFFFFFFu, 1, misterplex::DdrFrameFormat::Yuv420p) ==
          0xBFFFFFFFu);
    uint32_t decodedSeq = 0;
    int decodedBank = -1;
    CHECK(misterplex::decodeDdrDoorbell(misterplex::kDdrFrameDoorbellMagic, 0xA0000005u,
                                        misterplex::DdrFrameFormat::Yuv420p, decodedSeq,
                                        decodedBank));
    CHECK(decodedSeq == 5u);
    CHECK(decodedBank == 1);
    CHECK(misterplex::ddrDoorbellHi((decodedSeq + 1u) & misterplex::kDdrFrameDoorbellSeqMask,
                                    decodedBank, misterplex::DdrFrameFormat::Yuv420p) !=
          0xA0000005u);
    CHECK(!misterplex::decodeDdrDoorbell(0, 0xA0000005u,
                                         misterplex::DdrFrameFormat::Yuv420p, decodedSeq,
                                         decodedBank));

    // Hardware nondeterminism bbox from reload captures. Presentation x includes
    // the 11px pillarbox, so map it back to coded 624-wide YUV420 offsets.
    constexpr int kBboxX0 = 192, kBboxX1 = 360, kBboxY0 = 37, kBboxY1 = 325;
    constexpr int kSrcX0 = kBboxX0 - misterplex::kPlex480pPillarboxLeft;
    constexpr int kSrcX1 = kBboxX1 - misterplex::kPlex480pPillarboxLeft;
    CHECK(kSrcX0 == 181);
    CHECK(kSrcX1 == 349);
    CHECK(kSrcX0 / 8 == 22);
    CHECK(kSrcX1 / 8 == 43);
    CHECK(kSrcX0 / 16 == 11);
    CHECK(kSrcX1 / 16 == 21);
    CHECK(kBboxY0 * misterplex::kPlex480pYStrideBytes + kSrcX0 == 23269);
    CHECK(kBboxY1 * misterplex::kPlex480pYStrideBytes + kSrcX1 == 203149);
    CHECK(misterplex::kPlex480pUPlaneOffset + (kBboxY0 / 2) *
              misterplex::kPlex480pChromaStrideBytes + (kSrcX0 / 2) ==
          305226u);
    CHECK(misterplex::kPlex480pVPlaneOffset + (kBboxY1 / 2) *
              misterplex::kPlex480pChromaStrideBytes + (kSrcX1 / 2) ==
          425118u);
    CHECK((kSrcX0 / 8) / misterplex::kPlex480pYuvLumaLineQwords == 0);
    CHECK((kSrcX1 / 8) / misterplex::kPlex480pYuvLumaLineQwords == 0);
    CHECK((kSrcX0 / 16) / misterplex::kPlex480pYuvChromaLineQwords == 0);
    CHECK((kSrcX1 / 16) / misterplex::kPlex480pYuvChromaLineQwords == 0);
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
