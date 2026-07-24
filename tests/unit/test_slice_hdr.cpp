// Unit: PPS + IDR slice header from real Baseline annex-B (Phase 3.3d).
#include "libmisterplex/h264_nal.hpp"

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

int main(int argc, char** argv) {
    const char* path = argc > 1 ? argv[1] : "/tmp/plex_real_baseline.h264";
    auto blob = readFile(path);
    if (blob.empty()) {
        int r = std::system("python3 scripts/gen_test_annexb_real.py /tmp/plex_real_baseline.h264");
        if (r != 0) {
            std::printf("FAIL: no bitstream\n");
            return 1;
        }
        blob = readFile("/tmp/plex_real_baseline.h264");
    }
    auto c = misterplex::parseAnnexBChain(blob.data(), blob.size());
    if (!c.sps.valid || c.sps.width != 320 || c.sps.height != 240) {
        std::printf("FAIL SPS %u x %u\n", c.sps.width, c.sps.height);
        return 1;
    }
    if (!c.pps.valid || c.pps.entropy_cabac) {
        std::printf("FAIL PPS valid=%d cabac=%d\n", c.pps.valid, c.pps.entropy_cabac);
        return 1;
    }
    if (!c.slice.valid || !c.slice.is_idr || !c.slice.is_i_slice) {
        std::printf("FAIL slice valid=%d idr=%d i=%d type=%u\n", c.slice.valid, c.slice.is_idr,
                    c.slice.is_i_slice, c.slice.slice_type);
        return 1;
    }
    if (c.slice.first_mb_in_slice != 0 || c.slice.slice_type != 7) {
        std::printf("FAIL first=%u type=%u want 0/7\n", c.slice.first_mb_in_slice, c.slice.slice_type);
        return 1;
    }
    std::printf("test_slice_hdr: OK sps=%ux%u pps_id=%u slice_type=%u (I/IDR) qp=%d\n", c.sps.width,
                c.sps.height, c.pps.pps_id, c.slice.slice_type, c.pps.pic_init_qp);
    return 0;
}
