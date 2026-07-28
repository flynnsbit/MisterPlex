#include "libmisterplex/last_frame_latch.hpp"

#include <cstdint>
#include <cstdio>
#include <vector>

static int fails = 0;
#define CHECK(cond)                                                                              \
    do {                                                                                         \
        if (!(cond)) {                                                                           \
            std::fprintf(stderr, "FAIL %s:%d: %s\n", __FILE__, __LINE__, #cond);                 \
            ++fails;                                                                             \
        }                                                                                        \
    } while (0)

int main() {
    using namespace misterplex;

    LastFrameLatch latch;
    CHECK(!latch.haveFrame());

    const DdrFrameGeometry playbackGeometry = makeDdrFrameGeometry(320, 240);
    const DdrFrameLayout playbackLayout =
        makeDdrFrameLayout(playbackGeometry, kDdrFramePhysBase, kDdrFrameStrideAlign,
                           DdrFrameFormat::Yuv420p);
    CHECK(playbackLayout.frame_bytes == 115200);
    CHECK(playbackLayout.bank_stride == 0x40000u);
    CHECK(playbackLayout.doorbell_phys == 0x3007F000u);

    std::vector<uint8_t> frame(playbackLayout.frame_bytes);
    for (size_t i = 0; i < frame.size(); ++i)
        frame[i] = static_cast<uint8_t>((i * 17u + 3u) & 0xFFu);

    latch.remember(frame.data(), frame.size(), playbackGeometry);
    CHECK(latch.haveFrame());
    CHECK(latch.frame() == frame);
    CHECK(latch.geometry().coded_width == 320);
    CHECK(latch.geometry().coded_height == 240);

    struct Send {
        int bank = -1;
        DdrFrameGeometry geometry{};
        size_t len = 0;
        const uint8_t* data = nullptr;
    };
    std::vector<Send> sends;
    int nextBank = 1;
    const bool ok = latch.publishToBothBanks(
        [&](const uint8_t* data, size_t len, const DdrFrameGeometry& geometry, int bank) {
            sends.push_back({bank, geometry, len, data});
            return true;
        },
        nextBank);

    CHECK(ok);
    CHECK(sends.size() == 2);
    CHECK(nextBank == 1);
    if (sends.size() == 2) {
        CHECK(sends[0].bank == 1);
        CHECK(sends[1].bank == 0);
        for (const auto& s : sends) {
            CHECK(s.data == latch.frame().data());
            CHECK(s.len == playbackLayout.frame_bytes);
            CHECK(s.geometry.coded_width == playbackGeometry.coded_width);
            CHECK(s.geometry.coded_height == playbackGeometry.coded_height);
            const DdrFrameLayout sentLayout =
                makeDdrFrameLayout(s.geometry, kDdrFramePhysBase, kDdrFrameStrideAlign,
                                   DdrFrameFormat::Yuv420p);
            CHECK(sentLayout.bank_stride == 0x40000u);
            CHECK(sentLayout.doorbell_phys == 0x3007F000u);
        }
    }

    latch.clear();
    sends.clear();
    nextBank = 0;
    CHECK(!latch.publishToBothBanks(
        [&](const uint8_t* data, size_t len, const DdrFrameGeometry& geometry, int bank) {
            sends.push_back({bank, geometry, len, data});
            return true;
        },
        nextBank));
    CHECK(sends.empty());
    CHECK(nextBank == 0);

    return fails ? 1 : 0;
}
