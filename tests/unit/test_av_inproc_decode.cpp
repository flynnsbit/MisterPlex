// Host smoke for U1 AvInprocDecoder (workstation libav).
// unique24 is NOT claimed. Isolated host fps is not the A9 rate and is not a 23.9 gate.
// Requires -DMPX_HAVE_LIBAV. Clip default: /tmp/real720p_1500k_av.mp4
#ifndef MPX_HAVE_LIBAV
#error "test_av_inproc_decode.cpp requires -DMPX_HAVE_LIBAV"
#endif

#include "libmisterplex/av_inproc_decode.hpp"

#include <chrono>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

namespace {

constexpr int kW = 1280;
constexpr int kH = 720;
constexpr int kFrames = 24;
constexpr size_t kI420 = static_cast<size_t>(kW) * static_cast<size_t>(kH) * 3 / 2;
constexpr size_t kY = static_cast<size_t>(kW) * static_cast<size_t>(kH);

int fails = 0;
#define CHECK(cond)                                                                              \
    do {                                                                                         \
        if (!(cond)) {                                                                           \
            std::fprintf(stderr, "FAIL %s:%d: %s\n", __FILE__, __LINE__, #cond);                 \
            ++fails;                                                                             \
        }                                                                                        \
    } while (0)

bool yPlaneAllZero(const uint8_t* y, size_t n) {
    for (size_t i = 0; i < n; ++i) {
        if (y[i] != 0)
            return false;
    }
    return true;
}

} // namespace

void checkSolidScale(int srcW, int srcH, int dstW, int dstH, uint8_t Y, uint8_t U,
                     uint8_t V) {
    const size_t sY = static_cast<size_t>(srcW) * static_cast<size_t>(srcH);
    const size_t sC = sY / 4;
    const size_t dY = static_cast<size_t>(dstW) * static_cast<size_t>(dstH);
    const size_t dC = dY / 4;
    std::vector<uint8_t> src(sY + 2 * sC, 0);
    std::vector<uint8_t> dst(dY + 2 * dC, 0x5A);
    std::memset(src.data(), Y, sY);
    std::memset(src.data() + sY, U, sC);
    std::memset(src.data() + sY + sC, V, sC);
    CHECK(misterplex::scaleI420NearestPlanes(src.data(), srcW, src.data() + sY,
                                             srcW / 2, src.data() + sY + sC,
                                             srcW / 2, srcW, srcH, dst.data(),
                                             dstW, dstH, dst.size()));
    size_t badY = 0, badU = 0, badV = 0;
    for (size_t i = 0; i < dY; ++i)
        if (dst[i] != Y)
            ++badY;
    for (size_t i = 0; i < dC; ++i) {
        if (dst[dY + i] != U)
            ++badU;
        if (dst[dY + dC + i] != V)
            ++badV;
    }
    CHECK(badY == 0);
    CHECK(badU == 0);
    CHECK(badV == 0);
}

// dest(x,y) must equal src(x*srcW/dstW, y*srcH/dstH) on Y and chroma.
void checkNearestExact(int srcW, int srcH, int dstW, int dstH) {
    const int srcCw = srcW / 2;
    const int srcCh = srcH / 2;
    const int dstCw = dstW / 2;
    const int dstCh = dstH / 2;
    const size_t sY = static_cast<size_t>(srcW) * static_cast<size_t>(srcH);
    const size_t sC = sY / 4;
    const size_t dY = static_cast<size_t>(dstW) * static_cast<size_t>(dstH);
    const size_t dC = dY / 4;
    std::vector<uint8_t> src(sY + 2 * sC, 0);
    std::vector<uint8_t> dst(dY + 2 * dC, 0x5A);
    uint8_t* sYp = src.data();
    uint8_t* sU = src.data() + sY;
    uint8_t* sV = sU + sC;
    for (int y = 0; y < srcH; ++y) {
        for (int x = 0; x < srcW; ++x) {
            const uint8_t checker = static_cast<uint8_t>(((x ^ y) & 1) ? 210 : 40);
            sYp[static_cast<size_t>(y) * static_cast<size_t>(srcW) +
                static_cast<size_t>(x)] = checker;
        }
    }
    for (int y = 0; y < srcCh; ++y) {
        for (int x = 0; x < srcCw; ++x) {
            const size_t i =
                static_cast<size_t>(y) * static_cast<size_t>(srcCw) + static_cast<size_t>(x);
            sU[i] = static_cast<uint8_t>((x + 5 * y + 16) & 0xFF);
            sV[i] = static_cast<uint8_t>((x + 7 * y + 32) & 0xFF);
        }
    }
    CHECK(misterplex::scaleI420NearestPlanes(src.data(), srcW, sU, srcCw, sV, srcCw, srcW,
                                             srcH, dst.data(), dstW, dstH, dst.size()));
    size_t badY = 0, badU = 0, badV = 0;
    const uint8_t* dYp = dst.data();
    const uint8_t* dU = dst.data() + dY;
    const uint8_t* dV = dU + dC;
    for (int y = 0; y < dstH; ++y) {
        const int sy = y * srcH / dstH;
        for (int x = 0; x < dstW; ++x) {
            const int sx = x * srcW / dstW;
            const uint8_t want =
                sYp[static_cast<size_t>(sy) * static_cast<size_t>(srcW) +
                    static_cast<size_t>(sx)];
            const uint8_t got =
                dYp[static_cast<size_t>(y) * static_cast<size_t>(dstW) +
                    static_cast<size_t>(x)];
            if (got != want)
                ++badY;
        }
    }
    for (int y = 0; y < dstCh; ++y) {
        const int sy = y * srcCh / dstCh;
        for (int x = 0; x < dstCw; ++x) {
            const int sx = x * srcCw / dstCw;
            const size_t si =
                static_cast<size_t>(sy) * static_cast<size_t>(srcCw) + static_cast<size_t>(sx);
            const size_t di =
                static_cast<size_t>(y) * static_cast<size_t>(dstCw) + static_cast<size_t>(x);
            if (dU[di] != sU[si])
                ++badU;
            if (dV[di] != sV[si])
                ++badV;
        }
    }
    if (badY || badU || badV)
        std::fprintf(stderr, "FAIL nearest exact %dx%d->%dx%d badY=%zu badU=%zu badV=%zu\n",
                     srcW, srcH, dstW, dstH, badY, badU, badV);
    CHECK(badY == 0);
    CHECK(badU == 0);
    CHECK(badV == 0);
}

void benchNearestInfo(int srcW, int srcH, int dstW, int dstH, const char* tag) {
    const size_t sY = static_cast<size_t>(srcW) * static_cast<size_t>(srcH);
    const size_t sC = sY / 4;
    const size_t dY = static_cast<size_t>(dstW) * static_cast<size_t>(dstH);
    const size_t dC = dY / 4;
    std::vector<uint8_t> src(sY + 2 * sC, 80);
    std::vector<uint8_t> dst(dY + 2 * dC, 0);
    const int n = 80;
    CHECK(misterplex::scaleI420NearestPlanes(src.data(), srcW, src.data() + sY, srcW / 2,
                                             src.data() + sY + sC, srcW / 2, srcW, srcH,
                                             dst.data(), dstW, dstH, dst.size()));
    const auto t0 = std::chrono::steady_clock::now();
    for (int i = 0; i < n; ++i) {
        misterplex::scaleI420NearestPlanes(src.data(), srcW, src.data() + sY, srcW / 2,
                                           src.data() + sY + sC, srcW / 2, srcW, srcH,
                                           dst.data(), dstW, dstH, dst.size());
    }
    const auto t1 = std::chrono::steady_clock::now();
    const double us =
        std::chrono::duration<double, std::micro>(t1 - t0).count() / static_cast<double>(n);
    std::fprintf(stdout, "scale_info %s n=%d us/frame=%.1f (INFO only; not A9; not a 23.9 gate)\n",
                 tag, n, us);
}

int main(int argc, char** argv) {
    {
        checkSolidScale(2, 2, 4, 4, 80, 100, 120);
        checkSolidScale(320, 240, 1280, 720, 80, 100, 120);
        checkSolidScale(640, 480, 1280, 720, 90, 110, 130);
        checkNearestExact(320, 240, 1280, 720);
        checkNearestExact(640, 480, 1280, 720);
        checkNearestExact(16, 16, 20, 18);
        checkNearestExact(1280, 720, 1280, 720);
        benchNearestInfo(320, 240, 1280, 720, "320x240->1280x720");
        benchNearestInfo(640, 480, 1280, 720, "640x480->1280x720");
        CHECK(!misterplex::scaleI420NearestPlanes(nullptr, 2, nullptr, 1, nullptr, 1, 2,
                                                  2, nullptr, 4, 4, 24));
        std::vector<uint8_t> tiny(6, 80);
        std::vector<uint8_t> out(24, 0);
        CHECK(!misterplex::scaleI420NearestPlanes(tiny.data(), 3, tiny.data() + 4, 1,
                                                  tiny.data() + 5, 1, 3, 2, out.data(),
                                                  4, 4, out.size()));
        CHECK(!misterplex::inprocDecodeSizeOk(640, 480));
        CHECK(!misterplex::inprocDecodeSizeOk(320, 240));
    }

    const char* clip = "/tmp/real720p_1500k_av.mp4";
    if (argc > 1 && argv[1] && argv[1][0])
        clip = argv[1];

    std::fprintf(stdout, "clip=%s\n", clip);
    std::fprintf(stdout, "libav_expect=62.x packed_i420=%zux%zu need=%zu\n",
                 static_cast<size_t>(kW), static_cast<size_t>(kH), kI420);
    std::fflush(stdout);

    misterplex::AvInprocDecoder dec;
    std::string err;
    // H-u1 API: AvInprocOpenOpts{expectW, expectH, threads}. {1280,720,2} matches.
    if (!dec.open(clip, {kW, kH, 2}, err)) {
        std::fprintf(stderr, "FAIL open: %s\n", err.c_str());
        return 1;
    }
    CHECK(dec.isOpen());
    CHECK(dec.width() == kW);
    CHECK(dec.height() == kH);

    std::vector<uint8_t> buf(kI420, 0);
    int got = 0;
    bool firstYLive = false;
    const auto t0 = std::chrono::steady_clock::now();
    for (int i = 0; i < kFrames; ++i) {
        const int rc = dec.readI420(buf.data(), kI420, err);
        if (rc != 1) {
            std::fprintf(stderr, "FAIL readI420 frame=%d rc=%d err=%s\n", i, rc, err.c_str());
            ++fails;
            break;
        }
        // rc==1 and frameBytes==need means a full packed 1382400-byte I420.
        ++got;
        if (i == 0) {
            firstYLive = !yPlaneAllZero(buf.data(), kY);
            CHECK(firstYLive);
            if (!firstYLive)
                std::fprintf(stderr, "FAIL first-frame Y plane is all-zero\n");
        }
    }
    const auto t1 = std::chrono::steady_clock::now();
    const double ms = std::chrono::duration<double, std::milli>(t1 - t0).count();
    const double host_fps = (got > 0 && ms > 0.0) ? (1000.0 * static_cast<double>(got) / ms) : 0.0;

    std::fprintf(stdout, "frames_decoded=%d want=%d i420_bytes=%zu first_y_nonzero=%d\n", got,
                 kFrames, kI420, firstYLive ? 1 : 0);
    std::fprintf(stdout, "wall_ms=%.3f host_fps=%.2f (INFO only; not A9; not a 23.9 gate)\n", ms,
                 host_fps);
    std::fprintf(stdout, "unique24=NOT_CLAIMED\n");
    std::fflush(stdout);

    CHECK(got == kFrames);
    dec.close();

    // Packed 4/3 pack (no clip). dest(x,y)=src(x*4/3,y*4/3).
    {
        CHECK(misterplex::kInprocI420_960 == 777600u);
        CHECK(misterplex::inprocScale1280to960(kW, kH, 960, 540));
        std::vector<uint8_t> src(misterplex::kInprocI420_1280, 0);
        std::vector<uint8_t> dst(misterplex::kInprocI420_960, 0);
        for (size_t i = 0; i < kY; ++i)
            src[i] = static_cast<uint8_t>((i * 17u) & 0xFFu);
        CHECK(misterplex::downsampleI420_1280_to_960(src.data(), src.size(), dst.data(),
                                                     dst.size()));
        CHECK(dst[0] == src[0]);
        CHECK(dst[3] == src[4]);
        CHECK(!misterplex::downsampleI420_1280_to_960(src.data(), src.size(), dst.data(),
                                                      1382400u));
    }

    // Decode 1280, pack 960×540. Isolated host fps is not a 23.9 gate.
    {
        misterplex::AvInprocDecoder d960;
        misterplex::AvInprocOpenOpts o960;
        o960.expectW = kW;
        o960.expectH = kH;
        o960.threads = 2;
        o960.outW = 960;
        o960.outH = 540;
        if (!d960.open(clip, o960, err)) {
            std::fprintf(stderr, "FAIL open 960: %s\n", err.c_str());
            ++fails;
        } else {
            CHECK(d960.isOpen());
            CHECK(d960.width() == 960);
            CHECK(d960.height() == 540);
            std::vector<uint8_t> buf960(misterplex::kInprocI420_960, 0);
            const int rc = d960.readI420(buf960.data(), misterplex::kInprocI420_960, err);
            CHECK(rc == 1);
            if (rc != 1)
                std::fprintf(stderr, "FAIL readI420 960 rc=%d err=%s\n", rc, err.c_str());
            else {
                CHECK(!yPlaneAllZero(buf960.data(), static_cast<size_t>(960) * 540));
                std::string bad;
                CHECK(d960.readI420(buf960.data(), kI420, bad) == -1);
            }
            std::fprintf(stdout, "frames_960=1 i420_bytes=%zu wxh=%dx%d\n",
                         misterplex::kInprocI420_960, d960.width(), d960.height());
            d960.close();
        }
    }

    // 240p file into L4 1280×720 bank via nearest scale (no ffmpeg pipe).
    {
        const char* clip240 =
            "/home/shawn/Projects/MisterPlex-wt-480p-lessons/assets/avsync/"
            "sync_trekmatch_320x240_24_blip.mp4";
        misterplex::AvInprocDecoder d240;
        misterplex::AvInprocOpenOpts o240;
        o240.expectW = kW;
        o240.expectH = kH;
        o240.threads = 2;
        if (!d240.open(clip240, o240, err)) {
            std::fprintf(stderr, "FAIL open 240->1280: %s\n", err.c_str());
            ++fails;
        } else {
            CHECK(d240.isOpen());
            CHECK(d240.width() == kW);
            CHECK(d240.height() == kH);
            std::vector<uint8_t> buf240(kI420, 0);
            const int rc = d240.readI420(buf240.data(), kI420, err);
            CHECK(rc == 1);
            if (rc != 1)
                std::fprintf(stderr, "FAIL readI420 240->1280 rc=%d err=%s\n", rc,
                             err.c_str());
            else
                CHECK(!yPlaneAllZero(buf240.data(), kY));
            std::fprintf(stdout, "frames_240_to_1280=1 i420_bytes=%zu wxh=%dx%d\n",
                         kI420, d240.width(), d240.height());
            d240.close();
        }
    }

    if (fails) {
        std::fprintf(stderr, "test_av_inproc_decode FAIL fails=%d\n", fails);
        return 1;
    }
    std::fprintf(stdout, "test_av_inproc_decode OK\n");
    return 0;
}
