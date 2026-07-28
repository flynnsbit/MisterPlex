// Sanity checks for the C3 YUV420 DDR frame-store sizing / ABI.
#include "libmisterplex/ddr_frame_layout.hpp"
#include "libmisterplex/ddr_present_bank.hpp"
#include "libmisterplex/pixel_format.hpp"

#include <array>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
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

static uint16_t rgb565(unsigned r, unsigned g, unsigned b) {
    return static_cast<uint16_t>(((r & 0xF8) << 8) | ((g & 0xFC) << 3) | (b >> 3));
}

static void checkLayout(const misterplex::DdrFrameGeometry& g, size_t bytes, int lineQwords,
                        misterplex::DdrFrameFormat fmt = misterplex::DdrFrameFormat::Yuv420p,
                        int chromaLineQwords = 0) {
    constexpr uint32_t physBase = 0x30000000u;
    constexpr uint32_t strideAlign = 0x40000u;
    const auto l = misterplex::makeDdrFrameLayout(g, physBase, strideAlign, fmt);
    const uint32_t derivedStride =
        misterplex::alignUpU32(static_cast<uint32_t>(bytes), strideAlign);
    const uint32_t derivedDoorbell = physBase + derivedStride * 2u - 0x1000u;
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
    CHECK(l.bank_stride == derivedStride);
    CHECK(l.phys_base + l.bank_stride >= l.phys_base + l.frame_bytes);
    CHECK(l.phys_base + l.bank_stride + l.frame_bytes <= l.doorbell_phys);
    CHECK(l.doorbell_phys == derivedDoorbell);
    CHECK(l.map_bytes == l.bank_stride * 2u);
    CHECK(l.doorbell_format == misterplex::ddrFrameFormatCode(fmt));
}

static void checkLayout(int w, int h, size_t bytes, int lineQwords,
                        misterplex::DdrFrameFormat fmt = misterplex::DdrFrameFormat::Yuv420p,
                        int chromaLineQwords = 0) {
    checkLayout(misterplex::makeDdrFrameGeometry(w, h), bytes, lineQwords, fmt, chromaLineQwords);
}

static std::string seqString(const std::vector<int>& seq) {
    std::string out;
    for (size_t i = 0; i < seq.size(); ++i) {
        if (i)
            out += ",";
        out += std::to_string(seq[i]);
    }
    return out;
}

static void checkDdrBankConsumerEncoding() {
    const std::vector<int> wantSent{0, 1, 1, 0};
    const std::vector<bool> sendOk{true, false, true, true};
    std::vector<int> sawDoorbell;
    std::vector<int> sawSpi;
    uint8_t raw[16]{};
    raw[0] = 0xFF;
    raw[1] = 0xFF;
    int bank = 0;
    for (size_t i = 0; i < sendOk.size(); ++i) {
        const uint32_t hi =
            misterplex::ddrDoorbellHi(static_cast<uint32_t>(i + 1), bank,
                                      misterplex::DdrFrameFormat::Yuv420p);
        uint32_t decodedSeq = 0;
        int decodedBank = -1;
        CHECK((hi & 0x80000000u) == (bank ? 0x80000000u : 0u));
        CHECK(misterplex::decodeDdrDoorbell(misterplex::kDdrFrameDoorbellMagic, hi,
                                            misterplex::DdrFrameFormat::Yuv420p, decodedSeq,
                                            decodedBank));
        sawDoorbell.push_back(decodedBank);

        uint8_t idle[16]{};
        uint8_t pulse[16]{};
        misterplex::encodeDdrSpiKickStatusWord(raw, bank, false, idle);
        misterplex::encodeDdrSpiKickStatusWord(idle, bank, true, pulse);
        CHECK((idle[1] & misterplex::kDdrSpiStartBitHi) == 0);
        CHECK((pulse[1] & misterplex::kDdrSpiStartBitHi) != 0);
        CHECK((pulse[1] & misterplex::kDdrSpiBankBitHi) ==
              (bank ? misterplex::kDdrSpiBankBitHi : 0));
        CHECK((pulse[0] & misterplex::kDdrSpiResetBitLo) == 0);
        CHECK((pulse[1] & misterplex::kDdrSpiFlushBitHi) == 0);
        sawSpi.push_back((pulse[1] & misterplex::kDdrSpiBankBitHi) ? 1 : 0);

        bank = misterplex::nextDdrPresentBank(bank, sendOk[i]);
    }
    if (sawDoorbell != wantSent) {
        std::fprintf(stderr, "DDR bank alternation failed for doorbell: saw %s; expected %s\n",
                     seqString(sawDoorbell).c_str(), seqString(wantSent).c_str());
        ++fails;
    }
    if (sawSpi != wantSent) {
        std::fprintf(stderr, "DDR bank alternation failed for SPI status[13]: saw %s; expected %s\n",
                     seqString(sawSpi).c_str(), seqString(wantSent).c_str());
        ++fails;
    }
}

static void checkDdrPublishGeometrySwitch() {
    const auto g320 = misterplex::makeDdrFrameGeometry(320, 240);
    std::vector<uint8_t> yuv320(misterplex::yuv420pFrameBytes(320, 240), 0x10);
    misterplex::DdrPublishFrame f320{yuv320.data(), yuv320.size(), g320,
                                     misterplex::DdrFrameFormat::Yuv420p};
    misterplex::DdrPublishPlan p320{};
    std::string err;
    if (!misterplex::makeDdrPublishPlan(f320, 1, p320, &err)) {
        std::fprintf(stderr, "DDR publish geometry failed for 320x240: %s\n", err.c_str());
        ++fails;
    } else {
        if (p320.layout.bank_stride != 0x40000u || p320.bank_offset != 0x40000u ||
            p320.bank_phys != 0x30040000u || p320.layout.doorbell_phys != 0x3007F000u) {
            std::fprintf(stderr,
                         "DDR publish geometry failed for 320x240: stride=0x%05x "
                         "bank1=0x%08x doorbell=0x%08x, expected 0x40000/0x30040000/"
                         "0x3007F000\n",
                         static_cast<unsigned>(p320.layout.bank_stride),
                         static_cast<unsigned>(p320.bank_phys),
                         static_cast<unsigned>(p320.layout.doorbell_phys));
            ++fails;
        }
    }

    const auto g480 = misterplex::plex480pDdrFrameGeometry();
    std::vector<uint8_t> yuv480(misterplex::yuv420pFrameBytes(g480.coded_width, g480.coded_height),
                                0x10);
    misterplex::DdrPublishFrame f480{yuv480.data(), yuv480.size(), g480,
                                     misterplex::DdrFrameFormat::Yuv420p};
    misterplex::DdrPublishPlan p480{};
    if (!misterplex::makeDdrPublishPlan(f480, 1, p480, &err)) {
        std::fprintf(stderr, "DDR publish geometry failed for 624x480: %s\n", err.c_str());
        ++fails;
    } else {
        if (p480.layout.bank_stride != 0x80000u || p480.bank_offset != 0x80000u ||
            p480.bank_phys != 0x30080000u || p480.layout.doorbell_phys != 0x300FF000u) {
            std::fprintf(stderr,
                         "DDR publish geometry failed for 624x480: stride=0x%05x "
                         "bank1=0x%08x doorbell=0x%08x, expected 0x80000/0x30080000/"
                         "0x300FF000\n",
                         static_cast<unsigned>(p480.layout.bank_stride),
                         static_cast<unsigned>(p480.bank_phys),
                         static_cast<unsigned>(p480.layout.doorbell_phys));
            ++fails;
        }
        if (p320.bank_phys == p480.bank_phys) {
            std::fprintf(stderr,
                         "DDR publish geometry failed: 320x240 and 624x480 bank1 both "
                         "resolved to 0x%08x; geometry was not carried into publish\n",
                         static_cast<unsigned>(p480.bank_phys));
            ++fails;
        }
    }

    misterplex::DdrPublishFrame badLen{yuv320.data(), yuv320.size(), g480,
                                       misterplex::DdrFrameFormat::Yuv420p};
    if (misterplex::makeDdrPublishPlan(badLen, 0, p480, &err)) {
        std::fprintf(stderr,
                     "DDR publish geometry failed: accepted a 320x240 payload with "
                     "624x480 geometry\n");
        ++fails;
    }
}

static void checkDdrPublishAlternationSequence() {
    const auto g320 = misterplex::makeDdrFrameGeometry(320, 240);
    const auto g480 = misterplex::plex480pDdrFrameGeometry();
    std::vector<uint8_t> yuv320(misterplex::yuv420pFrameBytes(320, 240), 0x10);
    std::vector<uint8_t> yuv480(misterplex::yuv420pFrameBytes(g480.coded_width, g480.coded_height),
                                0x10);
    const std::vector<misterplex::DdrPublishFrame> frames{
        {yuv320.data(), yuv320.size(), g320, misterplex::DdrFrameFormat::Yuv420p},
        {yuv480.data(), yuv480.size(), g480, misterplex::DdrFrameFormat::Yuv420p},
        {yuv320.data(), yuv320.size(), g320, misterplex::DdrFrameFormat::Yuv420p},
        {yuv480.data(), yuv480.size(), g480, misterplex::DdrFrameFormat::Yuv420p},
    };
    const std::vector<bool> sendOk{true, true, false, true};
    const std::vector<int> wantBanks{0, 1, 0, 0};
    const std::vector<uint32_t> wantOffsets{0x00000u, 0x80000u, 0x00000u, 0x00000u};
    std::vector<int> sawBanks;
    std::vector<uint32_t> sawOffsets;
    int bank = 0;
    std::string err;
    for (size_t i = 0; i < frames.size(); ++i) {
        misterplex::DdrPublishPlan plan{};
        if (!misterplex::makeDdrPublishPlan(frames[i], bank, plan, &err)) {
            std::fprintf(stderr, "DDR publish alternation failed at step %zu: %s\n", i,
                         err.c_str());
            ++fails;
            return;
        }
        sawBanks.push_back(plan.bank);
        sawOffsets.push_back(static_cast<uint32_t>(plan.bank_offset));
        bank = misterplex::nextDdrPresentBank(bank, sendOk[i]);
    }
    if (sawBanks != wantBanks) {
        std::fprintf(stderr, "DDR publish alternation failed: saw banks %s; expected %s\n",
                     seqString(sawBanks).c_str(), seqString(wantBanks).c_str());
        ++fails;
    }
    if (sawOffsets != wantOffsets) {
        std::fprintf(stderr,
                     "DDR publish alternation failed: offsets were 0x%05x,0x%05x,0x%05x,"
                     "0x%05x; expected 0x00000,0x80000,0x00000,0x00000\n",
                     static_cast<unsigned>(sawOffsets[0]),
                     static_cast<unsigned>(sawOffsets[1]),
                     static_cast<unsigned>(sawOffsets[2]),
                     static_cast<unsigned>(sawOffsets[3]));
        ++fails;
    }
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
    constexpr int BYTES = PIXELS * 3 / 2;
    CHECK(PIXELS == 76800);
    CHECK(BYTES == 115200);
    checkLayout(320, 240, 115200, 40, misterplex::DdrFrameFormat::Yuv420p, 20);
    checkLayout(640, 480, 460800, 80, misterplex::DdrFrameFormat::Yuv420p, 40);
    const auto p480 = misterplex::plex480pDdrFrameGeometry();
    CHECK(p480.coded_width == 624);
    CHECK(p480.display_width == 618);
    CHECK(p480.presented_width == 640);
    CHECK(p480.crop_right == 6);
    CHECK(p480.present_x == 11);
    CHECK(p480.placement == misterplex::DdrFramePlacement::Pillarbox);
    checkLayout(p480, 449280, 78, misterplex::DdrFrameFormat::Yuv420p, 39);
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
    checkDdrBankConsumerEncoding();
    checkDdrPublishGeometrySwitch();
    checkDdrPublishAlternationSequence();

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
