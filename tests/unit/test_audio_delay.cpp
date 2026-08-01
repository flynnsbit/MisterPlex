// Host unit: conf AUDIO_DELAY_MS → filter string → PCM silence head.
// Pins the relationship the hardware A/B could not see (only conf intent was logged).
#include "libmisterplex/audio_delay.hpp"
#include "libmisterplex/mraudio_status.hpp"

#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstring>
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

static std::vector<int16_t> makePcm(int silenceMs, int toneMs, int sr = 48000) {
    const int silFrames = silenceMs * sr / 1000;
    const int toneFrames = toneMs * sr / 1000;
    std::vector<int16_t> out(static_cast<size_t>(silFrames + toneFrames) * 2, 0);
    for (int i = 0; i < toneFrames; ++i) {
        // Loud DC-ish step so the abs-threshold detector trips immediately.
        out[static_cast<size_t>(silFrames + i) * 2] = 8000;
        out[static_cast<size_t>(silFrames + i) * 2 + 1] = 8000;
    }
    return out;
}

int main() {
    using namespace misterplex;

    // --- filter string (conf → applied argv) ---
    CHECK(ffmpegAudioDelayFilter(0) == "aresample=48000");
    CHECK(ffmpegAudioDelayFilter(-9) == "aresample=48000");
    CHECK(ffmpegAudioDelayFilter(150) == "aresample=48000,adelay=150|150");
    CHECK(ffmpegAudioDelayFilter(60) == "aresample=48000,adelay=60|60");
    // Must NOT use :all=1 alone — portable | form is the product contract.
    CHECK(ffmpegAudioDelayFilter(150).find("all=") == std::string::npos);

    // --- model: full content authority; prefill cancels nothing ---
    CHECK(adelayContentShiftMs(150) == 150);
    CHECK(adelayContentShiftMs(0) == 0);
    CHECK(adelayContentShiftMs(-1) == 0);
    CHECK(adelayCancelledByPrefillMs(150, 100) == 0);
    CHECK(adelayCancelledByPrefillMs(150, static_cast<int>(kFeedTargetBytes * 1000 /
                                                           kMrAudioBytesPerSec)) == 0);

    // --- silence head on synthetic PCM ---
    {
        auto pcm = makePcm(/*silenceMs=*/150, /*toneMs=*/50);
        const int64_t nFrames = static_cast<int64_t>(pcm.size() / 2);
        const int64_t head = pcmSilenceHeadMs(pcm.data(), nFrames);
        CHECK(head == 150);
    }
    {
        auto pcm = makePcm(0, 50);
        CHECK(pcmSilenceHeadMs(pcm.data(), static_cast<int64_t>(pcm.size() / 2)) == 0);
    }
    {
        auto pcm = makePcm(33, 20);
        CHECK(pcmSilenceHeadMs(pcm.data(), static_cast<int64_t>(pcm.size() / 2)) == 33);
    }
    // could-not-measure
    CHECK(pcmSilenceHeadMs(nullptr, 100) == -1);
    CHECK(pcmSilenceHeadMs(makePcm(10, 10).data(), 0) == -1);

    // --- incremental scanner (pump path) ---
    {
        SilenceHeadScan scan;
        scan.reset(500, 48000, 2000);
        auto pcm = makePcm(150, 50);
        // Feed in 20 ms chunks (3840 bytes = 960 frames = 20 ms @ 48k stereo)
        const size_t chunkFrames = 960;
        bool finished = false;
        for (size_t off = 0; off + chunkFrames * 2 <= pcm.size(); off += chunkFrames * 2) {
            finished = scan.feed(pcm.data() + off, chunkFrames * 4);
            if (finished)
                break;
        }
        CHECK(finished);
        CHECK(scan.done);
        CHECK(scan.headMs == 150);
    }
    // conf 150 → predicted shift 150; measured head on matching PCM 150 (pins relationship)
    {
        const int conf = 150;
        CHECK(adelayContentShiftMs(conf) == conf);
        auto pcm = makePcm(conf, 40);
        CHECK(pcmSilenceHeadMs(pcm.data(), static_cast<int64_t>(pcm.size() / 2)) == conf);
    }

    if (fails) {
        std::fprintf(stderr, "test_audio_delay: %d FAIL(s)\n", fails);
        return 1;
    }
    std::printf("PASS test_audio_delay conf→filter→silence_head + prefill-cancel=0\n");
    return 0;
}
