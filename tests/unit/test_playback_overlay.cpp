#include "libmisterplex/playback_overlay.hpp"
#include "libmisterplex/fpga_playback_overlay.hpp"

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

void checkFpgaPackets() {
    namespace ui = misterplex::fpga_overlay;
    ui::Model model;
    model.state = ui::State::Paused;
    model.title = "MiSTer Plex: Caf\xc3\xa9 \xf0\x9f\x8e\xac";
    model.position_ms = 123456;
    model.duration_ms = 246912;
    const ui::Packet packet = ui::encode(7, 99, 1, model);
    CHECK(ui::validate(packet.data(), packet.size(), 7, 99, 0));
    CHECK(packet[28] & ui::AutoFit);
    CHECK(ui::get16(packet.data() + 36) == 128);
    CHECK(ui::displayText(model.title) == "MISTER PLEX: CAF   ");
    CHECK(ui::displayText(std::string(100, 'a')).size() == 42);
    CHECK(ui::displayText("\xe2\x82").size() == 1);
    CHECK(ui::displayText("a\nb") == "A B");
    for (char c = 'A'; c <= 'Z'; ++c) {
        unsigned ink = 0;
        for (unsigned row = 0; row != 7; ++row) ink |= ui::glyph(c)[row];
        CHECK(ink != 0);
    }
    CHECK(ui::progressPixels(-1, 20) == 0);
    CHECK(ui::progressPixels(20, 0) == 0);
    CHECK(ui::progressPixels(40, 20) == 256);
    CHECK(ui::progressPixels(INT64_MAX / 2, INT64_MAX) == 127);
    CHECK(ui::progressPixels(INT64_MAX - 1, INT64_MAX) == 255);
    for (unsigned width = 1; width <= 256; ++width)
        for (int64_t duration = 1; duration < 30; ++duration)
            for (int64_t position = 0; position <= duration; ++position)
                CHECK(ui::progressPixels(position, duration, width) ==
                      position * width / duration);
    for (const auto geometry : {std::pair<unsigned, unsigned>{320, 212},
                               {212, 320}, {128, 96}, {640, 424}, {6, 24}}) {
        ui::Model fitted = model;
        CHECK(ui::fitToViewport(fitted, geometry.first, geometry.second, 11, 5));
        CHECK(!(fitted.flags & ui::AutoFit));
        CHECK(fitted.x >= 11 && fitted.x + fitted.width * fitted.scale <=
              11 + geometry.first);
        CHECK(fitted.y >= 5 && fitted.y + ui::kPanelHeight * fitted.scale <=
              5 + geometry.second);
        const auto fit_packet = ui::encode(7, 99, 2, fitted);
        CHECK(ui::validate(fit_packet.data(), fit_packet.size(), 7, 99, 1));
        CHECK(ui::get16(fit_packet.data() + 36) == fitted.width / 2);
    }
    ui::Model too_small = model;
    CHECK(!ui::fitToViewport(too_small, 320, 23));
    CHECK(!(too_small.flags & ui::Visible));
    CHECK(!ui::fitToViewport(too_small, 5, 24));
    CHECK(!ui::fitToViewport(too_small, 320, 240, UINT32_MAX));
    for (size_t n = 0; n < packet.size(); ++n)
        CHECK(!ui::validate(packet.data(), n, 7, 99, 0));
    CHECK(!ui::validate(nullptr, packet.size(), 7, 99, 0));
    CHECK(!ui::validate(packet.data(), packet.size() + 1, 7, 99, 0));
    CHECK(!ui::validate(packet.data(), packet.size(), 8, 99, 0));
    CHECK(!ui::validate(packet.data(), packet.size(), 7, 98, 0));
    CHECK(!ui::validate(packet.data(), packet.size(), 7, 99, 1));
    for (size_t offset : {size_t(0), size_t(4), size_t(6), size_t(38),
                          size_t(43), size_t(47), size_t(51), size_t(52),
                          size_t(54), size_t(56), size_t(60)}) {
        ui::Packet bad = packet;
        bad[offset] ^= 0x80;
        CHECK(!ui::validate(bad.data(), bad.size(), 7, 99, 0));
    }
    for (size_t offset : {size_t(29), size_t(30), size_t(31), size_t(33),
                          size_t(35), size_t(37)}) {
        ui::Packet bad = packet;
        bad[offset] = 0xff;
        CHECK(!ui::validate(bad.data(), bad.size(), 7, 99, 0));
    }
    for (unsigned width : {0u, 257u}) {
        auto bad = packet;
        ui::put16(bad.data() + 52, width);
        CHECK(!ui::validate(bad.data(), bad.size(), 7, 99, 0));
    }
    model.x = UINT32_MAX; model.y = UINT32_MAX; model.scale = UINT32_MAX;
    model.foreground = UINT32_MAX;
    auto bounded = ui::encode(7, 99, 2, model);
    CHECK(ui::validate(bounded.data(), bounded.size(), 7, 99, 1));
    CHECK(ui::get16(bounded.data() + 32) == 2047);
    CHECK(ui::get16(bounded.data() + 34) == 2047);
    CHECK(bounded[31] == 4 && bounded[43] == 0);
    model.state = ui::State::Hidden;
    auto hidden = ui::encode(7, 99, 3, model);
    CHECK(ui::get16(hidden.data() + 28) == 0);

    struct Sender {
        ui::Packet latest{};
        bool success = false;
        bool sendFileTx(const uint8_t* data, size_t length, uint8_t index) {
            CHECK(length == ui::kPacketBytes && index == 6);
            std::copy(data, data + length, latest.begin());
            return success;
        }
    } sender;
    uint32_t sequence = 0;
    CHECK(!ui::send(sender, 7, 99, sequence, model));
    CHECK(sequence == 0);
    sender.success = true;
    CHECK(ui::send(sender, 7, 99, sequence, model));
    CHECK(sequence == 1 && ui::get32(sender.latest.data() + 24) == 1);
    CHECK(!ui::send(sender, 7, 0, sequence, model));
    sequence = UINT32_MAX;
    CHECK(!ui::send(sender, 7, 99, sequence, model));

    // The command-plane API has no pixel pointer; publishing UI cannot dirty a
    // retained decoded I420 frame even while the same frame is paused/reused.
    std::vector<uint8_t> reference(320 * 240 * 3 / 2, 0x67);
    const auto before = reference;
    sequence = 1;
    for (auto state : {ui::State::Playing, ui::State::Paused, ui::State::Buffering,
                       ui::State::Error, ui::State::Hidden}) {
        model.state = state;
        CHECK(ui::send(sender, 7, 99, sequence, model));
    }
    CHECK(reference == before);
}

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

bool inside(const misterplex::OverlayRect& r, int x, int y) {
    return x >= r.x && y >= r.y && x < r.x + r.w && y < r.y + r.h;
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

} // namespace

int main() {
    using namespace misterplex;
    checkFpgaPackets();

    // 1. Deterministic rendering: exact RGB565 frame hash plus readable pixel checks.
    const Golden golden = loadGolden();
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

    if (fails) {
        std::fprintf(stderr, "test_playback_overlay: %d failure(s)\n", fails);
        return 1;
    }
    std::printf("test_playback_overlay: OK\n");
    return 0;
}
