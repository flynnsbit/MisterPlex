// test_h264_level_limits.cpp — delivered level sizes DPB, not requested level.
#include "libmisterplex/h264_level_limits.hpp"

#include <cstdio>

using namespace misterplex;

static int fails = 0;
#define CHECK(c)                                                                                   \
    do {                                                                                           \
        if (!(c)) {                                                                                \
            std::fprintf(stderr, "FAIL %s:%d %s\n", __FILE__, __LINE__, #c);                       \
            ++fails;                                                                               \
        }                                                                                          \
    } while (0)

int main() {
    // Product request vs parent-measured delivery.
    CHECK(kPlexRequestedH264Level == 30);
    CHECK(kPlexDeliveredH264Level720p == 31);

    CHECK(h264FrameSizeMbs(1280, 720) == 3600u);
    CHECK(h264FrameSizeMbs(624, 480) == 1170u);
    CHECK(kPlex720pFrameSizeMbs == 3600u);

    // 720p illegal at requested Level 3.0 MaxFS=1620.
    CHECK(!h264FrameFitsLevel(30, 1280, 720));
    CHECK(h264MaxDpbFrames(30, 1280, 720) == 0u);
    CHECK(kDpbFrames720pIfSizedFromRequestL30 == 0u);

    // Delivered Level 3.1: fits exactly MaxFS, DPB = 5 frames.
    CHECK(h264FrameFitsLevel(31, 1280, 720));
    CHECK(h264MaxDpbFrames(31, 1280, 720) == 5u);
    CHECK(kDpbFrames720pFromDeliveredL31 == 5u);

    // 480p coded fits L3.0; DPB = floor(8100/1170)=6.
    CHECK(h264FrameFitsLevel(30, 624, 480));
    CHECK(h264MaxDpbFrames(30, 624, 480) == 6u);

    // NEG: sizing DPB from request for 720p under-counts fatally (0 slots).
    CHECK(h264MaxDpbFrames(kPlexRequestedH264Level, 1280, 720) == 0u);
    CHECK(h264MaxDpbFrames(kPlexDeliveredH264Level720p, 1280, 720) == 5u);
    CHECK(h264MaxDpbFrames(kPlexRequestedH264Level, 1280, 720) !=
          h264MaxDpbFrames(kPlexDeliveredH264Level720p, 1280, 720));

    // Bytes bound for endgame DPB (not present-bank count).
    CHECK(kDpb720pFrameBytes == 1382400u);
    CHECK(kDpb720pMaxBytesL31 == 5u * 1382400u);
    CHECK(kOptionCPresentBankCount == 2u);
    CHECK(kOptionCPresentBankCount != kDpbFrames720pFromDeliveredL31);

    // Unknown level → 0 (no invention).
    CHECK(h264MaxDpbFrames(99, 1280, 720) == 0u);

    if (fails) {
        std::fprintf(stderr, "FAILED %d\n", fails);
        return 1;
    }
    std::printf("test_h264_level_limits: OK\n");
    std::printf("  request_level=%d delivered_720p=%d fs720=%u dpb_L30=%u dpb_L31=%u\n",
                kPlexRequestedH264Level, kPlexDeliveredH264Level720p, kPlex720pFrameSizeMbs,
                h264MaxDpbFrames(30, 1280, 720), h264MaxDpbFrames(31, 1280, 720));
    std::printf("  present_banks=%u dpb_frames_L31=%u dpb_bytes_L31=%u\n",
                kOptionCPresentBankCount, kDpbFrames720pFromDeliveredL31, kDpb720pMaxBytesL31);
    return 0;
}
