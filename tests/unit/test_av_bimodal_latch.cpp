// Host unit tests for session-latch A/V probe helpers (no device).
#include "libmisterplex/av_bimodal_latch.hpp"
#include "libmisterplex/mraudio_status.hpp"

#include <cmath>
#include <cstdio>
#include <cstring>

static int fails = 0;
#define CHECK(cond)                                                                              \
    do {                                                                                         \
        if (!(cond)) {                                                                           \
            std::fprintf(stderr, "FAIL %s:%d: %s\n", __FILE__, __LINE__, #cond);                 \
            ++fails;                                                                             \
        }                                                                                        \
    } while (0)

int main() {
    using namespace misterplex;
    using namespace misterplex::av_bimodal;

    // --- DERIVED_FROM_RTL tick arithmetic (must match AV_BIMODAL_RTL_ANSWERS.md) ---
    CHECK(kDisplayTickCycles == 334312LL);
    CHECK(std::fabs(kDisplayTickMs - 16.715600) < 1e-9);
    CHECK(std::fabs(7.0 * kDisplayTickMs - 117.0092) < 1e-4);

    // Parent cluster separation maps to n=7, not n=0 and not content 3 frames.
    {
        const TickMatch m = nearestDisplayTicks(kParentClusterSepMs);
        CHECK(m.n == 7);
        CHECK(m.abs_err_ms < 0.2); // 117.10 - 117.0092
    }
    {
        const TickMatch m = nearestDisplayTicks(125.0); // 3 content frames @ 24fps
        CHECK(m.n == 7 || m.n == 8); // 125 is between 7T and 8T; nearer 7 or 8
        // Explicit kill: 3 content frames is 7.9 ms off parent sep — NOT nearest-tick proof.
        const double err3 = 125.0 - kParentClusterSepMs;
        CHECK(std::fabs(err3 - 7.9) < 0.05);
        CHECK(err3 > 7.0); // still the rejected 3-frame hypothesis gap
    }

    // Full MrAudio status parse (lab line shape).
    {
        const char* line = "rptr: 238120, wptr: 426576, len: 188456, comp: 4\n";
        const MrAudioStatusLine st =
            parseMrAudioStatusLine(line, static_cast<int64_t>(std::strlen(line)));
        CHECK(st.ok);
        CHECK(st.rptr == 238120);
        CHECK(st.wptr == 426576);
        CHECK(st.len == 188456);
        CHECK(st.comp == 4);
        CHECK(parseMrAudioQueuedBytes(line, static_cast<int64_t>(std::strlen(line))) == 188456);
    }
    // len-only still works for queued-bytes helper (legacy / tests).
    CHECK(parseMrAudioQueuedBytes("len: 20616\n", 11) == 20616);

    // Log line format is stable key=value.
    {
        char buf[512];
        const int n = formatBimodalLatchLine(buf, sizeof(buf), "AUDIO_T0", 1000, 0, 1, 2, 3, 0,
                                             1, 3, 0, 1, 42, 0);
        CHECK(n > 0);
        CHECK(std::strstr(buf, "BIMODAL_LATCH tag=AUDIO_T0") != nullptr);
        CHECK(std::strstr(buf, "wall_ms=1000") != nullptr);
        CHECK(std::strstr(buf, "frames_done=42") != nullptr);
        CHECK(std::strstr(buf, "T_disp_ms=16.715600") != nullptr);
    }
    {
        char buf[512];
        const int n = formatTickClassifyLine(buf, sizeof(buf), -117.10);
        CHECK(n > 0);
        CHECK(std::strstr(buf, "nearest_n=7") != nullptr);
        CHECK(std::strstr(buf, "H_VDISP7_pred_n=7") != nullptr);
    }

    if (fails) {
        std::fprintf(stderr, "test_av_bimodal_latch: %d FAIL\n", fails);
        return 1;
    }
    std::printf("test_av_bimodal_latch: OK\n");
    return 0;
}
