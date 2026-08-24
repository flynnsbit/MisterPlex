// Phase-1a host GOP recon: I + P_L0_16x16 + P_Skip + I-in-P (existing I path).
// No P_16x8. product_recon_ok stays RTL-side 0.
#pragma once
#include "libmisterplex/h264_recon.hpp"

#include <cmath>
#include <cstdio>
#include <utility>

namespace misterplex {
namespace recon {

struct GopReconResult {
    int width = 0;
    int height = 0;
    int frames = 0;
    int i_mb = 0;
    int p_mb = 0;
    int i_in_p = 0;
    int fail_frame = -1;
    int fail_mb = -1;
    const char* fail_reason = nullptr;
    std::vector<uint8_t> yuv; // packed I420 frames
};

namespace detail_p {

inline int clipi(int v, int lo, int hi) {
    if (v < lo) return lo;
    if (v > hi) return hi;
    return v;
}

inline uint8_t pel(const uint8_t* p, int w, int h, int x, int y) {
    return p[static_cast<size_t>(clipi(y, 0, h - 1) * w + clipi(x, 0, w - 1))];
}

inline int tap6(int a, int b, int c, int d, int e, int f) {
    return a - 5 * b + 20 * c + 20 * d - 5 * e + f;
}

inline uint8_t lumaQpel(const uint8_t* ref, int w, int h, int x, int y, int fx, int fy) {
    auto L = [&](int xx, int yy) { return static_cast<int>(pel(ref, w, h, xx, yy)); };
    auto halfH = [&](int xx, int yy) {
        int v = (tap6(L(xx - 2, yy), L(xx - 1, yy), L(xx, yy), L(xx + 1, yy), L(xx + 2, yy),
                      L(xx + 3, yy)) +
                 16) >>
                5;
        return detail_r::clip8(v);
    };
    auto halfV = [&](int xx, int yy) {
        int v = (tap6(L(xx, yy - 2), L(xx, yy - 1), L(xx, yy), L(xx, yy + 1), L(xx, yy + 2),
                      L(xx, yy + 3)) +
                 16) >>
                5;
        return detail_r::clip8(v);
    };
    auto halfHV = [&](int xx, int yy) {
        int t[6];
        for (int k = -2; k <= 3; ++k)
            t[k + 2] = tap6(L(xx - 2, yy + k), L(xx - 1, yy + k), L(xx, yy + k), L(xx + 1, yy + k),
                            L(xx + 2, yy + k), L(xx + 3, yy + k));
        int v = (tap6(t[0], t[1], t[2], t[3], t[4], t[5]) + 512) >> 10;
        return detail_r::clip8(v);
    };
    if (fx == 0 && fy == 0)
        return pel(ref, w, h, x, y);
    if (fy == 0 && fx == 2)
        return static_cast<uint8_t>(halfH(x, y));
    if (fx == 0 && fy == 2)
        return static_cast<uint8_t>(halfV(x, y));
    if (fx == 2 && fy == 2)
        return static_cast<uint8_t>(halfHV(x, y));
    if (fy == 0) { // 1 or 3
        int a = L(x, y);
        int b = halfH(x, y);
        if (fx == 3)
            a = L(x + 1, y);
        return static_cast<uint8_t>((a + b + 1) >> 1);
    }
    if (fx == 0) {
        int a = L(x, y);
        int b = halfV(x, y);
        if (fy == 3)
            a = L(x, y + 1);
        return static_cast<uint8_t>((a + b + 1) >> 1);
    }
    if (fx == 2) {
        int a = halfHV(x, y);
        int b = (fy == 1) ? halfH(x, y) : halfH(x, y + 1);
        return static_cast<uint8_t>((a + b + 1) >> 1);
    }
    if (fy == 2) {
        int a = halfHV(x, y);
        int b = (fx == 1) ? halfV(x, y) : halfV(x + 1, y);
        return static_cast<uint8_t>((a + b + 1) >> 1);
    }
    // corners: average of integer and opposite integer via halfs
    int ax = x + (fx == 3 ? 1 : 0);
    int ay = y + (fy == 3 ? 1 : 0);
    return static_cast<uint8_t>((halfH(ax, ay - (fy == 3 ? 1 : 0)) + halfV(ax - (fx == 3 ? 1 : 0), ay) + 1) >>
                                1);
}

inline uint8_t chromaEpel(const uint8_t* ref, int w, int h, int x, int y, int fx, int fy) {
    int A = pel(ref, w, h, x, y);
    int B = pel(ref, w, h, x + 1, y);
    int C = pel(ref, w, h, x, y + 1);
    int D = pel(ref, w, h, x + 1, y + 1);
    int v = ((8 - fx) * (8 - fy) * A + fx * (8 - fy) * B + (8 - fx) * fy * C + fx * fy * D + 32) >> 6;
    return static_cast<uint8_t>(v);
}

inline void mc16(const uint8_t* y, const uint8_t* u, const uint8_t* v, int w, int h, int mbx, int mby,
                 int mvx, int mvy, uint8_t predY[256], uint8_t predU[64], uint8_t predV[64]) {
    const int baseX = mbx * 16, baseY = mby * 16;
    for (int yy = 0; yy < 16; ++yy)
        for (int xx = 0; xx < 16; ++xx) {
            int sx = baseX + xx + (mvx >> 2);
            int sy = baseY + yy + (mvy >> 2);
            predY[yy * 16 + xx] = lumaQpel(y, w, h, sx, sy, mvx & 3, mvy & 3);
        }
    const int cw = (w + 1) / 2, ch = (h + 1) / 2;
    int cmvx = mvx, cmvy = mvy; // luma qpel; chroma 1/8 = same units / 2
    for (int yy = 0; yy < 8; ++yy)
        for (int xx = 0; xx < 8; ++xx) {
            int sx = mbx * 8 + xx + (cmvx >> 3);
            int sy = mby * 8 + yy + (cmvy >> 3);
            predU[yy * 8 + xx] = chromaEpel(u, cw, ch, sx, sy, cmvx & 7, cmvy & 7);
            predV[yy * 8 + xx] = chromaEpel(v, cw, ch, sx, sy, cmvx & 7, cmvy & 7);
        }
}

inline int16_t median3(int16_t a, int16_t b, int16_t c) {
    return static_cast<int16_t>(a + b + c - std::min(a, std::min(b, c)) - std::max(a, std::max(b, c)));
}

inline std::pair<int16_t, int16_t> mvPred(bool aa, bool bb, bool cc, int16_t ax, int16_t ay, int16_t bx,
                                           int16_t by, int16_t cx, int16_t cy, bool pskip) {
    int n = (int)aa + (int)bb + (int)cc;
    int16_t px = 0, py = 0;
    if (n == 1) {
        if (aa) { px = ax; py = ay; }
        else if (bb) { px = bx; py = by; }
        else { px = cx; py = cy; }
    } else if (n >= 2) {
        px = median3(aa ? ax : 0, bb ? bx : 0, cc ? cx : 0);
        py = median3(aa ? ay : 0, bb ? by : 0, cc ? cy : 0);
    }
    bool skip0 = pskip && (!aa || !bb || (ax == 0 && ay == 0) || (bx == 0 && by == 0));
    if (skip0) return {0, 0};
    return {px, py};
}

} // namespace detail_p

inline GopReconResult reconPhase1aGop(const uint8_t* annexb, size_t n) {
    using namespace detail_r;
    using namespace detail_p;
    GopReconResult g;
    auto I = reconISlice(annexb, n);
    if (I.mb_decoded != I.mb_total || I.y.empty()) {
        g.fail_reason = I.fail_reason ? I.fail_reason : "I";
        return g;
    }
    g.width = I.width;
    g.height = I.height;
    g.i_mb = I.mb_decoded;
    const int w = I.width, h = I.height;
    const int cw = (w + 1) / 2, ch = (h + 1) / 2;
    const int ysz = w * h, uvsz = cw * ch, frm = ysz + 2 * uvsz;
    const int mbW = (w + 15) / 16, mbH = (h + 15) / 16, tot = mbW * mbH;
    auto pack = [&](const std::vector<uint8_t>& Y, const std::vector<uint8_t>& U,
                    const std::vector<uint8_t>& V) {
        g.yuv.insert(g.yuv.end(), Y.begin(), Y.end());
        g.yuv.insert(g.yuv.end(), U.begin(), U.end());
        g.yuv.insert(g.yuv.end(), V.begin(), V.end());
        g.frames++;
    };
    pack(I.y, I.u, I.v);

    auto chain = parseAnnexBChain(annexb, n);
    int chroma_offset = 0;
    {
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
                    (annexb[jj + 2] == 1 || (jj + 3 < n && annexb[jj + 2] == 0 && annexb[jj + 3] == 1)))
                    break;
                ++jj;
            }
            if (jj + 3 >= n) jj = n;
            if ((annexb[ii + sc] & 0x1f) == 8) {
                auto pr = misterplex::detail::removeEpb(annexb + ii + sc + 1, jj - (ii + sc + 1));
                misterplex::detail::BitReader pbr(pr.data(), pr.size());
                pbr.ue(); pbr.ue(); pbr.u(1); pbr.u(1);
                if (pbr.ue() == 0) {
                    pbr.ue(); pbr.ue(); pbr.u(1); pbr.u(2); pbr.se(); pbr.se();
                    chroma_offset = pbr.se();
                }
                break;
            }
            ii = jj;
        }
    }

    std::vector<uint8_t> refY = I.y, refU = I.u, refV = I.v;
    size_t i = 0;
    int pidx = 0;
    while (i + 3 < n) {
        size_t sc = 0;
        if (i + 3 < n && annexb[i] == 0 && annexb[i + 1] == 0 && annexb[i + 2] == 0 && annexb[i + 3] == 1)
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
        if (j + 3 >= n) j = n;
        uint8_t t = annexb[i + sc] & 0x1f;
        if (t != 1) {
            i = j;
            continue;
        }
        const uint8_t* pay = annexb + i + sc + 1;
        size_t plen = j - (i + sc + 1);
        auto rbsp = misterplex::detail::removeEpb(pay, plen);
        misterplex::detail::BitReader peek(rbsp.data(), rbsp.size());
        peek.ue();
        uint32_t st = peek.ue();
        if (!walk_detail::isPSliceType(static_cast<uint8_t>(st))) {
            i = j;
            continue;
        }
        misterplex::detail::BitReader br(rbsp.data(), rbsp.size());
        br.ue(); br.ue(); br.ue();
        br.u(chain.log2_max_frame_num);
        int nref = static_cast<int>(chain.pps.num_ref_idx_l0_default) + 1;
        if (const char* e = walk_detail::parsePHeaderThreeU1(br, nref)) {
            g.fail_frame = pidx + 1;
            g.fail_reason = e;
            return g;
        }
        int qp = static_cast<int>(chain.pps.pic_init_qp) + br.se();
        if (qp < 0) qp = 0;
        if (qp > 51) qp = 51;
        if (chain.pps.deblock_ctrl) {
            uint32_t d = br.ue();
            if (d != 1) {
                br.se();
                br.se();
            }
        }

        std::vector<uint8_t> Y(static_cast<size_t>(ysz), 128), U(static_cast<size_t>(uvsz), 128),
            V(static_cast<size_t>(uvsz), 128);
        std::vector<int> tcL(static_cast<size_t>(tot * 16), -1);
        std::vector<int> tcC0(static_cast<size_t>(tot * 4), -1), tcC1(static_cast<size_t>(tot * 4), -1);
        std::vector<int8_t> i4mode(static_cast<size_t>(tot * 16), -1);
        std::vector<int16_t> mvx(static_cast<size_t>(tot), 0), mvy(static_cast<size_t>(tot), 0);
        std::vector<uint8_t> mvav(static_cast<size_t>(tot), 0);

        auto tcatL = [&](int mbx, int mby, int lx, int ly) -> int* {
            if (mbx < 0 || mby < 0 || mbx >= mbW || mby >= mbH) return nullptr;
            int& v = tcL[static_cast<size_t>(((mby * mbW + mbx) * 16) + ly * 4 + lx)];
            return (v < 0) ? nullptr : &v;
        };
        auto tcsetL = [&](int mbx, int mby, int lx, int ly, int v) {
            tcL[static_cast<size_t>(((mby * mbW + mbx) * 16) + ly * 4 + lx)] = v;
        };
        auto tcatC = [&](int pl, int mbx, int mby, int lx, int ly) -> int* {
            if (mbx < 0 || mby < 0 || mbx >= mbW || mby >= mbH) return nullptr;
            auto& t = (pl == 0) ? tcC0 : tcC1;
            int& v = t[static_cast<size_t>(((mby * mbW + mbx) * 4) + ly * 2 + lx)];
            return (v < 0) ? nullptr : &v;
        };
        auto tcsetC = [&](int pl, int mbx, int mby, int lx, int ly, int v) {
            auto& t = (pl == 0) ? tcC0 : tcC1;
            t[static_cast<size_t>(((mby * mbW + mbx) * 4) + ly * 2 + lx)] = v;
        };
        auto yAt = [&](int x, int y) -> uint8_t {
            if (x < 0 || y < 0 || x >= w || y >= h) return 128;
            return Y[static_cast<size_t>(y * w + x)];
        };
        auto setY = [&](int x, int y, uint8_t v) {
            if (x >= 0 && y >= 0 && x < w && y < h)
                Y[static_cast<size_t>(y * w + x)] = v;
        };
        auto modeAt = [&](int mbx, int mby, int lx, int ly) -> int {
            if (mbx < 0 || mby < 0 || mbx >= mbW || mby >= mbH) return -1;
            return i4mode[static_cast<size_t>(((mby * mbW + mbx) * 16) + ly * 4 + lx)];
        };
        auto blkOrd = [](int lx, int ly) {
            int i8 = (ly / 2) * 2 + (lx / 2);
            int i4 = (ly % 2) * 2 + (lx % 2);
            return i8 * 4 + i4;
        };
        auto lumaReady = [&](int px, int py, int mbx, int mby, int lx, int ly) {
            if (px < 0 || py < 0 || px >= w || py >= h) return false;
            int pmbx = px / 16, pmby = py / 16;
            int cur = mby * mbW + mbx, prev = pmby * mbW + pmbx;
            if (prev < cur) return true;
            if (prev > cur) return false;
            return blkOrd((px % 16) / 4, (py % 16) / 4) < blkOrd(lx, ly);
        };

        auto applyChrRes = [&](int mbx, int mby, int cbp_c) -> const char* {
            int qpc = chromaQp(qp, chroma_offset);
            uint8_t* planes[2] = {U.data(), V.data()};
            if (cbp_c) {
                auto r0 = cavlc::residualBlock(br, -1, 4);
                auto r1 = cavlc::residualBlock(br, -1, 4);
                if (!r0.ok || !r1.ok) return "chrDC";
                int16_t dcU[2][2], dcV[2][2];
                invChromaDc2x2(r0.coeff, qpc, dcU);
                invChromaDc2x2(r1.coeff, qpc, dcV);
                int16_t(*dcs[2])[2][2] = {&dcU, &dcV};
                for (int p = 0; p < 2; ++p)
                    for (int by = 0; by < 2; ++by)
                        for (int bx = 0; bx < 2; ++bx) {
                            int16_t blkq[4][4]{};
                            if (cbp_c == 2) {
                                int lx = bx, ly = by;
                                int* a = (lx > 0) ? tcatC(p, mbx, mby, lx - 1, ly)
                                                  : tcatC(p, mbx - 1, mby, 1, ly);
                                int* b = (ly > 0) ? tcatC(p, mbx, mby, lx, ly - 1)
                                                  : tcatC(p, mbx, mby - 1, lx, 1);
                                auto rr = cavlc::residualBlock(br, walk_detail::ncFrom(a, b), 15);
                                if (!rr.ok) return "chrAC";
                                tcsetC(p, mbx, mby, lx, ly, rr.total_coeff);
                                dequant4x4(rr.coeff, 15, qpc, blkq);
                            } else
                                tcsetC(p, mbx, mby, bx, by, 0);
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
            } else {
                for (int p = 0; p < 2; ++p)
                    for (int b = 0; b < 4; ++b) {
                        int lx, ly;
                        walk_detail::chrXY(b, lx, ly);
                        tcsetC(p, mbx, mby, lx, ly, 0);
                    }
            }
            return nullptr;
        };

        auto reconI16 = [&](int mbx, int mby, uint32_t imt) -> const char* {
            int x = static_cast<int>(imt) - 1;
            int predMode = x % 4;
            int cbp_c = (x / 4) % 3;
            int cbp_l = (x / 12) ? 15 : 0;
            int chromaMode = static_cast<int>(br.ue());
            qp += br.se();
            if (qp < 0) qp = 0;
            if (qp > 51) qp = 51;
            const int baseX = mbx * 16, baseY = mby * 16;
            bool hasA = mby > 0, hasL = mbx > 0;
            uint8_t above[16], left[16], tl = 128;
            for (int t = 0; t < 16; ++t) {
                above[t] = hasA ? yAt(baseX + t, baseY - 1) : 128;
                left[t] = hasL ? yAt(baseX - 1, baseY + t) : 128;
            }
            if (hasA && hasL) tl = yAt(baseX - 1, baseY - 1);
            uint8_t mbpred[256];
            if (predMode == 0 && hasA)
                predI16_V(mbpred, 16, above);
            else if (predMode == 1 && hasL)
                predI16_H(mbpred, 16, left);
            else if (predMode == 3 && hasA && hasL)
                predI16_Plane(mbpred, 16, above, left, tl);
            else
                predI16_DC(mbpred, 16, above, left, hasA, hasL);
            for (int yy = 0; yy < 16; ++yy)
                for (int xx = 0; xx < 16; ++xx)
                    setY(baseX + xx, baseY + yy, mbpred[yy * 16 + xx]);
            int* nA = tcatL(mbx - 1, mby, 3, 0);
            int* nB = tcatL(mbx, mby - 1, 0, 3);
            auto rdc = cavlc::residualBlock(br, walk_detail::ncFrom(nA, nB), 16);
            if (!rdc.ok) return "I16_dc";
            int16_t dc[4][4];
            cavlc::invQuantHadamardDc4x4(rdc.coeff, qp, dc);
            for (int i8 = 0; i8 < 4; ++i8)
                for (int i4 = 0; i4 < 4; ++i4) {
                    int lx, ly;
                    walk_detail::blkXY(i8, i4, lx, ly);
                    int16_t blkq[4][4]{};
                    if (cbp_l) {
                        int* a = (lx > 0) ? tcatL(mbx, mby, lx - 1, ly) : tcatL(mbx - 1, mby, 3, ly);
                        int* b = (ly > 0) ? tcatL(mbx, mby, lx, ly - 1) : tcatL(mbx, mby - 1, lx, 3);
                        auto rr = cavlc::residualBlock(br, walk_detail::ncFrom(a, b), 15);
                        if (!rr.ok) return "I16_ac";
                        tcsetL(mbx, mby, lx, ly, rr.total_coeff);
                        dequant4x4(rr.coeff, 15, qp, blkq);
                    } else
                        tcsetL(mbx, mby, lx, ly, 0);
                    blkq[0][0] = dc[ly][lx];
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
            uint8_t* planes[2] = {U.data(), V.data()};
            for (int p = 0; p < 2; ++p) {
                uint8_t cmb[64], ab[8], lf[8], tlp = 128;
                int cx = mbx * 8, cy = mby * 8;
                for (int t = 0; t < 8; ++t) {
                    ab[t] = (mby > 0) ? planes[p][(cy - 1) * cw + cx + t] : 128;
                    lf[t] = (mbx > 0) ? planes[p][(cy + t) * cw + cx - 1] : 128;
                }
                if (mby > 0 && mbx > 0) tlp = planes[p][(cy - 1) * cw + cx - 1];
                predChroma8(chromaMode, cmb, 8, ab, lf, tlp, mby > 0, mbx > 0);
                for (int yy = 0; yy < 8; ++yy)
                    for (int xx = 0; xx < 8; ++xx)
                        if (cx + xx < cw && cy + yy < ch)
                            planes[p][(cy + yy) * cw + cx + xx] = cmb[yy * 8 + xx];
            }
            if (pidx == 0 && mbx == 0 && mby == 2) {
                std::printf("HOST_F1_MB40 I16 imt=%u mode=%d(V=0) cbpL=%d cbpC=%d qp=%d chr=%d pred00=%d above0=%d left0=%d hasA=%d hasL=%d dc00=%d scan0=%d recon00=%d recon15=%d\n",
                            imt, predMode, cbp_l, cbp_c, qp, chromaMode, (int)mbpred[0], (int)above[0],
                            (int)left[0], (int)hasA, (int)hasL, (int)dc[0][0], (int)rdc.coeff[0],
                            (int)yAt(baseX, baseY), (int)yAt(baseX + 15, baseY));
            }
            return applyChrRes(mbx, mby, cbp_c);
        };

        auto reconI4 = [&](int mbx, int mby) -> const char* {
            int predModes[16];
            for (int blk = 0; blk < 16; ++blk) {
                int i8 = blk / 4, i4 = blk % 4, lx, ly;
                walk_detail::blkXY(i8, i4, lx, ly);
                int modeA = (lx > 0) ? modeAt(mbx, mby, lx - 1, ly) : modeAt(mbx - 1, mby, 3, ly);
                int modeB = (ly > 0) ? modeAt(mbx, mby, lx, ly - 1) : modeAt(mbx, mby - 1, lx, 3);
                int pred = (modeA < 0 || modeB < 0) ? 2 : std::min(modeA, modeB);
                if (br.u(1))
                    predModes[blk] = pred;
                else {
                    int rem = static_cast<int>(br.u(3));
                    predModes[blk] = rem + (rem >= pred ? 1 : 0);
                }
                i4mode[static_cast<size_t>(((mby * mbW + mbx) * 16) + ly * 4 + lx)] =
                    static_cast<int8_t>(predModes[blk]);
            }
            int chromaMode = static_cast<int>(br.ue());
            uint32_t code = br.ue();
            if (code >= 48) return "me_cbp";
            int cbp = walk_detail::kMeIntra[code];
            int cbp_l = cbp & 15, cbp_c = cbp >> 4;
            if (cbp) {
                qp += br.se();
                if (qp < 0) qp = 0;
                if (qp > 51) qp = 51;
            }
            const int baseX = mbx * 16, baseY = mby * 16;
            for (int i8 = 0; i8 < 4; ++i8)
                for (int i4 = 0; i4 < 4; ++i4) {
                    int lx, ly;
                    walk_detail::blkXY(i8, i4, lx, ly);
                    int mode = predModes[i8 * 4 + i4];
                    int x0 = baseX + lx * 4, y0 = baseY + ly * 4;
                    uint8_t above[8], left[4], tl = 128;
                    bool ha = (y0 > 0) && lumaReady(x0, y0 - 1, mbx, mby, lx, ly);
                    bool hl = (x0 > 0) && lumaReady(x0 - 1, y0, mbx, mby, lx, ly);
                    for (int t = 0; t < 4; ++t)
                        above[t] = ha ? yAt(x0 + t, y0 - 1) : 128;
                    for (int t = 0; t < 4; ++t) {
                        int tx = x0 + 4 + t;
                        above[4 + t] = (ha && lumaReady(tx, y0 - 1, mbx, mby, lx, ly)) ? yAt(tx, y0 - 1)
                                                                                       : above[3];
                    }
                    for (int t = 0; t < 4; ++t)
                        left[t] = hl ? yAt(x0 - 1, y0 + t) : 128;
                    if (ha && hl && lumaReady(x0 - 1, y0 - 1, mbx, mby, lx, ly))
                        tl = yAt(x0 - 1, y0 - 1);
                    else if (ha)
                        tl = above[0];
                    else if (hl)
                        tl = left[0];
                    int useMode = mode;
                    if (!ha && (mode == 0 || mode == 3 || mode == 7)) useMode = 2;
                    if (!hl && (mode == 1 || mode == 8)) useMode = 2;
                    if ((!ha || !hl) && (mode == 4 || mode == 5 || mode == 6)) useMode = 2;
                    uint8_t pred[16];
                    predI4(useMode, pred, 4, above, left, tl, ha, hl);
                    for (int yy = 0; yy < 4; ++yy)
                        for (int xx = 0; xx < 4; ++xx)
                            setY(x0 + xx, y0 + yy, pred[yy * 4 + xx]);
                    if ((cbp_l >> i8) & 1) {
                        int* a = (lx > 0) ? tcatL(mbx, mby, lx - 1, ly) : tcatL(mbx - 1, mby, 3, ly);
                        int* b = (ly > 0) ? tcatL(mbx, mby, lx, ly - 1) : tcatL(mbx, mby - 1, lx, 3);
                        auto r = cavlc::residualBlock(br, walk_detail::ncFrom(a, b), 16);
                        if (!r.ok) return "I4_res";
                        tcsetL(mbx, mby, lx, ly, r.total_coeff);
                        int16_t blkq[4][4]{};
                        dequant4x4(r.coeff, 16, qp, blkq);
                        uint8_t tmp[16];
                        for (int yy = 0; yy < 4; ++yy)
                            for (int xx = 0; xx < 4; ++xx)
                                tmp[yy * 4 + xx] = yAt(x0 + xx, y0 + yy);
                        idct4x4_add(blkq, tmp, 4);
                        for (int yy = 0; yy < 4; ++yy)
                            for (int xx = 0; xx < 4; ++xx)
                                setY(x0 + xx, y0 + yy, tmp[yy * 4 + xx]);
                    } else
                        tcsetL(mbx, mby, lx, ly, 0);
                }
            uint8_t* planes[2] = {U.data(), V.data()};
            for (int p = 0; p < 2; ++p) {
                uint8_t cmb[64], ab[8], lf[8], tlp = 128;
                int cx = mbx * 8, cy = mby * 8;
                for (int t = 0; t < 8; ++t) {
                    ab[t] = (mby > 0) ? planes[p][(cy - 1) * cw + cx + t] : 128;
                    lf[t] = (mbx > 0) ? planes[p][(cy + t) * cw + cx - 1] : 128;
                }
                if (mby > 0 && mbx > 0) tlp = planes[p][(cy - 1) * cw + cx - 1];
                predChroma8(chromaMode, cmb, 8, ab, lf, tlp, mby > 0, mbx > 0);
                for (int yy = 0; yy < 8; ++yy)
                    for (int xx = 0; xx < 8; ++xx)
                        if (cx + xx < cw && cy + yy < ch)
                            planes[p][(cy + yy) * cw + cx + xx] = cmb[yy * 8 + xx];
            }
            return applyChrRes(mbx, mby, cbp_c);
        };

        bool need_skip = true;
        uint32_t skip_run = 0;
        for (int mb = 0; mb < tot; ++mb) {
            int mbx = mb % mbW, mby = mb / mbW;
            if (!br.ok) {
                g.fail_frame = pidx + 1;
                g.fail_mb = mb;
                g.fail_reason = "br";
                return g;
            }
            if (need_skip) {
                skip_run = br.ue();
                need_skip = false;
            }
            if (skip_run) {
                bool aa = mbx > 0 && mvav[static_cast<size_t>(mby * mbW + mbx - 1)];
                bool bb = mby > 0 && mvav[static_cast<size_t>((mby - 1) * mbW + mbx)];
                bool cc = false;
                int16_t ax = 0, ay = 0, bx = 0, by = 0, cx = 0, cy = 0;
                if (aa) {
                    ax = mvx[static_cast<size_t>(mby * mbW + mbx - 1)];
                    ay = mvy[static_cast<size_t>(mby * mbW + mbx - 1)];
                }
                if (bb) {
                    bx = mvx[static_cast<size_t>((mby - 1) * mbW + mbx)];
                    by = mvy[static_cast<size_t>((mby - 1) * mbW + mbx)];
                }
                if (mbx + 1 < mbW && mby > 0 && mvav[static_cast<size_t>((mby - 1) * mbW + mbx + 1)]) {
                    cc = true;
                    cx = mvx[static_cast<size_t>((mby - 1) * mbW + mbx + 1)];
                    cy = mvy[static_cast<size_t>((mby - 1) * mbW + mbx + 1)];
                } else if (mbx > 0 && mby > 0 && mvav[static_cast<size_t>((mby - 1) * mbW + mbx - 1)]) {
                    cc = true;
                    cx = mvx[static_cast<size_t>((mby - 1) * mbW + mbx - 1)];
                    cy = mvy[static_cast<size_t>((mby - 1) * mbW + mbx - 1)];
                }
                auto pred = mvPred(aa, bb, cc, ax, ay, bx, by, cx, cy, true);
                uint8_t py[256], pu[64], pv[64];
                mc16(refY.data(), refU.data(), refV.data(), w, h, mbx, mby, pred.first, pred.second, py, pu,
                     pv);
                for (int yy = 0; yy < 16; ++yy)
                    for (int xx = 0; xx < 16; ++xx)
                        setY(mbx * 16 + xx, mby * 16 + yy, py[yy * 16 + xx]);
                for (int yy = 0; yy < 8; ++yy)
                    for (int xx = 0; xx < 8; ++xx) {
                        if (mbx * 8 + xx < cw && mby * 8 + yy < ch) {
                            U[static_cast<size_t>((mby * 8 + yy) * cw + mbx * 8 + xx)] = pu[yy * 8 + xx];
                            V[static_cast<size_t>((mby * 8 + yy) * cw + mbx * 8 + xx)] = pv[yy * 8 + xx];
                        }
                    }
                for (int ly = 0; ly < 4; ++ly)
                    for (int lx = 0; lx < 4; ++lx)
                        tcsetL(mbx, mby, lx, ly, 0);
                for (int p = 0; p < 2; ++p)
                    for (int b = 0; b < 4; ++b) {
                        int lx, ly;
                        walk_detail::chrXY(b, lx, ly);
                        tcsetC(p, mbx, mby, lx, ly, 0);
                    }
                mvx[static_cast<size_t>(mb)] = pred.first;
                mvy[static_cast<size_t>(mb)] = pred.second;
                mvav[static_cast<size_t>(mb)] = 1;
                skip_run--;
                g.p_mb++;
                continue;
            }
            uint32_t mt = br.ue();
            if (mt >= 5 && mt <= 29) {
                uint32_t imt = mt - 5;
                const char* e = (imt == 0) ? reconI4(mbx, mby) : reconI16(mbx, mby, imt);
                if (e) {
                    g.fail_frame = pidx + 1;
                    g.fail_mb = mb;
                    g.fail_reason = e;
                    return g;
                }
                mvav[static_cast<size_t>(mb)] = 0;
                g.i_in_p++;
                g.p_mb++;
                need_skip = true;
            } else if (mt == 0) {
                if (nref > 1) br.ue();
                int16_t mvd_x = static_cast<int16_t>(br.se());
                int16_t mvd_y = static_cast<int16_t>(br.se());
                uint32_t code = br.ue();
                if (code >= 48) {
                    g.fail_frame = pidx + 1;
                    g.fail_mb = mb;
                    g.fail_reason = "me_cbp";
                    return g;
                }
                int cbp = walk_detail::kMeInter[code];
                int cbp_l = cbp & 15, cbp_c = cbp >> 4;
                if (cbp) {
                    qp += br.se();
                    if (qp < 0) qp = 0;
                    if (qp > 51) qp = 51;
                }
                bool aa = mbx > 0 && mvav[static_cast<size_t>(mby * mbW + mbx - 1)];
                bool bb = mby > 0 && mvav[static_cast<size_t>((mby - 1) * mbW + mbx)];
                bool cc = false;
                int16_t ax = 0, ay = 0, bx = 0, by = 0, cx = 0, cy = 0;
                if (aa) {
                    ax = mvx[static_cast<size_t>(mby * mbW + mbx - 1)];
                    ay = mvy[static_cast<size_t>(mby * mbW + mbx - 1)];
                }
                if (bb) {
                    bx = mvx[static_cast<size_t>((mby - 1) * mbW + mbx)];
                    by = mvy[static_cast<size_t>((mby - 1) * mbW + mbx)];
                }
                if (mbx + 1 < mbW && mby > 0 && mvav[static_cast<size_t>((mby - 1) * mbW + mbx + 1)]) {
                    cc = true;
                    cx = mvx[static_cast<size_t>((mby - 1) * mbW + mbx + 1)];
                    cy = mvy[static_cast<size_t>((mby - 1) * mbW + mbx + 1)];
                } else if (mbx > 0 && mby > 0 && mvav[static_cast<size_t>((mby - 1) * mbW + mbx - 1)]) {
                    cc = true;
                    cx = mvx[static_cast<size_t>((mby - 1) * mbW + mbx - 1)];
                    cy = mvy[static_cast<size_t>((mby - 1) * mbW + mbx - 1)];
                }
                auto pred = mvPred(aa, bb, cc, ax, ay, bx, by, cx, cy, false);
                int16_t mx = static_cast<int16_t>(pred.first + mvd_x);
                int16_t my = static_cast<int16_t>(pred.second + mvd_y);
                uint8_t py[256], pu[64], pv[64];
                mc16(refY.data(), refU.data(), refV.data(), w, h, mbx, mby, mx, my, py, pu, pv);
                for (int yy = 0; yy < 16; ++yy)
                    for (int xx = 0; xx < 16; ++xx)
                        setY(mbx * 16 + xx, mby * 16 + yy, py[yy * 16 + xx]);
                for (int yy = 0; yy < 8; ++yy)
                    for (int xx = 0; xx < 8; ++xx)
                        if (mbx * 8 + xx < cw && mby * 8 + yy < ch) {
                            U[static_cast<size_t>((mby * 8 + yy) * cw + mbx * 8 + xx)] = pu[yy * 8 + xx];
                            V[static_cast<size_t>((mby * 8 + yy) * cw + mbx * 8 + xx)] = pv[yy * 8 + xx];
                        }
                for (int i8 = 0; i8 < 4; ++i8) {
                    if ((cbp_l >> i8) & 1) {
                        for (int i4 = 0; i4 < 4; ++i4) {
                            int lx, ly;
                            walk_detail::blkXY(i8, i4, lx, ly);
                            int* a = (lx > 0) ? tcatL(mbx, mby, lx - 1, ly) : tcatL(mbx - 1, mby, 3, ly);
                            int* b = (ly > 0) ? tcatL(mbx, mby, lx, ly - 1) : tcatL(mbx, mby - 1, lx, 3);
                            auto r = cavlc::residualBlock(br, walk_detail::ncFrom(a, b), 16);
                            if (!r.ok) {
                                g.fail_frame = pidx + 1;
                                g.fail_mb = mb;
                                g.fail_reason = "P16_res";
                                return g;
                            }
                            tcsetL(mbx, mby, lx, ly, r.total_coeff);
                            int16_t blkq[4][4]{};
                            dequant4x4(r.coeff, 16, qp, blkq);
                            int x0 = mbx * 16 + lx * 4, y0 = mby * 16 + ly * 4;
                            uint8_t tmp[16];
                            for (int yy = 0; yy < 4; ++yy)
                                for (int xx = 0; xx < 4; ++xx)
                                    tmp[yy * 4 + xx] = yAt(x0 + xx, y0 + yy);
                            idct4x4_add(blkq, tmp, 4);
                            for (int yy = 0; yy < 4; ++yy)
                                for (int xx = 0; xx < 4; ++xx)
                                    setY(x0 + xx, y0 + yy, tmp[yy * 4 + xx]);
                        }
                    } else {
                        for (int i4 = 0; i4 < 4; ++i4) {
                            int lx, ly;
                            walk_detail::blkXY(i8, i4, lx, ly);
                            tcsetL(mbx, mby, lx, ly, 0);
                        }
                    }
                }
                if (const char* e = applyChrRes(mbx, mby, cbp_c)) {
                    g.fail_frame = pidx + 1;
                    g.fail_mb = mb;
                    g.fail_reason = e;
                    return g;
                }
                for (int ly = 0; ly < 4; ++ly)
                    for (int lx = 0; lx < 4; ++lx)
                        i4mode[static_cast<size_t>(((mby * mbW + mbx) * 16) + ly * 4 + lx)] = 2;
                mvx[static_cast<size_t>(mb)] = mx;
                mvy[static_cast<size_t>(mb)] = my;
                mvav[static_cast<size_t>(mb)] = 1;
                if (pidx == 0 && (mb == 41 || mb == 61)) {
                    std::printf("HOST_F1_MB%d P16 mvd=%d,%d mvp=%d,%d mv=%d,%d cbp=%d cbpL=%d cbpC=%d residual=%d pred00=%d pred_2_10=%d recon00=%d recon_2_10=%d ref00=%d ref_2_10=%d aa=%d bb=%d cc=%d ax=%d,%d bx=%d,%d cx=%d,%d\n",
                                mb, (int)mvd_x, (int)mvd_y, (int)pred.first, (int)pred.second, (int)mx, (int)my,
                                cbp, cbp_l, cbp_c, (cbp != 0), (int)py[0], (int)py[10 * 16 + 2],
                                (int)yAt(mbx * 16, mby * 16), (int)yAt(mbx * 16 + 2, mby * 16 + 10),
                                (int)refY[(size_t)(mby * 16 * w + mbx * 16)],
                                (int)refY[(size_t)((mby * 16 + 10) * w + mbx * 16 + 2)],
                                (int)aa, (int)bb, (int)cc, (int)ax, (int)ay, (int)bx, (int)by, (int)cx, (int)cy);
                }
                g.p_mb++;
                need_skip = true;
            } else {
                g.fail_frame = pidx + 1;
                g.fail_mb = mb;
                g.fail_reason = (mt == 1 || mt == 2) ? "p_part" : "mb_type";
                return g;
            }
        }
        pack(Y, U, V);
        refY.swap(Y);
        refU.swap(U);
        refV.swap(V);
        pidx++;
        i = j;
    }
    (void)frm;
    return g;
}

} // namespace recon
} // namespace misterplex
