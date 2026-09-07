// Unit: parse real Baseline SPS from ffmpeg annex-B (mirrors FPGA 3.3c).
#include "libmisterplex/h264_sps.hpp"
#ifdef MPX_HAVE_LIBAV
#include "libmisterplex/av_inproc_decode.hpp"
#endif

#include <cstdio>
#include <cstdlib>
#include <fstream>
#include <string>
#include <vector>

static std::vector<uint8_t> readFile(const char* path) {
    std::ifstream in(path, std::ios::binary);
    if (!in)
        return {};
    return std::vector<uint8_t>((std::istreambuf_iterator<char>(in)), {});
}

// Synthetic SPS-like from gen_test_annexb.py is NOT valid — skip.

int main(int argc, char** argv) {
#ifdef MPX_HAVE_LIBAV
    if (argc >= 4 && std::string(argv[1]) == "--compressed") {
        misterplex::AvInprocOpenOpts opts;
        opts.compressedVideo = true;
        opts.expectW = 320; opts.expectH = 240;
        opts.allowInter = true;
        opts.allowDeblock = true;
        opts.expectedFpsNum = 24;
        opts.expectedFpsDen = 1;
        bool expectAudio = false;
        bool rejectGeometry = false;
        bool rejectLevel = false;
        bool rejectVcl = false;
        bool rejectAu = false;
        bool rejectIdr = false, rejectFilter = false;
        bool rejectColor = false;
        bool unknownDar = false;
        bool unknownColor = false;
        int codedW = 0, codedH = 0, visibleW = 0, visibleH = 0, darNum = 0, darDen = 0;
        for (int i = 4; i < argc; ++i) {
            expectAudio |= std::string(argv[i]) == "audio";
            rejectGeometry |= std::string(argv[i]) == "reject-geometry";
            rejectLevel |= std::string(argv[i]) == "reject-level";
            rejectVcl |= std::string(argv[i]) == "reject-vcl";
            rejectAu |= std::string(argv[i]) == "reject-au";
            rejectIdr |= std::string(argv[i]) == "reject-idr";
            rejectFilter |= std::string(argv[i]) == "reject-filter";
            rejectColor |= std::string(argv[i]) == "reject-color";
            unknownDar |= std::string(argv[i]) == "unknown-dar";
            unknownColor |= std::string(argv[i]) == "unknown-color";
            if (std::string(argv[i]) == "limited-601") opts.requireLimitedBt601 = true;
            if (std::string(argv[i]) == "all-idr") {
                opts.requireAllIdr = true;
                opts.allowInter = false;
            }
            if (std::string(argv[i]) == "filter-off") opts.allowDeblock = false;
            if (std::string(argv[i]).rfind("au=", 0) == 0)
                opts.maxAccessUnitBytes = std::strtoull(argv[i] + 3, nullptr, 10);
            if (std::string(argv[i]).rfind("vcl=", 0) == 0)
                opts.maxVclRbspBytes = std::strtoull(argv[i] + 4, nullptr, 10);
            if (std::string(argv[i]).rfind("coded=", 0) == 0)
                std::sscanf(argv[i], "coded=%dx%d", &codedW, &codedH);
            if (std::string(argv[i]).rfind("visible=", 0) == 0)
                std::sscanf(argv[i], "visible=%dx%d", &visibleW, &visibleH);
            if (std::string(argv[i]).rfind("dar=", 0) == 0)
                std::sscanf(argv[i], "dar=%d:%d", &darNum, &darDen);
            if (std::string(argv[i]) == "23976") {
                opts.expectedFpsNum = 24000;
                opts.expectedFpsDen = 1001;
            }
        }
        const int expectedNum = opts.expectedFpsNum, expectedDen = opts.expectedFpsDen;
        std::atomic<bool> cancelled{false};
        opts.cancelled = &cancelled;
        misterplex::AvInprocDecoder source;
        std::string error;
        int frames = 0;
        int64_t lastPts = misterplex::ddr_bitstream_ring::kNoTimestamp;
        int64_t pcmBytes = 0;
        uint8_t pcm[4096];
        if (!source.open(argv[2], opts, error)) {
            std::printf("FAIL: compressed open %s\n", error.c_str());
            return 1;
        }
        if (source.width() != 0 || source.height() != 0) {
            std::printf("FAIL: configured maximum reported as actual before SPS\n");
            return 1;
        }
        if (rejectGeometry || rejectLevel) {
            misterplex::AvCompressedAccessUnit au;
            if (source.readAccessUnit(au, error) != -1 ||
                error.find("unsupported SPS") == std::string::npos) {
                std::printf("FAIL: unsupported SPS was accepted: %s\n", error.c_str());
                return 1;
            }
            std::puts(rejectLevel ? "test_sps_parse compressed: OK unsupported SPS level rejected" :
                                  "test_sps_parse compressed: OK oversized coded geometry rejected");
            return 0;
        }
        for (;;) {
            misterplex::AvCompressedAccessUnit au;
            const int got = source.readAccessUnit(au, error);
            if (got < 0) {
                if (rejectColor && error.find("limited-BT601 scanout") != std::string::npos) {
                    std::printf("test_sps_parse compressed: OK color mismatch rejected after %d AUs: %s\n",
                                frames, error.c_str());
                    return 0;
                }
                if ((rejectIdr && error.find("all-IDR profile") != std::string::npos) ||
                    (rejectFilter && error.find("unnegotiated deblocking") != std::string::npos)) {
                    std::printf("test_sps_parse compressed: OK profile mismatch rejected after %d AUs: %s\n",
                                frames, error.c_str());
                    return 0;
                }
                if (rejectAu && error.find("bounded ring capacity") != std::string::npos) {
                    std::printf("test_sps_parse compressed: OK AU bound=%zu rejected after %d AUs\n",
                                opts.maxAccessUnitBytes, frames);
                    return 0;
                }
                if (rejectVcl && error.find("frontend capacity") != std::string::npos) {
                    std::printf("test_sps_parse compressed: OK VCL bound=%zu rejected after %d AUs\n",
                                opts.maxVclRbspBytes, frames);
                    return 0;
                }
                std::printf("FAIL: compressed read after %d AUs: %s\n", frames, error.c_str());
                return 1;
            }
            while (const int n = source.drainPcm(pcm, sizeof(pcm))) pcmBytes += n;
            if (!got) break;
            if (au.annexb.empty() || !au.timebaseNum || !au.timebaseDen ||
                (frames == 0 && (!au.keyframe || !au.parameterSetsChanged)) ||
                (frames > 0 && au.pts <= lastPts)) {
                std::printf("FAIL: compressed AU metadata/boundaries\n");
                return 1;
            }
            const auto& geometry = au.geometry;
            if (geometry.codedWidth <= 0 || geometry.codedHeight <= 0 ||
                geometry.codedWidth > 320 || geometry.codedHeight > 240 ||
                geometry.codedWidth != geometry.macroblockColumns * 16 ||
                geometry.codedHeight != geometry.macroblockRows * 16 ||
                geometry.visibleWidth + geometry.cropLeft + geometry.cropRight != geometry.codedWidth ||
                geometry.visibleHeight + geometry.cropTop + geometry.cropBottom != geometry.codedHeight ||
                source.width() != geometry.codedWidth || source.height() != geometry.codedHeight ||
                (unknownDar && geometry.sourceAspect.valid) ||
                (unknownColor && (geometry.matrixCoefficients != 2 ||
                                  geometry.limitedBt601Signaled())) ||
                (codedW && (codedW != geometry.codedWidth || codedH != geometry.codedHeight)) ||
                (visibleW && (visibleW != geometry.visibleWidth || visibleH != geometry.visibleHeight)) ||
                (darNum && (!geometry.sourceAspect.valid ||
                    uint64_t(geometry.sourceAspect.x) * darDen !=
                    uint64_t(geometry.sourceAspect.y) * darNum))) {
                std::printf("FAIL: actual coded/visible/MB/crop/DAR geometry mismatch\n");
                return 1;
            }
            lastPts = au.pts;
            ++frames;
        }
        if (rejectVcl || rejectAu || rejectIdr || rejectFilter || rejectColor) {
            std::printf("FAIL: expected compressed capacity/profile rejection was absent\n");
            return 1;
        }
        if (frames != std::atoi(argv[3]) || !source.audioEof()) {
            std::printf("FAIL: final AU/PCM EOF frames=%d\n", frames);
            return 1;
        }
        if (expectAudio && pcmBytes == 0) {
            std::printf("FAIL: same-demux audio absent\n");
            return 1;
        }
        if (pcmBytes > 0 &&
            source.firstAudioPtsUs() == misterplex::ddr_bitstream_ring::kNoTimestamp) {
            std::printf("FAIL: original audio timestamp missing\n");
            return 1;
        }
        const auto acceptedGeometry = source.videoGeometry();
        source.close();
        opts.expectedFpsNum = expectedNum == 24 ? 24000 : 24;
        opts.expectedFpsDen = expectedNum == 24 ? 1001 : 1;
        if (!source.open(argv[2], opts, error)) return 1;
        int mismatch = 1;
        for (int i = 0; i <= frames && mismatch == 1; ++i) {
            misterplex::AvCompressedAccessUnit au;
            mismatch = source.readAccessUnit(au, error);
            while (source.drainPcm(pcm, sizeof(pcm)) > 0) {}
        }
        if (mismatch != -1 || error.find("source frame rate") == std::string::npos) {
            std::printf("FAIL: native source rate mismatch accepted: %s\n", error.c_str());
            return 1;
        }
        source.close();
        opts.expectedFpsNum = expectedNum;
        opts.expectedFpsDen = expectedDen;
        for (int axis = 0; axis != 2; ++axis) {
            auto bounded = opts;
            if (axis == 0) bounded.expectW = acceptedGeometry.codedWidth - 1;
            else bounded.expectH = acceptedGeometry.codedHeight - 1;
            misterplex::AvCompressedAccessUnit au;
            if (!source.open(argv[2], bounded, error) ||
                source.readAccessUnit(au, error) != -1 ||
                error.find("unsupported SPS") == std::string::npos) {
                std::printf("FAIL: coded geometry exceeded non-MB-aligned bound: %s\n", error.c_str());
                return 1;
            }
            source.close();
        }
        opts.maxAccessUnitBytes = 8;
        if (!source.open(argv[2], opts, error)) return 1;
        misterplex::AvCompressedAccessUnit rejected;
        if (source.readAccessUnit(rejected, error) != -1) {
            std::printf("FAIL: AU capacity bound ignored\n");
            return 1;
        }
        source.close();
        opts.maxAccessUnitBytes = misterplex::ddr_bitstream_ring::kMaxAccessUnitBytes;
        opts.maxVclRbspBytes = 8;
        if (!source.open(argv[2], opts, error) ||
            source.readAccessUnit(rejected, error) != -1 ||
            error.find("frontend capacity") == std::string::npos) {
            std::printf("FAIL: VCL capacity bound ignored: %s\n", error.c_str());
            return 1;
        }
        source.close();
        opts.maxVclRbspBytes = misterplex::ddr_bitstream_ring::kMaxAccessUnitBytes;
        opts.startMs = 100;
        if (!source.open(argv[2], opts, error) ||
            source.readAccessUnit(rejected, error) != -1 ||
            error.find("preroll") == std::string::npos) {
            std::printf("FAIL: direct non-IDR seek was not explicitly rejected: %s\n", error.c_str());
            return 1;
        }
        source.close();
        opts.startMs = 0;
        cancelled.store(true);
        if (source.open(argv[2], opts, error)) {
            std::printf("FAIL: cancelled open restarted old session\n");
            return 1;
        }
        std::printf("test_sps_parse compressed: OK frames=%d fps=%d/%d pcm_bytes=%lld "
                    "coded=%dx%d visible=%dx%d mb=%dx%d full_range=%d matrix=%u "
                    "color_description=%d limited_bt601_signaling=%d\n",
                    frames, expectedNum, expectedDen, static_cast<long long>(pcmBytes),
                    acceptedGeometry.codedWidth, acceptedGeometry.codedHeight,
                    acceptedGeometry.visibleWidth, acceptedGeometry.visibleHeight,
                    acceptedGeometry.macroblockColumns, acceptedGeometry.macroblockRows,
                    acceptedGeometry.fullRange, acceptedGeometry.matrixCoefficients,
                    acceptedGeometry.colorDescriptionPresent,
                    acceptedGeometry.limitedBt601Signaled());
        return 0;
    }
#endif

    const char* path = argc > 1 ? argv[1] : "build/plex_real_baseline.264";


    auto blob = readFile(path);
    if (blob.empty()) {
        // Generate via script if missing
        std::string cmd = std::string("python3 ") +
                          (argc > 2 ? argv[2] : "scripts/gen_test_annexb_real.py") + " " + path;
        int r = std::system(cmd.c_str());
        if (r != 0) {
            std::printf("FAIL: no bitstream and gen failed path=%s\n", path);
            return 1;
        }
        blob = readFile(path);
    }
    if (blob.empty()) {
        std::printf("FAIL: empty %s\n", path);
        return 1;
    }
    auto s = misterplex::parseFirstSpsAnnexB(blob.data(), blob.size());
    if (!s.valid) {
        std::printf("FAIL: SPS not valid (%zu bytes)\n", blob.size());
        return 1;
    }
    if (s.width != 320 || s.height != 240) {
        std::printf("FAIL: size %ux%u want 320x240 profile=%u level=%u\n", s.width, s.height,
                    s.profile_idc, s.level_idc);
        return 1;
    }
    if (s.profile_idc != 66) {
        std::printf("FAIL: profile_idc=%u want 66 (Baseline)\n", s.profile_idc);
        return 1;
    }
    std::printf("test_sps_parse: OK %ux%u profile=%u level=%u\n", s.width, s.height, s.profile_idc,
                s.level_idc);
    return 0;
}
