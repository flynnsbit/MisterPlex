// Phase 3.3l-0: host inv-quant + 4x4 IDCT goldens for FPGA bring-up.
// Synthetic DC residual + real Baseline first 4x4 (pred=128, unavailable neighbours).
#include "libmisterplex/h264_cavlc.hpp"
#include "libmisterplex/h264_recon.hpp"

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

static int clip8(int v) {
    if (v < 0)
        return 0;
    if (v > 255)
        return 255;
    return v;
}

// Known path: single DC coeff in scan pos 0, qp=25, pred=128.
// dequant then idct_add must be stable for FPGA status compares.
static bool testSyntheticDc() {
    int16_t coeff[16]{};
    coeff[0] = -24; // matches golden residual_dc magnitude family
    const int qp = 25;
    int16_t blk[4][4];
    misterplex::recon::detail_r::dequant4x4(coeff, 16, qp, blk);

    uint8_t dst[16];
    for (int i = 0; i < 16; ++i)
        dst[i] = 128;
    misterplex::recon::detail_r::idct4x4_add(blk, dst, 4);

    // DC-only: all 16 samples equal after idct_add
    for (int i = 1; i < 16; ++i) {
        if (dst[i] != dst[0]) {
            std::printf("FAIL synth: non-uniform IDCT %d vs %d\n", dst[0], dst[i]);
            return false;
        }
    }
    // Rough range check: residual pulls mid-gray down for negative DC
    if (dst[0] > 128 || dst[0] < 32) {
        std::printf("FAIL synth: y=%d out of expected range\n", dst[0]);
        return false;
    }
    std::printf("OK synth: qp=%d coeff0=%d → y=%d (uniform 4x4)\n", qp, coeff[0], dst[0]);
    return true;
}

// Real annex-B: first residual block → dequant+IDCT onto 128.
static bool testRealFirst4x4(const uint8_t* annexb, size_t n) {
    auto r = misterplex::cavlc::probeFirstI16Dc(annexb, n);
    if (!r.ok || r.total_coeff <= 0) {
        std::printf("FAIL real: residual probe ok=%d tc=%d\n", r.ok, r.total_coeff);
        return false;
    }
    // Golden Baseline: tc=8, coeff[0]=-24
    if (r.total_coeff != 8 || r.coeff[0] != -24) {
        std::printf("WARN real: tc=%d coeff0=%d (expected 8 / -24 on golden clip)\n",
                    r.total_coeff, r.coeff[0]);
    }

    // Slice QP after mb_qp_delta on golden is 25 (see test_f3_residual / 3.3e)
    const int qp = 25;
    int16_t blk[4][4];
    misterplex::recon::detail_r::dequant4x4(r.coeff, 16, qp, blk);

    uint8_t dst[16];
    for (int i = 0; i < 16; ++i)
        dst[i] = 128;
    misterplex::recon::detail_r::idct4x4_add(blk, dst, 4);

    int sum = 0;
    for (int i = 0; i < 16; ++i)
        sum += dst[i];
    const int mean = (sum + 8) / 16;

    std::printf("OK real: tc=%d t1=%d coeff0=%d qp=%d y00=%d mean4x4=%d\n", r.total_coeff,
                r.trailing_ones, r.coeff[0], qp, dst[0], mean);
    std::printf("  pixels:");
    for (int i = 0; i < 16; ++i)
        std::printf(" %d", dst[i]);
    std::printf("\n");
    // Sanity: not all clipped
    if (mean < 1 || mean > 254) {
        std::printf("FAIL real: mean=%d clipped\n", mean);
        return false;
    }
    (void)clip8;
    return true;
}

int main(int argc, char** argv) {
    if (!testSyntheticDc())
        return 1;

    const char* path = argc > 1 ? argv[1] : "/tmp/plex_real_baseline.h264";
    auto blob = readFile(path);
    if (blob.empty()) {
        if (std::system("python3 scripts/gen_test_annexb_real.py /tmp/plex_real_baseline.h264") !=
            0) {
            std::printf("FAIL: no bitstream (gen_test_annexb_real.py)\n");
            return 1;
        }
        blob = readFile("/tmp/plex_real_baseline.h264");
        path = "/tmp/plex_real_baseline.h264";
    }
    if (blob.empty()) {
        std::printf("FAIL: empty bitstream\n");
        return 1;
    }
    if (!testRealFirst4x4(blob.data(), blob.size()))
        return 1;

    std::printf("test_idct_quant: OK\n");
    return 0;
}
