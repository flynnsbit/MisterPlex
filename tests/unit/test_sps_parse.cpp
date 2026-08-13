// Unit: parse real Baseline SPS from ffmpeg annex-B (mirrors FPGA 3.3c).
#include "libmisterplex/ddr_frame_layout.hpp"
#include "libmisterplex/h264_sps.hpp"

#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <fstream>
#include <string>
#include <vector>

static int fails = 0;
#define CHECK(c)                                                                                 \
    do {                                                                                         \
        if (!(c)) {                                                                              \
            std::fprintf(stderr, "FAIL %s:%d %s\n", __FILE__, __LINE__, #c);                     \
            ++fails;                                                                             \
        }                                                                                        \
    } while (0)

static std::vector<uint8_t> readFile(const char* path) {
    std::ifstream in(path, std::ios::binary);
    if (!in)
        return {};
    return std::vector<uint8_t>((std::istreambuf_iterator<char>(in)), {});
}

struct Bits {
    std::vector<int> bits;

    void bit(int value) { bits.push_back(value ? 1 : 0); }
    void u(uint32_t value, int width) {
        for (int i = width - 1; i >= 0; --i)
            bit((value >> i) & 1u);
    }
    void ue(uint32_t value) {
        const uint32_t code = value + 1;
        int leading = 0;
        for (uint32_t t = code; t > 1; t >>= 1)
            ++leading;
        for (int i = 0; i < leading; ++i)
            bit(0);
        for (int i = leading; i >= 0; --i)
            bit((code >> i) & 1u);
    }
    std::vector<uint8_t> bytes() {
        bit(1);
        while ((bits.size() & 7u) != 0)
            bit(0);
        std::vector<uint8_t> out(bits.size() / 8u, 0);
        for (size_t i = 0; i < bits.size(); ++i)
            out[i / 8u] |= static_cast<uint8_t>(bits[i] << (7u - (i & 7u)));
        return out;
    }
};

static std::vector<uint8_t> makeBaselineSps(int widthMbs, int heightMapUnits,
                                            int cropRightUnits = 0) {
    Bits w;
    w.u(66, 8);
    w.u(0, 8);
    w.u(30, 8);
    w.ue(0); // sps id
    w.ue(3); // log2_max_frame_num_minus4
    w.ue(2); // POC type
    w.ue(1); // max refs
    w.bit(0);
    w.ue(static_cast<uint32_t>(widthMbs - 1));
    w.ue(static_cast<uint32_t>(heightMapUnits - 1));
    w.bit(1); // progressive
    w.bit(1); // direct_8x8
    w.bit(cropRightUnits != 0);
    if (cropRightUnits != 0) {
        w.ue(0);
        w.ue(static_cast<uint32_t>(cropRightUnits));
        w.ue(0);
        w.ue(0);
    }
    return w.bytes();
}

static misterplex::SpsInfo parseSynthetic(int widthMbs, int heightMapUnits,
                                         int cropRightUnits = 0) {
    const auto rbsp = makeBaselineSps(widthMbs, heightMapUnits, cropRightUnits);
    return misterplex::parseSpsRbsp(rbsp.data(), rbsp.size());
}

static void checkContractGeometry() {
    const auto expected = misterplex::plex480pDdrFrameGeometry();
    const auto good = parseSynthetic(39, 30, 3);
    CHECK(good.valid);
    CHECK(good.coded_width == 624 && good.coded_height == 480);
    CHECK(good.display_width == 618 && good.display_height == 480);
    CHECK(good.width == good.display_width && good.height == good.display_height);
    CHECK(good.crop_unit_x == 2 && good.crop_unit_y == 2);
    CHECK(good.crop_right_units == 3);
    CHECK(good.crop_right_pixels == 6);
    CHECK(misterplex::ddrFrameGeometryMatchesDelivered(
        expected, good.coded_width, good.coded_height, good.display_width, good.display_height,
        good.crop_left_pixels, good.crop_right_pixels, good.crop_top_pixels,
        good.crop_bottom_pixels));

    const auto coded640 = parseSynthetic(40, 30, 11);
    CHECK(coded640.valid);
    CHECK(coded640.coded_width == 640 && coded640.display_width == 618);
    CHECK(!misterplex::ddrFrameGeometryMatchesDelivered(
        expected, coded640.coded_width, coded640.coded_height, coded640.display_width,
        coded640.display_height, coded640.crop_left_pixels, coded640.crop_right_pixels,
        coded640.crop_top_pixels, coded640.crop_bottom_pixels));

    const auto pillar10 = parseSynthetic(39, 30, 2);
    CHECK(pillar10.valid && pillar10.display_width == 620);
    CHECK(!misterplex::ddrFrameGeometryMatchesDelivered(
        expected, pillar10.coded_width, pillar10.coded_height, pillar10.display_width,
        pillar10.display_height, pillar10.crop_left_pixels, pillar10.crop_right_pixels,
        pillar10.crop_top_pixels, pillar10.crop_bottom_pixels));

    const auto pillar12 = parseSynthetic(39, 30, 4);
    CHECK(pillar12.valid && pillar12.display_width == 616);
    CHECK(!misterplex::ddrFrameGeometryMatchesDelivered(
        expected, pillar12.coded_width, pillar12.coded_height, pillar12.display_width,
        pillar12.display_height, pillar12.crop_left_pixels, pillar12.crop_right_pixels,
        pillar12.crop_top_pixels, pillar12.crop_bottom_pixels));

    const auto shortFrame = parseSynthetic(39, 29, 3);
    CHECK(shortFrame.valid && shortFrame.coded_height == 464);
    CHECK(!misterplex::ddrFrameGeometryMatchesDelivered(
        expected, shortFrame.coded_width, shortFrame.coded_height, shortFrame.display_width,
        shortFrame.display_height, shortFrame.crop_left_pixels, shortFrame.crop_right_pixels,
        shortFrame.crop_top_pixels, shortFrame.crop_bottom_pixels));
}

int main(int argc, char** argv) {
    checkContractGeometry();

    const char* path = argc > 1 ? argv[1] : "build/plex_real_baseline.264";
    auto blob = readFile(path);
    if (blob.empty()) {
        const std::string cmd = std::string("python3 ") +
                                (argc > 2 ? argv[2] : "scripts/gen_test_annexb_real.py") + " " +
                                path;
        CHECK(std::system(cmd.c_str()) == 0);
        blob = readFile(path);
    }
    CHECK(!blob.empty());
    if (!blob.empty()) {
        const auto s = misterplex::parseFirstSpsAnnexB(blob.data(), blob.size());
        CHECK(s.valid);
        CHECK(s.coded_width == 320 && s.coded_height == 240);
        CHECK(s.display_width == 320 && s.display_height == 240);
        CHECK(s.profile_idc == 66);
    }

    if (fails) {
        std::fprintf(stderr, "test_sps_parse: %d fails\n", fails);
        return 1;
    }
    std::printf("test_sps_parse: OK coded=624x480 display=618x480 crop_right=6px; "
                "coded640/pillar10/pillar12/height464 rejected\n");
    return 0;
}
