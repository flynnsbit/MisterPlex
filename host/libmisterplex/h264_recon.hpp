// Baseline I-slice reconstruct: CAVLC residual → inv quant → IDCT → Intra pred → YUV/RGB565.
// Phase 3.3h host path (golden vs FFmpeg Y).
#pragma once
#include "libmisterplex/h264_slice_walk.hpp"

#include <algorithm>
#include <cstdint>
#include <cstring>
#include <vector>

namespace misterplex {
namespace recon {

struct ReconResult {
    int width = 0;
    int height = 0;
    int mb_decoded = 0;
    int mb_total = 0;
    int fail_mb = -1;
    const char* fail_reason = nullptr;
    std::vector<uint8_t> y;  // width*height
    std::vector<uint8_t> u;  // (w/2)*(h/2)
    std::vector<uint8_t> v;
};

namespace detail_r {

inline int clip8(int v) {
    if (v < 0)
        return 0;
    if (v > 255)
        return 255;
    return v;
}

// H.264 LevelScale4x4 (normAdjust * sm) — FFmpeg dequant4_coeff base
static const int kNormAdjust[6][3] = {
    {10, 13, 16}, {11, 14, 18}, {13, 16, 20}, {14, 18, 23}, {16, 20, 25}, {18, 23, 29},
};
// scan pos → (i%4, i/4) zigzag
static const int kZigzag[16] = {0, 1, 4, 8, 5, 2, 3, 6, 9, 12, 13, 10, 7, 11, 14, 15};

inline int levelScale(int qp, int i, int j) {
    // mf index: 0 if both even, 1 if one odd, 2 if both odd
    int mi = ((i & 1) + (j & 1)) == 0 ? 0 : (((i & 1) + (j & 1)) == 1 ? 1 : 2);
    return kNormAdjust[qp % 6][mi];
}

// FFmpeg-style dequant: block = (level * qmul + 32) >> 6
// qmul = (mf * scaling=16) << (qp/6 + 2); maxCoeff 15 skips DC scan slot
inline void dequant4x4(const int16_t coeffScan[16], int maxCoeff, int qp, int16_t blk[4][4]) {
    std::memset(blk, 0, 16 * sizeof(int16_t));
    const int shift = qp / 6 + 2;
    for (int k = 0; k < maxCoeff; ++k) {
        if (!coeffScan[k])
            continue;
        int zi = (maxCoeff == 15) ? kZigzag[k + 1] : kZigzag[k];
        int i = zi / 4, j = zi % 4;
        int qmul = (levelScale(qp, i, j) * 16) << shift;
        int v = (static_cast<int>(coeffScan[k]) * qmul + 32) >> 6;
        blk[i][j] = static_cast<int16_t>(v);
    }
}

// FFmpeg ff_h264_idct_add: block[0]+=32; butterflies; dst += x>>6
inline void idct4x4_add(int16_t blk[4][4], uint8_t* dst, int stride) {
    int b[4][4];
    for (int i = 0; i < 4; ++i)
        for (int j = 0; j < 4; ++j)
            b[i][j] = blk[i][j];
    b[0][0] += 32;
    int t[4][4];
    for (int i = 0; i < 4; ++i) {
        int z0 = b[i][0] + b[i][2];
        int z1 = b[i][0] - b[i][2];
        int z2 = (b[i][1] >> 1) - b[i][3];
        int z3 = b[i][1] + (b[i][3] >> 1);
        t[i][0] = z0 + z3;
        t[i][1] = z1 + z2;
        t[i][2] = z1 - z2;
        t[i][3] = z0 - z3;
    }
    for (int j = 0; j < 4; ++j) {
        int z0 = t[0][j] + t[2][j];
        int z1 = t[0][j] - t[2][j];
        int z2 = (t[1][j] >> 1) - t[3][j];
        int z3 = t[1][j] + (t[3][j] >> 1);
        dst[0 * stride + j] = static_cast<uint8_t>(clip8(dst[0 * stride + j] + ((z0 + z3) >> 6)));
        dst[1 * stride + j] = static_cast<uint8_t>(clip8(dst[1 * stride + j] + ((z1 + z2) >> 6)));
        dst[2 * stride + j] = static_cast<uint8_t>(clip8(dst[2 * stride + j] + ((z1 - z2) >> 6)));
        dst[3 * stride + j] = static_cast<uint8_t>(clip8(dst[3 * stride + j] + ((z0 - z3) >> 6)));
    }
}

// Intra16x16 DC Hadamard + dequant → 4x4 DC values (ITU 8.5.10)
// Reuse cavlc::invQuantHadamardDc4x4 which returns scaled DC for each 4x4.
// Those DCs are added into residual AC path as (0,0) before idct — or applied as
// prediction-free residual at DC. Standard: DC after Hadamard is dequant'd and becomes
// the DC coefficient of each 4x4 residual before inverse transform.
inline void placeI16Dc(const int16_t dc[4][4], int16_t acBlk[4][4], int by, int bx) {
    // Add DC into (0,0) of residual block prior to idct (scale already applied)
    acBlk[0][0] = static_cast<int16_t>(acBlk[0][0] + dc[by][bx]);
}

// --- Intra prediction ---
// Available samples: above row [-1..16], left col, top-left corner.
// Constrained: unavailable → 128 for DC modes when neither side avail.

inline void predI16_V(uint8_t* mb, int stride, const uint8_t* above) {
    for (int y = 0; y < 16; ++y)
        for (int x = 0; x < 16; ++x)
            mb[y * stride + x] = above[x];
}
inline void predI16_H(uint8_t* mb, int stride, const uint8_t* left) {
    for (int y = 0; y < 16; ++y)
        for (int x = 0; x < 16; ++x)
            mb[y * stride + x] = left[y];
}
inline void predI16_DC(uint8_t* mb, int stride, const uint8_t* above, const uint8_t* left,
                       bool hasA, bool hasL) {
    int sum = 0, n = 0;
    if (hasA) {
        for (int i = 0; i < 16; ++i)
            sum += above[i];
        n += 16;
    }
    if (hasL) {
        for (int i = 0; i < 16; ++i)
            sum += left[i];
        n += 16;
    }
    int v = n ? (sum + (n >> 1)) / n : 128;
    for (int y = 0; y < 16; ++y)
        std::memset(mb + y * stride, v, 16);
}
inline void predI16_Plane(uint8_t* mb, int stride, const uint8_t* above, const uint8_t* left,
                          uint8_t tl) {
    int H = 0, V = 0;
    for (int i = 0; i < 8; ++i) {
        H += (i + 1) * (above[8 + i] - above[6 - i]);
        V += (i + 1) * (left[8 + i] - left[6 - i]);
    }
    // above[-1] for H uses above[ -1 ] = top-left; for i=0: above[8]-above[6];
    // Spec uses p[8+i] - p[6-i] with p[-1]=top-left when i=7: above[15]-above[-1]
    H = 0;
    V = 0;
    for (int i = 0; i < 8; ++i) {
        int a_hi = above[8 + i];
        int a_lo = (6 - i >= 0) ? above[6 - i] : tl;
        H += (i + 1) * (a_hi - a_lo);
        int l_hi = left[8 + i];
        int l_lo = (6 - i >= 0) ? left[6 - i] : tl;
        V += (i + 1) * (l_hi - l_lo);
    }
    int a = 16 * (above[15] + left[15]);
    int b = (5 * H + 32) >> 6;
    int c = (5 * V + 32) >> 6;
    for (int y = 0; y < 16; ++y)
        for (int x = 0; x < 16; ++x) {
            int val = (a + b * (x - 7) + c * (y - 7) + 16) >> 5;
            mb[y * stride + x] = static_cast<uint8_t>(clip8(val));
        }
}

// Intra4x4 modes 0..8
inline void predI4(int mode, uint8_t* dst, int stride, const uint8_t* above /*4+4*/,
                   const uint8_t* left /*4*/, uint8_t tl, bool hasA, bool hasL) {
    // above[0..3] = top, above[4..7] = top-right (if avail else replicate)
    auto dc = [&]() {
        int s = 0, n = 0;
        if (hasA) {
            for (int i = 0; i < 4; ++i)
                s += above[i];
            n += 4;
        }
        if (hasL) {
            for (int i = 0; i < 4; ++i)
                s += left[i];
            n += 4;
        }
        int v = n ? (s + 2) / n : 128;
        // Spec uses +2 for 4 samples or +4 for 8
        if (hasA && hasL)
            v = (s + 4) >> 3;
        else if (hasA || hasL)
            v = (s + 2) >> 2;
        else
            v = 128;
        for (int y = 0; y < 4; ++y)
            for (int x = 0; x < 4; ++x)
                dst[y * stride + x] = static_cast<uint8_t>(v);
    };
    switch (mode) {
    case 0: // Vertical
        for (int y = 0; y < 4; ++y)
            for (int x = 0; x < 4; ++x)
                dst[y * stride + x] = above[x];
        break;
    case 1: // Horizontal
        for (int y = 0; y < 4; ++y)
            for (int x = 0; x < 4; ++x)
                dst[y * stride + x] = left[y];
        break;
    case 2:
        dc();
        break;
    case 3: { // Diagonal Down-Left
        // uses above[0..7]
        auto p = [&](int i) -> int {
            if (i < 4)
                return above[i];
            return above[i]; // 4..7 top-right
        };
        for (int y = 0; y < 4; ++y)
            for (int x = 0; x < 4; ++x) {
                int k = x + y;
                int v;
                if (k < 6)
                    v = (p(k) + 2 * p(k + 1) + p(k + 2) + 2) >> 2;
                else
                    v = (p(6) + 3 * p(7) + 2) >> 2;
                dst[y * stride + x] = static_cast<uint8_t>(clip8(v));
            }
        break;
    }
    case 4: { // Diagonal Down-Right
        auto A = [&](int i) { return above[i]; };
        auto L = [&](int i) { return left[i]; };
        for (int y = 0; y < 4; ++y)
            for (int x = 0; x < 4; ++x) {
                int v;
                if (x > y)
                    v = (A(x - y - 2 + 1) + 2 * A(x - y - 1 + 1) + A(x - y + 1) + 2) >> 2;
                else if (x < y)
                    v = (L(y - x - 2 + 1) + 2 * L(y - x - 1 + 1) + L(y - x + 1) + 2) >> 2;
                else
                    v = (L(0) + 2 * tl + A(0) + 2) >> 2;
                // Simpler correct form from JM:
                (void)v;
            }
        // Use compact JM-style table via samples[9]: L3 L2 L1 L0 TL A0 A1 A2 A3
        int s[9] = {left[3], left[2], left[1], left[0], tl, above[0], above[1], above[2], above[3]};
        for (int y = 0; y < 4; ++y)
            for (int x = 0; x < 4; ++x) {
                int z = 4 + x - y;
                int v = (s[z - 1] + 2 * s[z] + s[z + 1] + 2) >> 2;
                dst[y * stride + x] = static_cast<uint8_t>(clip8(v));
            }
        break;
    }
    case 5: { // Vertical-Right
        int s[9] = {left[3], left[2], left[1], left[0], tl, above[0], above[1], above[2], above[3]};
        static const int8_t vr[4][4] = {
            {6, 7, 8, 9}, // will remap
            {0, 0, 0, 0},
            {0, 0, 0, 0},
            {0, 0, 0, 0},
        };
        (void)vr;
        // positions relative to TL
        for (int y = 0; y < 4; ++y)
            for (int x = 0; x < 4; ++x) {
                int z = 2 * x - y;
                int v;
                if (z >= 0 && (z & 1) == 0)
                    v = (s[4 + (z >> 1)] + s[5 + (z >> 1)] + 1) >> 1;
                else if (z >= 0)
                    v = (s[4 + (z >> 1)] + 2 * s[5 + (z >> 1)] + s[6 + (z >> 1)] + 2) >> 2;
                else if (z == -1)
                    v = (s[3] + 2 * s[4] + s[5] + 2) >> 2;
                else
                    v = (s[1] + 2 * s[2] + s[3] + 2) >> 2; // y=2,3 x=0 etc.
                // Fix bottom-left using left
                if (z < -1)
                    v = (s[4 + z] + 2 * s[5 + z] + s[6 + z] + 2) >> 2; // may OOB — use left path
                if (2 * x - y < -1) {
                    int yy = y - 1;
                    v = (left[yy] + 2 * left[yy - 1] + left[yy - 2] + 2) >> 2;
                    if (y == 2 && x == 0)
                        v = (left[0] + 2 * left[1] + left[2] + 2) >> 2;
                    if (y == 3 && x == 0)
                        v = (left[1] + 2 * left[2] + left[3] + 2) >> 2;
                    if (y == 3 && x == 1)
                        v = (left[0] + 2 * left[1] + left[2] + 2) >> 2;
                }
                dst[y * stride + x] = static_cast<uint8_t>(clip8(v));
            }
        break;
    }
    case 6: { // Horizontal-Down
        int s[9] = {left[3], left[2], left[1], left[0], tl, above[0], above[1], above[2], above[3]};
        for (int y = 0; y < 4; ++y)
            for (int x = 0; x < 4; ++x) {
                int z = 2 * y - x;
                int v;
                if (z >= 0 && (z & 1) == 0)
                    v = (s[4 - (z >> 1)] + s[3 - (z >> 1)] + 1) >> 1;
                else if (z >= 0)
                    v = (s[4 - (z >> 1)] + 2 * s[3 - (z >> 1)] + s[2 - (z >> 1)] + 2) >> 2;
                else if (z == -1)
                    v = (s[3] + 2 * s[4] + s[5] + 2) >> 2;
                else {
                    // x-heavy
                    v = (above[x - 1] + 2 * above[x - 2] + above[x - 3] + 2) >> 2;
                    if (x == 2 && y == 0)
                        v = (above[0] + 2 * above[1] + above[2] + 2) >> 2;
                    if (x == 3 && y == 0)
                        v = (above[1] + 2 * above[2] + above[3] + 2) >> 2;
                    if (x == 3 && y == 1)
                        v = (above[0] + 2 * above[1] + above[2] + 2) >> 2;
                }
                (void)s;
                dst[y * stride + x] = static_cast<uint8_t>(clip8(v));
            }
        break;
    }
    case 7: { // Vertical-Left
        for (int y = 0; y < 4; ++y)
            for (int x = 0; x < 4; ++x) {
                int z = 2 * x + y;
                int v;
                if ((z & 1) == 0)
                    v = (above[x + (y >> 1)] + above[x + (y >> 1) + 1] + 1) >> 1;
                else
                    v = (above[x + (y >> 1)] + 2 * above[x + (y >> 1) + 1] + above[x + (y >> 1) + 2] +
                         2) >>
                        2;
                dst[y * stride + x] = static_cast<uint8_t>(clip8(v));
            }
        break;
    }
    case 8: { // Horizontal-Up
        for (int y = 0; y < 4; ++y)
            for (int x = 0; x < 4; ++x) {
                int z = 2 * y + x;
                int v;
                if (z < 5) {
                    if ((z & 1) == 0)
                        v = (left[y + (x >> 1)] + left[y + (x >> 1) + 1] + 1) >> 1;
                    else
                        v = (left[y + (x >> 1)] + 2 * left[y + (x >> 1) + 1] +
                             left[y + (x >> 1) + 2] + 2) >>
                            2;
                } else if (z == 5)
                    v = (left[2] + 3 * left[3] + 2) >> 2;
                else
                    v = left[3];
                dst[y * stride + x] = static_cast<uint8_t>(clip8(v));
            }
        break;
    }
    default:
        dc();
        break;
    }
}

// Chroma 8x8 Intra pred modes 0=DC, 1=H, 2=V, 3=Plane
inline void predChroma8(int mode, uint8_t* mb, int stride, const uint8_t* above,
                        const uint8_t* left, uint8_t tl, bool hasA, bool hasL) {
    if (mode == 0) { // DC — 4 corner 4x4 regions slightly special
        auto fill = [&](int x0, int y0, int v) {
            for (int y = 0; y < 4; ++y)
                for (int x = 0; x < 4; ++x)
                    mb[(y0 + y) * stride + x0 + x] = static_cast<uint8_t>(v);
        };
        auto avg4 = [](const uint8_t* p) {
            return (p[0] + p[1] + p[2] + p[3] + 2) >> 2;
        };
        if (hasA && hasL) {
            fill(0, 0, (avg4(above) + avg4(left) + 1) >> 1);
            fill(4, 0, avg4(above + 4));
            fill(0, 4, avg4(left + 4));
            fill(4, 4, (avg4(above + 4) + avg4(left + 4) + 1) >> 1);
        } else if (hasA) {
            fill(0, 0, avg4(above));
            fill(4, 0, avg4(above + 4));
            fill(0, 4, avg4(above));
            fill(4, 4, avg4(above + 4));
        } else if (hasL) {
            fill(0, 0, avg4(left));
            fill(4, 0, avg4(left));
            fill(0, 4, avg4(left + 4));
            fill(4, 4, avg4(left + 4));
        } else {
            for (int y = 0; y < 8; ++y)
                std::memset(mb + y * stride, 128, 8);
        }
    } else if (mode == 1) { // H
        for (int y = 0; y < 8; ++y)
            for (int x = 0; x < 8; ++x)
                mb[y * stride + x] = left[y];
    } else if (mode == 2) { // V
        for (int y = 0; y < 8; ++y)
            for (int x = 0; x < 8; ++x)
                mb[y * stride + x] = above[x];
    } else { // Plane
        int H = 0, V = 0;
        for (int i = 0; i < 4; ++i) {
            int alo = (i == 3) ? static_cast<int>(tl) : above[2 - i];
            int llo = (i == 3) ? static_cast<int>(tl) : left[2 - i];
            H += (i + 1) * (above[4 + i] - alo);
            V += (i + 1) * (left[4 + i] - llo);
        }
        int a = 16 * (above[7] + left[7]);
        int b = (17 * H + 16) >> 5;
        int c = (17 * V + 16) >> 5;
        for (int y = 0; y < 8; ++y)
            for (int x = 0; x < 8; ++x) {
                int val = (a + b * (x - 3) + c * (y - 3) + 16) >> 5;
                mb[y * stride + x] = static_cast<uint8_t>(clip8(val));
            }
    }
}

// Chroma QP from luma QP (default table without pps offset — offset applied by caller)
static const int kChromaQP[52] = {
    0,  1,  2,  3,  4,  5,  6,  7,  8,  9,  10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23,
    24, 25, 26, 27, 28, 29, 29, 30, 31, 32, 32, 33, 34, 34, 35, 35, 36, 36, 37, 37, 37, 38, 38, 38,
    39, 39, 39, 39};

inline int chromaQp(int qpy, int offset) {
    int q = qpy + offset;
    if (q < 0)
        q = 0;
    if (q > 51)
        q = 51;
    return kChromaQP[q];
}

// Inverse chroma DC 2x2 Hadamard + dequant (4:2:0)
inline void invChromaDc2x2(const int16_t coeff[4], int qp, int16_t dc[2][2]) {
    // Place scan: 0=(0,0), 1=(0,1), 2=(1,0), 3=(1,1) for chroma DC
    int c0 = coeff[0], c1 = coeff[1], c2 = coeff[2], c3 = coeff[3];
    int t0 = c0 + c1;
    int t1 = c0 - c1;
    int t2 = c2 + c3;
    int t3 = c2 - c3;
    int d00 = t0 + t2, d01 = t1 + t3, d10 = t0 - t2, d11 = t1 - t3;
    static const int mf0[6] = {10, 11, 13, 14, 16, 18};
    int scale = mf0[qp % 6];
    int qbits = qp / 6;
    auto dq = [&](int v) -> int16_t {
        if (qbits >= 1)
            return static_cast<int16_t>((v * scale) << (qbits - 1));
        else
            return static_cast<int16_t>((v * scale) >> 1); // qp 0..5
    };
    dc[0][0] = dq(d00);
    dc[0][1] = dq(d01);
    dc[1][0] = dq(d10);
    dc[1][1] = dq(d11);
}

} // namespace detail_r

// Reconstruct full I-slice of first IDR/I NAL into YUV420 planar.
inline ReconResult reconISlice(const uint8_t* annexb, size_t n) {
    using namespace detail_r;
    ReconResult out;
    auto chain = parseAnnexBChain(annexb, n);
    if (!chain.sps.valid || !chain.pps.valid || !chain.slice.valid) {
        out.fail_reason = "no chain";
        return out;
    }
    out.width = chain.sps.width;
    out.height = chain.sps.height;
    const int mbW = (out.width + 15) / 16;
    const int mbH = (out.height + 15) / 16;
    out.mb_total = mbW * mbH;
    out.y.assign(static_cast<size_t>(out.width * out.height), 128);
    const int cw = (out.width + 1) / 2, ch = (out.height + 1) / 2;
    out.u.assign(static_cast<size_t>(cw * ch), 128);
    out.v.assign(static_cast<size_t>(cw * ch), 128);

    // Find VCL
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
    if (!pay) {
        out.fail_reason = "no VCL";
        return out;
    }
    auto rbsp = misterplex::detail::removeEpb(pay, plen);
    misterplex::detail::BitReader br(rbsp.data(), rbsp.size());
    br.ue();
    br.ue();
    br.ue();
    br.u(chain.log2_max_frame_num);
    if (ntype == 5) {
        br.ue();
        br.u(1);
        br.u(1);
    }
    br.se(); // slice_qp_delta already in chain.slice.slice_qp
    if (chain.pps.deblock_ctrl) {
        uint32_t d = br.ue();
        if (d != 1) {
            br.se();
            br.se();
        }
    }

    int qp = chain.slice.slice_qp;
    // chroma_qp_index_offset from PPS — re-parse roughly; default often -2 for x264
    // Our PPS parser doesn't export it; default 0, x264 uses -2. Probe from known SEI not available.
    // Read chroma offset by re-parsing PPS quickly:
    int chroma_offset = 0;
    {
        // scan PPS NAL
        size_t ii = 0;
        while (ii + 3 < n) {
            size_t sc = 0;
            if (ii + 3 < n && annexb[ii] == 0 && annexb[ii + 1] == 0 && annexb[ii + 2] == 0 &&
                annexb[ii + 3] == 1)
                sc = 4;
            else if (annexb[ii] == 0 && annexb[ii + 1] == 0 && annexb[ii + 2] == 1)
                sc = 3;
            else {
                ++ii;
                continue;
            }
            size_t jj = ii + sc;
            while (jj + 3 < n) {
                if (annexb[jj] == 0 && annexb[jj + 1] == 0 &&
                    (annexb[jj + 2] == 1 ||
                     (jj + 3 < n && annexb[jj + 2] == 0 && annexb[jj + 3] == 1)))
                    break;
                ++jj;
            }
            if (jj + 3 >= n)
                jj = n;
            if ((annexb[ii + sc] & 0x1f) == 8) {
                auto pr = misterplex::detail::removeEpb(annexb + ii + sc + 1, jj - (ii + sc + 1));
                misterplex::detail::BitReader pbr(pr.data(), pr.size());
                pbr.ue();
                pbr.ue();
                pbr.u(1);
                pbr.u(1);
                if (pbr.ue() > 0)
                    break;
                pbr.ue();
                pbr.ue();
                pbr.u(1);
                pbr.u(2);
                pbr.se(); // pic_init_qp
                pbr.se(); // qs
                chroma_offset = pbr.se();
                break;
            }
            ii = jj;
        }
    }

    std::vector<int> tcLuma(static_cast<size_t>(mbW * mbH * 16), -1);
    std::vector<int> tcChr[2] = {std::vector<int>(static_cast<size_t>(mbW * mbH * 4), -1),
                                  std::vector<int>(static_cast<size_t>(mbW * mbH * 4), -1)};
    // Intra4x4 pred modes storage for neighbors (mpm)
    std::vector<int8_t> i4mode(static_cast<size_t>(mbW * mbH * 16), 2);

    auto tcatL = [&](int mbx, int mby, int lx, int ly) -> int* {
        if (mbx < 0 || mby < 0 || mbx >= mbW || mby >= mbH || lx < 0 || ly < 0 || lx > 3 || ly > 3)
            return nullptr;
        int& v = tcLuma[static_cast<size_t>(((mby * mbW + mbx) * 16) + ly * 4 + lx)];
        return (v < 0) ? nullptr : &v;
    };
    auto tcsetL = [&](int mbx, int mby, int lx, int ly, int v) {
        tcLuma[static_cast<size_t>(((mby * mbW + mbx) * 16) + ly * 4 + lx)] = v;
    };
    auto tcatC = [&](int plane, int mbx, int mby, int lx, int ly) -> int* {
        if (mbx < 0 || mby < 0 || mbx >= mbW || mby >= mbH || lx < 0 || ly < 0 || lx > 1 || ly > 1)
            return nullptr;
        int& v = tcChr[plane][static_cast<size_t>(((mby * mbW + mbx) * 4) + ly * 2 + lx)];
        return (v < 0) ? nullptr : &v;
    };
    auto tcsetC = [&](int plane, int mbx, int mby, int lx, int ly, int v) {
        tcChr[plane][static_cast<size_t>(((mby * mbW + mbx) * 4) + ly * 2 + lx)] = v;
    };
    auto modeAt = [&](int mbx, int mby, int lx, int ly) -> int {
        if (mbx < 0 || mby < 0 || mbx >= mbW || mby >= mbH)
            return -1;
        return i4mode[static_cast<size_t>(((mby * mbW + mbx) * 16) + ly * 4 + lx)];
    };

    auto yAt = [&](int x, int y) -> uint8_t {
        if (x < 0 || y < 0 || x >= out.width || y >= out.height)
            return 128;
        return out.y[static_cast<size_t>(y * out.width + x)];
    };
    auto setY = [&](int x, int y, uint8_t v) {
        if (x >= 0 && y >= 0 && x < out.width && y < out.height)
            out.y[static_cast<size_t>(y * out.width + x)] = v;
    };

    for (int mby = 0; mby < mbH; ++mby) {
        for (int mbx = 0; mbx < mbW; ++mbx) {
            int mb = mby * mbW + mbx;
            if (!br.ok) {
                out.fail_mb = mb;
                out.fail_reason = "br";
                return out;
            }
            uint32_t mt = br.ue();
            if (mt > 25) {
                out.fail_mb = mb;
                out.fail_reason = "mb_type";
                return out;
            }
            const int baseX = mbx * 16;
            const int baseY = mby * 16;
            const bool hasLeft = mbx > 0;
            const bool hasAbove = mby > 0;

            if (mt == 25) {
                while (br.ok && (br.bit % 8) != 0)
                    br.u(1);
                for (int yy = 0; yy < 16; ++yy)
                    for (int xx = 0; xx < 16; ++xx)
                        setY(baseX + xx, baseY + yy, static_cast<uint8_t>(br.u(8)));
                for (int p = 0; p < 2; ++p)
                    for (int k = 0; k < 64; ++k)
                        br.u(8);
                for (int ly = 0; ly < 4; ++ly)
                    for (int lx = 0; lx < 4; ++lx)
                        tcsetL(mbx, mby, lx, ly, 16);
                out.mb_decoded++;
                continue;
            }

            if (mt == 0) {
                // I_NxN — 16 pred modes in 8x8-group / 4x4 scan order
                int predModes[16];
                for (int blk = 0; blk < 16; ++blk) {
                    int i8 = blk / 4, i4 = blk % 4;
                    int lx, ly;
                    walk_detail::blkXY(i8, i4, lx, ly);
                    int modeA = (lx > 0) ? modeAt(mbx, mby, lx - 1, ly)
                                         : modeAt(mbx - 1, mby, 3, ly);
                    int modeB = (ly > 0) ? modeAt(mbx, mby, lx, ly - 1)
                                         : modeAt(mbx, mby - 1, lx, 3);
                    if (modeA < 0)
                        modeA = 2;
                    if (modeB < 0)
                        modeB = 2;
                    int pred = std::min(modeA, modeB);
                    if (br.u(1)) {
                        predModes[blk] = pred;
                    } else {
                        int rem = static_cast<int>(br.u(3));
                        predModes[blk] = rem + (rem >= pred ? 1 : 0);
                    }
                    i4mode[static_cast<size_t>(((mby * mbW + mbx) * 16) + ly * 4 + lx)] =
                        static_cast<int8_t>(predModes[blk]);
                }
                int chromaMode = static_cast<int>(br.ue());
                uint32_t code = br.ue();
                if (code >= 48) {
                    out.fail_mb = mb;
                    out.fail_reason = "me_cbp";
                    return out;
                }
                int cbp = walk_detail::kMeIntra[code];
                int cbp_l = cbp & 15;
                int cbp_c = cbp >> 4;
                if (cbp != 0) {
                    int d = br.se();
                    qp += d;
                    if (qp < 0)
                        qp = 0;
                    if (qp > 51)
                        qp = 51;
                }

                // Predict + residual each 4x4
                for (int i8 = 0; i8 < 4; ++i8) {
                    for (int i4 = 0; i4 < 4; ++i4) {
                        int lx, ly;
                        walk_detail::blkXY(i8, i4, lx, ly);
                        int blk = i8 * 4 + i4;
                        int mode = predModes[blk];
                        int x0 = baseX + lx * 4;
                        int y0 = baseY + ly * 4;
                        uint8_t above[8], left[4], tl = 128;
                        bool ha = (y0 > 0);
                        bool hl = (x0 > 0);
                        for (int t = 0; t < 4; ++t)
                            above[t] = ha ? yAt(x0 + t, y0 - 1) : 128;
                        // top-right
                        for (int t = 0; t < 4; ++t) {
                            if (ha && x0 + 4 + t < out.width)
                                above[4 + t] = yAt(x0 + 4 + t, y0 - 1);
                            else
                                above[4 + t] = above[3];
                        }
                        for (int t = 0; t < 4; ++t)
                            left[t] = hl ? yAt(x0 - 1, y0 + t) : 128;
                        if (ha && hl)
                            tl = yAt(x0 - 1, y0 - 1);
                        else if (ha)
                            tl = above[0];
                        else if (hl)
                            tl = left[0];

                        // Unavailable mode restrictions: V needs above, H needs left
                        int useMode = mode;
                        if (!ha && (mode == 0 || mode == 3 || mode == 7))
                            useMode = 2;
                        if (!hl && (mode == 1 || mode == 8))
                            useMode = 2;
                        if ((!ha || !hl) && (mode == 4 || mode == 5 || mode == 6))
                            useMode = 2;

                        uint8_t pred[16];
                        predI4(useMode, pred, 4, above, left, tl, ha, hl);
                        for (int yy = 0; yy < 4; ++yy)
                            for (int xx = 0; xx < 4; ++xx)
                                setY(x0 + xx, y0 + yy, pred[yy * 4 + xx]);

                        if ((cbp_l >> i8) & 1) {
                            int* nA = (lx > 0) ? tcatL(mbx, mby, lx - 1, ly)
                                               : tcatL(mbx - 1, mby, 3, ly);
                            int* nB = (ly > 0) ? tcatL(mbx, mby, lx, ly - 1)
                                               : tcatL(mbx, mby - 1, lx, 3);
                            int nC = walk_detail::ncFrom(nA, nB);
                            auto r = cavlc::residualBlock(br, nC, 16);
                            if (!r.ok) {
                                out.fail_mb = mb;
                                out.fail_reason = "I4_res";
                                return out;
                            }
                            tcsetL(mbx, mby, lx, ly, r.total_coeff);
                            int16_t blkq[4][4];
                            dequant4x4(r.coeff, 16, qp, blkq);
                            uint8_t tmp[16];
                            for (int yy = 0; yy < 4; ++yy)
                                for (int xx = 0; xx < 4; ++xx)
                                    tmp[yy * 4 + xx] = yAt(x0 + xx, y0 + yy);
                            idct4x4_add(blkq, tmp, 4);
                            for (int yy = 0; yy < 4; ++yy)
                                for (int xx = 0; xx < 4; ++xx)
                                    setY(x0 + xx, y0 + yy, tmp[yy * 4 + xx]);
                        } else {
                            tcsetL(mbx, mby, lx, ly, 0);
                        }
                    }
                }

                // Chroma
                int qpc = chromaQp(qp, chroma_offset);
                uint8_t* planes[2] = {out.u.data(), out.v.data()};
                for (int p = 0; p < 2; ++p) {
                    uint8_t cmb[64];
                    uint8_t above[8], left[8], tl = 128;
                    int cx = mbx * 8, cy = mby * 8;
                    bool ha = mby > 0, hl = mbx > 0;
                    for (int t = 0; t < 8; ++t) {
                        above[t] = ha ? planes[p][(cy - 1) * cw + cx + t] : 128;
                        left[t] = hl ? planes[p][(cy + t) * cw + cx - 1] : 128;
                    }
                    if (ha && hl)
                        tl = planes[p][(cy - 1) * cw + cx - 1];
                    predChroma8(chromaMode, cmb, 8, above, left, tl, ha, hl);
                    for (int yy = 0; yy < 8; ++yy)
                        for (int xx = 0; xx < 8; ++xx)
                            if (cx + xx < cw && cy + yy < ch)
                                planes[p][(cy + yy) * cw + cx + xx] = cmb[yy * 8 + xx];
                }
                if (cbp_c) {
                    auto r0 = cavlc::residualBlock(br, -1, 4);
                    auto r1 = cavlc::residualBlock(br, -1, 4);
                    if (!r0.ok || !r1.ok) {
                        out.fail_mb = mb;
                        out.fail_reason = "chrDC";
                        return out;
                    }
                    int16_t dcU[2][2], dcV[2][2];
                    invChromaDc2x2(r0.coeff, qpc, dcU);
                    invChromaDc2x2(r1.coeff, qpc, dcV);
                    int16_t(*dcs[2])[2][2] = {&dcU, &dcV};
                    for (int p = 0; p < 2; ++p) {
                        for (int by = 0; by < 2; ++by)
                            for (int bx = 0; bx < 2; ++bx) {
                                int16_t blkq[4][4]{};
                                if (cbp_c == 2) {
                                    int b = by * 2 + bx;
                                    int lx = b % 2, ly = b / 2;
                                    int* nA = (lx > 0) ? tcatC(p, mbx, mby, lx - 1, ly)
                                                       : tcatC(p, mbx - 1, mby, 1, ly);
                                    int* nB = (ly > 0) ? tcatC(p, mbx, mby, lx, ly - 1)
                                                       : tcatC(p, mbx, mby - 1, lx, 1);
                                    auto rr =
                                        cavlc::residualBlock(br, walk_detail::ncFrom(nA, nB), 15);
                                    if (!rr.ok) {
                                        out.fail_mb = mb;
                                        out.fail_reason = "chrAC";
                                        return out;
                                    }
                                    tcsetC(p, mbx, mby, lx, ly, rr.total_coeff);
                                    dequant4x4(rr.coeff, 15, qpc, blkq);
                                } else {
                                    tcsetC(p, mbx, mby, bx, by, 0);
                                }
                                // Chroma DC into (0,0) of each 4x4 residual
                                blkq[0][0] = (*dcs[p])[by][bx];
                                int x0 = mbx * 8 + bx * 4;
                                int y0 = mby * 8 + by * 4;
                                uint8_t tmp[16];
                                for (int yy = 0; yy < 4; ++yy)
                                    for (int xx = 0; xx < 4; ++xx)
                                        tmp[yy * 4 + xx] =
                                            (x0 + xx < cw && y0 + yy < ch)
                                                ? planes[p][(y0 + yy) * cw + x0 + xx]
                                                : 128;
                                idct4x4_add(blkq, tmp, 4);
                                for (int yy = 0; yy < 4; ++yy)
                                    for (int xx = 0; xx < 4; ++xx)
                                        if (x0 + xx < cw && y0 + yy < ch)
                                            planes[p][(y0 + yy) * cw + x0 + xx] = tmp[yy * 4 + xx];
                            }
                    }
                } else {
                    for (int p = 0; p < 2; ++p)
                        for (int b = 0; b < 4; ++b) {
                            int lx, ly;
                            walk_detail::chrXY(b, lx, ly);
                            tcsetC(p, mbx, mby, lx, ly, 0);
                        }
                }
            } else {
                // I_16x16
                int x = static_cast<int>(mt) - 1;
                int predMode = x % 4;
                int cbp_c = (x / 4) % 3;
                int cbp_l = (x / 12) ? 15 : 0;
                int chromaMode = static_cast<int>(br.ue());
                int d = br.se();
                qp += d;
                if (qp < 0)
                    qp = 0;
                if (qp > 51)
                    qp = 51;

                uint8_t above[16], left[16], tl = 128;
                for (int t = 0; t < 16; ++t) {
                    above[t] = hasAbove ? yAt(baseX + t, baseY - 1) : 128;
                    left[t] = hasLeft ? yAt(baseX - 1, baseY + t) : 128;
                }
                if (hasAbove && hasLeft)
                    tl = yAt(baseX - 1, baseY - 1);

                uint8_t mbpred[256];
                if (predMode == 0 && hasAbove)
                    predI16_V(mbpred, 16, above);
                else if (predMode == 1 && hasLeft)
                    predI16_H(mbpred, 16, left);
                else if (predMode == 3 && hasAbove && hasLeft)
                    predI16_Plane(mbpred, 16, above, left, tl);
                else
                    predI16_DC(mbpred, 16, above, left, hasAbove, hasLeft);

                for (int yy = 0; yy < 16; ++yy)
                    for (int xx = 0; xx < 16; ++xx)
                        setY(baseX + xx, baseY + yy, mbpred[yy * 16 + xx]);

                int* nA = tcatL(mbx - 1, mby, 3, 0);
                int* nB = tcatL(mbx, mby - 1, 0, 3);
                auto rdc = cavlc::residualBlock(br, walk_detail::ncFrom(nA, nB), 16);
                if (!rdc.ok) {
                    out.fail_mb = mb;
                    out.fail_reason = "I16_dc";
                    return out;
                }
                int16_t dc[4][4];
                cavlc::invQuantHadamardDc4x4(rdc.coeff, qp, dc);

                for (int i8 = 0; i8 < 4; ++i8)
                    for (int i4 = 0; i4 < 4; ++i4) {
                        int lx, ly;
                        walk_detail::blkXY(i8, i4, lx, ly);
                        int16_t blkq[4][4]{};
                        if (cbp_l) {
                            int* a = (lx > 0) ? tcatL(mbx, mby, lx - 1, ly)
                                              : tcatL(mbx - 1, mby, 3, ly);
                            int* b = (ly > 0) ? tcatL(mbx, mby, lx, ly - 1)
                                              : tcatL(mbx, mby - 1, lx, 3);
                            auto rr = cavlc::residualBlock(br, walk_detail::ncFrom(a, b), 15);
                            if (!rr.ok) {
                                out.fail_mb = mb;
                                out.fail_reason = "I16_ac";
                                return out;
                            }
                            tcsetL(mbx, mby, lx, ly, rr.total_coeff);
                            dequant4x4(rr.coeff, 15, qp, blkq);
                        } else {
                            tcsetL(mbx, mby, lx, ly, 0);
                        }
                        // Inject DC (already fully scaled for idct add path)
                        // FFmpeg: DC is stored and used as block[0] before idct with different scale.
                        // invQuantHadamardDc4x4 produces values meant as residual DC after >> .
                        // Add into dequant'd (0,0) then idct.
                        blkq[0][0] = static_cast<int16_t>(blkq[0][0] + (dc[ly][lx] << 6) / 1);
                        // Standard: after Hadamard+dequant, DC is at full residual domain before
                        // inverse transform; idct does (x+32)>>6. So DC should be pre-scaled
                        // by not shifting extra. cavlc::invQuantHadamard already applies >>1 in had.
                        // Match reconFirstI16DcMeanY: val = 128 + dc[by][bx] without idct for DC-only.
                        // For full idct, DC coefficient before idct is dc*64? Actually JM puts
                        // dequantized DC directly as block[0][0] and runs idct.
                        // Re-do: use dc as block[0][0] directly (overwrite add).
                        blkq[0][0] = dc[ly][lx];
                        if (cbp_l) {
                            // re-dequant AC only into blk, then set DC
                            // already did; just set DC after dequant of AC (AC dequant leaves 0,0=0
                            // for max15)
                        }
                        int x0 = baseX + lx * 4, y0 = baseY + ly * 4;
                        uint8_t tmp[16];
                        for (int yy = 0; yy < 4; ++yy)
                            for (int xx = 0; xx < 4; ++xx)
                                tmp[yy * 4 + xx] = yAt(x0 + xx, y0 + yy);
                        idct4x4_add(blkq, tmp, 4);
                        for (int yy = 0; yy < 4; ++yy)
                            for (int xx = 0; xx < 4; ++xx)
                                setY(x0 + xx, y0 + yy, tmp[yy * 4 + xx]);
                        i4mode[static_cast<size_t>(((mby * mbW + mbx) * 16) + ly * 4 + lx)] = 2;
                    }

                // Chroma for I16
                int qpc = chromaQp(qp, chroma_offset);
                uint8_t* planes[2] = {out.u.data(), out.v.data()};
                for (int p = 0; p < 2; ++p) {
                    uint8_t cmb[64];
                    uint8_t ab[8], lf[8], tlp = 128;
                    int cx = mbx * 8, cy = mby * 8;
                    bool ha = mby > 0, hl = mbx > 0;
                    for (int t = 0; t < 8; ++t) {
                        ab[t] = ha ? planes[p][(cy - 1) * cw + cx + t] : 128;
                        lf[t] = hl ? planes[p][(cy + t) * cw + cx - 1] : 128;
                    }
                    if (ha && hl)
                        tlp = planes[p][(cy - 1) * cw + cx - 1];
                    predChroma8(chromaMode, cmb, 8, ab, lf, tlp, ha, hl);
                    for (int yy = 0; yy < 8; ++yy)
                        for (int xx = 0; xx < 8; ++xx)
                            if (cx + xx < cw && cy + yy < ch)
                                planes[p][(cy + yy) * cw + cx + xx] = cmb[yy * 8 + xx];
                }
                if (cbp_c) {
                    auto r0 = cavlc::residualBlock(br, -1, 4);
                    auto r1 = cavlc::residualBlock(br, -1, 4);
                    if (!r0.ok || !r1.ok) {
                        out.fail_mb = mb;
                        out.fail_reason = "chrDC";
                        return out;
                    }
                    int16_t dcU[2][2], dcV[2][2];
                    invChromaDc2x2(r0.coeff, qpc, dcU);
                    invChromaDc2x2(r1.coeff, qpc, dcV);
                    int16_t(*dcs[2])[2][2] = {&dcU, &dcV};
                    for (int p = 0; p < 2; ++p) {
                        for (int by = 0; by < 2; ++by)
                            for (int bx = 0; bx < 2; ++bx) {
                                int16_t blkq[4][4]{};
                                if (cbp_c == 2) {
                                    int lx = bx, ly = by;
                                    int* a = (lx > 0) ? tcatC(p, mbx, mby, lx - 1, ly)
                                                      : tcatC(p, mbx - 1, mby, 1, ly);
                                    int* b = (ly > 0) ? tcatC(p, mbx, mby, lx, ly - 1)
                                                      : tcatC(p, mbx, mby - 1, lx, 1);
                                    auto rr =
                                        cavlc::residualBlock(br, walk_detail::ncFrom(a, b), 15);
                                    if (!rr.ok) {
                                        out.fail_mb = mb;
                                        out.fail_reason = "chrAC";
                                        return out;
                                    }
                                    tcsetC(p, mbx, mby, lx, ly, rr.total_coeff);
                                    dequant4x4(rr.coeff, 15, qpc, blkq);
                                } else {
                                    tcsetC(p, mbx, mby, bx, by, 0);
                                }
                                blkq[0][0] = (*dcs[p])[by][bx];
                                int x0 = mbx * 8 + bx * 4, y0 = mby * 8 + by * 4;
                                uint8_t tmp[16];
                                for (int yy = 0; yy < 4; ++yy)
                                    for (int xx = 0; xx < 4; ++xx)
                                        tmp[yy * 4 + xx] =
                                            (x0 + xx < cw && y0 + yy < ch)
                                                ? planes[p][(y0 + yy) * cw + x0 + xx]
                                                : 128;
                                idct4x4_add(blkq, tmp, 4);
                                for (int yy = 0; yy < 4; ++yy)
                                    for (int xx = 0; xx < 4; ++xx)
                                        if (x0 + xx < cw && y0 + yy < ch)
                                            planes[p][(y0 + yy) * cw + x0 + xx] = tmp[yy * 4 + xx];
                            }
                    }
                } else {
                    for (int p = 0; p < 2; ++p)
                        for (int b = 0; b < 4; ++b) {
                            int lx, ly;
                            walk_detail::chrXY(b, lx, ly);
                            tcsetC(p, mbx, mby, lx, ly, 0);
                        }
                }
            }
            out.mb_decoded++;
        }
    }
    return out;
}

// YUV420 → RGB565 (BT.601 full-range style, integer)
inline void yuv420ToRgb565(const uint8_t* y, const uint8_t* u, const uint8_t* v, int w, int h,
                           std::vector<uint16_t>& rgb) {
    rgb.resize(static_cast<size_t>(w * h));
    const int cw = (w + 1) / 2;
    for (int j = 0; j < h; ++j) {
        for (int i = 0; i < w; ++i) {
            int Y = y[j * w + i];
            int U = u[(j / 2) * cw + (i / 2)] - 128;
            int V = v[(j / 2) * cw + (i / 2)] - 128;
            int R = Y + ((360 * V) >> 8);
            int G = Y - ((88 * U + 184 * V) >> 8);
            int B = Y + ((455 * U) >> 8);
            R = detail_r::clip8(R);
            G = detail_r::clip8(G);
            B = detail_r::clip8(B);
            rgb[static_cast<size_t>(j * w + i)] =
                static_cast<uint16_t>(((R >> 3) << 11) | ((G >> 2) << 5) | (B >> 3));
        }
    }
}

// Mean absolute error of Y vs golden (or -1 if size mismatch)
inline double maeY(const ReconResult& r, const uint8_t* golden, size_t glen) {
    if (!golden || r.y.size() != glen)
        return -1.0;
    double s = 0;
    for (size_t i = 0; i < glen; ++i)
        s += std::abs(static_cast<int>(r.y[i]) - static_cast<int>(golden[i]));
    return s / static_cast<double>(glen);
}

} // namespace recon
} // namespace misterplex
