// Host proof: F_SETPIPE_SZ raises raw-video pipe capacity above the kernel
// default, and we only claim success from F_GETPIPE_SZ read-back.
//
// RED path (request=0 / disabled): capacity stays at the kernel default
// (~65536) which is < 2 frames of 624x480 I420 — not decoupled.
// GREEN path (default 2 MiB target): actual read-back must be decoupled
// (actual >= kMinUsefulRawVideoPipeBytes) OR the kernel refused the set
// with a logged errno (then we still fail the green assert — this host
// must be able to raise the pipe for the gate to have power).
//
// Exit 0 only when both red-before-green and green-before-red hold.
#include "libmisterplex/raw_video_pipe.hpp"

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>

#include <fcntl.h>
#include <unistd.h>

static int fails = 0;
#define CHECK(cond)                                                                              \
    do {                                                                                         \
        if (!(cond)) {                                                                           \
            std::fprintf(stderr, "FAIL %s:%d: %s\n", __FILE__, __LINE__, #cond);                 \
            ++fails;                                                                             \
        }                                                                                        \
    } while (0)

static void testConfParse() {
    using misterplex::kDefaultRawVideoPipeBytes;
    using misterplex::parseRawVideoPipeBytesConf;
    CHECK(parseRawVideoPipeBytesConf("") == kDefaultRawVideoPipeBytes);
    CHECK(parseRawVideoPipeBytesConf("auto") == kDefaultRawVideoPipeBytes);
    CHECK(parseRawVideoPipeBytesConf("on") == kDefaultRawVideoPipeBytes);
    CHECK(parseRawVideoPipeBytesConf("1") == kDefaultRawVideoPipeBytes);
    CHECK(parseRawVideoPipeBytesConf("0") == 0);
    CHECK(parseRawVideoPipeBytesConf("off") == 0);
    CHECK(parseRawVideoPipeBytesConf("1048576") == 1048576);
    CHECK(parseRawVideoPipeBytesConf(" 2097152\r") == 2097152);
}

static int measureDefaultPipe() {
    int p[2] = {-1, -1};
    if (::pipe(p) != 0) {
        std::perror("pipe");
        return -1;
    }
    const auto r = misterplex::applyRawVideoPipeSize(p[0], /*requestBytes=*/0);
    ::close(p[0]);
    ::close(p[1]);
    return r.actual;
}

static misterplex::RawVideoPipeSizeResult measureWithRequest(int req) {
    int p[2] = {-1, -1};
    misterplex::RawVideoPipeSizeResult r{};
    if (::pipe(p) != 0) {
        std::perror("pipe");
        r.actual = -1;
        return r;
    }
    r = misterplex::applyRawVideoPipeSize(p[0], req);
    ::close(p[0]);
    ::close(p[1]);
    return r;
}

int main() {
    std::printf("test_raw_video_pipe: start\n");
    testConfParse();

#ifndef F_SETPIPE_SZ
    std::fprintf(stderr, "FAIL: F_SETPIPE_SZ not defined on this host — cannot prove fix\n");
    return 1;
#endif

    const int defSz = measureDefaultPipe();
    std::printf("default_F_GETPIPE_SZ=%d frame_bytes=%d\n", defSz,
                misterplex::kYuv420p624x480FrameBytes);
    CHECK(defSz > 0);
    // Documented Linux default capacity is 65536 (16 pages). Tolerate small
    // distro variance but require it is well under one 480p frame.
    CHECK(defSz < misterplex::kYuv420p624x480FrameBytes);

    // --- RED: disabled path must NOT be decoupled ---
    const auto red = measureWithRequest(0);
    std::printf("RED_disabled %s\n", misterplex::formatRawVideoPipeLog(red).c_str());
    CHECK(red.attempted == false);
    CHECK(red.actual > 0);
    CHECK(!misterplex::rawVideoPipeIsDecoupled(red));
    // Vacuity guard: if "red" were somehow decoupled, the gate has no power.
    if (misterplex::rawVideoPipeIsDecoupled(red)) {
        std::fprintf(stderr,
                     "FAIL: red path already decoupled (actual=%d) — gate vacuous\n",
                     red.actual);
        return 1;
    }
    std::printf("PASS red-before-green: disabled pipe actual=%d is NOT decoupled\n", red.actual);

    // --- GREEN: default target must raise capacity (may clamp to pipe-max-size) ---
    const auto green = measureWithRequest(misterplex::kDefaultRawVideoPipeBytes);
    std::printf("GREEN_default %s\n", misterplex::formatRawVideoPipeLog(green).c_str());
    CHECK(green.attempted == true);
    CHECK(green.actual > 0);
    CHECK(green.set_ok);
    CHECK(misterplex::rawVideoPipeIsDecoupled(green));
    CHECK(green.actual > defSz);
    // Must not report success when actual stayed at default.
    if (!green.set_ok || green.actual <= defSz ||
        !misterplex::rawVideoPipeIsDecoupled(green)) {
        std::fprintf(stderr,
                     "FAIL: green path did not decouple (set_ok=%d actual=%d default=%d)\n",
                     green.set_ok ? 1 : 0, green.actual, defSz);
        return 1;
    }
    std::printf("PASS green-before-red: actual=%d > default=%d decoupled=1 "
                "requested_final=%d\n",
                green.actual, defSz, green.requested);

    // Log format must carry actual= and must not claim set_ok=1 on failure.
    {
        misterplex::RawVideoPipeSizeResult fakeFail{};
        fakeFail.requested = 2097152;
        fakeFail.actual = 65536;
        fakeFail.attempted = true;
        fakeFail.set_ok = false;
        fakeFail.set_errno = EPERM;
        const std::string line = misterplex::formatRawVideoPipeLog(fakeFail);
        CHECK(line.find("set_ok=0") != std::string::npos);
        CHECK(line.find("actual=65536") != std::string::npos);
        CHECK(line.find("set_ok=1") == std::string::npos);
        std::printf("log_fail_sample: %s\n", line.c_str());
    }
    {
        misterplex::RawVideoPipeSizeResult fakeOk{};
        fakeOk.requested = 2097152;
        fakeOk.actual = 2097152;
        fakeOk.attempted = true;
        fakeOk.set_ok = true;
        const std::string line = misterplex::formatRawVideoPipeLog(fakeOk);
        CHECK(line.find("set_ok=1") != std::string::npos);
        CHECK(line.find("actual=2097152") != std::string::npos);
        std::printf("log_ok_sample: %s\n", line.c_str());
    }

    // Constants: one frame and default target relationship.
    CHECK(misterplex::kYuv420p624x480FrameBytes == 449280);
    CHECK(misterplex::kDefaultRawVideoPipeBytes == 2 * 1024 * 1024);
    CHECK(misterplex::kDefaultRawVideoPipeBytes >
          4 * misterplex::kYuv420p624x480FrameBytes / 1); // >4 frames? 2MiB/449280≈4.67
    {
        const double frames = static_cast<double>(misterplex::kDefaultRawVideoPipeBytes) /
                              static_cast<double>(misterplex::kYuv420p624x480FrameBytes);
        std::printf("default_frames_cap≈%.2f\n", frames);
        CHECK(frames >= 4.0 && frames < 5.0);
    }

    if (fails) {
        std::fprintf(stderr, "test_raw_video_pipe: %d FAIL(s)\n", fails);
        return 1;
    }
    std::printf("test_raw_video_pipe: OK\n");
    return 0;
}
