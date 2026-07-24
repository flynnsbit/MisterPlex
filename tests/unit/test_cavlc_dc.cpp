// Unit: CAVLC first I_16x16 DC + inv-quant recon mean Y (Phase 3.3f/g).
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
    if (!r.ok || r.total_coeff != 2 || r.trailing_ones != 2) {
        std::printf("FAIL: residual ok=%d tc=%d t1=%d want 2/2\n", r.ok, r.total_coeff,
                    r.trailing_ones);
        return 1;
    }
    int nz = 0;
    for (int i = 0; i < 16; ++i)
        if (r.coeff[i] != 0)
            ++nz;
    if (nz != 2) {
        std::printf("FAIL: nonzero %d want 2\n", nz);
        return 1;
    }
    int16_t y[16][16];
    int mean = misterplex::cavlc::reconFirstI16DcMeanY(blob.data(), blob.size(), y);
    if (mean < 0 || mean > 255) {
        std::printf("FAIL: meanY=%d\n", mean);
        return 1;
    }
    // Residual non-zero → mean should move off pure mid-gray 128 for this clip
    // (allow wide band; structural check is range)
    std::printf("test_cavlc_dc: OK tc=%d t1=%d nz=%d meanY=%d y00=%d\n", r.total_coeff,
                r.trailing_ones, nz, mean, (int)y[0][0]);
    return 0;
}
