// Unit: parse real Baseline SPS from ffmpeg annex-B (mirrors FPGA 3.3c).
#include "libmisterplex/h264_sps.hpp"

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
