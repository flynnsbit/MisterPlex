// Emit the product DDR YUV vf string for a delivered source geometry.
// Used by scripts/vf_delivery_behaviour_check.sh so the gate drives the same
// planner as the daemon (buildFfmpegVideoFilter), not a hand-copied FOAR stub.
//
// Usage:
//   test_vf_plan_emit <src_w> <src_h> [--verified 0|1] [--mode always|skip_identity]
// Prints one line: reason=<r> identity_skip=<0|1> scale_applied=<0|1> vf=<string|none>
#include "libmisterplex/ddr_frame_layout.hpp"
#include "libmisterplex/ffmpeg_vf.hpp"

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>

int main(int argc, char** argv) {
    using namespace misterplex;
    if (argc < 3) {
        std::fprintf(stderr,
                     "usage: %s <src_w> <src_h> [--verified 0|1] [--mode always|skip_identity]\n",
                     argv[0]);
        return 2;
    }
    const int sw = std::atoi(argv[1]);
    const int sh = std::atoi(argv[2]);
    bool verified = false;
    FfmpegScaleMode mode = FfmpegScaleMode::Always; // product FORCE_SCALE maps SkipIdentity→Always
    for (int i = 3; i < argc; ++i) {
        if (std::strcmp(argv[i], "--verified") == 0 && i + 1 < argc) {
            verified = std::atoi(argv[++i]) != 0;
        } else if (std::strcmp(argv[i], "--mode") == 0 && i + 1 < argc) {
            const char* m = argv[++i];
            if (std::strcmp(m, "skip_identity") == 0)
                mode = FfmpegScaleMode::SkipIdentity;
            else
                mode = FfmpegScaleMode::Always;
        }
    }

    FfmpegVfRequest r;
    r.coded_w = kPlex480pCodedWidth.get();
    r.coded_h = kPlex480pCodedHeight.get();
    r.display_w = kPlex480pDisplayWidth.get();
    r.display_h = kPlex480pDisplayHeight.get();
    r.crop_left = kPlex480pCropLeft;
    r.crop_top = kPlex480pCropTop;
    r.source_w = sw;
    r.source_h = sh;
    r.delivery_geometry_verified = verified;
    r.assume_source_matches_coded = false;
    r.scale_mode = mode;
    r.sws_flags = "fast_bilinear";

    const auto p = buildFfmpegVideoFilter(r);
    std::printf("reason=%s identity_skip=%d scale_applied=%d vf=%s\n", p.reason.c_str(),
                p.identity_skip ? 1 : 0, p.scale_applied ? 1 : 0,
                p.vf.empty() ? "(none)" : p.vf.c_str());
    return 0;
}
