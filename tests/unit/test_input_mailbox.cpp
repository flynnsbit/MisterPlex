#include "libmisterplex/input_mailbox.hpp"

#include <cstdio>
#include <cstdlib>
#include <string>
#include <vector>

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

static uint64_t frameWord(uint8_t seq, uint8_t debug, uint16_t underrun,
                          uint32_t magic = misterplex::kUnderrunMailboxMagic) {
    return static_cast<uint64_t>(magic) | (static_cast<uint64_t>(seq) << 32) |
           (static_cast<uint64_t>(debug) << 40) | (static_cast<uint64_t>(underrun) << 48);
}

struct FakeTransport {
    bool playing = true;
    bool paused = false;
    int64_t pos = 0;
    int64_t dur = 120000;
    int pauses = 0;
    int resumes = 0;
    int stops = 0;
    std::vector<int64_t> seeks;

    misterplex::PlaybackTransportState state() const { return {playing, paused, pos, dur}; }

    int calls() const {
        return pauses + resumes + stops + static_cast<int>(seeks.size());
    }

    void pause() {
        ++pauses;
        paused = true;
    }

    void resume() {
        ++resumes;
        paused = false;
    }

    void stop() {
        ++stops;
        playing = false;
    }

    void seekMs(int64_t ms) {
        seeks.push_back(ms);
        pos = ms;
    }
};

static bool pollWord(misterplex::InputMailboxEdgeDetector& edge, FakeTransport& transport,
                     uint64_t firstRead, uint64_t secondRead, int64_t nowMs = 1000,
                     int64_t ignoreUntilMs = 0) {
    using namespace misterplex;
    InputMailboxSample sample;
    if (!decodeStableInputMailbox(lo(firstRead), hi(firstRead), lo(secondRead), hi(secondRead),
                                  sample)) {
        if (lo(firstRead) == lo(secondRead) && hi(firstRead) == hi(secondRead) &&
            lo(firstRead) != kInputMailboxMagic) {
            edge.noteNoValidWord();
        }
        return false;
    }
    PlaybackCommand cmd = PlaybackCommand::None;
    if (!edge.accept(sample, cmd))
        return false;
    const int before = transport.calls();
    (void)dispatchPlaybackCommand(cmd, transport.state(), 30000, 10000, nowMs, ignoreUntilMs,
                                  transport);
    return transport.calls() != before;
}

int main() {
    using namespace misterplex;

    CHECK(kDdrStatusMailboxPhys == 0x3007F100u);
    CHECK(kDdrStatusMailboxMagic == 0x504C5853u);
    CHECK(kInputMailboxPhys == 0x3007F108u);
    CHECK(kInputMailboxMagic == 0x504C5849u);
    CHECK(kMemtestMailboxPhys == 0x3007F110u);
    CHECK(kMemtestMailboxMagic == 0x504C584Du);
    CHECK(kUnderrunMailboxPhys == 0x3007F118u);
    CHECK(kUnderrunMailboxMagic == 0x504C5846u);
    CHECK(kBankReleaseMailboxPhys == 0x3007F128u);
    CHECK(kBankReleaseMailboxMagic == 0x504C5844u);
    CHECK(kFrameStoreDebugFormatError == 0xE1u);

    InputMailboxSample s;
    CHECK(decodeInputMailboxWord(word(1, 1, PlaybackCommand::None), s));
    CHECK(s.command == PlaybackCommand::None);
    CHECK(decodeInputMailboxWord(word(2, 2, PlaybackCommand::PlayPause), s));
    CHECK(s.command == PlaybackCommand::PlayPause);
    CHECK(decodeInputMailboxWord(word(3, 3, PlaybackCommand::Stop), s));
    CHECK(s.command == PlaybackCommand::Stop);
    CHECK(decodeInputMailboxWord(word(7, 9, PlaybackCommand::SkipForward), s));
    CHECK(s.seq == 7);
    CHECK(s.cmdSeq == 9);
    CHECK(s.command == PlaybackCommand::SkipForward);
    CHECK(decodeInputMailboxWord(word(8, 10, PlaybackCommand::SkipBack), s));
    CHECK(s.command == PlaybackCommand::SkipBack);
    CHECK(!decodeInputMailboxWord(word(7, 9, PlaybackCommand::SkipForward, 0xDEADBEEFu), s));
    CHECK(!decodeInputMailboxWord(static_cast<uint64_t>(kInputMailboxMagic) |
                                      (static_cast<uint64_t>(0x7Fu) << 32),
                                  s));

    FrameStoreStatus fs;
    CHECK(decodeFrameStoreStatusWord(frameWord(4, kFrameStoreDebugFormatError, 17), fs));
    CHECK(fs.seq == 4);
    CHECK(fs.debug_state == kFrameStoreDebugFormatError);
    CHECK(fs.underrun_count == 17);
    CHECK(fs.nonYuvDoorbellRejected());
    CHECK(std::string(frameStoreDebugDescription(fs.debug_state)) ==
          "frame store refused non-YUV doorbell (0xE1)");
    CHECK(std::string(frameStoreStatusUnavailableDescription()) ==
          "frame store status unavailable (PLXF mailbox absent/unwritten)");
    CHECK(!decodeFrameStoreStatusWord(frameWord(4, kFrameStoreDebugFormatError, 17, 0), fs));
    CHECK(decodeStableFrameStoreStatus(lo(frameWord(5, 0x23, 7)),
                                       hi(frameWord(5, 0x23, 7)),
                                       lo(frameWord(5, 0x23, 7)),
                                       hi(frameWord(5, 0x23, 7)), fs));
    CHECK(fs.seq == 5 && fs.debug_state == 0x23 && fs.underrun_count == 7);
    CHECK(!decodeStableFrameStoreStatus(lo(frameWord(5, 0x23, 7)),
                                        hi(frameWord(5, 0x23, 7)),
                                        lo(frameWord(6, 0x23, 7)),
                                        hi(frameWord(6, 0x23, 7)), fs));

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

    {
        InputMailboxEdgeDetector ed;
        FakeTransport tr;
        CHECK(!pollWord(ed, tr, word(1, 1, PlaybackCommand::SkipForward, 0), // bad magic
                        word(1, 1, PlaybackCommand::SkipForward, 0)));
        CHECK(tr.calls() == 0);
        CHECK(pollWord(ed, tr, word(1, 1, PlaybackCommand::SkipForward),
                       word(1, 1, PlaybackCommand::SkipForward)));
        CHECK(tr.seeks.size() == 1 && tr.seeks.back() == 30000);
        for (int i = 0; i < 5; ++i) {
            CHECK(!pollWord(ed, tr, word(1, 1, PlaybackCommand::SkipForward),
                            word(1, 1, PlaybackCommand::SkipForward)));
        }
        CHECK(tr.seeks.size() == 1); // stale repeated mailbox word fires zero more times
        CHECK(pollWord(ed, tr, word(2, 2, PlaybackCommand::SkipForward),
                       word(2, 2, PlaybackCommand::SkipForward)));
        CHECK(pollWord(ed, tr, word(3, 3, PlaybackCommand::SkipForward),
                       word(3, 3, PlaybackCommand::SkipForward)));
        CHECK(tr.seeks.size() == 3); // identical cmd, new cmd_seq -> one dispatch each
        CHECK(tr.seeks[0] == 30000 && tr.seeks[1] == 60000 && tr.seeks[2] == 90000);
    }

    {
        InputMailboxEdgeDetector ed;
        FakeTransport tr;
        const uint64_t oldHalf = word(10, 10, PlaybackCommand::Stop);
        const uint64_t newHalf = word(11, 11, PlaybackCommand::Stop);
        CHECK(!pollWord(ed, tr, oldHalf, newHalf)); // torn seq/cmd_seq read
        CHECK(tr.calls() == 0);
        CHECK(!pollWord(ed, tr, word(12, 12, PlaybackCommand::PlayPause),
                        word(12, 12, PlaybackCommand::Stop))); // inconsistent command half
        CHECK(tr.calls() == 0);
    }

    {
        InputMailboxEdgeDetector ed;
        FakeTransport tr;
        CHECK(!pollWord(ed, tr, word(1, 1, PlaybackCommand::Stop, 0x12345678u),
                        word(1, 1, PlaybackCommand::Stop, 0x12345678u)));
        CHECK(tr.calls() == 0);
    }

    {
        InputMailboxEdgeDetector ed;
        FakeTransport tr;
        ed.noteNoValidWord();
        tr.pos = 10000;
        CHECK(pollWord(ed, tr, word(20, 255, PlaybackCommand::SkipBack),
                       word(20, 255, PlaybackCommand::SkipBack)));
        tr.pos = 50000;
        CHECK(pollWord(ed, tr, word(21, 0, PlaybackCommand::SkipBack),
                       word(21, 0, PlaybackCommand::SkipBack)));
        CHECK(tr.seeks.size() == 2);
        CHECK(tr.seeks[0] == 0);
        CHECK(tr.seeks[1] == 40000); // 255->0 is one normal event, not 255 events
    }

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

    {
        FakeTransport tr;
        (void)dispatchPlaybackCommand(PlaybackCommand::PlayPause, tr.state(), 30000, 10000, 1000,
                                      0, tr);
        CHECK(tr.paused);
        CHECK(tr.pauses == 1);
        (void)dispatchPlaybackCommand(PlaybackCommand::PlayPause, tr.state(), 30000, 10000, 1000,
                                      0, tr);
        CHECK(!tr.paused);
        CHECK(tr.resumes == 1);
    }

    {
        FakeTransport tr;
        tr.pos = 5000;
        (void)dispatchPlaybackCommand(PlaybackCommand::SkipBack, tr.state(), 30000, 10000, 1000,
                                      0, tr);
        CHECK(tr.seeks.size() == 1 && tr.seeks.back() == 0);
        tr.pos = 119000;
        tr.dur = 120000;
        (void)dispatchPlaybackCommand(PlaybackCommand::SkipForward, tr.state(), 30000, 10000,
                                      1000, 0, tr);
        CHECK(tr.seeks.size() == 2 && tr.seeks.back() == 120000);
    }

    {
        FakeTransport tr;
        (void)dispatchPlaybackCommand(PlaybackCommand::Stop, tr.state(), 30000, 10000, 1000,
                                      1500, tr);
        CHECK(tr.calls() == 0);
        CHECK(tr.playing);
        (void)dispatchPlaybackCommand(PlaybackCommand::Stop, tr.state(), 30000, 10000, 1500,
                                      1500, tr);
        CHECK(tr.stops == 1);
        CHECK(!tr.playing);
    }

    // --- PLXD bank-release mailbox tests ---
    {
        BankReleaseStatus br;

        // Helper: build a PLXD word matching w-a3's RTL layout (b187df5).
        // [31:0]=magic, [33:32]=free_bank_mask, [34]=disp_bank,
        // [35]=swap_pending, [63:48]=frames_done
        auto plxd = [](uint8_t fbm, uint8_t db, bool sp, uint16_t fd) -> uint64_t {
            return static_cast<uint64_t>(kBankReleaseMailboxMagic) |
                   (static_cast<uint64_t>(fbm & 3u) << 32) |
                   (static_cast<uint64_t>(db & 1u) << 34) |
                   (static_cast<uint64_t>(sp ? 1u : 0u) << 35) |
                   (static_cast<uint64_t>(fd) << 48);
        };

        // Bank 0 free, disp_bank=1, no swap pending, frames_done=42
        const uint64_t w1 = plxd(0x01, 1, false, 42);
        CHECK(decodeBankReleaseWord(w1, br));
        CHECK(br.free_bank_mask == 0x01);
        CHECK(br.bank0Free());
        CHECK(!br.bank1Free());
        CHECK(br.anyFree());
        CHECK(br.freeBank() == 0);
        CHECK(br.disp_bank == 1);
        CHECK(!br.swap_pending);
        CHECK(br.frames_done == 42);

        // Bank 1 free, disp_bank=0, swap pending, frames_done=1000
        const uint64_t w2 = plxd(0x02, 0, true, 1000);
        CHECK(decodeBankReleaseWord(w2, br));
        CHECK(br.free_bank_mask == 0x02);
        CHECK(!br.bank0Free());
        CHECK(br.bank1Free());
        CHECK(br.freeBank() == 1);
        CHECK(br.disp_bank == 0);
        CHECK(br.swap_pending);
        CHECK(br.frames_done == 1000);

        // Both banks free (idle — no pending frame)
        const uint64_t w3 = plxd(0x03, 0, false, 500);
        CHECK(decodeBankReleaseWord(w3, br));
        CHECK(br.free_bank_mask == 0x03);
        CHECK(br.bank0Free() && br.bank1Free());
        CHECK(br.freeBank() == 0); // picks lowest

        // No bank free (both in use — swap pending)
        const uint64_t w4 = plxd(0x00, 1, true, 99);
        CHECK(decodeBankReleaseWord(w4, br));
        CHECK(br.free_bank_mask == 0x00);
        CHECK(!br.anyFree());
        CHECK(br.freeBank() == -1);
        CHECK(br.swap_pending);

        // Bad magic
        CHECK(!decodeBankReleaseWord(0xDEADBEEFu, br));

        // Stable decode
        CHECK(decodeStableBankRelease(lo(w1), hi(w1), lo(w1), hi(w1), br));
        CHECK(br.bank0Free() && br.disp_bank == 1);

        // Torn read
        CHECK(!decodeStableBankRelease(lo(w1), hi(w1), lo(w2), hi(w2), br));

        // --- Independent RTL cross-check ---
        // This word is constructed from the RTL packing expression in
        // ddr_frame_store.sv (b187df5), NOT from the spec constants.
        // It proves the C++ decoder matches what the FPGA actually writes,
        // not just that the codec is self-consistent.
        //
        // RTL packing (from ddr_frame_store.sv line 829-837):
        //   DDRAM_DIN <= {bank_vsync_count,           // [63:48]
        //                 12'd0,                       // [47:36]
        //                 swap_pending_d2,             // [35]
        //                 disp_bank_d2,                // [34]
        //                 swap_pending_d2 ? 2'b00 :    // [33:32]
        //                   (disp_bank_d2 ? 2'b01 : 2'b10),
        //                 MAGIC_D};                    // [31:0]
        //
        // Test case: disp_bank=1, swap_pending=0, bank_vsync_count=7
        //   free_bank_mask = disp_bank ? 0b01 : 0b10 = 0b01
        //   bits: [63:48]=7, [35]=0, [34]=1, [33:32]=01, [31:0]=0x504C5844
        //   upper word = (7 << 16) | (0 << 3) | (1 << 2) | 0x01 = 0x00070005
        //   full word  = 0x0007000500000000 | 0x504C5844
        constexpr uint64_t rtl_word_a = 0x0007000500000000ull | 0x504C5844ull;
        CHECK(decodeBankReleaseWord(rtl_word_a, br));
        CHECK(br.free_bank_mask == 0x01);
        CHECK(br.bank0Free());
        CHECK(!br.bank1Free());
        CHECK(br.disp_bank == 1);
        CHECK(!br.swap_pending);
        CHECK(br.frames_done == 7);

        // Test case: disp_bank=0, swap_pending=1, bank_vsync_count=0x1234
        //   free_bank_mask = swap_pending ? 0b00 : ... = 0b00
        //   bits: [63:48]=0x1234, [35]=1, [34]=0, [33:32]=00, [31:0]=0x504C5844
        //   upper word = (0x1234 << 16) | (1 << 3) | (0 << 2) | 0x00 = 0x12340008
        //   full word  = 0x1234000800000000 | 0x504C5844
        constexpr uint64_t rtl_word_b = 0x1234000800000000ull | 0x504C5844ull;
        CHECK(decodeBankReleaseWord(rtl_word_b, br));
        CHECK(br.free_bank_mask == 0x00);
        CHECK(!br.anyFree());
        CHECK(br.freeBank() == -1);
        CHECK(br.disp_bank == 0);
        CHECK(br.swap_pending);
        CHECK(br.frames_done == 0x1234);

        // Test case: disp_bank=0, swap_pending=0, bank_vsync_count=0xFFFF
        //   free_bank_mask = 0 ? 0b01 : 0b10 = 0b10
        //   bits: [63:48]=0xFFFF, [35]=0, [34]=0, [33:32]=10, [31:0]=0x504C5844
        //   upper word = (0xFFFF << 16) | (0 << 3) | (0 << 2) | 0x02 = 0xFFFF0002
        //   full word  = 0xFFFF000200000000 | 0x504C5844
        constexpr uint64_t rtl_word_c = 0xFFFF000200000000ull | 0x504C5844ull;
        CHECK(decodeBankReleaseWord(rtl_word_c, br));
        CHECK(br.free_bank_mask == 0x02);
        CHECK(!br.bank0Free());
        CHECK(br.bank1Free());
        CHECK(br.freeBank() == 1);
        CHECK(br.disp_bank == 0);
        CHECK(!br.swap_pending);
        CHECK(br.frames_done == 0xFFFF);

        // --- ARM bank-release policy ---
        // Operand A: initial/final PLXD samples. Operand B: host-planned bank.
        // Covers bank choice and stale-release classification only; it does not
        // cover real /dev/mem timing or the RTL allocator itself.
        {
            BankReleasePolicyState policy{};
            BankReleaseDecision d =
                chooseDdrPresentBankFromRelease(policy, 1,
                                                BankReleaseStatus{0x01, 1, false, 42},
                                                BankReleaseStatus{0x01, 1, false, 42});
            CHECK(d.kind == BankReleaseDecisionKind::UseFreeBank);
            CHECK(d.bank == 0);
            CHECK(!policy.release_stuck);
        }
        {
            BankReleasePolicyState policy{};
            BankReleaseDecision d =
                chooseDdrPresentBankFromRelease(policy, 1,
                                                BankReleaseStatus{0x00, 0, true, 100},
                                                BankReleaseStatus{0x00, 0, true, 100});
            CHECK(d.kind == BankReleaseDecisionKind::SkipFrame);
            CHECK(d.bank == -1);
            CHECK(!policy.release_stuck);
        }
        {
            BankReleasePolicyState policy{};
            BankReleaseDecision d =
                chooseDdrPresentBankFromRelease(policy, 1,
                                                BankReleaseStatus{0x00, 0, true, 100},
                                                BankReleaseStatus{0x00, 0, true, 101});
            CHECK(d.kind == BankReleaseDecisionKind::UseTimedFallback);
            CHECK(d.bank == 1);
            CHECK(d.release_stuck);
            CHECK(policy.release_stuck);

            d = chooseDdrPresentBankFromRelease(policy, 0,
                                                BankReleaseStatus{0x00, 0, true, 102},
                                                BankReleaseStatus{0x00, 0, true, 102});
            CHECK(d.kind == BankReleaseDecisionKind::UseTimedFallback);
            CHECK(d.bank == 0);
            CHECK(policy.release_stuck);

            d = chooseDdrPresentBankFromRelease(policy, 0,
                                                BankReleaseStatus{0x02, 0, false, 103},
                                                BankReleaseStatus{0x02, 0, false, 103});
            CHECK(d.kind == BankReleaseDecisionKind::UseFreeBank);
            CHECK(d.bank == 1);
            CHECK(!d.release_stuck);
            CHECK(!policy.release_stuck);
        }

        // --- Permanently silent fabric must not wedge the host forever ---
        // free_bank_mask stuck at 0 AND frames_done frozen is indistinguishable
        // from "busy" for one frame, and from "dead" after a second. Because a
        // skip means the host neither writes nor rings the doorbell, an
        // unbounded skip is self-sustaining: the fabric can never change its
        // mind, so the next read is identical, so we skip again. Forever.
        {
            BankReleasePolicyState policy{};
            const BankReleaseStatus dead{0x00, 0, false, 7}; // frozen, nothing free
            int skips = 0;
            BankReleaseDecision d{};
            for (int i = 0; i < kBankReleaseSkipLimitFrames + 5; ++i) {
                d = chooseDdrPresentBankFromRelease(policy, 1, dead, dead);
                if (d.kind == BankReleaseDecisionKind::SkipFrame) {
                    ++skips;
                    continue;
                }
                break;
            }
            // Skipping is still the first response -- backpressure is real.
            CHECK(skips > 0);
            CHECK(skips < kBankReleaseSkipLimitFrames + 5);
            // But it is bounded, and the escape writes a bank rather than
            // waiting on a handshake that is not coming.
            CHECK(d.kind == BankReleaseDecisionKind::UseTimedFallback);
            CHECK(d.bank == 1);
            CHECK(policy.release_stuck);

            // And it stays escaped while the fabric stays silent...
            d = chooseDdrPresentBankFromRelease(policy, 0, dead, dead);
            CHECK(d.kind == BankReleaseDecisionKind::UseTimedFallback);
            CHECK(d.bank == 0);

            // ...but heals the moment the fabric releases a bank again.
            d = chooseDdrPresentBankFromRelease(policy, 0,
                                                BankReleaseStatus{0x02, 0, false, 8},
                                                BankReleaseStatus{0x02, 0, false, 8});
            CHECK(d.kind == BankReleaseDecisionKind::UseFreeBank);
            CHECK(d.bank == 1);
            CHECK(!policy.release_stuck);
            CHECK(policy.consecutive_skips == 0);
        }

        // --- A slow feed must not be able to outlive the frame bound ---
        // The frame bound is not a clock. On a half-built fabric during
        // bring-up the feed can run at a few frames per second, where 30 skips
        // is tens of seconds of a frozen screen. The wall-clock deadline must
        // escape first in that case.
        {
            BankReleasePolicyState policy{};
            const BankReleaseStatus dead{0x00, 0, false, 7};
            double t = 1000.0;
            BankReleaseDecision d{};
            int skips = 0;
            for (int i = 0; i < 8; ++i) {
                d = chooseDdrPresentBankFromRelease(policy, 1, dead, dead, t);
                if (d.kind != BankReleaseDecisionKind::SkipFrame)
                    break;
                ++skips;
                t += 120.0;  // ~8 fps
            }
            CHECK(d.kind == BankReleaseDecisionKind::UseTimedFallback);
            CHECK(d.bank == 1);
            CHECK(policy.release_stuck);
            // Escaped on time, well before the frame bound could have expired.
            CHECK(skips < kBankReleaseSkipLimitFrames);
            CHECK(skips * 120.0 >= kBankReleaseSkipLimitMs - 120.0);
        }

        // The deadline must not fire inside a legitimate busy window: a fabric
        // that is briefly busy at 60 Hz stays skipped, not guessed.
        {
            BankReleasePolicyState policy{};
            const BankReleaseStatus busy{0x00, 0, true, 500};
            double t = 5000.0;
            for (int i = 0; i < 20; ++i) {
                BankReleaseDecision d =
                    chooseDdrPresentBankFromRelease(policy, 1, busy, busy, t);
                CHECK(d.kind == BankReleaseDecisionKind::SkipFrame);
                t += 16.7;
            }
            CHECK(!policy.release_stuck);
        }

        // The deadline is per run of consecutive skips, not per session: an
        // isolated skip every few seconds must never accumulate into an escape.
        {
            BankReleasePolicyState policy{};
            const BankReleaseStatus dead{0x00, 0, false, 7};
            const BankReleaseStatus freeb{0x01, 0, false, 7};
            double t = 0.0;
            for (int i = 0; i < 10; ++i) {
                BankReleaseDecision d =
                    chooseDdrPresentBankFromRelease(policy, 1, dead, dead, t);
                CHECK(d.kind == BankReleaseDecisionKind::SkipFrame);
                t += 3000.0;
                d = chooseDdrPresentBankFromRelease(policy, 1, freeb, freeb, t);
                CHECK(d.kind == BankReleaseDecisionKind::UseFreeBank);
                CHECK(policy.first_skip_ms < 0.0);
                t += 33.0;
            }
            CHECK(!policy.release_stuck);
        }

        // No clock available: the frame bound must still apply on its own.
        {
            BankReleasePolicyState policy{};
            const BankReleaseStatus dead{0x00, 0, false, 7};
            BankReleaseDecision d{};
            for (int i = 0; i < kBankReleaseSkipLimitFrames + 2; ++i) {
                d = chooseDdrPresentBankFromRelease(policy, 1, dead, dead, -1.0);
                if (d.kind != BankReleaseDecisionKind::SkipFrame)
                    break;
            }
            CHECK(d.kind == BankReleaseDecisionKind::UseTimedFallback);
            CHECK(policy.release_stuck);
        }

        // A busy fabric that recovers within the window must NOT be escaped:
        // the bound must not turn legitimate backpressure into a bank guess.
        {
            BankReleasePolicyState policy{};
            const BankReleaseStatus busy{0x00, 0, true, 500};
            for (int i = 0; i < kBankReleaseSkipLimitFrames - 1; ++i) {
                BankReleaseDecision d =
                    chooseDdrPresentBankFromRelease(policy, 1, busy, busy);
                CHECK(d.kind == BankReleaseDecisionKind::SkipFrame);
            }
            CHECK(!policy.release_stuck);
            BankReleaseDecision d =
                chooseDdrPresentBankFromRelease(policy, 1,
                                                BankReleaseStatus{0x01, 0, false, 500},
                                                BankReleaseStatus{0x01, 0, false, 500});
            CHECK(d.kind == BankReleaseDecisionKind::UseFreeBank);
            CHECK(d.bank == 0);
            // The counter must reset, or a run of isolated busy frames spread
            // across a whole session would eventually trip the escape.
            CHECK(policy.consecutive_skips == 0);
        }
    }

    if (fails) {
        std::fprintf(stderr, "test_input_mailbox: %d failure(s)\n", fails);
        return 1;
    }

    // --- Degeneracy assertions (instrument-integrity #18) ---
    // Verify that different PLXD inputs produce observably different outputs.
    // If a broken decoder returned the same thing for all inputs, the earlier
    // tests would still pass if both expected and actual were identical garbage.
    {
        // Three distinct raw words with different free_bank_mask, disp_bank, frames_done
        constexpr uint64_t w1 = 0x0001000100000000ull | 0x504C5844ull; // frames_done=1, mask=01
        constexpr uint64_t w2 = 0x0002000600000000ull | 0x504C5844ull; // frames_done=2, mask=10, disp_bank=1
        constexpr uint64_t w3 = 0x000A000B00000000ull | 0x504C5844ull; // frames_done=10, mask=11, swap_pend=1

        BankReleaseStatus r1{}, r2{}, r3{};
        CHECK(decodeBankReleaseWord(w1, r1));
        CHECK(decodeBankReleaseWord(w2, r2));
        CHECK(decodeBankReleaseWord(w3, r3));

        // Assert outputs are NOT all equal — i.e. decoder actually differentiates
        bool all_same = (r1.frames_done == r2.frames_done) &&
                        (r2.frames_done == r3.frames_done) &&
                        (r1.free_bank_mask == r2.free_bank_mask) &&
                        (r2.free_bank_mask == r3.free_bank_mask) &&
                        (r1.disp_bank == r2.disp_bank) &&
                        (r2.disp_bank == r3.disp_bank);
        if (all_same) {
            std::fprintf(stderr,
                         "DEGENERACY: three distinct PLXD words produced identical outputs\n");
            ++fails;
        }
        // Assert a wrong-magic word FAILS decode — not everything passes
        constexpr uint64_t bad_magic = 0x0001000100000000ull | 0xDEADBEEFull;
        BankReleaseStatus rbad{};
        CHECK(!decodeBankReleaseWord(bad_magic, rbad));
    }

    if (fails) {
        std::fprintf(stderr, "test_input_mailbox: %d DEGENERACY failure(s)\n", fails);
        return 1;
    }

    std::printf("test_input_mailbox: OK\n");
    return 0;
}
