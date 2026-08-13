#include "libmisterplex/playback_overlay.hpp"

#include <algorithm>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <string>
#include <vector>

static int fails = 0;
#define CHECK(c)                                                                                 \
    do {                                                                                         \
        if (!(c)) {                                                                              \
            std::fprintf(stderr, "FAIL %s:%d %s\n", __FILE__, __LINE__, #c);                    \
            ++fails;                                                                             \
        }                                                                                        \
    } while (0)

#define CHECK_EQ_U64(actual, expected)                                                           \
    do {                                                                                         \
        const uint64_t a_ = (actual);                                                            \
        const uint64_t e_ = (expected);                                                          \
        if (a_ != e_) {                                                                          \
            std::fprintf(stderr, "FAIL %s:%d got=0x%016llx want=0x%016llx\n", __FILE__,         \
                         __LINE__, static_cast<unsigned long long>(a_),                          \
                         static_cast<unsigned long long>(e_));                                   \
            ++fails;                                                                             \
        }                                                                                        \
    } while (0)

#define CHECK_EQ_HEX16(actual, expected)                                                         \
    do {                                                                                         \
        const uint16_t a_ = (actual);                                                            \
        const uint16_t e_ = (expected);                                                          \
        if (a_ != e_) {                                                                          \
            std::fprintf(stderr, "FAIL %s:%d got=0x%04x want=0x%04x\n", __FILE__, __LINE__, a_,  \
                         e_);                                                                    \
            ++fails;                                                                             \
        }                                                                                        \
    } while (0)

namespace {

constexpr int W = 320;
constexpr int H = 240;
constexpr int kBarX = 26;
constexpr int kBarY = 212;
constexpr int kBarW = 268;
constexpr uint16_t kAmber565 = 0xfd84;
constexpr uint16_t kWhite565 = 0xef7e;

struct PixelGold {
    int x = 0;
    int y = 0;
    uint16_t value = 0;
};

struct Golden {
    uint64_t fnv64 = 0;
    misterplex::OverlayRect dirty;
    std::vector<PixelGold> pixels;
};

struct I420PixelGold {
    char plane = 'Y';
    int x = 0;
    int y = 0;
    uint8_t value = 0;
};

struct I420Golden {
    uint64_t fnv64 = 0;
    misterplex::OverlayRect dirty;
    std::vector<I420PixelGold> pixels;
};

uint16_t pack565(unsigned r, unsigned g, unsigned b) {
    return static_cast<uint16_t>(((r & 0xf8) << 8) | ((g & 0xfc) << 3) | (b >> 3));
}

uint64_t fnv1a(const std::vector<uint8_t>& buf) {
    uint64_t h = 1469598103934665603ull;
    for (uint8_t b : buf) {
        h ^= b;
        h *= 1099511628211ull;
    }
    return h;
}

uint16_t rgb565At(const std::vector<uint8_t>& buf, int x, int y) {
    const size_t i = (static_cast<size_t>(y) * W + x) * 2;
    return static_cast<uint16_t>(buf[i] | (buf[i + 1] << 8));
}

std::vector<uint8_t> syntheticBackground() {
    std::vector<uint8_t> out(static_cast<size_t>(W) * H * 2);
    for (int y = 0; y < H; ++y) {
        for (int x = 0; x < W; ++x) {
            const uint16_t p = pack565((x * 3 + y * 5) & 0xff, (x * 7 + y * 11) & 0xff,
                                       (x * 13 + y * 17) & 0xff);
            const size_t i = (static_cast<size_t>(y) * W + x) * 2;
            out[i + 0] = static_cast<uint8_t>(p & 0xff);
            out[i + 1] = static_cast<uint8_t>(p >> 8);
        }
    }
    return out;
}

std::vector<uint8_t> blackFrame() {
    return std::vector<uint8_t>(static_cast<size_t>(W) * H * 2, 0);
}

uint64_t parseU64(const std::string& s) {
    return static_cast<uint64_t>(std::strtoull(s.c_str(), nullptr, 0));
}

Golden loadGolden() {
    std::ifstream f("tests/unit/golden/playback_overlay_rgb565.txt");
    if (!f) {
        std::fprintf(stderr, "FAIL cannot open playback overlay golden artifact\n");
        ++fails;
        return {};
    }
    Golden g;
    std::string tag;
    while (f >> tag) {
        if (tag == "fnv64") {
            std::string v;
            f >> v;
            g.fnv64 = parseU64(v);
        } else if (tag == "dirty") {
            f >> g.dirty.x >> g.dirty.y >> g.dirty.w >> g.dirty.h;
        } else if (tag == "pixel") {
            PixelGold p;
            std::string v;
            f >> p.x >> p.y >> v;
            p.value = static_cast<uint16_t>(parseU64(v));
            g.pixels.push_back(p);
        } else {
            std::fprintf(stderr, "FAIL unknown golden tag: %s\n", tag.c_str());
            ++fails;
            break;
        }
    }
    return g;
}

I420Golden loadI420Golden(const char* path) {
    std::ifstream f(path);
    if (!f) {
        std::fprintf(stderr, "FAIL cannot open I420 overlay golden artifact: %s\n", path);
        ++fails;
        return {};
    }
    I420Golden g;
    std::string tag;
    while (f >> tag) {
        if (tag == "fnv64") {
            std::string v;
            f >> v;
            g.fnv64 = parseU64(v);
        } else if (tag == "dirty") {
            f >> g.dirty.x >> g.dirty.y >> g.dirty.w >> g.dirty.h;
        } else if (tag == "pixel") {
            I420PixelGold p;
            std::string plane;
            unsigned value = 0;
            f >> plane >> p.x >> p.y >> value;
            p.plane = plane.empty() ? '?' : plane[0];
            p.value = static_cast<uint8_t>(value);
            g.pixels.push_back(p);
        } else {
            std::fprintf(stderr, "FAIL unknown I420 golden tag: %s\n", tag.c_str());
            ++fails;
            break;
        }
    }
    return g;
}

bool inside(const misterplex::OverlayRect& r, int x, int y) {
    return x >= r.x && y >= r.y && x < r.x + r.w && y < r.y + r.h;
}

bool sameRect(const misterplex::OverlayRect& a, const misterplex::OverlayRect& b) {
    return a.x == b.x && a.y == b.y && a.w == b.w && a.h == b.h;
}

size_t i420Bytes(int w, int h) {
    return static_cast<size_t>(w) * static_cast<size_t>(h) * 3 / 2;
}

uint8_t i420At(const std::vector<uint8_t>& frame, int w, int h, char plane, int x, int y) {
    const size_t yBytes = static_cast<size_t>(w) * static_cast<size_t>(h);
    const size_t cBytes = static_cast<size_t>(w / 2) * static_cast<size_t>(h / 2);
    if (plane == 'Y')
        return frame[static_cast<size_t>(y) * static_cast<size_t>(w) + x];
    const size_t offset = plane == 'U' ? yBytes : yBytes + cBytes;
    return frame[offset + static_cast<size_t>(y) * static_cast<size_t>(w / 2) + x];
}

std::vector<uint8_t> syntheticI420(int w, int h) {
    std::vector<uint8_t> frame(i420Bytes(w, h));
    const size_t yBytes = static_cast<size_t>(w) * static_cast<size_t>(h);
    const size_t cBytes = static_cast<size_t>(w / 2) * static_cast<size_t>(h / 2);
    uint8_t* yPlane = frame.data();
    uint8_t* uPlane = yPlane + yBytes;
    uint8_t* vPlane = uPlane + cBytes;
    for (int y = 0; y < h; ++y) {
        for (int x = 0; x < w; ++x)
            yPlane[static_cast<size_t>(y) * w + x] =
                static_cast<uint8_t>(16 + ((x * 7 + y * 11) % 220));
    }
    for (int y = 0; y < h / 2; ++y) {
        for (int x = 0; x < w / 2; ++x) {
            const size_t i = static_cast<size_t>(y) * (w / 2) + x;
            uPlane[i] = static_cast<uint8_t>(16 + ((x * 13 + y * 17) % 225));
            vPlane[i] = static_cast<uint8_t>(16 + ((x * 19 + y * 23) % 225));
        }
    }
    return frame;
}

std::vector<uint8_t> blackI420(int w, int h) {
    std::vector<uint8_t> frame(i420Bytes(w, h), 128);
    std::fill(frame.begin(), frame.begin() + static_cast<std::ptrdiff_t>(
                                             static_cast<size_t>(w) * h),
              16);
    return frame;
}

uint8_t rgbToY(unsigned r, unsigned g, unsigned b) {
    return static_cast<uint8_t>(((66 * r + 129 * g + 25 * b + 128) >> 8) + 16);
}

uint8_t rgbToU(unsigned r, unsigned g, unsigned b) {
    return static_cast<uint8_t>(((-38 * static_cast<int>(r) - 74 * static_cast<int>(g) +
                                  112 * static_cast<int>(b) + 128) >>
                                 8) +
                                128);
}

uint8_t rgbToV(unsigned r, unsigned g, unsigned b) {
    return static_cast<uint8_t>(((112 * static_cast<int>(r) - 94 * static_cast<int>(g) -
                                  18 * static_cast<int>(b) + 128) >>
                                 8) +
                                128);
}

void checkI420OutsideDirtyUnchanged(const std::vector<uint8_t>& before,
                                    const std::vector<uint8_t>& after, int w, int h,
                                    const misterplex::OverlayRect& dirty) {
    CHECK(before.size() == after.size());
    for (int y = 0; y < h; ++y) {
        for (int x = 0; x < w; ++x) {
            if (!inside(dirty, x, y) &&
                i420At(before, w, h, 'Y', x, y) != i420At(after, w, h, 'Y', x, y)) {
                std::fprintf(stderr, "FAIL I420 Y outside dirty changed at (%d,%d)\n", x, y);
                ++fails;
                return;
            }
        }
    }
    const misterplex::OverlayRect chroma{dirty.x / 2, dirty.y / 2, dirty.w / 2, dirty.h / 2};
    for (char plane : {'U', 'V'}) {
        for (int y = 0; y < h / 2; ++y) {
            for (int x = 0; x < w / 2; ++x) {
                if (!inside(chroma, x, y) &&
                    i420At(before, w, h, plane, x, y) !=
                        i420At(after, w, h, plane, x, y)) {
                    std::fprintf(stderr, "FAIL I420 %c outside dirty changed at (%d,%d)\n",
                                 plane, x, y);
                    ++fails;
                    return;
                }
            }
        }
    }
}

bool i420ChangedOutsideDirty(const std::vector<uint8_t>& before,
                             const std::vector<uint8_t>& after, int w, int h,
                             const misterplex::OverlayRect& dirty) {
    for (int y = 0; y < h; ++y) {
        for (int x = 0; x < w; ++x) {
            if (!inside(dirty, x, y) &&
                i420At(before, w, h, 'Y', x, y) != i420At(after, w, h, 'Y', x, y))
                return true;
        }
    }
    const misterplex::OverlayRect chroma{dirty.x / 2, dirty.y / 2, dirty.w / 2, dirty.h / 2};
    for (char plane : {'U', 'V'}) {
        for (int y = 0; y < h / 2; ++y) {
            for (int x = 0; x < w / 2; ++x) {
                if (!inside(chroma, x, y) &&
                    i420At(before, w, h, plane, x, y) !=
                        i420At(after, w, h, plane, x, y))
                    return true;
            }
        }
    }
    return false;
}

void checkI420Golden(const I420Golden& golden, const std::vector<uint8_t>& frame, int w,
                     int h, const misterplex::OverlayRect& dirty) {
    CHECK(dirty.x == golden.dirty.x);
    CHECK(dirty.y == golden.dirty.y);
    CHECK(dirty.w == golden.dirty.w);
    CHECK(dirty.h == golden.dirty.h);
    CHECK_EQ_U64(fnv1a(frame), golden.fnv64);
    for (const I420PixelGold& p : golden.pixels) {
        const uint8_t actual = i420At(frame, w, h, p.plane, p.x, p.y);
        if (actual != p.value) {
            std::fprintf(stderr, "FAIL I420 %c(%d,%d) got=%u want=%u\n", p.plane, p.x,
                         p.y, actual, p.value);
            ++fails;
        }
    }
}

void checkOutsideDirtyUnchanged(const std::vector<uint8_t>& before,
                                const std::vector<uint8_t>& after,
                                const misterplex::OverlayRect& dirty) {
    CHECK(before.size() == after.size());
    for (int y = 0; y < H; ++y) {
        for (int x = 0; x < W; ++x) {
            if (inside(dirty, x, y))
                continue;
            const size_t i = (static_cast<size_t>(y) * W + x) * 2;
            if (before[i] != after[i] || before[i + 1] != after[i + 1]) {
                std::fprintf(stderr,
                             "FAIL outside dirty changed at (%d,%d): got=%02x%02x want=%02x%02x\n",
                             x, y, after[i + 1], after[i], before[i + 1], before[i]);
                ++fails;
                return;
            }
        }
    }
}

int knobCenterOnBar(const std::vector<uint8_t>& buf) {
    int lo = 9999;
    int hi = -1;
    const int y = kBarY + 2;
    for (int x = kBarX - 4; x < kBarX + kBarW + 6; ++x) {
        if (x >= 0 && x < W && rgb565At(buf, x, y) == kWhite565) {
            lo = std::min(lo, x);
            hi = std::max(hi, x);
        }
    }
    if (hi < lo)
        return -1;
    return (lo + hi) / 2;
}

void renderProgressCase(int64_t elapsedMs, int64_t durationMs, std::vector<uint8_t>& frame) {
    misterplex::PlaybackOverlay ov;
    ov.showAt(misterplex::PlaybackOverlayState::Playing, elapsedMs, durationMs, 5000);
    CHECK(ov.renderRgb565LeAt(frame.data(), W, H, 5000));
}

void checkGuardedProgress(int64_t elapsedMs, int64_t durationMs, int expectedKnobX) {
    constexpr size_t kGuard = 32;
    std::vector<uint8_t> guarded(kGuard + static_cast<size_t>(W) * H * 2 + kGuard, 0xa5);
    std::fill(guarded.begin() + static_cast<std::ptrdiff_t>(kGuard),
              guarded.end() - static_cast<std::ptrdiff_t>(kGuard), 0);
    misterplex::PlaybackOverlay ov;
    ov.showAt(misterplex::PlaybackOverlayState::Playing, elapsedMs, durationMs, 3000);
    CHECK(ov.renderRgb565LeAt(guarded.data() + kGuard, W, H, 3000));
    for (size_t i = 0; i < kGuard; ++i) {
        CHECK(guarded[i] == 0xa5);
        CHECK(guarded[guarded.size() - 1 - i] == 0xa5);
    }
    std::vector<uint8_t> frame(guarded.begin() + static_cast<std::ptrdiff_t>(kGuard),
                               guarded.end() - static_cast<std::ptrdiff_t>(kGuard));
    const int center = knobCenterOnBar(frame);
    if (std::abs(center - expectedKnobX) > 1) {
        std::fprintf(stderr, "FAIL progress knob center got=%d want≈%d\n", center,
                     expectedKnobX);
        ++fails;
    }
}

std::vector<uint8_t> renderGuardedI420(int w, int h, misterplex::PlaybackOverlay& ov,
                                       int64_t nowMs) {
    constexpr size_t kGuard = 64;
    const std::vector<uint8_t> source = syntheticI420(w, h);
    std::vector<uint8_t> guarded(kGuard + source.size() + kGuard, 0xa5);
    std::copy(source.begin(), source.end(),
              guarded.begin() + static_cast<std::ptrdiff_t>(kGuard));
    CHECK(ov.renderI420At(guarded.data() + kGuard, w, h, nowMs));
    for (size_t i = 0; i < kGuard; ++i) {
        CHECK(guarded[i] == 0xa5);
        CHECK(guarded[guarded.size() - 1 - i] == 0xa5);
    }
    return std::vector<uint8_t>(
        guarded.begin() + static_cast<std::ptrdiff_t>(kGuard),
        guarded.end() - static_cast<std::ptrdiff_t>(kGuard));
}

void checkScale2Luma(const std::vector<uint8_t>& scale1, const std::vector<uint8_t>& scale2) {
    for (int y = 0; y < H; ++y) {
        for (int x = 0; x < W; ++x) {
            const uint8_t expected = i420At(scale1, W, H, 'Y', x, y);
            for (int dy = 0; dy < 2; ++dy) {
                for (int dx = 0; dx < 2; ++dx) {
                    const uint8_t actual = i420At(scale2, W * 2, H * 2, 'Y', x * 2 + dx,
                                                  y * 2 + dy);
                    if (actual != expected) {
                        std::fprintf(stderr,
                                     "FAIL scale2 luma (%d,%d)+(%d,%d) got=%u want=%u\n", x,
                                     y, dx, dy, actual, expected);
                        ++fails;
                        return;
                    }
                }
            }
        }
    }
}

void checkI420MatchesRgbCoverage(int w, int h) {
    constexpr int64_t kNow = 44000;
    misterplex::PlaybackOverlay rgbOverlay;
    rgbOverlay.showAt(misterplex::PlaybackOverlayState::Playing, 61000, 2732000, kNow);
    misterplex::PlaybackOverlay i420Overlay;
    i420Overlay.showAt(misterplex::PlaybackOverlayState::Playing, 61000, 2732000, kNow);
    std::vector<uint8_t> rgb(static_cast<size_t>(w) * h * 3, 0);
    std::vector<uint8_t> i420 = blackI420(w, h);
    CHECK(rgbOverlay.renderRgb24At(rgb.data(), w, h, kNow));
    CHECK(i420Overlay.renderI420At(i420.data(), w, h, kNow));
    const misterplex::OverlayRect dirty = i420Overlay.dirtyBoundsI420At(w, h, kNow);

    for (int y = dirty.y; y < dirty.y + dirty.h; ++y) {
        for (int x = dirty.x; x < dirty.x + dirty.w; ++x) {
            const size_t i = (static_cast<size_t>(y) * w + x) * 3;
            const int expected = rgbToY(rgb[i], rgb[i + 1], rgb[i + 2]);
            const int actual = i420At(i420, w, h, 'Y', x, y);
            if (std::abs(actual - expected) > 1) {
                std::fprintf(stderr, "FAIL I420 Y/RGB mismatch (%d,%d) got=%d want≈%d\n", x,
                             y, actual, expected);
                ++fails;
                return;
            }
        }
    }

    for (int y = dirty.y / 2; y < (dirty.y + dirty.h) / 2; ++y) {
        for (int x = dirty.x / 2; x < (dirty.x + dirty.w) / 2; ++x) {
            int expectedU = 0;
            int expectedV = 0;
            for (int dy = 0; dy < 2; ++dy) {
                for (int dx = 0; dx < 2; ++dx) {
                    const size_t i =
                        (static_cast<size_t>(y * 2 + dy) * w + x * 2 + dx) * 3;
                    expectedU += rgbToU(rgb[i], rgb[i + 1], rgb[i + 2]);
                    expectedV += rgbToV(rgb[i], rgb[i + 1], rgb[i + 2]);
                }
            }
            expectedU = (expectedU + 2) / 4;
            expectedV = (expectedV + 2) / 4;
            const int actualU = i420At(i420, w, h, 'U', x, y);
            const int actualV = i420At(i420, w, h, 'V', x, y);
            if (std::abs(actualU - expectedU) > 2 || std::abs(actualV - expectedV) > 2) {
                std::fprintf(stderr,
                             "FAIL I420 UV coverage mismatch (%d,%d) got=%d,%d want≈%d,%d\n",
                             x, y, actualU, actualV, expectedU, expectedV);
                ++fails;
                return;
            }
        }
    }
}

} // namespace

int main() {
    using namespace misterplex;

    // 1. Deterministic rendering: exact RGB565 frame hash plus readable pixel checks.
    const Golden golden = loadGolden();
    const I420Golden i420Golden320 =
        loadI420Golden("tests/unit/golden/playback_overlay_i420_320.txt");
    const I420Golden i420Golden640 =
        loadI420Golden("tests/unit/golden/playback_overlay_i420_640.txt");
    PlaybackOverlay ov;
    const std::vector<uint8_t> background = syntheticBackground();
    std::vector<uint8_t> frame = background;
    ov.showAt(PlaybackOverlayState::Playing, 61000, 2732000, 10000);
    const OverlayRect dirty = ov.dirtyBoundsAt(W, H, 10000);
    CHECK(dirty.x == golden.dirty.x);
    CHECK(dirty.y == golden.dirty.y);
    CHECK(dirty.w == golden.dirty.w);
    CHECK(dirty.h == golden.dirty.h);
    CHECK(ov.renderRgb565LeAt(frame.data(), W, H, 10000));
    CHECK_EQ_U64(fnv1a(frame), golden.fnv64);
    for (const PixelGold& p : golden.pixels)
        CHECK_EQ_HEX16(rgb565At(frame, p.x, p.y), p.value);

    // 4. Non-destructive compositing: outside the dirty rect is byte-identical.
    checkOutsideDirtyUnchanged(background, frame, dirty);

    // Packed RGB24/BGRA32 stay channel-equivalent; BGRA alpha changes only where drawn.
    {
        std::vector<uint8_t> rgb(static_cast<size_t>(W) * H * 3);
        std::vector<uint8_t> bgra(static_cast<size_t>(W) * H * 4);
        for (int y = 0; y < H; ++y) {
            for (int x = 0; x < W; ++x) {
                const size_t p = static_cast<size_t>(y) * W + x;
                const uint8_t r = static_cast<uint8_t>((x * 3 + y * 5) & 0xff);
                const uint8_t g = static_cast<uint8_t>((x * 7 + y * 11) & 0xff);
                const uint8_t b = static_cast<uint8_t>((x * 13 + y * 17) & 0xff);
                rgb[p * 3 + 0] = r;
                rgb[p * 3 + 1] = g;
                rgb[p * 3 + 2] = b;
                bgra[p * 4 + 0] = b;
                bgra[p * 4 + 1] = g;
                bgra[p * 4 + 2] = r;
                bgra[p * 4 + 3] = 0x7a;
            }
        }
        PlaybackOverlay rgbOv;
        rgbOv.showAt(PlaybackOverlayState::Playing, 61000, 2732000, 10000);
        PlaybackOverlay bgraOv;
        bgraOv.showAt(PlaybackOverlayState::Playing, 61000, 2732000, 10000);
        CHECK(rgbOv.renderRgb24At(rgb.data(), W, H, 10000));
        CHECK(bgraOv.renderBgra32At(bgra.data(), W, H, 10000));
        for (int y = 0; y < H; ++y) {
            for (int x = 0; x < W; ++x) {
                const size_t p = static_cast<size_t>(y) * W + x;
                CHECK(rgb[p * 3 + 0] == bgra[p * 4 + 2]);
                CHECK(rgb[p * 3 + 1] == bgra[p * 4 + 1]);
                CHECK(rgb[p * 3 + 2] == bgra[p * 4 + 0]);
                CHECK(bgra[p * 4 + 3] == (inside(dirty, x, y) ? 0xff : 0x7a));
            }
        }
    }

    // 2. Progress-bar geometry and edge cases.
    {
        std::vector<uint8_t> zero = blackFrame();
        renderProgressCase(0, 100000, zero);
        CHECK(knobCenterOnBar(zero) == kBarX);
        CHECK(rgb565At(zero, kBarX + 4, kBarY + 2) != kAmber565);

        std::vector<uint8_t> half = blackFrame();
        renderProgressCase(100000, 200000, half);
        CHECK(std::abs(knobCenterOnBar(half) - (kBarX + kBarW / 2)) <= 1);
        CHECK_EQ_HEX16(rgb565At(half, kBarX + kBarW / 2 - 4, kBarY + 2), kAmber565);
        CHECK(rgb565At(half, kBarX + kBarW / 2 + 4, kBarY + 2) != kAmber565);

        std::vector<uint8_t> full = blackFrame();
        renderProgressCase(200000, 200000, full);
        CHECK(std::abs(knobCenterOnBar(full) - (kBarX + kBarW)) <= 1);
        CHECK_EQ_HEX16(rgb565At(full, kBarX + kBarW - 4, kBarY + 2), kAmber565);

        checkGuardedProgress(400000, 200000, kBarX + kBarW); // seek overshoot clamps full
        checkGuardedProgress(100000, 0, kBarX);              // live stream duration unknown
    }

    // 3. Auto-hide timing with injected timestamps, no sleeps.
    {
        PlaybackOverlay timed;
        timed.showAt(PlaybackOverlayState::Paused, 1000, 5000, 10000);
        CHECK(timed.visibleAt(10000));
        CHECK(timed.visibleAt(10000 + PlaybackOverlay::kVisibleMs - PlaybackOverlay::kFadeMs));
        CHECK(timed.visibleAt(10000 + PlaybackOverlay::kVisibleMs - 1));
        CHECK(!timed.visibleAt(10000 + PlaybackOverlay::kVisibleMs));
        CHECK(timed.dirtyBoundsAt(W, H, 10000 + PlaybackOverlay::kVisibleMs).empty());

        timed.flashSkipAt(30000, 2000, 90000, 20000);
        CHECK(timed.visibleAt(20000));
        CHECK(timed.visibleAt(20000 + PlaybackOverlay::kSkipVisibleMs - 1));
        CHECK(!timed.visibleAt(20000 + PlaybackOverlay::kVisibleMs));
    }

    // 5. Product I420 path: deterministic scale-1 and exact scale-2 rendering.
    {
        constexpr int64_t kNow = 30000;
        PlaybackOverlay planar320;
        planar320.showAt(PlaybackOverlayState::Playing, 61000, 2732000, kNow);
        const std::vector<uint8_t> before320 = syntheticI420(W, H);
        const std::vector<uint8_t> frame320 = renderGuardedI420(W, H, planar320, kNow);
        const OverlayRect dirty320 = planar320.dirtyBoundsI420At(W, H, kNow);
        checkI420Golden(i420Golden320, frame320, W, H, dirty320);
        checkI420OutsideDirtyUnchanged(before320, frame320, W, H, dirty320);

        PlaybackOverlay planar640;
        planar640.showAt(PlaybackOverlayState::Playing, 61000, 2732000, kNow);
        const std::vector<uint8_t> before640 = syntheticI420(W * 2, H * 2);
        const std::vector<uint8_t> frame640 =
            renderGuardedI420(W * 2, H * 2, planar640, kNow);
        const OverlayRect dirty640 = planar640.dirtyBoundsI420At(W * 2, H * 2, kNow);
        checkI420Golden(i420Golden640, frame640, W * 2, H * 2, dirty640);
        checkI420OutsideDirtyUnchanged(before640, frame640, W * 2, H * 2, dirty640);
        CHECK(dirty640.x == dirty320.x * 2);
        CHECK(dirty640.y == dirty320.y * 2);
        CHECK(dirty640.w == dirty320.w * 2);
        CHECK(dirty640.h == dirty320.h * 2);

        std::vector<uint8_t> black320 = blackI420(W, H);
        std::vector<uint8_t> black640 = blackI420(W * 2, H * 2);
        PlaybackOverlay exact320;
        exact320.showAt(PlaybackOverlayState::Playing, 61000, 2732000, kNow);
        PlaybackOverlay exact640;
        exact640.showAt(PlaybackOverlayState::Playing, 61000, 2732000, kNow);
        CHECK(exact320.renderI420At(black320.data(), W, H, kNow));
        CHECK(exact640.renderI420At(black640.data(), W * 2, H * 2, kNow));
        checkScale2Luma(black320, black640);

        // Fully covered 2x2 cells must carry limited-range BT.601 amber/white.
        CHECK(i420At(black640, W * 2, H * 2, 'Y', 54, 366) == 175);
        CHECK(i420At(black640, W * 2, H * 2, 'U', 27, 183) == 53);
        CHECK(i420At(black640, W * 2, H * 2, 'V', 27, 183) == 172);
        CHECK(i420At(black640, W * 2, H * 2, 'Y', 112, 360) == 220);
        CHECK(i420At(black640, W * 2, H * 2, 'U', 56, 180) == 131);
        CHECK(i420At(black640, W * 2, H * 2, 'V', 56, 180) == 126);

        checkI420MatchesRgbCoverage(W, H);
    }

    // 6. I420 dirty rectangles align to chroma cells; skip/panel geometry scales exactly.
    {
        const OverlayRect aligned = alignI420DirtyRect(OverlayRect{11, 17, 7, 9}, W, H);
        CHECK(aligned.x == 10);
        CHECK(aligned.y == 16);
        CHECK(aligned.w == 8);
        CHECK(aligned.h == 10);
        CHECK((aligned.x & 1) == 0);
        CHECK((aligned.y & 1) == 0);
        CHECK((aligned.w & 1) == 0);
        CHECK((aligned.h & 1) == 0);
        std::vector<uint8_t> alignedFrame = syntheticI420(W, H);
        I420DirtyBackup alignedBackup;
        CHECK(alignedBackup.capture(alignedFrame.data(), W, H, OverlayRect{11, 17, 7, 9}));
        CHECK(alignedBackup.rect.x == aligned.x);
        CHECK(alignedBackup.rect.y == aligned.y);
        CHECK(alignedBackup.rect.w == aligned.w);
        CHECK(alignedBackup.rect.h == aligned.h);

        PlaybackOverlay skip320;
        skip320.flashSkipAt(30000, 61000, 2732000, 50000);
        PlaybackOverlay skip640;
        skip640.flashSkipAt(30000, 61000, 2732000, 50000);
        const OverlayRect s1 = skip320.dirtyBoundsI420At(W, H, 50000);
        const OverlayRect s2 = skip640.dirtyBoundsI420At(W * 2, H * 2, 50000);
        CHECK(s2.x == s1.x * 2);
        CHECK(s2.y == s1.y * 2);
        CHECK(s2.w == s1.w * 2);
        CHECK(s2.h == s1.h * 2);

        std::vector<uint8_t> skipFrame320 = blackI420(W, H);
        std::vector<uint8_t> skipFrame640 = blackI420(W * 2, H * 2);
        CHECK(skip320.renderI420At(skipFrame320.data(), W, H, 50000));
        CHECK(skip640.renderI420At(skipFrame640.data(), W * 2, H * 2, 50000));
        checkScale2Luma(skipFrame320, skipFrame640);
    }

    // 7. Fade/hide and planar pause-frame restore are non-destructive.
    {
        constexpr int64_t kNow = 60000;
        PlaybackOverlay paused;
        paused.showAt(PlaybackOverlayState::Paused, 1000, 5000, kNow);
        const OverlayRect planarDirty = paused.dirtyBoundsI420At(W, H, kNow);
        CHECK((planarDirty.x & 1) == 0);
        CHECK((planarDirty.y & 1) == 0);
        CHECK((planarDirty.w & 1) == 0);
        CHECK((planarDirty.h & 1) == 0);

        const std::vector<uint8_t> clean = syntheticI420(W, H);
        std::vector<uint8_t> painted = clean;
        I420DirtyBackup backup;
        CHECK(backup.capture(painted.data(), W, H, planarDirty));
        CHECK(backup.rect.x == planarDirty.x);
        CHECK(backup.rect.y == planarDirty.y);
        CHECK(backup.rect.w == planarDirty.w);
        CHECK(backup.rect.h == planarDirty.h);
        CHECK(backup.y.size() == static_cast<size_t>(planarDirty.w) * planarDirty.h);
        CHECK(backup.u.size() ==
              static_cast<size_t>(planarDirty.w / 2) * (planarDirty.h / 2));
        CHECK(backup.v.size() == backup.u.size());
        CHECK(paused.renderI420At(painted.data(), W, H, kNow));
        CHECK(painted != clean);
        checkI420OutsideDirtyUnchanged(clean, painted, W, H, planarDirty);
        CHECK(backup.restore(painted.data(), W, H));
        CHECK(painted == clean);

        const int64_t fadeAt =
            kNow + PlaybackOverlay::kVisibleMs - PlaybackOverlay::kFadeMs / 2;
        std::vector<uint8_t> full = clean;
        std::vector<uint8_t> faded = clean;
        CHECK(paused.renderI420At(full.data(), W, H, kNow));
        CHECK(paused.renderI420At(faded.data(), W, H, fadeAt));
        const int sampleX = 100;
        const int sampleY = 200;
        const int baseY = i420At(clean, W, H, 'Y', sampleX, sampleY);
        const int fullY = i420At(full, W, H, 'Y', sampleX, sampleY);
        const int fadeY = i420At(faded, W, H, 'Y', sampleX, sampleY);
        CHECK(std::abs(fadeY - baseY) < std::abs(fullY - baseY));

        std::vector<uint8_t> hidden = clean;
        CHECK(!paused.renderI420At(hidden.data(), W, H,
                                  kNow + PlaybackOverlay::kVisibleMs));
        CHECK(hidden == clean);
        CHECK(paused.dirtyBoundsI420At(W, H, kNow + PlaybackOverlay::kVisibleMs).empty());

        I420DirtyBackup oddReject;
        CHECK(!oddReject.capture(clean.data(), W - 1, H, planarDirty));
        CHECK(!backup.restore(painted.data(), W * 2, H));
    }

    // 8. Transactional I420 rendering freezes one state/time for dirty backup and paint.
    {
        constexpr int64_t kNow = 70000;
        const OverlayRect panelDirty{10, 170, 300, 60};
        const OverlayRect panelAndSkipDirty{10, 90, 300, 140};
        PlaybackOverlay transactional;
        transactional.showAt(PlaybackOverlayState::Playing, 61000, 2732000, kNow);
        const std::vector<uint8_t> clean = syntheticI420(W, H);

        // Negative control: the reviewed two-call sequence leaves skip residue.
        std::vector<uint8_t> stalePaint = clean;
        const OverlayRect staleDirty = transactional.dirtyBoundsI420At(W, H, kNow);
        CHECK(sameRect(staleDirty, panelDirty));
        I420DirtyBackup staleBackup;
        CHECK(staleBackup.capture(stalePaint.data(), W, H, staleDirty));
        transactional.flashSkipAt(30000, 61000, 2732000, kNow);
        CHECK(transactional.renderI420At(stalePaint.data(), W, H, kNow));
        CHECK(i420ChangedOutsideDirty(clean, stalePaint, W, H, staleBackup.rect));
        CHECK(staleBackup.restore(stalePaint.data(), W, H));
        CHECK(stalePaint != clean);

        // The one-call API backs up the expanded state it actually composites.
        std::vector<uint8_t> painted = clean;
        I420DirtyBackup transactionBackup;
        CHECK(transactional.renderI420WithBackupAt(painted.data(), W, H, kNow,
                                                   transactionBackup));
        CHECK(sameRect(transactionBackup.rect, panelAndSkipDirty));
        CHECK(!i420ChangedOutsideDirty(clean, painted, W, H, transactionBackup.rect));
        CHECK(transactionBackup.restore(painted.data(), W, H));
        CHECK(painted == clean);
    }

    // 9. Product true480 pause repaint uses coded 624x480 and sends one clean
    // frame after the overlay expires.
    {
        constexpr int kCodedW = 624;
        constexpr int kCodedH = 480;
        constexpr int64_t kNow = 80000;
        PlaybackOverlay paused;
        paused.showAt(PlaybackOverlayState::Paused, 61000, 2732000, kNow);

        const std::vector<uint8_t> clean = syntheticI420(kCodedW, kCodedH);
        std::vector<uint8_t> lastPresentedFrame = clean;
        I420DirtyBackup backup;
        const bool overlayDrawn = paused.renderI420WithBackupAt(
            lastPresentedFrame.data(), kCodedW, kCodedH, kNow, backup);
        CHECK(overlayDrawn);
        CHECK((backup.rect.x & 1) == 0);
        CHECK((backup.rect.y & 1) == 0);
        CHECK((backup.rect.w & 1) == 0);
        CHECK((backup.rect.h & 1) == 0);
        CHECK(backup.y.size() ==
              static_cast<size_t>(backup.rect.w) * backup.rect.h);
        CHECK(backup.u.size() ==
              static_cast<size_t>(backup.rect.w / 2) * (backup.rect.h / 2));
        CHECK(backup.v.size() == backup.u.size());
        CHECK(lastPresentedFrame != clean);
        checkI420OutsideDirtyUnchanged(
            clean, lastPresentedFrame, kCodedW, kCodedH, backup.rect);

        const std::vector<uint8_t> outgoingOverlay = lastPresentedFrame;
        CHECK(backup.restore(lastPresentedFrame.data(), kCodedW, kCodedH));
        CHECK(lastPresentedFrame == clean);
        CHECK(outgoingOverlay != clean);

        const int64_t expiredAt = kNow + PlaybackOverlay::kVisibleMs;
        CHECK(!paused.visibleAt(expiredAt));
        const bool expiredOverlayDrawn = paused.renderI420WithBackupAt(
            lastPresentedFrame.data(), kCodedW, kCodedH, expiredAt, backup);
        CHECK(!expiredOverlayDrawn);
        CHECK(backup.rect.empty());
        CHECK(lastPresentedFrame == clean);
    }

    if (fails) {
        std::fprintf(stderr, "test_playback_overlay: %d failure(s)\n", fails);
        return 1;
    }
    std::printf("test_playback_overlay: OK\n");
    return 0;
}
