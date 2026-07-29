#include "Vh264_decode_core_p16z_tb.h"
#include "verilated.h"

#include <algorithm>
#include <array>
#include <cstdint>
#include <iostream>
#include <string>
#include <array>
#include <vector>

namespace {

constexpr int FRAME_W = 64;
constexpr int FRAME_H = 32;
constexpr int MB_W = FRAME_W / 16;
constexpr int MB_H = FRAME_H / 16;
constexpr int Y_BYTES = FRAME_W * FRAME_H;
constexpr int C_W = FRAME_W / 2;
constexpr int C_H = FRAME_H / 2;
constexpr int C_BYTES = C_W * C_H;
constexpr uint32_t REF_BASE = 0x4000;
constexpr uint32_t WRITE_BASE = 0x1000;
constexpr int MV_Y_QPEL = 0;
constexpr int kMeasuredP16RealPCycles = 131002;
constexpr int kP16RealPTimeoutCycles = (kMeasuredP16RealPCycles * 17 + 9) / 10;

constexpr int kScheduledLumaBlocks = 16;
// Product chroma residual schedule: DC_U, DC_V, then 8 AC (U0..U3,V0..V3).
constexpr int kChrDcU = 16;
constexpr int kChrDcV = 17;
constexpr int kChrAc0 = 18;
constexpr int kScheduledChromaBlocks = 10; // 2 DC + 8 AC
constexpr int kScheduledBlocks = kScheduledLumaBlocks + kScheduledChromaBlocks;

// coded_block_pattern gating. Macroblock 2 deliberately leaves one luma 8x8
// group and both chroma components uncoded so the product core's cbp gate is
// exercised rather than assumed: uncoded blocks must contribute no residual and
// must consume no bits from the macroblock's CAVLC chain.
constexpr int kCbpGatedMb = 2;
int cbpLumaFor(int mbIdx) { return mbIdx == kCbpGatedMb ? 0xb : 0xf; }
int cbpChromaFor(int mbIdx) { return mbIdx == kCbpGatedMb ? 0x0 : 0x2; }

bool isChrDcBlock(int block) { return block == kChrDcU || block == kChrDcV; }
bool isChrAcBlock(int block) { return block >= kChrAc0 && block < kScheduledBlocks; }

bool blockCoded(int mbIdx, int block) {
    if (block < kScheduledLumaBlocks) {
        // The core indexes 4x4 blocks in raster order, so the 8x8 cbp group is
        // {block_y[1], block_x[1]}.
        const int group = ((block >> 3) & 1) * 2 + ((block >> 1) & 1);
        return ((cbpLumaFor(mbIdx) >> group) & 1) != 0;
    }
    if (isChrDcBlock(block)) return cbpChromaFor(mbIdx) != 0;
    if (isChrAcBlock(block)) return cbpChromaFor(mbIdx) == 0x2;
    return false;
}

int residualBlockSample(int mbIdx, int block, int pos) {
    static constexpr int kScan14[16] = {19, 11, -5, -13, 19, 11, -5, -13,
                                        19, 11, -5, -13, 19, 11, -5, -13};
    static constexpr int kScan11[16] = {7, 5, 1, -1, 7, 5, 1, -1,
                                        7, 5, 1, -1, 7, 5, 1, -1};
    static constexpr int kHighClamp[16] = {264, 262, 258, 256, 264, 262, 258, 256,
                                           264, 262, 258, 256, 264, 262, 258, 256};
    if (!blockCoded(mbIdx, block)) return 0;
    // Chroma DC has no direct plane samples; AC slots carry DC-only IDCT after
    // 2x2 Hadamard inject (empty AC). QP_Y=26 / QPc=26, DC level ±1 → ±2.
    if (isChrDcBlock(block)) return 0;
    if (isChrAcBlock(block)) {
        const bool isV = block >= (kChrAc0 + 4);
        return isV ? -2 : 2;
    }
    if (mbIdx == 1 && block == 0) return kHighClamp[pos];
    return (block & 1) ? kScan11[pos] : kScan14[pos];
}

// The decoder picks the coeff_token VLC table from nC (H.264 9.2.1), derived
// from the total_coeff of the left and upper 4x4 neighbours, so the fixture
// cannot hardcode one table: it has to encode every block with the table the
// decoder will select. codeFor() supplies the two encodings of each coefficient
// pattern; only the coeff_token prefix differs, the suffixes are identical.
// Chroma DC uses table4 (nC=-1). Chroma AC uses neighbour nC tables; fixture
// emits empty AC (tc=0) so residual is DC-only (non-zero from Hadamard inject).
std::string codeFor(int mbIdx, int block, int table) {
    if (isChrDcBlock(block)) {
        // table4: TotalCoeff=1 TrailingOnes=1 → "1", sign, total_zeros=0 → "1".
        // U uses +1 (sign 0), V uses -1 (sign 1) so U/V residual planes differ.
        if (block == kChrDcV) return "111";
        return "101";
    }
    if (isChrAcBlock(block)) {
        // max15 AC TotalCoeff=0: table0/1/2/3 all accept leading '1' for tc=0
        return "1";
    }
    if (table > 1) {
        std::cerr << "FAIL h264_decode_core residual fixture: no encoding for coeff_token table "
                  << table << " (mb=" << mbIdx << " block=" << block << ")\n";
        std::exit(1);
    }
    if (mbIdx == 1 && block == 0)  // total_coeff=2 trailing_ones=1, scan coeffs [80, 1]
        return std::string(table ? "00111" : "000100") + "00000000000000001000001111110111";
    const bool patternA = (block & 1) != 0;
    if (patternA)  // total_coeff=2 trailing_ones=2, scan coeffs [1, 1]
        return std::string(table ? "011" : "001") + "00111";
    // total_coeff=2 trailing_ones=0, scan coeffs [1, 4]
    return std::string(table ? "000111" : "00000111") + "00001100111";
}

std::string residualBlockBits(int mbIdx, int block);

struct Write {
    uint32_t addr = 0;
    uint8_t data = 0;
};

struct MbCase {
    int mbX = 0;
    int mbY = 0;
    int mvdX = 0;
    int mvdY = 0;
    int predX = 0;
    int predY = 0;
    int mvX = 0;
    int mvY = 0;
    int residualBitOffset = 0;
    int rbspWindowBase = 0;
};

const std::vector<MbCase> kCases = {
    {1, 0, 2, 0, 0, 0, 2, 0, 296, 32},
    {2, 0, 3, 0, 2, 0, 5, 0, 400, 48},
    {3, 0, 4, 0, 5, 0, 9, 0, 504, 56},
};

// Independent model of the nC neighbour walk the core performs, run once over
// the fixture's macroblocks in decode order. Uncoded blocks contribute
// total_coeff 0 to their neighbours and emit no bits at all, which is what makes
// the cbp gate observable: get it wrong in the RTL and every later block in the
// macroblock reads the wrong bits.
const std::vector<std::array<std::string, kScheduledBlocks>>& residualPlan() {
    static const std::vector<std::array<std::string, kScheduledBlocks>> plan = [] {
        std::vector<std::array<std::string, kScheduledBlocks>> out(kCases.size());
        const int firstMb = kCases.front().mbY * MB_W + kCases.front().mbX;
        int left[4] = {0, 0, 0, 0};
        bool leftValid = false;
        std::vector<std::array<int, 4>> top(MB_W, {0, 0, 0, 0});
        std::vector<char> topValid(MB_W, 0);
        for (size_t mbIdx = 0; mbIdx < kCases.size(); ++mbIdx) {
            const MbCase& mb = kCases[mbIdx];
            const int mbIndex = mb.mbY * MB_W + mb.mbX;
            const bool leftMbAvailable = mb.mbX != 0 && (mbIndex - 1) >= firstMb;
            const bool upMbAvailable = mb.mbY != 0 && (mbIndex - MB_W) >= firstMb;
            int cur[16] = {0};
            for (int block = 0; block < kScheduledBlocks; ++block) {
                if (!blockCoded(static_cast<int>(mbIdx), block)) continue;
                int table = 0;
                if (block < kScheduledLumaBlocks) {
                    const int bx = block & 3;
                    const int by = (block >> 2) & 3;
                    const bool nAav = (bx != 0) || (leftValid && leftMbAvailable);
                    const bool nBav = (by != 0) || (topValid[mb.mbX] && upMbAvailable);
                    const int nA = bx ? cur[by * 4 + bx - 1] : left[by];
                    const int nB = by ? cur[(by - 1) * 4 + bx] : top[mb.mbX][bx];
                    const int nC = (nAav && nBav) ? ((nA + nB + 1) >> 1) : nAav ? nA : nBav ? nB : 0;
                    table = nC < 2 ? 0 : nC < 4 ? 1 : nC < 8 ? 2 : 3;
                    cur[block] = 2;  // every luma coefficient pattern here has total_coeff 2
                } else if (isChrDcBlock(block)) {
                    table = 4;
                } else {
                    table = 0; // empty AC; table unused beyond tc=0 token
                }
                out[mbIdx][block] = codeFor(static_cast<int>(mbIdx), block, table);
            }
            leftValid = true;
            for (int i = 0; i < 4; ++i) {
                left[i] = cur[i * 4 + 3];
                top[mb.mbX][i] = cur[12 + i];
            }
            topValid[mb.mbX] = 1;
        }
        return out;
    }();
    return plan;
}

std::string residualBlockBits(int mbIdx, int block) {
    return residualPlan().at(static_cast<size_t>(mbIdx)).at(static_cast<size_t>(block));
}

uint32_t i420Addr(uint32_t base, int plane, int x, int y) {
    if (plane == 0) return base + static_cast<uint32_t>(y * FRAME_W + x);
    if (plane == 1) return base + Y_BYTES + static_cast<uint32_t>(y * C_W + x);
    return base + Y_BYTES + C_BYTES + static_cast<uint32_t>(y * C_W + x);
}

uint32_t expectedWriteAddr(const MbCase& mb, int idx) {
    if (idx < 256) {
        const int sx = idx & 15;
        const int sy = idx >> 4;
        return i420Addr(WRITE_BASE, 0, mb.mbX * 16 + sx, mb.mbY * 16 + sy);
    }
    if (idx < 320) {
        const int rel = idx - 256;
        const int sx = rel & 7;
        const int sy = rel >> 3;
        return i420Addr(WRITE_BASE, 1, mb.mbX * 8 + sx, mb.mbY * 8 + sy);
    }
    const int rel = idx - 320;
    const int sx = rel & 7;
    const int sy = rel >> 3;
    return i420Addr(WRITE_BASE, 2, mb.mbX * 8 + sx, mb.mbY * 8 + sy);
}

const char* planeName(int idx) {
    if (idx < 256) return "Y";
    if (idx < 320) return "U";
    return "V";
}

int clampInt(int v, int lo, int hi) { return std::max(lo, std::min(v, hi)); }

uint8_t refSample(int plane, int x, int y) {
    if (plane == 0) {
        x = clampInt(x, 0, FRAME_W - 1);
        y = clampInt(y, 0, FRAME_H - 1);
        if (y <= 4 && x >= 12 && x <= 20) return 73;
        return static_cast<uint8_t>((37 + x * 11 + y * 17 + ((x * y) % 23)) & 0xff);
    }
    x = clampInt(x, 0, C_W - 1);
    y = clampInt(y, 0, C_H - 1);
    if (plane == 1) return static_cast<uint8_t>((91 + x * 7 + y * 13 + ((x + 3 * y) % 29)) & 0xff);
    return static_cast<uint8_t>((23 + x * 19 + y * 5 + ((5 * x + y) % 31)) & 0xff);
}

uint8_t refSampleFromAddr(uint32_t addr) {
    if (addr < REF_BASE) return 0;
    const uint32_t off = addr - REF_BASE;
    if (off < Y_BYTES) return refSample(0, off % FRAME_W, off / FRAME_W);
    if (off < Y_BYTES + C_BYTES) {
        const uint32_t c = off - Y_BYTES;
        return refSample(1, c % C_W, c / C_W);
    }
    if (off < Y_BYTES + 2 * C_BYTES) {
        const uint32_t c = off - Y_BYTES - C_BYTES;
        return refSample(2, c % C_W, c / C_W);
    }
    return 0;
}

int residualSample(int mbIdx, int localIdx) {
    if (localIdx < 256) {
        const int sx = localIdx & 15;
        const int sy = localIdx >> 4;
        const int block = (sy >> 2) * 4 + (sx >> 2);
        const int pos = (sy & 3) * 4 + (sx & 3);
        return residualBlockSample(mbIdx, block, pos);
    }
    // Chroma planes: AC blocks start at kChrAc0 (U0..U3 then V0..V3).
    if (localIdx < 320) {
        const int rel = localIdx - 256;
        const int sx = rel & 7;
        const int sy = rel >> 3;
        const int block = kChrAc0 + (sy >> 2) * 2 + (sx >> 2);
        const int pos = (sy & 3) * 4 + (sx & 3);
        return residualBlockSample(mbIdx, block, pos);
    }
    const int rel = localIdx - 320;
    const int sx = rel & 7;
    const int sy = rel >> 3;
    const int block = kChrAc0 + 4 + (sy >> 2) * 2 + (sx >> 2);
    const int pos = (sy & 3) * 4 + (sx & 3);
    return residualBlockSample(mbIdx, block, pos);
}

uint8_t clipU8(int value) {
    if (value < 0) return 0;
    if (value > 255) return 255;
    return static_cast<uint8_t>(value);
}

int clip1(int v) { return clampInt(v, 0, 255); }
int avg2(int a, int b) { return (a + b + 1) >> 1; }

// Block motion compensation reference model: one 21x21 luma window and two
// 9x9 chroma windows are fetched per macroblock, then the whole 16x16 / 8x8
// prediction block is produced from those windows (h264_inter_mc_part).
using LumaWin = std::array<uint8_t, 441>;
using ChromaWin = std::array<uint8_t, 81>;

LumaWin lumaRefWindow(const MbCase& mb) {
    LumaWin win{};
    const int originX = mb.mbX * 16 + (mb.mvX >> 2);
    const int originY = mb.mbY * 16 + (mb.mvY >> 2);
    for (int i = 0; i < 441; ++i)
        win[i] = refSample(0, originX + (i % 21) - 2, originY + (i / 21) - 2);
    return win;
}

ChromaWin chromaRefWindow(const MbCase& mb, int plane) {
    ChromaWin win{};
    const int originX = mb.mbX * 8 + (mb.mvX >> 3);
    const int originY = mb.mbY * 8 + (mb.mvY >> 3);
    for (int i = 0; i < 81; ++i)
        win[i] = refSample(plane, originX + (i % 9), originY + (i / 9));
    return win;
}

int winPix(const LumaWin& w, int row, int col) { return w[row * 21 + col]; }

int hrawWin(const LumaWin& w, int row, int col) {
    return winPix(w, row, col - 2) - 5 * winPix(w, row, col - 1) + 20 * winPix(w, row, col) +
           20 * winPix(w, row, col + 1) - 5 * winPix(w, row, col + 2) + winPix(w, row, col + 3);
}
int halfHWin(const LumaWin& w, int row, int col) { return clip1((hrawWin(w, row, col) + 16) >> 5); }
int halfVWin(const LumaWin& w, int row, int col) {
    return clip1((winPix(w, row - 2, col) - 5 * winPix(w, row - 1, col) + 20 * winPix(w, row, col) +
                  20 * winPix(w, row + 1, col) - 5 * winPix(w, row + 2, col) + winPix(w, row + 3, col) + 16) >> 5);
}
int halfCWin(const LumaWin& w, int row, int col) {
    const int sum = hrawWin(w, row - 2, col) - 5 * hrawWin(w, row - 1, col) +
                    20 * hrawWin(w, row, col) + 20 * hrawWin(w, row + 1, col) -
                    5 * hrawWin(w, row + 2, col) + hrawWin(w, row + 3, col);
    return clip1((sum + 512) >> 10);
}

uint8_t lumaPred(const MbCase& mb, int sampleIdx) {
    const LumaWin w = lumaRefWindow(mb);
    const int col = (sampleIdx & 15) + 2;
    const int row = (sampleIdx >> 4) + 2;
    const int fx = mb.mvX & 3;
    const int fy = mb.mvY & 3;
    switch ((fy << 2) | fx) {
    case 0x0: return static_cast<uint8_t>(winPix(w, row, col));
    case 0x1: return static_cast<uint8_t>(avg2(winPix(w, row, col), halfHWin(w, row, col)));
    case 0x2: return static_cast<uint8_t>(halfHWin(w, row, col));
    case 0x3: return static_cast<uint8_t>(avg2(halfHWin(w, row, col), winPix(w, row, col + 1)));
    case 0x4: return static_cast<uint8_t>(avg2(winPix(w, row, col), halfVWin(w, row, col)));
    case 0x5: return static_cast<uint8_t>(avg2(halfHWin(w, row, col), halfVWin(w, row, col)));
    case 0x6: return static_cast<uint8_t>(avg2(halfHWin(w, row, col), halfCWin(w, row, col)));
    case 0x7: return static_cast<uint8_t>(avg2(halfHWin(w, row, col), halfVWin(w, row, col + 1)));
    case 0x8: return static_cast<uint8_t>(halfVWin(w, row, col));
    case 0x9: return static_cast<uint8_t>(avg2(halfVWin(w, row, col), halfCWin(w, row, col)));
    case 0xa: return static_cast<uint8_t>(halfCWin(w, row, col));
    case 0xb: return static_cast<uint8_t>(avg2(halfCWin(w, row, col), halfVWin(w, row, col + 1)));
    case 0xc: return static_cast<uint8_t>(avg2(halfVWin(w, row, col), winPix(w, row + 1, col)));
    case 0xd: return static_cast<uint8_t>(avg2(halfHWin(w, row + 1, col), halfVWin(w, row, col)));
    case 0xe: return static_cast<uint8_t>(avg2(halfCWin(w, row, col), halfHWin(w, row + 1, col)));
    default: return static_cast<uint8_t>(avg2(halfHWin(w, row + 1, col), halfVWin(w, row, col + 1)));
    }
}

uint8_t chromaPred(const MbCase& mb, int sampleIdx) {
    const int plane = (sampleIdx < 320) ? 1 : 2;
    const int rel = (sampleIdx < 320) ? sampleIdx - 256 : sampleIdx - 320;
    const int sx = rel & 7;
    const int sy = rel >> 3;
    const ChromaWin w = chromaRefWindow(mb, plane);
    const int fx = mb.mvX & 7;
    const int fy = mb.mvY & 7;
    const int p00 = w[sy * 9 + sx];
    const int p10 = w[sy * 9 + sx + 1];
    const int p01 = w[(sy + 1) * 9 + sx];
    const int p11 = w[(sy + 1) * 9 + sx + 1];
    const int sum = (8 - fx) * (8 - fy) * p00 + fx * (8 - fy) * p10 +
                    (8 - fx) * fy * p01 + fx * fy * p11 + 32;
    return static_cast<uint8_t>(sum >> 6);
}

uint8_t predSample(const MbCase& mb, int idx) { return (idx < 256) ? lumaPred(mb, idx) : chromaPred(mb, idx); }
uint8_t expectedRecon(int mbIdx, const MbCase& mb, int localIdx) { return clipU8(predSample(mb, localIdx) + residualSample(mbIdx, localIdx)); }

bool checkResidualFixture() {
    int nonzero = 0;
    int positionDependent = 0;
    int uncoded = 0;
    for (int mb = 0; mb < static_cast<int>(kCases.size()); ++mb) {
        for (int block = 0; block < kScheduledBlocks; ++block) {
            if (!blockCoded(mb, block)) {
                for (int i = 0; i < 16; ++i) {
                    if (residualBlockSample(mb, block, i) != 0) {
                        std::cerr << "FAIL h264_decode_core residual fixture: mb=" << mb
                                  << " block=" << block << " is cbp-uncoded but not zero\n";
                        return false;
                    }
                }
                ++uncoded;
                continue;
            }
            // Chroma DC/AC fixture is intentionally empty (tc=0); sample plane is 0.
            if (isChrDcBlock(block) || isChrAcBlock(block)) continue;
            bool anyNonzero = false;
            bool differsFromFirst = false;
            for (int i = 0; i < 16; ++i) {
                const int v = residualBlockSample(mb, block, i);
                anyNonzero |= (v != 0);
                differsFromFirst |= (v != residualBlockSample(mb, block, 0));
            }
            if (!anyNonzero || !differsFromFirst) {
                std::cerr << "FAIL h264_decode_core residual fixture: mb=" << mb
                          << " block=" << block << " is degenerate\n";
                return false;
            }
            for (int i = 0; i < 16; ++i) nonzero += (residualBlockSample(mb, block, i) != 0);
            ++positionDependent;
        }
    }
    int uvDiff = 0;
    for (int y = 0; y < C_H; ++y)
        for (int x = 0; x < C_W; ++x)
            uvDiff += (refSample(1, x, y) != refSample(2, x, y));
    if (residualBlockSample(0, 0, 0) == residualBlockSample(0, 0, 1)) {
        std::cerr << "FAIL h264_decode_core residual fixture: scan-order sentinel aliases coeff positions\n";
        return false;
    }
    if (uvDiff < C_BYTES - 2) {
        std::cerr << "FAIL h264_decode_core residual fixture: U/V reference planes are not distinguishable\n";
        return false;
    }
    std::cout << "INFO h264_decode_core residual fixture: " << positionDependent
              << " coded luma CAVLC blocks are nonzero and position-dependent, " << uncoded
              << " cbp-uncoded blocks are zero (of " << kScheduledBlocks * static_cast<int>(kCases.size())
              << " scheduled, 16Y+2DC+8AC per MB); nonzero_samples="
              << nonzero << " uv_ref_distinguishable_samples=" << uvDiff
              << " chroma_dc_only_residual_ok scan_order_sentinel=19/11\n";
    return true;
}

constexpr int kLumaWinSamples = 441;
constexpr int kChromaWinSamples = 81;

std::size_t readsPerMb() { return kLumaWinSamples + 2 * kChromaWinSamples; }
std::size_t expectedReadCount() { return readsPerMb() * kCases.size(); }

uint32_t expectedReadAddr(const MbCase& mb, int localOrdinal) {
    if (localOrdinal < kLumaWinSamples) {
        const int x = clampInt(mb.mbX * 16 + (mb.mvX >> 2) + (localOrdinal % 21) - 2, 0, FRAME_W - 1);
        const int y = clampInt(mb.mbY * 16 + (mb.mvY >> 2) + (localOrdinal / 21) - 2, 0, FRAME_H - 1);
        return i420Addr(REF_BASE, 0, x, y);
    }
    const int rel = (localOrdinal < kLumaWinSamples + kChromaWinSamples)
                        ? localOrdinal - kLumaWinSamples
                        : localOrdinal - kLumaWinSamples - kChromaWinSamples;
    const int plane = (localOrdinal < kLumaWinSamples + kChromaWinSamples) ? 1 : 2;
    const int x = clampInt(mb.mbX * 8 + (mb.mvX >> 3) + (rel % 9), 0, C_W - 1);
    const int y = clampInt(mb.mbY * 8 + (mb.mvY >> 3) + (rel / 9), 0, C_H - 1);
    return i420Addr(REF_BASE, plane, x, y);
}

uint32_t expectedReadAddrForOrdinal(std::size_t ord) {
    const std::size_t mbIdx = ord / readsPerMb();
    const int localOrdinal = static_cast<int>(ord % readsPerMb());
    return expectedReadAddr(kCases.at(mbIdx), localOrdinal);
}

bool expectedChromaRightClamp(const MbCase& mb, int localOrdinal) {
    if (localOrdinal < kLumaWinSamples) return false;
    const int rel = (localOrdinal < kLumaWinSamples + kChromaWinSamples)
                        ? localOrdinal - kLumaWinSamples
                        : localOrdinal - kLumaWinSamples - kChromaWinSamples;
    const int unclampedX = mb.mbX * 8 + (mb.mvX >> 3) + (rel % 9);
    return unclampedX > C_W - 1;
}

class Sim {
public:
    Vh264_decode_core_p16z_tb top{};
    uint64_t cycles = 0;
    std::vector<uint32_t> reads;
    std::vector<Write> writes;
    std::vector<uint16_t> rbspRequests;
    bool frameDoneSeen = false;
    bool pendingValid = false;
    uint8_t pendingData = 0;

    void tick() {
        top.clk = 0;
        top.dpb_rd_valid = pendingValid ? 1 : 0;
        top.dpb_rd_data = pendingData;
        top.eval();
        top.clk = 1;
        top.eval();
        if (top.dpb_wr_en) writes.push_back({top.dpb_wr_addr, static_cast<uint8_t>(top.dpb_wr_data)});
        if (top.rbsp_request_valid) rbspRequests.push_back(top.rbsp_request_offset);
        if (top.frame_done) frameDoneSeen = true;
        const bool sawRead = top.dpb_rd_en;
        const uint32_t readAddr = top.dpb_rd_addr;
        top.clk = 0;
        top.eval();
        ++cycles;

        pendingValid = sawRead;
        if (sawRead) {
            reads.push_back(readAddr);
            pendingData = refSampleFromAddr(readAddr);
        } else {
            pendingData = 0;
        }
    }
};

void clearInputs(Sim& s) {
    s.top.slice_start = 0;
    s.top.first_mb_in_slice = 0;
    s.top.mb_type_valid = 0;
    s.top.mb_type = 0;
    s.top.mb_skip = 0;
    s.top.mb_residual_bit_offset = 0;
    s.top.cbp_luma = 0;
    s.top.cbp_chroma = 0;
    s.top.p16_zero_mv_valid = 0;
    s.top.p16_mb_x = 0;
    s.top.p16_mb_y = 0;
    s.top.p16_mb_is_ref = 0;
    s.top.dpb_ref_base = REF_BASE;
    s.top.dpb_write_base = WRITE_BASE;
    s.top.p16_mv_x_qpel = 0;
    s.top.p16_mv_y_qpel = 0;
    s.top.p16_mvd_x_qpel = 0;
    s.top.p16_mvd_y_qpel = 0;
    s.top.p16_ref_idx_l0 = 0;
    s.top.dpb_rd_valid = 0;
    s.top.dpb_rd_data = 0;
    s.top.rbsp_window_base = 0;
    for (int i = 0; i < 64; ++i) s.top.rbsp_byte_in[i] = 0;
    for (int i = 0; i < 256; ++i) s.top.p16_residual_y[i] = 0;
    for (int i = 0; i < 64; ++i) {
        s.top.p16_residual_u[i] = 0;
        s.top.p16_residual_v[i] = 0;
    }
}

void loadScheduledResidualRbsp(Sim& s, int mbOrdinal) {
    for (int i = 0; i < 64; ++i) s.top.rbsp_byte_in[i] = 0;
    auto putBits = [&](int bitOffset, const char* bits) {
        for (int i = 0; bits[i] != '\0'; ++i) {
            if (bits[i] == '1') s.top.rbsp_byte_in[(bitOffset + i) >> 3] |= 1u << (7 - ((bitOffset + i) & 7));
        }
    };
    const MbCase& mb = kCases.at(mbOrdinal);
    int bitOffset = mb.residualBitOffset - mb.rbspWindowBase * 8;
    for (int block = 0; block < kScheduledBlocks; ++block) {
        const std::string bits = residualBlockBits(mbOrdinal, block);
        putBits(bitOffset, bits.c_str());
        bitOffset += static_cast<int>(bits.size());
    }
}

void reset(Sim& s) {
    clearInputs(s);
    s.top.reset = 1;
    s.tick();
    s.tick();
    s.top.reset = 0;
    s.tick();
}

void driveSliceStart(Sim& s) {
    s.top.first_mb_in_slice = kCases.front().mbY * MB_W + kCases.front().mbX;
    s.top.slice_start = 1;
    s.tick();
    s.top.slice_start = 0;
    s.tick();
}

void driveMb(Sim& s, int mbOrdinal) {
    loadScheduledResidualRbsp(s, mbOrdinal);
    const MbCase& mb = kCases.at(mbOrdinal);
    s.top.p16_mb_x = mb.mbX;
    s.top.p16_mb_y = mb.mbY;
    s.top.p16_mb_is_ref = 1;
    s.top.dpb_ref_base = REF_BASE;
    s.top.dpb_write_base = WRITE_BASE;
    s.top.p16_mv_x_qpel = mb.mvX;
    s.top.p16_mv_y_qpel = mb.mvY;
    s.top.p16_mvd_x_qpel = mb.mvdX;
    s.top.p16_mvd_y_qpel = mb.mvdY;
    s.top.p16_ref_idx_l0 = 0;
    s.top.mb_residual_bit_offset = mb.residualBitOffset;
    s.top.cbp_luma = cbpLumaFor(mbOrdinal);
    s.top.cbp_chroma = cbpChromaFor(mbOrdinal);
    s.top.rbsp_window_base = mb.rbspWindowBase;
    s.top.mb_type = 0;
    s.top.mb_skip = 0;
    s.top.mb_type_valid = 1;
    s.tick();
    s.top.mb_type_valid = 0;
}

bool waitForWrites(Sim& s, std::size_t wantWrites) {
    for (int i = 0; i < kP16RealPTimeoutCycles; ++i) {
        if (!s.top.busy && s.writes.size() >= wantWrites) return true;
        s.tick();
    }
    return !s.top.busy && s.writes.size() >= wantWrites;
}

int checkScoreboard(const Sim& s) {
    const std::size_t wantReads = expectedReadCount();
    const std::size_t wantWrites = kCases.size() * 384;
    if (s.reads.size() != wantReads) {
        std::cerr << "FAIL h264_decode_core p16x16 real-P scoreboard: read count "
                  << s.reads.size() << " want=" << wantReads << "\n";
        return 1;
    }
    if (s.writes.size() != wantWrites) {
        std::cerr << "FAIL h264_decode_core p16x16 real-P scoreboard: write count "
                  << s.writes.size() << " want=" << wantWrites << "\n";
        return 1;
    }
    if (s.rbspRequests.size() != kCases.size()) {
        std::cerr << "FAIL h264_decode_core p16x16 syntax scoreboard: rbsp request count "
                  << s.rbspRequests.size() << " want=" << kCases.size() << "\n";
        return 1;
    }
    for (std::size_t mb = 0; mb < kCases.size(); ++mb) {
        const int wantReq = kCases.at(mb).residualBitOffset >> 3;
        if (s.rbspRequests.at(mb) != wantReq) {
            std::cerr << "FAIL h264_decode_core p16x16 syntax scoreboard: mb=(" << kCases.at(mb).mbX
                      << "," << kCases.at(mb).mbY << ") rbsp_request_offset got="
                      << s.rbspRequests.at(mb) << " want=" << wantReq
                      << " residual_bit_offset=" << kCases.at(mb).residualBitOffset << "\n";
            return 1;
        }
    }
    int chromaRightClampReads = 0;
    for (std::size_t i = 0; i < s.reads.size(); ++i) {
        const uint32_t wantReadAddr = expectedReadAddrForOrdinal(i);
        const MbCase& readMb = kCases.at(i / readsPerMb());
        chromaRightClampReads += expectedChromaRightClamp(readMb, static_cast<int>(i % readsPerMb()));
        if (s.reads.at(i) != wantReadAddr) {
            const MbCase& mb = kCases.at(i / readsPerMb());
            std::cerr << "FAIL h264_decode_core p16x16 real-P scoreboard: mb=(" << mb.mbX << "," << mb.mbY
                      << ") read_ordinal " << i
                      << " got_addr=0x" << std::hex << s.reads.at(i)
                      << " want_addr=0x" << wantReadAddr << std::dec << "\n";
            return 1;
        }
    }
    int clipped = 0;
    int clipLow = 0;
    int clipHigh = 0;
    for (std::size_t mbIdx = 0; mbIdx < kCases.size(); ++mbIdx) {
        const MbCase& mb = kCases.at(mbIdx);
        for (int local = 0; local < 384; ++local) {
            const int global = static_cast<int>(mbIdx * 384 + local);
            const Write& w = s.writes.at(global);
            const uint32_t wantWriteAddr = expectedWriteAddr(mb, local);
            if (w.addr != wantWriteAddr) {
                std::cerr << "FAIL h264_decode_core p16x16 real-P scoreboard: mb=(" << mb.mbX << "," << mb.mbY
                          << ") write sample " << local << " plane=" << planeName(local)
                          << " got_addr=0x" << std::hex << w.addr
                          << " want_addr=0x" << wantWriteAddr << std::dec << "\n";
                return 1;
            }
            const int pred = predSample(mb, local);
            const int residual = residualSample(static_cast<int>(mbIdx), local);
            const uint8_t want = expectedRecon(static_cast<int>(mbIdx), mb, local);
            if (pred + residual < 0) {
                ++clipped;
                ++clipLow;
            } else if (pred + residual > 255) {
                ++clipped;
                ++clipHigh;
            }
            if (w.data != want) {
                std::cerr << "FAIL h264_decode_core p16x16 real-P scoreboard: mb=(" << mb.mbX << "," << mb.mbY
                          << ") sample " << local << " plane=" << planeName(local)
                          << " got=" << int(w.data)
                          << " want=" << int(want)
                          << " pred=" << pred
                          << " residual=" << residual << "\n";
                return 1;
            }
        }
    }
    if (chromaRightClampReads < 1) {
        std::cerr << "FAIL h264_decode_core p16x16 real-P scoreboard: chroma_right_clamp_reads="
                  << chromaRightClampReads << " want>=1\n";
        return 1;
    }
    if (s.frameDoneSeen) {
        std::cerr << "FAIL h264_decode_core p16x16 real-P scoreboard: nonterminal frame_done asserted\n";
        return 1;
    }
    if (s.top.frame_mb_count != kCases.size()) {
        std::cerr << "FAIL h264_decode_core p16x16 real-P scoreboard: frame_mb_count="
                  << int(s.top.frame_mb_count) << " want=" << kCases.size() << "\n";
        return 1;
    }
    if (clipLow < 1 || clipHigh < 1) {
        std::cerr << "FAIL h264_decode_core p16x16 real-P scoreboard: clip_low="
                  << clipLow << " clip_high=" << clipHigh << " want>=1 each\n";
        return 1;
    }
    std::cout << "OK h264_decode_core p16x16 real-P scoreboard: 3 MBs syntax+MV-neighbor+CAVLC-residual path "
              << "384x3 exact clipped pred+16Y+8C scheduled-residual samples landed at DPB addresses; reads="
              << s.reads.size() << " clipped_samples=" << clipped
              << " clip_low=" << clipLow << " clip_high=" << clipHigh
              << " rbsp_request_offsets=" << s.rbspRequests.at(0) << "/" << s.rbspRequests.at(1)
              << "/" << s.rbspRequests.at(2)
              << " chroma_right_clamp_reads=" << chromaRightClampReads
              << " cycles=" << s.cycles << " timeout_cycles=" << kP16RealPTimeoutCycles
              << "; nonterminal frame_done stayed low\n";
    return 0;
}

} // namespace

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);

    Sim s;
    if (!checkResidualFixture()) return 1;
    reset(s);
    driveSliceStart(s);
    for (std::size_t i = 0; i < kCases.size(); ++i) {
        driveMb(s, static_cast<int>(i));
        if (!waitForWrites(s, (i + 1) * 384)) {
            std::cerr << "FAIL h264_decode_core p16x16 real-P scoreboard: MB " << i << " did not return idle\n";
            return 1;
        }
    }
    return checkScoreboard(s);
}
