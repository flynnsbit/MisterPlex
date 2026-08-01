#include "libmisterplex/playback_overlay.hpp"
#include <cstdint>
#include <cstdio>
#include <fstream>
#include <string>
#include <vector>

static uint16_t pack565(unsigned r, unsigned g, unsigned b) {
    return static_cast<uint16_t>(((r & 0xf8) << 8) | ((g & 0xfc) << 3) | (b >> 3));
}
static uint64_t fnv1a(const std::vector<uint8_t>& buf) {
    uint64_t h = 1469598103934665603ull;
    for (uint8_t b : buf) { h ^= b; h *= 1099511628211ull; }
    return h;
}
static uint16_t at(const std::vector<uint8_t>& buf, int w, int x, int y) {
    const size_t i = (static_cast<size_t>(y) * w + x) * 2;
    return static_cast<uint16_t>(buf[i] | (buf[i + 1] << 8));
}

int main() {
    constexpr int W = 320, H = 240;
    std::vector<uint8_t> frame(static_cast<size_t>(W) * H * 2);
    for (int y = 0; y < H; ++y)
        for (int x = 0; x < W; ++x) {
            const uint16_t p = pack565((x * 3 + y * 5) & 0xff, (x * 7 + y * 11) & 0xff,
                                       (x * 13 + y * 17) & 0xff);
            const size_t i = (static_cast<size_t>(y) * W + x) * 2;
            frame[i] = static_cast<uint8_t>(p & 0xff);
            frame[i + 1] = static_cast<uint8_t>(p >> 8);
        }
    misterplex::PlaybackOverlay ov;
    ov.showAt(misterplex::PlaybackOverlayState::Playing, 61000, 2732000, 10000);
    const auto dirty = ov.dirtyBoundsAt(W, H, 10000);
    ov.renderRgb565LeAt(frame.data(), W, H, 10000);
    const uint64_t h = fnv1a(frame);
    std::ofstream out("tests/unit/golden/playback_overlay_rgb565.txt");
    out << "fnv64 0x" << std::hex << h << std::dec << "\n";
    out << "dirty " << dirty.x << " " << dirty.y << " " << dirty.w << " " << dirty.h << "\n";
    // Sample a grid of interesting pixels inside the dirty rect.
    const int samples[][2] = {
        {dirty.x + 4, dirty.y + 4},
        {dirty.x + dirty.w / 2, dirty.y + 12},
        {dirty.x + 22, dirty.y + 18},
        {dirty.x + 40, dirty.y + 10},
        {dirty.x + 14, dirty.y + dirty.h - 12},
        {dirty.x + dirty.w / 2, dirty.y + dirty.h - 10},
        {dirty.x + dirty.w - 20, dirty.y + 30},
        {dirty.x + 30, dirty.y + 34},
    };
    for (const auto& s : samples) {
        const int x = s[0], y = s[1];
        if (x < 0 || y < 0 || x >= W || y >= H) continue;
        char buf[32];
        std::snprintf(buf, sizeof(buf), "0x%04x", at(frame, W, x, y));
        out << "pixel " << x << " " << y << " " << buf << "\n";
    }
    std::printf("wrote golden dirty=%d %d %d %d fnv=0x%llx\n", dirty.x, dirty.y, dirty.w,
                dirty.h, static_cast<unsigned long long>(h));
    return 0;
}
