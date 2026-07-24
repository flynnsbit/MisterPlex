// Baseline CAVLC residual_block (subset) + first-MB I_16x16 DC probe for 3.3f.
// Validated: real plex_real_baseline.h264 first I_16x16 DC → TotalCoeff=2.
#pragma once
#include "libmisterplex/h264_nal.hpp"

#include <cstdlib>
#include <cstdint>
#include <cstring>
#include <vector>

namespace misterplex {
namespace cavlc {

struct ResidualResult {
    bool ok = false;
    int total_coeff = 0;
    int trailing_ones = 0;
    int16_t level[16]{}; // reverse-scan order levels (nonzero first)
    int16_t coeff[16]{}; // zig-zag scan order
};

namespace detail_c {

struct Tok {
    const char* bits;
    uint8_t tc, t1;
};

// Table 9-5 num-VLC0 (0 <= nC < 2), longest-first match via bit length
inline bool matchVlc(detail::BitReader& br, const Tok* tab, size_t n, int& tc, int& t1) {
    uint32_t code = 0;
    for (int bits = 1; bits <= 16 && br.ok; ++bits) {
        code = (code << 1) | br.u(1);
        for (size_t i = 0; i < n; ++i) {
            const char* s = tab[i].bits;
            int len = 0;
            while (s[len])
                ++len;
            if (len != bits)
                continue;
            uint32_t want = 0;
            for (int k = 0; k < len; ++k)
                want = (want << 1) | static_cast<uint32_t>(s[k] - '0');
            if (want == code) {
                tc = tab[i].tc;
                t1 = tab[i].t1;
                return true;
            }
        }
    }
    return false;
}

// Complete num-VLC0
static const Tok kNc0[] = {
    {"1", 0, 0},
    {"000101", 1, 0}, {"01", 1, 1},
    {"00000111", 2, 0}, {"000100", 2, 1}, {"001", 2, 2},
    {"000000111", 3, 0}, {"00000110", 3, 1}, {"0000101", 3, 2}, {"00011", 3, 3},
    {"0000000111", 4, 0}, {"000000110", 4, 1}, {"00000101", 4, 2}, {"000011", 4, 3},
    {"00000000111", 5, 0}, {"0000000110", 5, 1}, {"000000101", 5, 2}, {"0000100", 5, 3},
    {"0000000001111", 6, 0}, {"00000000110", 6, 1}, {"0000000101", 6, 2}, {"00000100", 6, 3},
    {"0000000001011", 7, 0}, {"0000000001110", 7, 1}, {"00000000101", 7, 2}, {"000000100", 7, 3},
    {"0000000001000", 8, 0}, {"0000000001010", 8, 1}, {"0000000001101", 8, 2}, {"0000000100", 8, 3},
    {"00000000001111", 9, 0}, {"00000000001110", 9, 1}, {"0000000001001", 9, 2}, {"00000000100", 9, 3},
    {"00000000001011", 10, 0}, {"00000000001010", 10, 1}, {"00000000001101", 10, 2}, {"0000000001100", 10, 3},
    {"000000000001111", 11, 0}, {"000000000001110", 11, 1}, {"00000000001001", 11, 2}, {"00000000001100", 11, 3},
    {"000000000001011", 12, 0}, {"000000000001010", 12, 1}, {"000000000001101", 12, 2}, {"00000000001000", 12, 3},
    {"0000000000001111", 13, 0}, {"000000000000001", 13, 1}, {"000000000001001", 13, 2}, {"000000000001100", 13, 3},
    {"0000000000001011", 14, 0}, {"0000000000001110", 14, 1}, {"0000000000001101", 14, 2}, {"000000000001000", 14, 3},
    {"0000000000000111", 15, 0}, {"0000000000001010", 15, 1}, {"0000000000001001", 15, 2}, {"0000000000001100", 15, 3},
    {"0000000000000100", 16, 0}, {"0000000000000110", 16, 1}, {"0000000000000101", 16, 2}, {"0000000000001000", 16, 3},
};

// chroma DC nC=-1 (max 4)
static const Tok kNcm1[] = {
    {"1", 0, 0},
    {"0001111", 1, 0}, {"01", 1, 1},
    {"0001110", 2, 0}, {"0001101", 2, 1}, {"001", 2, 2},
    {"000000111", 3, 0}, {"0001100", 3, 1}, {"0001011", 3, 2}, {"00001", 3, 3},
    {"000000110", 4, 0}, {"000000101", 4, 1}, {"0001010", 4, 2}, {"000001", 4, 3},
};

// total_zeros for 4x4, TotalCoeff=1..15 (subset used by first blocks)
struct ZTok {
    const char* bits;
    uint8_t zeros;
};
inline bool matchZ(detail::BitReader& br, const ZTok* tab, size_t n, int& zeros) {
    uint32_t code = 0;
    for (int bits = 1; bits <= 16 && br.ok; ++bits) {
        code = (code << 1) | br.u(1);
        for (size_t i = 0; i < n; ++i) {
            const char* s = tab[i].bits;
            int len = 0;
            while (s[len])
                ++len;
            if (len != bits)
                continue;
            uint32_t want = 0;
            for (int k = 0; k < len; ++k)
                want = (want << 1) | static_cast<uint32_t>(s[k] - '0');
            if (want == code) {
                zeros = tab[i].zeros;
                return true;
            }
        }
    }
    return false;
}

// total_zeros TC=2 (common for our first block)
static const ZTok kTz2[] = {
    {"111", 0}, {"110", 1}, {"101", 2}, {"100", 3}, {"011", 4}, {"0101", 5}, {"0100", 6},
    {"0011", 7}, {"0010", 8}, {"00011", 9}, {"00010", 10}, {"000011", 11}, {"000010", 12},
    {"000001", 13}, {"000000", 14},
};
// TC=1
static const ZTok kTz1[] = {
    {"1", 0}, {"011", 1}, {"010", 2}, {"0011", 3}, {"0010", 4}, {"00011", 5}, {"00010", 6},
    {"000011", 7}, {"000010", 8}, {"0000011", 9}, {"0000010", 10}, {"00000011", 11},
    {"00000010", 12}, {"000000011", 13}, {"000000010", 14}, {"000000001", 15},
};
// chroma total_zeros
static const ZTok kTzCh1[] = {{"1", 0}, {"01", 1}, {"001", 2}, {"000", 3}};
static const ZTok kTzCh2[] = {{"1", 0}, {"01", 1}, {"00", 2}};
static const ZTok kTzCh3[] = {{"1", 0}, {"0", 1}};

// run_before zerosLeft=1..6
static const ZTok kRb1[] = {{"1", 0}, {"0", 1}};
static const ZTok kRb2[] = {{"1", 0}, {"01", 1}, {"00", 2}};
static const ZTok kRb3[] = {{"11", 0}, {"10", 1}, {"01", 2}, {"00", 3}};

inline int runBefore(detail::BitReader& br, int zerosLeft) {
    if (zerosLeft <= 0)
        return 0;
    int z = 0;
    if (zerosLeft == 1) {
        if (!matchZ(br, kRb1, 2, z))
            return -1;
        return z;
    }
    if (zerosLeft == 2) {
        if (!matchZ(br, kRb2, 3, z))
            return -1;
        return z;
    }
    if (zerosLeft == 3) {
        if (!matchZ(br, kRb3, 4, z))
            return -1;
        return z;
    }
    // zerosLeft >= 4: use 3-bit FLC for zerosLeft>6; for 4-6 use simplified
    if (zerosLeft > 6) {
        int v = static_cast<int>(br.u(3));
        if (v < 7)
            return v;
        int run = 7;
        while (br.ok && br.u(1) == 0)
            ++run;
        return run;
    }
    // zerosLeft 4,5,6: 3-bit style tables abbreviated as FLC-like
    // Table 9-10: implement bit match for common
    static const ZTok kRb4[] = {{"11", 0}, {"10", 1}, {"01", 2}, {"001", 3}, {"000", 4}};
    static const ZTok kRb5[] = {{"11", 0}, {"10", 1}, {"011", 2}, {"010", 3}, {"001", 4}, {"000", 5}};
    static const ZTok kRb6[] = {
        {"11", 0}, {"000", 1}, {"001", 2}, {"011", 3}, {"010", 4}, {"101", 5}, {"100", 6}};
    const ZTok* t = zerosLeft == 4 ? kRb4 : (zerosLeft == 5 ? kRb5 : kRb6);
    size_t n = zerosLeft == 4 ? 5 : (zerosLeft == 5 ? 6 : 7);
    if (!matchZ(br, t, n, z))
        return -1;
    return z;
}

} // namespace detail_c

// Decode one residual block. nC: neighbor context; -1 = chroma DC 4:2:0.
// maxNumCoeff: 16 for 4x4, 15 for AC, 4 for chroma DC.
inline ResidualResult residualBlock(detail::BitReader& br, int nC, int maxNumCoeff) {
    ResidualResult out;
    if (!br.ok || maxNumCoeff <= 0 || maxNumCoeff > 16)
        return out;

    int tc = 0, t1 = 0;
    if (nC >= 8) {
        uint32_t v = br.u(6);
        if (v == 3) {
            tc = 0;
            t1 = 0;
        } else {
            tc = static_cast<int>((v >> 2) + 1);
            t1 = static_cast<int>(v & 3);
        }
    } else if (nC == -1) {
        if (!detail_c::matchVlc(br, detail_c::kNcm1,
                                sizeof(detail_c::kNcm1) / sizeof(detail_c::kNcm1[0]), tc, t1))
            return out;
        if (tc > 4)
            tc = 4;
    } else {
        // nC 0..1 only for this bring-up (first MB neighbors unavailable)
        if (!detail_c::matchVlc(br, detail_c::kNc0,
                                sizeof(detail_c::kNc0) / sizeof(detail_c::kNc0[0]), tc, t1))
            return out;
    }
    if (tc > maxNumCoeff)
        tc = maxNumCoeff;
    if (t1 > tc)
        t1 = tc;
    out.total_coeff = tc;
    out.trailing_ones = t1;
    if (tc == 0) {
        out.ok = true;
        return out;
    }

    int16_t level[16]{};
    for (int i = 0; i < t1; ++i)
        level[i] = br.u(1) ? -1 : 1;

    int suffixLength = (tc > 10 && t1 < 3) ? 1 : 0;
    for (int i = t1; i < tc && br.ok; ++i) {
        int level_prefix = 0;
        while (br.ok && br.u(1) == 0)
            ++level_prefix;
        int levelCode = 0;
        if (level_prefix < 14) {
            if (suffixLength > 0)
                levelCode = (level_prefix << suffixLength) + static_cast<int>(br.u(suffixLength));
            else
                levelCode = level_prefix;
        } else if (level_prefix == 14) {
            if (suffixLength == 0)
                levelCode = 14 + static_cast<int>(br.u(4));
            else
                levelCode = (14 << suffixLength) + static_cast<int>(br.u(suffixLength));
        } else {
            levelCode = 30 + static_cast<int>(br.u(12));
            if (suffixLength == 0)
                levelCode += 15;
        }
        if (i == t1 && t1 < 3)
            levelCode += 2;
        int16_t lvl;
        if ((levelCode & 1) == 0)
            lvl = static_cast<int16_t>((levelCode + 2) >> 1);
        else
            lvl = static_cast<int16_t>(-((levelCode + 1) >> 1));
        level[i] = lvl;
        out.level[i] = lvl;
        if (suffixLength == 0)
            suffixLength = 1;
        if (std::abs(lvl) > (3 << (suffixLength - 1)) && suffixLength < 6)
            ++suffixLength;
    }

    int zerosLeft = 0;
    if (tc < maxNumCoeff) {
        int z = 0;
        bool zok = false;
        if (maxNumCoeff == 4) {
            if (tc == 1)
                zok = detail_c::matchZ(br, detail_c::kTzCh1, 4, z);
            else if (tc == 2)
                zok = detail_c::matchZ(br, detail_c::kTzCh2, 3, z);
            else if (tc == 3)
                zok = detail_c::matchZ(br, detail_c::kTzCh3, 2, z);
        } else {
            if (tc == 1)
                zok = detail_c::matchZ(br, detail_c::kTz1, 16, z);
            else if (tc == 2)
                zok = detail_c::matchZ(br, detail_c::kTz2, 15, z);
            else
                return out; // only TC=1,2 fully tabled for 4x4 in this bring-up
        }
        if (!zok)
            return out;
        zerosLeft = z;
    }

    int run[16]{};
    for (int i = 0; i < tc - 1; ++i) {
        if (zerosLeft > 0) {
            int r = detail_c::runBefore(br, zerosLeft);
            if (r < 0)
                return out;
            run[i] = r;
            zerosLeft -= r;
        }
    }
    run[tc - 1] = zerosLeft;

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

// Probe first I_16x16 MB of an IDR annex-B stream: parse headers + mb_type + qp_delta +
// Intra16x16DCLevel (nC=0). Returns residual result for that DC block.
inline ResidualResult probeFirstI16Dc(const uint8_t* annexb, size_t n) {
    ResidualResult fail;
    auto chain = parseAnnexBChain(annexb, n);
    if (!chain.sps.valid || !chain.pps.valid || !chain.slice.valid || !chain.slice.has_first_mb_type)
        return fail;
    if (chain.slice.first_mb_type == 0 || chain.slice.first_mb_type > 24)
        return fail; // need I_16x16

    // Re-scan to bit position after first mb_type and decode mb_qp_delta + residual
    // Find IDR payload
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
    br.ue(); // first_mb
    br.ue(); // slice_type
    br.ue(); // pps
    br.u(chain.log2_max_frame_num);
    if (ntype == 5)
        br.ue();
    br.se(); // slice_qp_delta
    if (chain.pps.deblock_ctrl) {
        uint32_t d = br.ue();
        if (d != 1) {
            br.se();
            br.se();
        }
    }
    br.ue(); // mb_type
    br.se(); // mb_qp_delta
    // Intra16x16DCLevel, nC=0 (no neighbors)
    return residualBlock(br, /*nC=*/0, /*maxNumCoeff=*/16);
}

} // namespace cavlc
} // namespace misterplex
