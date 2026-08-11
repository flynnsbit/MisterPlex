#include "libmisterplex/path_mailbox.hpp"

#include <cstdio>
#include <cstdlib>
#include <string>

static int fails = 0;
#define CHECK(cond)                                                                              \
    do {                                                                                         \
        if (!(cond)) {                                                                           \
            std::fprintf(stderr, "FAIL %s:%d: %s\n", __FILE__, __LINE__, #cond);                 \
            ++fails;                                                                             \
        }                                                                                        \
    } while (0)

static uint64_t ctrlWord(uint16_t seq, uint8_t len,
                         uint32_t magic = misterplex::kPathMailboxMagic) {
    return static_cast<uint64_t>(magic) | (static_cast<uint64_t>(len) << 32) |
           (static_cast<uint64_t>(seq) << 48);
}

int main() {
    using namespace misterplex;

    CHECK(kPathMailboxMagic == 0x504C5850u);
    CHECK(kPathMailboxCtrlOff == 0x130u);
    CHECK(kPathMailboxPathOff == 0x138u);

    uint16_t seq = 0;
    uint8_t len = 0;
    CHECK(decodePathMailboxWord(ctrlWord(3, 42), seq, len));
    CHECK(seq == 3 && len == 42);
    CHECK(!decodePathMailboxWord(ctrlWord(1, 0), seq, len));
    CHECK(!decodePathMailboxWord(ctrlWord(1, 1, 0xDEADBEEFu), seq, len));
    CHECK(decodePathMailboxWord(ctrlWord(1, 200), seq, len));
    CHECK(seq == 1 && len == 200);
    CHECK(!decodePathMailboxWord(ctrlWord(1, 0), seq, len));

    const char* p = "/media/fat/Games/Plex/clip.mp4\n";
    auto s = pathFromBuffer(reinterpret_cast<const uint8_t*>(p), 32);
    CHECK(s == "/media/fat/Games/Plex/clip.mp4");

    PathMailboxEdgeDetector edge;
    std::string out;
    CHECK(!edge.accept(1, "/a.mp4", out)); // first sample ignored (stale)
    CHECK(out.empty());
    CHECK(!edge.accept(1, "/a.mp4", out)); // same seq
    CHECK(edge.accept(2, "/b.mp4", out));
    CHECK(out == "/b.mp4");

    if (fails) {
        std::fprintf(stderr, "%d FAIL(s)\n", fails);
        return 1;
    }
    std::printf("PASS test_path_mailbox\n");
    return 0;
}
