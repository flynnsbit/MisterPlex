#include "libmisterplex/playback_overlay.hpp"

#include <cstdint>
#include <cstdio>
#include <vector>

static int fails = 0;
#define CHECK(c)                                                                                 \
    do {                                                                                         \
        if (!(c)) {                                                                              \
            std::fprintf(stderr, "FAIL %s:%d %s\n", __FILE__, __LINE__, #c);                    \
            ++fails;                                                                             \
        }                                                                                        \
    } while (0)

static uint64_t fnv1a(const std::vector<uint8_t>& buf) {
    uint64_t h = 1469598103934665603ull;
    for (uint8_t b : buf) {
        h ^= b;
        h *= 1099511628211ull;
    }
    return h;
}

static uint16_t rgb565At(const std::vector<uint8_t>& buf, int w, int x, int y) {
    const size_t i = (static_cast<size_t>(y) * w + x) * 2;
    return static_cast<uint16_t>(buf[i] | (buf[i + 1] << 8));
}

int main() {
    using namespace misterplex;
    constexpr int W = 320;
    constexpr int H = 240;
    constexpr uint16_t kBlue = 0x001f;

    PlaybackOverlay ov;
    std::vector<uint8_t> rgb565(static_cast<size_t>(W) * H * 2);
    for (size_t i = 0; i < rgb565.size(); i += 2) {
        rgb565[i + 0] = static_cast<uint8_t>(kBlue & 0xff);
        rgb565[i + 1] = static_cast<uint8_t>(kBlue >> 8);
    }
    const uint64_t clean565 = fnv1a(rgb565);

    ov.showAt(PlaybackOverlayState::Playing, 30000, 120000, 1000);
    OverlayRect dirty = ov.dirtyBoundsAt(W, H, 1000);
    CHECK(dirty.x == 10);
    CHECK(dirty.y == 170);
    CHECK(dirty.w == 300);
    CHECK(dirty.h == 60);
    CHECK(ov.renderRgb565LeAt(rgb565.data(), W, H, 1000));
    CHECK(rgb565At(rgb565, W, 2, 2) == kBlue);
    CHECK(rgb565At(rgb565, W, 30, 214) != kBlue);  // progress fill
    CHECK(rgb565At(rgb565, W, 260, 214) != kBlue); // scrub track
    const uint64_t playingSum = fnv1a(rgb565);
    CHECK(playingSum == 15024079914267145814ull);
    CHECK(playingSum != clean565);

    std::vector<uint8_t> hidden = rgb565;
    CHECK(!ov.renderRgb565LeAt(hidden.data(), W, H, 4500));
    CHECK(fnv1a(hidden) == playingSum);

    std::vector<uint8_t> skip(static_cast<size_t>(W) * H * 2, 0);
    ov.flashSkipAt(-30000, 60000, 120000, 2000);
    dirty = ov.dirtyBoundsAt(W, H, 2000);
    CHECK(dirty.y < 170);
    CHECK(ov.renderRgb565LeAt(skip.data(), W, H, 2000));
    const uint64_t skipSum = fnv1a(skip);
    CHECK(skipSum == 12777997056436687251ull);

    std::vector<uint8_t> rgb24(static_cast<size_t>(W) * H * 3, 0x20);
    ov.showAt(PlaybackOverlayState::Paused, 45000, 90000, 7000);
    CHECK(ov.renderRgb24At(rgb24.data(), W, H, 7000));
    const uint64_t paused24Sum = fnv1a(rgb24);
    CHECK(paused24Sum == 4019970145560657442ull);
    CHECK(rgb24[(static_cast<size_t>(10) * W + 10) * 3] == 0x20);
    CHECK(rgb24[(static_cast<size_t>(190) * W + 42) * 3] != 0x20);

    if (fails) {
        std::fprintf(stderr, "test_playback_overlay: %d failure(s)\n", fails);
        std::fprintf(stderr, "sums playing=%llu skip=%llu paused24=%llu clean=%llu\n",
                     static_cast<unsigned long long>(playingSum),
                     static_cast<unsigned long long>(skipSum),
                     static_cast<unsigned long long>(paused24Sum),
                     static_cast<unsigned long long>(clean565));
        return 1;
    }
    std::printf("test_playback_overlay: OK\n");
    return 0;
}
