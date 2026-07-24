// Baseline CAVLC residual_block using FFmpeg table layout (ITU-T H.264 9.2).
// 3.3f/g: first I_16x16 DC probe + residual walk helpers.
#pragma once
#include "libmisterplex/h264_nal.hpp"

#include <algorithm>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <vector>

namespace misterplex {
namespace cavlc {

struct ResidualResult {
    bool ok = false;
    int total_coeff = 0;
    int trailing_ones = 0;
    int16_t level[16]{}; // reverse order (first = last in scan)
    int16_t coeff[16]{}; // scan-order placement
};

namespace tables {

// FFmpeg libavcodec/h264_cavlc.c — coeff_token for nC categories 0..3 (3 = nC>=8 FLC)
// Layout: index = 4*TotalCoeff + TrailingOnes
static const uint8_t coeff_token_len[4][4 * 17] = {
    {1, 0, 0, 0, 6, 2, 0, 0, 8, 6, 3, 0, 9, 8, 7, 5, 10, 9, 8, 6, 11, 10, 9, 7,
     13, 11, 10, 8, 13, 13, 11, 9, 13, 13, 13, 10, 14, 14, 13, 11, 14, 14, 14, 13,
     15, 15, 14, 14, 15, 15, 15, 14, 16, 15, 15, 15, 16, 16, 16, 15, 16, 16, 16, 16,
     16, 16, 16, 16},
    {2, 0, 0, 0, 6, 2, 0, 0, 6, 5, 3, 0, 7, 6, 6, 4, 8, 6, 6, 4, 8, 7, 7, 5, 9, 8,
     8, 6, 11, 9, 9, 6, 11, 11, 11, 7, 12, 11, 11, 9, 12, 12, 12, 11, 12, 12, 12, 11,
     13, 13, 13, 12, 13, 13, 13, 13, 13, 14, 13, 13, 14, 14, 14, 13, 14, 14, 14, 14},
    {4, 0, 0, 0, 6, 4, 0, 0, 6, 5, 4, 0, 6, 5, 5, 4, 7, 5, 5, 4, 7, 5, 5, 4, 7, 6,
     6, 4, 7, 6, 6, 4, 8, 7, 7, 5, 8, 8, 7, 6, 9, 8, 8, 7, 9, 9, 8, 8, 9, 9, 9, 8,
     10, 9, 9, 9, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10},
    // nC >= 8: 6-bit FLC (invalid (tc,t1) have len 0)
    {6, 0, 0, 0, 6, 6, 0, 0, 6, 6, 6, 0, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6,
     6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6,
     6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6},
};
static const uint8_t coeff_token_bits[4][4 * 17] = {
    {1, 0, 0, 0, 5, 1, 0, 0, 7, 4, 1, 0, 7, 6, 5, 3, 7, 6, 5, 3, 7, 6, 5, 4, 15, 6,
     5, 4, 11, 14, 5, 4, 8, 10, 13, 4, 15, 14, 9, 4, 11, 10, 13, 12, 15, 14, 9, 12,
     11, 10, 13, 8, 15, 1, 9, 12, 11, 14, 13, 8, 7, 10, 9, 12, 4, 6, 5, 8},
    {3, 0, 0, 0, 11, 2, 0, 0, 7, 7, 3, 0, 7, 10, 9, 5, 7, 6, 5, 4, 4, 6, 5, 6, 7, 6,
     5, 8, 15, 6, 5, 4, 11, 14, 13, 4, 15, 10, 9, 4, 11, 14, 13, 12, 8, 10, 9, 8,
     15, 14, 13, 12, 11, 10, 9, 12, 7, 11, 6, 8, 9, 8, 10, 1, 7, 6, 5, 4},
    {15, 0, 0, 0, 15, 14, 0, 0, 11, 15, 13, 0, 8, 12, 14, 12, 15, 10, 11, 11, 11, 8,
     9, 10, 9, 14, 13, 9, 8, 10, 9, 8, 15, 14, 13, 13, 11, 14, 10, 12, 15, 10, 13,
     12, 11, 14, 9, 12, 8, 10, 13, 8, 13, 7, 9, 12, 9, 12, 11, 10, 5, 8, 7, 6, 1, 4,
     3, 2},
    {3, 0, 0, 0, 0, 1, 0, 0, 4, 5, 6, 0, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19,
     20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31, 32, 33, 34, 35, 36, 37, 38, 39,
     40, 41, 42, 43, 44, 45, 46, 47, 48, 49, 50, 51, 52, 53, 54, 55, 56, 57, 58, 59,
     60, 61, 62, 63},
};
static const uint8_t chroma_dc_len[4 * 5] = {2, 0, 0, 0, 6, 1, 0, 0, 6, 6, 3, 0,
                                              6, 7, 7, 6, 6, 8, 8, 7};
static const uint8_t chroma_dc_bits[4 * 5] = {1, 0, 0, 0, 7, 1, 0, 0, 4, 6, 1, 0,
                                               3, 3, 2, 5, 2, 3, 2, 0};

static const uint8_t total_zeros_len[15][16] = {
    {1, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 9},
    {3, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 6, 6, 6, 6},
    {4, 3, 3, 3, 4, 4, 3, 3, 4, 5, 5, 6, 5, 6},
    {5, 3, 4, 4, 3, 3, 3, 4, 3, 4, 5, 5, 5},
    {4, 4, 4, 3, 3, 3, 3, 3, 4, 5, 4, 5},
    {6, 5, 3, 3, 3, 3, 3, 3, 4, 3, 6},
    {6, 5, 3, 3, 3, 2, 3, 4, 3, 6},
    {6, 4, 5, 3, 2, 2, 3, 3, 6},
    {6, 6, 4, 2, 2, 3, 2, 5},
    {5, 5, 3, 2, 2, 2, 4},
    {4, 4, 3, 3, 1, 3},
    {4, 4, 2, 1, 3},
    {3, 3, 1, 2},
    {2, 2, 1},
    {1, 1},
};
static const uint8_t total_zeros_bits[15][16] = {
    {1, 3, 2, 3, 2, 3, 2, 3, 2, 3, 2, 3, 2, 3, 2, 1},
    {7, 6, 5, 4, 3, 5, 4, 3, 2, 3, 2, 3, 2, 1, 0},
    {5, 7, 6, 5, 4, 3, 4, 3, 2, 3, 2, 1, 1, 0},
    {3, 7, 5, 4, 6, 5, 4, 3, 3, 2, 2, 1, 0},
    {5, 4, 3, 7, 6, 5, 4, 3, 2, 1, 1, 0},
    {1, 1, 7, 6, 5, 4, 3, 2, 1, 1, 0},
    {1, 1, 5, 4, 3, 3, 2, 1, 1, 0},
    {1, 1, 1, 3, 3, 2, 2, 1, 0},
    {1, 0, 1, 3, 2, 1, 1, 1},
    {1, 0, 1, 3, 2, 1, 1},
    {0, 1, 1, 2, 1, 3},
    {0, 1, 1, 1, 1},
    {0, 1, 1, 1},
    {0, 1, 1},
    {0, 1},
};
static const uint8_t chroma_tz_len[3][4] = {{1, 2, 3, 3}, {1, 2, 2, 0}, {1, 1, 0, 0}};
static const uint8_t chroma_tz_bits[3][4] = {{1, 1, 1, 0}, {1, 1, 0, 0}, {1, 0, 0, 0}};
static const uint8_t run_len[7][16] = {
    {1, 1}, {1, 2, 2}, {2, 2, 2, 2}, {2, 2, 2, 3, 3}, {2, 2, 3, 3, 3, 3},
    {2, 3, 3, 3, 3, 3, 3}, {3, 3, 3, 3, 3, 3, 3, 4, 5, 6, 7, 8, 9, 10, 11},
};
static const uint8_t run_bits[7][16] = {
    {1, 0}, {1, 1, 0}, {3, 2, 1, 0}, {3, 2, 1, 1, 0}, {3, 2, 3, 2, 1, 0},
    {3, 0, 1, 3, 2, 5, 4}, {7, 6, 5, 4, 3, 2, 1, 1, 1, 1, 1, 1, 1, 1, 1},
};

inline bool matchMap(detail::BitReader& br, const uint8_t* lens, const uint8_t* bits, int n,
                     int& outIdx) {
    // Build match: for each idx with len>0, map (len,code)->idx
    uint32_t code = 0;
    for (int L = 1; L <= 16 && br.ok; ++L) {
        code = (code << 1) | br.u(1);
        for (int i = 0; i < n; ++i) {
            if (lens[i] == L && bits[i] == code) {
                outIdx = i;
                return true;
            }
        }
    }
    return false;
}

} // namespace tables

inline ResidualResult residualBlock(detail::BitReader& br, int nC, int maxNumCoeff) {
    ResidualResult out;
    if (!br.ok || maxNumCoeff <= 0 || maxNumCoeff > 16)
        return out;

    int tc = 0, t1 = 0;
    if (nC == -1) {
        int idx = 0;
        if (!tables::matchMap(br, tables::chroma_dc_len, tables::chroma_dc_bits, 20, idx))
            return out;
        tc = idx / 4;
        t1 = idx % 4;
        if (tc > 4)
            return out;
    } else {
        // FFmpeg table index: 0,0,1,1,2,2,2,2,3,3,... for nC 0..16
        int tab = nC < 2 ? 0 : (nC < 4 ? 1 : (nC < 8 ? 2 : 3));
        int idx = 0;
        if (!tables::matchMap(br, tables::coeff_token_len[tab], tables::coeff_token_bits[tab],
                              4 * 17, idx))
            return out;
        tc = idx / 4;
        t1 = idx % 4;
    }
    // Invalid token or exceeds residual size → bitstream misalignment / error
    if (tc > maxNumCoeff || t1 > tc || t1 > 3)
        return out;
    out.total_coeff = tc;
    out.trailing_ones = t1;
    if (tc == 0) {
        out.ok = true;
        return out;
    }

    // Level decode matches OpenH264 CavlcGetLevelVal / ITU-T H.264 9.2.2
    int16_t level[16]{};
    for (int i = 0; i < t1; ++i) {
        level[i] = br.u(1) ? -1 : 1;
        out.level[i] = level[i];
    }
    int suffixLength = (tc > 10 && t1 < 3) ? 1 : 0;
    for (int i = t1; i < tc && br.ok; ++i) {
        int level_prefix = 0;
        while (br.ok && br.u(1) == 0) {
            ++level_prefix;
            if (level_prefix > 31)
                return out;
        }
        // levelCode starts as prefix << suffixLength; suffix size may grow for escapes
        int levelCode = level_prefix << suffixLength;
        int suffixBits = suffixLength;
        if (level_prefix >= 14) {
            if (level_prefix == 14 && suffixLength == 0)
                suffixBits = 4;
            else if (level_prefix == 15) {
                // Always 12-bit suffix when prefix==15 (OpenH264 / common practice)
                suffixBits = 12;
                if (suffixLength == 0)
                    levelCode += 15;
            } else if (level_prefix > 15) {
                // FFmpeg path for rare large prefixes
                suffixBits = level_prefix - 3;
                levelCode = 30;
                if (level_prefix >= 16)
                    levelCode += (1 << (level_prefix - 3)) - 4096;
            }
        }
        if (suffixBits > 0)
            levelCode += static_cast<int>(br.u(suffixBits));
        if (i == t1 && t1 < 3)
            levelCode += 2;
        int16_t lvl =
            (levelCode & 1) == 0 ? static_cast<int16_t>((levelCode + 2) >> 1)
                                 : static_cast<int16_t>(-((levelCode + 1) >> 1));
        level[i] = lvl;
        out.level[i] = lvl;
        // suffixLength++: first non-zero after T1s always bumps 0→1, then by magnitude
        if (suffixLength == 0)
            suffixLength = 1;
        if (std::abs(static_cast<int>(lvl)) > (3 << (suffixLength - 1)) && suffixLength < 6)
            ++suffixLength;
    }

    int zerosLeft = 0;
    if (tc < maxNumCoeff) {
        int zidx = 0;
        bool zok = false;
        if (maxNumCoeff == 4) {
            zok = tables::matchMap(br, tables::chroma_tz_len[tc - 1], tables::chroma_tz_bits[tc - 1],
                                   4, zidx);
        } else {
            zok = tables::matchMap(br, tables::total_zeros_len[tc - 1],
                                   tables::total_zeros_bits[tc - 1], 16 - tc + 1, zidx);
        }
        if (!zok) {
            return out;
        }
        zerosLeft = zidx;
    }

    int run[16]{};
    for (int i = 0; i < tc - 1; ++i) {
        if (zerosLeft > 0) {
            int r = 0;
            if (zerosLeft < 7) {
                int ridx = 0;
                if (!tables::matchMap(br, tables::run_len[zerosLeft - 1],
                                      tables::run_bits[zerosLeft - 1], zerosLeft + 1, ridx))
                    return out;
                r = ridx;
            } else {
                // zerosLeft > 6: Table 9-10 — 111→0 … 001→6; 0001→7; 00001→8 …
                // (FFmpeg run_bits[6]: codes 7,6,5,4,3,2,1 with len 3)
                int v = static_cast<int>(br.u(3));
                if (v > 0) {
                    r = 7 - v;
                } else {
                    r = 7;
                    while (br.ok && br.u(1) == 0)
                        ++r;
                }
            }
            run[i] = r;
            zerosLeft -= r;
            if (zerosLeft < 0)
                return out;
        }
    }
    run[tc - 1] = zerosLeft;

    // Place levels in reverse-scan order (level[0]=highest freq).
    int coeffNum = -1;
    for (int i = tc - 1; i >= 0; --i) {
        coeffNum += run[i] + 1;
        if (coeffNum < 0 || coeffNum >= 16)
            return out;
        out.coeff[coeffNum] = level[i];
    }
    out.ok = br.ok;
    return out;
}

// --- Inv quant + Hadamard for Intra16x16 DC (ITU 8.5.10 / FFmpeg luma_dc_dequant_idct)
// Output is in residual-IDCT domain: place at each 4x4 (0,0), then run 4x4 idct
// (or idct_dc_add: pred += (dc+32)>>6 when AC==0).
inline void invQuantHadamardDc4x4(const int16_t coeffScan[16], int qp, int16_t dcOut[4][4]) {
    // Place zigzag scan → 4x4
    static const int zz[16] = {0, 1, 4, 8, 5, 2, 3, 6, 9, 12, 13, 10, 7, 11, 14, 15};
    int c[4][4]{};
    for (int i = 0; i < 16; ++i)
        c[zz[i] / 4][zz[i] % 4] = coeffScan[i];

    // Inverse 4x4 Hadamard (no intermediate scale)
    int t[4][4];
    for (int i = 0; i < 4; ++i) {
        int a0 = c[i][0] + c[i][1];
        int a1 = c[i][0] - c[i][1];
        int a2 = c[i][2] + c[i][3];
        int a3 = c[i][2] - c[i][3];
        t[i][0] = a0 + a2;
        t[i][1] = a1 + a3;
        t[i][2] = a0 - a2;
        t[i][3] = a1 - a3;
    }
    int f[4][4];
    for (int j = 0; j < 4; ++j) {
        int a0 = t[0][j] + t[1][j];
        int a1 = t[0][j] - t[1][j];
        int a2 = t[2][j] + t[3][j];
        int a3 = t[2][j] - t[3][j];
        f[0][j] = a0 + a2;
        f[1][j] = a1 + a3;
        f[2][j] = a0 - a2;
        f[3][j] = a1 - a3;
    }

    // FFmpeg: qmul = (mf * scaling_matrix=16) << (qp/6 + 2); (f*qmul+128)>>8
    // → idct_dc_add: (dc+32)>>6 is pixel residual
    static const int mf0[6] = {10, 11, 13, 14, 16, 18};
    const int qmul = (mf0[qp % 6] * 16) << (qp / 6 + 2);
    for (int i = 0; i < 4; ++i)
        for (int j = 0; j < 4; ++j)
            dcOut[i][j] = static_cast<int16_t>((f[i][j] * qmul + 128) >> 8);
}

// Probe first I_16x16 MB of an IDR annex-B stream
inline ResidualResult probeFirstI16Dc(const uint8_t* annexb, size_t n) {
    ResidualResult fail;
    auto chain = parseAnnexBChain(annexb, n);
    if (!chain.sps.valid || !chain.pps.valid || !chain.slice.valid || !chain.slice.has_first_mb_type)
        return fail;
    // first_mb_type 0 = I_NxN, 1..24 = I_16x16, 25 = PCM
    if (chain.slice.first_mb_type > 25)
        return fail;

    size_t i = 0;
    const uint8_t* pay = nullptr;
    size_t plen = 0;
    uint8_t ntype = 0;
    while (i + 3 < n) {
        size_t sc = 0;
        if (i + 3 < n && annexb[i] == 0 && annexb[i + 1] == 0 && annexb[i + 2] == 0 &&
            annexb[i + 3] == 1)
            sc = 4;
        else if (annexb[i] == 0 && annexb[i + 1] == 0 && annexb[i + 2] == 1)
            sc = 3;
        else {
            ++i;
            continue;
        }
        size_t j = i + sc;
        while (j + 3 < n) {
            if (annexb[j] == 0 && annexb[j + 1] == 0 &&
                (annexb[j + 2] == 1 || (j + 3 < n && annexb[j + 2] == 0 && annexb[j + 3] == 1)))
                break;
            ++j;
        }
        if (j + 3 >= n)
            j = n;
        uint8_t t = annexb[i + sc] & 0x1f;
        if (t == 5 || t == 1) {
            pay = annexb + i + sc + 1;
            plen = j - (i + sc + 1);
            ntype = t;
            break;
        }
        i = j;
    }
    if (!pay)
        return fail;
    auto rbsp = misterplex::detail::removeEpb(pay, plen);
    detail::BitReader br(rbsp.data(), rbsp.size());
    br.ue();
    br.ue();
    br.ue();
    br.u(chain.log2_max_frame_num);
    if (ntype == 5) {
        br.ue();
        br.u(1);
        br.u(1);
    }
    br.se();
    if (chain.pps.deblock_ctrl) {
        uint32_t d = br.ue();
        if (d != 1) {
            br.se();
            br.se();
        }
    }
    // First MB may be I_NxN (mt=0) or I_16x16 (1..24).
    uint32_t mt = br.ue();
    if (mt == 0) {
        for (int k = 0; k < 16; ++k)
            if (br.u(1) == 0)
                br.u(3);
        br.ue(); // chroma pred
        uint32_t code = br.ue();
        if (code >= 48)
            return fail;
        static const uint8_t kMe[48] = {
            47, 31, 15, 0,  23, 27, 29, 30, 7,  11, 13, 14, 39, 43, 45, 46,
            16, 3,  5,  10, 12, 19, 21, 26, 28, 35, 37, 42, 44, 1,  2,  4,
            8,  17, 18, 20, 24, 6,  9,  22, 25, 32, 33, 34, 36, 40, 38, 41};
        int cbp = kMe[code];
        if (cbp != 0)
            br.se();
        // First coded luma 4x4 in raster of 8x8 groups
        for (int i8 = 0; i8 < 4; ++i8) {
            if ((cbp >> i8) & 1)
                return residualBlock(br, 0, 16);
        }
        return fail;
    }
    if (mt > 24)
        return fail;
    br.ue(); // intra_chroma_pred_mode (all Intra MBs, 7.3.5)
    br.se(); // mb_qp_delta
    return residualBlock(br, 0, 16);
}

// Reconstruct first I_16x16 MB luma as DC prediction (128) + DC residual only.
// Returns mean Y 0..255 for unit/HW correlation.
inline int reconFirstI16DcMeanY(const uint8_t* annexb, size_t n, int16_t yOut[16][16] = nullptr) {
    auto r = probeFirstI16Dc(annexb, n);
    if (!r.ok)
        return -1;
    auto chain = parseAnnexBChain(annexb, n);
    // Apply typical first-MB qp: slice_qp + mb_qp_delta (delta often +1 on this clip)
    int qp = chain.slice.slice_qp;
    // Re-parse mb_qp_delta for accuracy
    // (slice_qp from header is pre-mb; real qp after first mb_qp_delta)
    // From known clip: slice_qp=14, mb_qp_delta=+1 → 15
    // Re-scan:
    {
        size_t i = 0;
        const uint8_t* pay = nullptr;
        size_t plen = 0;
        uint8_t ntype = 0;
        while (i + 3 < n) {
            size_t sc = 0;
            if (i + 3 < n && annexb[i] == 0 && annexb[i + 1] == 0 && annexb[i + 2] == 0 &&
                annexb[i + 3] == 1)
                sc = 4;
            else if (annexb[i] == 0 && annexb[i + 1] == 0 && annexb[i + 2] == 1)
                sc = 3;
            else {
                ++i;
                continue;
            }
            size_t j = i + sc;
            while (j + 3 < n) {
                if (annexb[j] == 0 && annexb[j + 1] == 0 &&
                    (annexb[j + 2] == 1 || (j + 3 < n && annexb[j + 2] == 0 && annexb[j + 3] == 1)))
                    break;
                ++j;
            }
            if (j + 3 >= n)
                j = n;
            uint8_t t = annexb[i + sc] & 0x1f;
            if (t == 5 || t == 1) {
                pay = annexb + i + sc + 1;
                plen = j - (i + sc + 1);
                ntype = t;
                break;
            }
            i = j;
        }
        if (pay) {
            auto rbsp = misterplex::detail::removeEpb(pay, plen);
            detail::BitReader br(rbsp.data(), rbsp.size());
            br.ue();
            br.ue();
            br.ue();
            br.u(chain.log2_max_frame_num);
            if (ntype == 5) {
                br.ue();
                br.u(1);
                br.u(1);
            }
            br.se();
            if (chain.pps.deblock_ctrl) {
                uint32_t d = br.ue();
                if (d != 1) {
                    br.se();
                    br.se();
                }
            }
            uint32_t mt = br.ue();
            if (mt == 0)
                return -1; // I_NxN — recon path is I16 DC only
            br.ue(); // intra_chroma_pred_mode
            int dlt = br.se();
            qp = chain.slice.slice_qp + dlt;
            if (qp < 0)
                qp = 0;
            if (qp > 51)
                qp = 51;
        }
    }
    int16_t dc[4][4]{};
    invQuantHadamardDc4x4(r.coeff, qp, dc);
    int sum = 0;
    for (int by = 0; by < 4; ++by)
        for (int bx = 0; bx < 4; ++bx) {
            // idct_dc_add: pixel += (dc + 32) >> 6
            int val = 128 + ((static_cast<int>(dc[by][bx]) + 32) >> 6);
            if (val < 0)
                val = 0;
            if (val > 255)
                val = 255;
            for (int y = 0; y < 4; ++y)
                for (int x = 0; x < 4; ++x) {
                    if (yOut)
                        yOut[by * 4 + y][bx * 4 + x] = static_cast<int16_t>(val);
                    sum += val;
                }
        }
    return sum / 256;
}

} // namespace cavlc
} // namespace misterplex
