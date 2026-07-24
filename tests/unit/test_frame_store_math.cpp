// Sanity checks for Phase 3 frame_store sizing / RGB565 packing.
#include <cstdint>
#include <cstdio>
#include <cstdlib>

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

int main() {
    constexpr int W = 320, H = 240;
    constexpr int PIXELS = W * H;
    constexpr int BYTES = PIXELS * 2;
    CHECK(PIXELS == 76800);
    CHECK(BYTES == 153600);
    // Dual bank ~307200 bytes
    CHECK(BYTES * 2 == 307200);

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
