#include "libmisterplex/input_mailbox.hpp"

#include <cstdio>
#include <cstdlib>

static int fails = 0;
#define CHECK(cond)                                                                              \
    do {                                                                                         \
        if (!(cond)) {                                                                           \
            std::fprintf(stderr, "FAIL %s:%d: %s\n", __FILE__, __LINE__, #cond);                 \
            ++fails;                                                                             \
        }                                                                                        \
    } while (0)

static uint64_t word(uint16_t seq, uint8_t cmdSeq, misterplex::PlaybackCommand cmd,
                     uint32_t magic = misterplex::kInputMailboxMagic) {
    return static_cast<uint64_t>(magic) |
           (static_cast<uint64_t>(static_cast<uint8_t>(cmd)) << 32) |
           (static_cast<uint64_t>(cmdSeq) << 40) | (static_cast<uint64_t>(seq) << 48);
}

static uint32_t lo(uint64_t v) { return static_cast<uint32_t>(v); }
static uint32_t hi(uint64_t v) { return static_cast<uint32_t>(v >> 32); }

int main() {
    using namespace misterplex;

    InputMailboxSample s;
    CHECK(decodeInputMailboxWord(word(7, 9, PlaybackCommand::SkipForward), s));
    CHECK(s.seq == 7);
    CHECK(s.cmdSeq == 9);
    CHECK(s.command == PlaybackCommand::SkipForward);
    CHECK(!decodeInputMailboxWord(word(7, 9, PlaybackCommand::SkipForward, 0xDEADBEEFu), s));
    CHECK(!decodeInputMailboxWord(static_cast<uint64_t>(kInputMailboxMagic) |
                                      (static_cast<uint64_t>(0x7Fu) << 32),
                                  s));

    const uint64_t good = word(10, 1, PlaybackCommand::PlayPause);
    CHECK(decodeStableInputMailbox(lo(good), hi(good), lo(good), hi(good), s));
    CHECK(!decodeStableInputMailbox(lo(good), hi(good), lo(good) ^ 1u, hi(good), s));
    CHECK(!decodeStableInputMailbox(lo(good), hi(good), lo(good), hi(good) ^ 0x10000u, s));

    InputMailboxEdgeDetector edge;
    PlaybackCommand cmd = PlaybackCommand::None;
    CHECK(!edge.accept({1, 1, PlaybackCommand::PlayPause}, cmd)); // first valid word is stale
    CHECK(cmd == PlaybackCommand::None);
    CHECK(!edge.accept({1, 1, PlaybackCommand::PlayPause}, cmd)); // non-zero cmd alone is not enough
    CHECK(edge.accept({2, 2, PlaybackCommand::PlayPause}, cmd));
    CHECK(cmd == PlaybackCommand::PlayPause);
    CHECK(edge.accept({3, 3, PlaybackCommand::PlayPause}, cmd)); // repeated same command
    CHECK(cmd == PlaybackCommand::PlayPause);
    CHECK(!edge.accept({3, 4, PlaybackCommand::Stop}, cmd)); // seq must advance too
    CHECK(!edge.accept({4, 4, PlaybackCommand::None}, cmd));
    CHECK(edge.accept({5, 255, PlaybackCommand::SkipForward}, cmd));
    CHECK(cmd == PlaybackCommand::SkipForward);
    CHECK(edge.accept({6, 0, PlaybackCommand::SkipBack}, cmd)); // cmd_seq wrap 255->0
    CHECK(cmd == PlaybackCommand::SkipBack);
    edge.reset();
    edge.noteNoValidWord();
    CHECK(edge.accept({1, 1, PlaybackCommand::Stop}, cmd)); // no stale magic before first command
    CHECK(cmd == PlaybackCommand::Stop);

    auto a = mapPlaybackCommand(PlaybackCommand::PlayPause, true, false, 1000, 10000, 30000,
                                10000);
    CHECK(a.kind == PlaybackActionKind::Pause);
    a = mapPlaybackCommand(PlaybackCommand::PlayPause, true, true, 1000, 10000, 30000, 10000);
    CHECK(a.kind == PlaybackActionKind::Resume);
    a = mapPlaybackCommand(PlaybackCommand::Stop, true, false, 1000, 10000, 30000, 10000);
    CHECK(a.kind == PlaybackActionKind::Stop);
    a = mapPlaybackCommand(PlaybackCommand::SkipForward, true, false, 1000, 45000, 30000,
                            10000);
    CHECK(a.kind == PlaybackActionKind::Seek);
    CHECK(a.seekTargetMs == 31000);
    a = mapPlaybackCommand(PlaybackCommand::SkipForward, true, false, 40000, 45000, 30000,
                            10000);
    CHECK(a.kind == PlaybackActionKind::Seek);
    CHECK(a.seekTargetMs == 45000);
    a = mapPlaybackCommand(PlaybackCommand::SkipBack, true, false, 5000, 45000, 30000, 10000);
    CHECK(a.kind == PlaybackActionKind::Seek);
    CHECK(a.seekTargetMs == 0);
    a = mapPlaybackCommand(PlaybackCommand::SkipBack, true, false, 0, 45000, 30000, 10000);
    CHECK(a.kind == PlaybackActionKind::None);
    a = mapPlaybackCommand(PlaybackCommand::SkipForward, false, false, 1000, 45000, 30000,
                            10000);
    CHECK(a.kind == PlaybackActionKind::None);

    if (fails) {
        std::fprintf(stderr, "test_input_mailbox: %d failure(s)\n", fails);
        return 1;
    }
    std::printf("test_input_mailbox: OK\n");
    return 0;
}
