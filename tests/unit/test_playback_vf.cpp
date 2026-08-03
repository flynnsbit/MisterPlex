// RED-before-GREEN contract: identity geometry must not emit scale/pad.
#include "libmisterplex/playback_vf.hpp"
#include "libmisterplex/content_modes.hpp"
#include "libmisterplex/osd_menu.hpp"

#include <cstdio>
#include <string>

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

    // Identity 720p: NO scale/pad (fps-only ok).
    {
        const std::string vf = buildPlaybackVideoFilter(1280, 720, 1280, 720, 24, 1);
        CHECK(vf.find("scale=") == std::string::npos);
        CHECK(vf.find("pad=") == std::string::npos);
        CHECK(!playbackVfHasGeometryFilter(vf));
        CHECK(vf.find("fps=24/1") != std::string::npos);
    }
    // Identity 240p empty fps.
    {
        const std::string vf = buildPlaybackVideoFilter(320, 240, 320, 240, 0, 0);
        CHECK(vf.empty());
        CHECK(!playbackVfHasGeometryFilter(vf));
    }
    // Non-identity: scale required.
    {
        const std::string vf = buildPlaybackVideoFilter(1280, 720, 640, 360, 0, 0);
        CHECK(vf.find("scale=1280:720") != std::string::npos);
        CHECK(vf.find("pad=1280:720") != std::string::npos);
        CHECK(playbackVfHasGeometryFilter(vf));
    }
    // Unknown source (0x0): must still scale (safe default) — negative of "always skip".
    {
        const std::string vf = buildPlaybackVideoFilter(1280, 720, 0, 0, 0, 0);
        CHECK(playbackVfHasGeometryFilter(vf));
        CHECK(vf.find("scale=") != std::string::npos);
    }
    // Content mode table exposes 720p; size map must not clamp.
    CHECK(findContentModeExact(1280, 720) != nullptr);
    CHECK(contentModeFromSize(1280, 720).height == 720);
    CHECK(contentResolutionFromSize(1280, 720).width == 1280);
    CHECK(contentResolutionFromSize(1280, 720).height == 720);
    // Oversized request pins to 720p tier, not 480p.
    CHECK(contentResolutionFromSize(1920, 1080).width == 1280);

    if (fails) {
        std::fprintf(stderr, "test_playback_vf: %d failure(s)\n", fails);
        return 1;
    }
    std::printf("test_playback_vf: OK\n");
    return 0;
}
