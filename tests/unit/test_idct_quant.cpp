// Phase 3.3l-0: host inv-quant + 4x4 IDCT goldens for FPGA bring-up.
// Synthetic DC residual + real Baseline first I_NxN 4x4 (pred=128, no neighbours).
// Exit: locked coeffs + recon pixels for HW status compare (3.3l-2+).
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

// Golden Baseline (scripts/gen_test_annexb_real.py): first residual scan-order coeffs.
// probeFirstI16Dc → tc=8 t1=3 coeff[0]=-24 (matches FPGA residual_dc).
static const int16_t kGoldCoeff[16] = {-24, 4, 4, 0, -4, 0, -1, 0, 0, -1, 1, 0, 1, 0, 0, 0};
static const int kGoldTc = 8;
static const int kGoldT1 = 3;
static const int kGoldQp = 25;

// pred=128 (unavailable A/L), dequant+idct_add of kGoldCoeff @ qp=25.
// Row-major y[r][c]:
static const uint8_t kGoldY[4][4] = {
    {73, 72, 76, 76},
    {72, 74, 71, 73},
    {76, 71, 32, 27},
    {76, 73, 27, 24},
};
static const int kGoldY00 = 73;
static const int kGoldMean = 62; // (sum+8)/16

// Synthetic DC-only: coeff[0]=-24, rest 0 → uniform 4x4 after idct_add onto 128.
static const int kSynthY = 62;

static void printBlock4x4(const char* label, const uint8_t y[4][4]) {
    std::printf("%s:\n", label);
    for (int r = 0; r < 4; ++r) {
        std::printf("  ");
        for (int c = 0; c < 4; ++c)
            std::printf("%3d", y[r][c]);
        std::printf("\n");
    }
}

static void printCoeffs(const char* label, const int16_t coeff[16]) {
    std::printf("%s:", label);
    for (int i = 0; i < 16; ++i)
        std::printf(" %d", coeff[i]);
    std::printf("\n");
}

// Known path: single DC coeff in scan pos 0, qp=25, pred=128.
static bool testSyntheticDc() {
    int16_t coeff[16]{};
    coeff[0] = -24; // matches golden residual_dc family
    int16_t blk[4][4];
    misterplex::recon::detail_r::dequant4x4(coeff, 16, kGoldQp, blk);

    // DC-only dequant lands only at (0,0)
    if (blk[0][0] != -4224) {
        std::printf("FAIL synth: dequant blk00=%d want -4224\n", blk[0][0]);
        return false;
    }
    for (int i = 0; i < 4; ++i) {
        for (int j = 0; j < 4; ++j) {
            if (i == 0 && j == 0)
                continue;
            if (blk[i][j] != 0) {
                std::printf("FAIL synth: non-zero AC dequant at [%d][%d]=%d\n", i, j, blk[i][j]);
                return false;
            }
        }
    }

    uint8_t dst[16];
    for (int i = 0; i < 16; ++i)
        dst[i] = 128;
    misterplex::recon::detail_r::idct4x4_add(blk, dst, 4);

    for (int i = 0; i < 16; ++i) {
        if (dst[i] != kSynthY) {
            std::printf("FAIL synth: y[%d]=%d want uniform %d\n", i, dst[i], kSynthY);
            return false;
        }
    }
    std::printf("OK synth: qp=%d coeff0=%d deq00=%d → y=%d (uniform 4x4)\n", kGoldQp, coeff[0],
                -4224, kSynthY);
    return true;
}

// Real annex-B first residual → dequant+IDCT onto pred=128 (first 4x4, no neighbours).
static bool testRealFirst4x4(const uint8_t* annexb, size_t n) {
    auto r = misterplex::cavlc::probeFirstI16Dc(annexb, n);
    if (!r.ok || r.total_coeff <= 0) {
        std::printf("FAIL real: residual probe ok=%d tc=%d\n", r.ok, r.total_coeff);
        return false;
    }
    if (r.total_coeff != kGoldTc || r.trailing_ones != kGoldT1 || r.coeff[0] != -24) {
        std::printf("FAIL real: tc=%d t1=%d coeff0=%d (want %d/%d/-24)\n", r.total_coeff,
                    r.trailing_ones, r.coeff[0], kGoldTc, kGoldT1);
        return false;
    }
    for (int i = 0; i < 16; ++i) {
        if (r.coeff[i] != kGoldCoeff[i]) {
            std::printf("FAIL real: coeff[%d]=%d want %d\n", i, r.coeff[i], kGoldCoeff[i]);
            printCoeffs("  got", r.coeff);
            printCoeffs("  exp", kGoldCoeff);
            return false;
        }
    }

    int16_t blk[4][4];
    misterplex::recon::detail_r::dequant4x4(r.coeff, 16, kGoldQp, blk);

    uint8_t flat[16];
    for (int i = 0; i < 16; ++i)
        flat[i] = 128;
    misterplex::recon::detail_r::idct4x4_add(blk, flat, 4);

    uint8_t y[4][4];
    int sum = 0;
    for (int row = 0; row < 4; ++row) {
        for (int col = 0; col < 4; ++col) {
            y[row][col] = flat[row * 4 + col];
            sum += y[row][col];
        }
    }
    const int mean = (sum + 8) / 16;

    printCoeffs("GOLD coeffs scan", r.coeff);
    std::printf("GOLD dequant 4x4 (row-major residual domain):\n");
    for (int i = 0; i < 4; ++i) {
        std::printf("  ");
        for (int j = 0; j < 4; ++j)
            std::printf("%6d", blk[i][j]);
        std::printf("\n");
    }
    printBlock4x4("GOLD recon Y 4x4 (pred=128, qp=25)", y);
    std::printf("GOLD y00=%d mean4x4=%d tc=%d t1=%d qp=%d\n", y[0][0], mean, r.total_coeff,
                r.trailing_ones, kGoldQp);

    if (y[0][0] != kGoldY00 || mean != kGoldMean) {
        std::printf("FAIL real: y00=%d mean=%d want y00=%d mean=%d\n", y[0][0], mean, kGoldY00,
                    kGoldMean);
        return false;
    }
    for (int row = 0; row < 4; ++row) {
        for (int col = 0; col < 4; ++col) {
            if (y[row][col] != kGoldY[row][col]) {
                std::printf("FAIL real: y[%d][%d]=%d want %d\n", row, col, y[row][col],
                            kGoldY[row][col]);
                return false;
            }
        }
    }
    std::printf("OK real: first I_NxN 4x4 bit-exact vs locked golden\n");
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
