// Red-before-green: stderr pump must surface fatal ffmpeg lines (ce727a43 hole).
#include "libmisterplex/ffmpeg_stderr.hpp"

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

    CHECK(classifyFfmpegStderrLine("frame=  123 fps=24 q=28.0") ==
          FfmpegStderrClass::ProgressNoise);
    CHECK(classifyFfmpegStderrLine("size=     512kB time=00:00:01.00 bitrate= 400.0kbits/s") ==
          FfmpegStderrClass::ProgressNoise);
    CHECK(classifyFfmpegStderrLine(
              "  Stream #0:0: Video: h264 (Constrained Baseline), yuv420p, 624x350, 24 fps") ==
          FfmpegStderrClass::GeometryCandidate);

    const char* fatal =
        "Error initializing output stream 0:0 -- Error while opening encoder for output stream";
    CHECK(classifyFfmpegStderrLine(fatal) == FfmpegStderrClass::Diagnostic);
    CHECK(ffmpegStderrLooksFatal(fatal));
    CHECK(classifyFfmpegStderrLine("Nothing was written into output files") ==
          FfmpegStderrClass::Diagnostic);
    CHECK(ffmpegStderrLooksFatal("Nothing was written into output files"));
    CHECK(classifyFfmpegStderrLine("Conversion failed!") == FfmpegStderrClass::Diagnostic);

    // CR-split: -stats progress must not leave a stuck buffer.
    {
        std::string acc = "frame=1 fps=24\rframe=2 fps=24\nError opening input\n";
        std::string line;
        CHECK(takeFfmpegStderrLine(acc, &line));
        CHECK(classifyFfmpegStderrLine(line) == FfmpegStderrClass::ProgressNoise);
        CHECK(takeFfmpegStderrLine(acc, &line));
        CHECK(classifyFfmpegStderrLine(line) == FfmpegStderrClass::ProgressNoise);
        CHECK(takeFfmpegStderrLine(acc, &line));
        CHECK(classifyFfmpegStderrLine(line) == FfmpegStderrClass::Diagnostic);
        CHECK(ffmpegStderrLooksFatal(line));
        CHECK(!takeFfmpegStderrLine(acc, &line));
    }

    // Simulate pump filter: count diagnostics that would be logged.
    {
        const char* lines[] = {
            "frame= 10 fps=24",
            "  Stream #0:0: Video: h264, yuv420p, 624x350, 24 fps",
            "Error while decoding stream #0:0: Invalid data found when processing input",
            "Nothing was written into output files, because at least one output file "
            "did not have a stream with any packets written to it.",
        };
        int diag = 0, fatalN = 0, geom = 0;
        for (const char* L : lines) {
            const auto c = classifyFfmpegStderrLine(L);
            if (c == FfmpegStderrClass::ProgressNoise)
                continue;
            if (c == FfmpegStderrClass::GeometryCandidate) {
                ++geom;
                continue;
            }
            if (c == FfmpegStderrClass::Diagnostic) {
                ++diag;
                if (ffmpegStderrLooksFatal(L))
                    ++fatalN;
            }
        }
        CHECK(geom == 1);
        CHECK(diag == 2);
        CHECK(fatalN == 2);
        std::printf("PASS stderr classify would log fatal_n=%d (not swallow)\n", fatalN);
    }

    if (fails) {
        std::fprintf(stderr, "test_ffmpeg_stderr: %d FAIL\n", fails);
        return 1;
    }
    std::printf("test_ffmpeg_stderr: OK\n");
    return 0;
}
