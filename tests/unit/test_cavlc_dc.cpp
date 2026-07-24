// Unit: CAVLC first I_16x16 DC residual of real Baseline IDR (Phase 3.3f).
#include "libmisterplex/h264_cavlc.hpp"

#include <cstdio>
#include <cstdlib>
#include <fstream>
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
        if (std::system("python3 scripts/gen_test_annexb_real.py /tmp/plex_real_baseline.h264") !=
            0) {
            std::printf("FAIL: no bitstream\n");
            return 1;
        }
        blob = readFile("/tmp/plex_real_baseline.h264");
    }
    auto r = misterplex::cavlc::probeFirstI16Dc(blob.data(), blob.size());
    if (!r.ok) {
        std::printf("FAIL: residual probe not ok (tc=%d)\n", r.total_coeff);
        return 1;
    }
    // Golden from bit-level analysis of plex_real_baseline.h264
    if (r.total_coeff != 2 || r.trailing_ones != 2) {
        std::printf("FAIL: tc=%d t1=%d want 2/2\n", r.total_coeff, r.trailing_ones);
        return 1;
    }
    // levels of two trailing ones are ±1
    int nz = 0;
    for (int i = 0; i < 16; ++i)
        if (r.coeff[i] != 0)
            ++nz;
    if (nz != 2) {
        std::printf("FAIL: nonzero count %d want 2\n", nz);
        return 1;
    }
    std::printf("test_cavlc_dc: OK first I16 DC TotalCoeff=%d TrailingOnes=%d\n", r.total_coeff,
                r.trailing_ones);
    return 0;
}
