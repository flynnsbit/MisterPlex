#pragma once
// Independent frame-level reference model of H.264 clause 8.7 (deblocking).
//
// This model is deliberately written frame-first: it walks macroblocks in
// raster order and filters edges directly in the picture buffer.  The product
// RTL (h264_deblock_mb_filter) instead works on a 20x20 / 12x12 macroblock
// neighbourhood with a four-sample skirt and a step-encoded edge schedule.
// The two share no addressing, no scheduling and no writeback structure, so a
// bit-exact frame comparison between them is a real cross-check of the RTL
// skirt indexing, edge ordering, bS derivation and chroma QP mapping.
//
// The alpha/beta/tC0 lookup values are the normative Tables 8-16/8-17 and are
// necessarily the same numbers the RTL carries; a shared *table* typo would
// not be caught here.  Everything structural around them would be.

#include <cstdint>
#include <cstddef>
#include <algorithm>
#include <stdexcept>
#include <vector>

namespace h264_deblock_ref {

struct MbCtx {
    bool intra = false;
    int qp = 0;
    uint16_t nz4 = 0;   // per-4x4 luma coded-block flags, bit blky*4+blkx
    int mvx[16] = {0};
    int mvy[16] = {0};
    int ref[16] = {0};
};

struct Frame {
    int w = 0;
    int h = 0;
    std::vector<uint8_t> y;
    std::vector<uint8_t> u;
    std::vector<uint8_t> v;

    void alloc(int width, int height) {
        w = width;
        h = height;
        y.assign(static_cast<size_t>(w) * static_cast<size_t>(h), 0);
        u.assign(static_cast<size_t>(w / 2) * static_cast<size_t>(h / 2), 0);
        v.assign(static_cast<size_t>(w / 2) * static_cast<size_t>(h / 2), 0);
    }
    uint8_t& at_y(int x, int yy) { return y[static_cast<size_t>(yy) * static_cast<size_t>(w) + static_cast<size_t>(x)]; }
    uint8_t& at_u(int x, int yy) { return u[static_cast<size_t>(yy) * static_cast<size_t>(w / 2) + static_cast<size_t>(x)]; }
    uint8_t& at_v(int x, int yy) { return v[static_cast<size_t>(yy) * static_cast<size_t>(w / 2) + static_cast<size_t>(x)]; }
};

struct Options {
    int disable_idc = 0;
    int alpha_off = 0;
    int beta_off = 0;
    int chroma_qp_off = 0;
    // Fault injections used to red-prove the frame comparison.  Each of these
    // makes the reference deviate from the standard; if the RTL is really
    // implementing the standard the comparison must then FAIL.
    bool fault_skip_skipped_mbs = false;   // do not filter skipped MBs
    bool fault_qpy_for_qpc = false;        // use QPy where QPc is normative
    bool fault_horizontal_first = false;   // filter horizontal edges before vertical
    bool fault_no_chroma = false;          // skip chroma edges entirely
    bool fault_no_internal_edges = false;  // filter only macroblock edges
    std::vector<uint8_t> skipped_mb;       // 1 = MB was coded as P_Skip
};

inline const int* alphaTable() {
    static const int t[52] = {
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        4, 4, 5, 6, 7, 8, 9, 10, 12, 13, 15, 17, 20, 22, 25, 28,
        32, 36, 40, 45, 50, 56, 63, 71, 80, 90, 101, 113, 127, 144, 162, 182,
        203, 226, 255, 255};
    return t;
}

inline const int* betaTable() {
    static const int t[52] = {
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 6, 6, 7, 7, 8, 8,
        9, 9, 10, 10, 11, 11, 12, 12, 13, 13, 14, 14, 15, 15, 16, 16,
        17, 17, 18, 18};
    return t;
}

inline int tc0Table(int index_a, int bs) {
    static const uint8_t t[52][3] = {
        {0, 0, 0}, {0, 0, 0}, {0, 0, 0}, {0, 0, 0}, {0, 0, 0}, {0, 0, 0},
        {0, 0, 0}, {0, 0, 0}, {0, 0, 0}, {0, 0, 0}, {0, 0, 0}, {0, 0, 0},
        {0, 0, 0}, {0, 0, 0}, {0, 0, 0}, {0, 0, 0}, {0, 0, 0}, {0, 0, 1},
        {0, 0, 1}, {0, 0, 1}, {0, 0, 1}, {0, 1, 1}, {0, 1, 1}, {1, 1, 1},
        {1, 1, 1}, {1, 1, 1}, {1, 1, 1}, {1, 1, 2}, {1, 1, 2}, {1, 1, 2},
        {1, 1, 2}, {1, 2, 3}, {1, 2, 3}, {2, 2, 3}, {2, 2, 4}, {2, 3, 4},
        {2, 3, 4}, {3, 3, 5}, {3, 4, 6}, {3, 4, 6}, {4, 5, 7}, {4, 5, 8},
        {4, 6, 9}, {5, 7, 10}, {6, 8, 11}, {6, 8, 13}, {7, 10, 14}, {8, 11, 16},
        {9, 12, 18}, {10, 13, 20}, {11, 15, 23}, {13, 17, 25}};
    if (bs < 1 || bs > 3) return 0;
    return t[index_a][bs - 1];
}

inline int qpcMap(int qp_y, int chroma_qp_off) {
    static const int t[22] = {29, 30, 31, 32, 32, 33, 34, 34, 35, 35, 36,
                              36, 37, 37, 37, 38, 38, 38, 39, 39, 39, 39};
    const int qpi = std::clamp(qp_y + chroma_qp_off, 0, 51);
    return (qpi < 30) ? qpi : t[qpi - 30];
}

inline int clip3(int lo, int hi, int v) { return v < lo ? lo : (v > hi ? hi : v); }
inline uint8_t clip8(int v) { return static_cast<uint8_t>(clip3(0, 255, v)); }

// One 8-tap line straddling an edge.  p[0]=p0 .. p[3]=p3, q[0]=q0 .. q[3]=q3.
inline void filterLine(int* p, int* q, int bs, int qp_avg, bool chroma,
                       int alpha_off, int beta_off) {
    if (bs == 0) return;
    const int index_a = clip3(0, 51, qp_avg + alpha_off);
    const int index_b = clip3(0, 51, qp_avg + beta_off);
    const int alpha = alphaTable()[index_a];
    const int beta = betaTable()[index_b];
    if (std::abs(p[0] - q[0]) >= alpha) return;
    if (std::abs(p[1] - p[0]) >= beta) return;
    if (std::abs(q[1] - q[0]) >= beta) return;
    const bool ap = std::abs(p[2] - p[0]) < beta;
    const bool aq = std::abs(q[2] - q[0]) < beta;

    if (bs == 4) {
        if (chroma) {
            const int np0 = (2 * p[1] + p[0] + q[1] + 2) >> 2;
            const int nq0 = (2 * q[1] + q[0] + p[1] + 2) >> 2;
            p[0] = clip8(np0);
            q[0] = clip8(nq0);
            return;
        }
        const bool strong = std::abs(p[0] - q[0]) < ((alpha >> 2) + 2);
        int np0, np1, np2, nq0, nq1, nq2;
        np0 = p[0]; np1 = p[1]; np2 = p[2];
        nq0 = q[0]; nq1 = q[1]; nq2 = q[2];
        if (strong && ap) {
            np0 = (p[2] + 2 * p[1] + 2 * p[0] + 2 * q[0] + q[1] + 4) >> 3;
            np1 = (p[2] + p[1] + p[0] + q[0] + 2) >> 2;
            np2 = (2 * p[3] + 3 * p[2] + p[1] + p[0] + q[0] + 4) >> 3;
        } else {
            np0 = (2 * p[1] + p[0] + q[1] + 2) >> 2;
        }
        if (strong && aq) {
            nq0 = (p[1] + 2 * p[0] + 2 * q[0] + 2 * q[1] + q[2] + 4) >> 3;
            nq1 = (p[0] + q[0] + q[1] + q[2] + 2) >> 2;
            nq2 = (p[0] + q[0] + q[1] + 3 * q[2] + 2 * q[3] + 4) >> 3;
        } else {
            nq0 = (2 * q[1] + q[0] + p[1] + 2) >> 2;
        }
        p[0] = clip8(np0); p[1] = clip8(np1); p[2] = clip8(np2);
        q[0] = clip8(nq0); q[1] = clip8(nq1); q[2] = clip8(nq2);
        return;
    }

    const int tc0 = tc0Table(index_a, bs);
    const int tc = chroma ? (tc0 + 1) : (tc0 + (ap ? 1 : 0) + (aq ? 1 : 0));
    const int delta = clip3(-tc, tc, ((((q[0] - p[0]) << 2) + (p[1] - q[1]) + 4) >> 3));
    const int np0 = clip8(p[0] + delta);
    const int nq0 = clip8(q[0] - delta);
    int np1 = p[1];
    int nq1 = q[1];
    if (!chroma && ap)
        np1 = clip8(p[1] + clip3(-tc0, tc0, (p[2] + ((p[0] + q[0] + 1) >> 1) - 2 * p[1]) >> 1));
    if (!chroma && aq)
        nq1 = clip8(q[1] + clip3(-tc0, tc0, (q[2] + ((p[0] + q[0] + 1) >> 1) - 2 * q[1]) >> 1));
    p[0] = np0; q[0] = nq0; p[1] = np1; q[1] = nq1;
}

inline int deriveBs(const MbCtx& pmb, const MbCtx& qmb, int pblk, int qblk, bool mb_edge) {
    if (pmb.intra || qmb.intra) return mb_edge ? 4 : 3;
    const bool pnz = ((pmb.nz4 >> pblk) & 1u) != 0;
    const bool qnz = ((qmb.nz4 >> qblk) & 1u) != 0;
    if (pnz || qnz) return 2;
    if (pmb.ref[pblk] != qmb.ref[qblk]) return 1;
    if (std::abs(pmb.mvx[pblk] - qmb.mvx[qblk]) >= 4) return 1;
    if (std::abs(pmb.mvy[pblk] - qmb.mvy[qblk]) >= 4) return 1;
    return 0;
}

struct Stats {
    long long mbs_filtered = 0;
    long long skipped_mbs_filtered = 0;
    long long luma_edges = 0;
    long long chroma_edges = 0;
    long long luma_modified = 0;
    long long chroma_modified = 0;
    long long bs_hist[5] = {0, 0, 0, 0, 0};
};

namespace detail {

inline void lumaVertical(Frame& f, const std::vector<MbCtx>& mbs, int mb_w, int mbx, int mby,
                         const Options& o, Stats& st) {
    const int addr = mby * mb_w + mbx;
    const MbCtx& cur = mbs[static_cast<size_t>(addr)];
    for (int e = 0; e < 4; ++e) {
        const bool mb_edge = (e == 0);
        if (mb_edge && mbx == 0) continue;
        if (!mb_edge && o.fault_no_internal_edges) continue;
        const MbCtx& pmb = mb_edge ? mbs[static_cast<size_t>(addr - 1)] : cur;
        const int x = mbx * 16 + e * 4;
        for (int row = 0; row < 16; ++row) {
            const int yy = mby * 16 + row;
            const int blky = row / 4;
            const int pblk = blky * 4 + (mb_edge ? 3 : (e - 1));
            const int qblk = blky * 4 + e;
            const int bs = deriveBs(pmb, cur, pblk, qblk, mb_edge);
            st.bs_hist[bs]++;
            if (bs == 0) continue;
            const int qp_avg = (pmb.qp + cur.qp + 1) >> 1;
            int p[4], q[4], p0[4], q0[4];
            for (int t = 0; t < 4; ++t) {
                p[t] = f.at_y(x - 1 - t, yy);
                q[t] = f.at_y(x + t, yy);
                p0[t] = p[t];
                q0[t] = q[t];
            }
            filterLine(p, q, bs, qp_avg, false, o.alpha_off, o.beta_off);
            for (int t = 0; t < 4; ++t) {
                if (p[t] != p0[t]) ++st.luma_modified;
                if (q[t] != q0[t]) ++st.luma_modified;
                f.at_y(x - 1 - t, yy) = static_cast<uint8_t>(p[t]);
                f.at_y(x + t, yy) = static_cast<uint8_t>(q[t]);
            }
            ++st.luma_edges;
        }
    }
}

inline void lumaHorizontal(Frame& f, const std::vector<MbCtx>& mbs, int mb_w, int mbx, int mby,
                           const Options& o, Stats& st) {
    const int addr = mby * mb_w + mbx;
    const MbCtx& cur = mbs[static_cast<size_t>(addr)];
    for (int e = 0; e < 4; ++e) {
        const bool mb_edge = (e == 0);
        if (mb_edge && mby == 0) continue;
        if (!mb_edge && o.fault_no_internal_edges) continue;
        const MbCtx& pmb = mb_edge ? mbs[static_cast<size_t>(addr - mb_w)] : cur;
        const int yy = mby * 16 + e * 4;
        for (int col = 0; col < 16; ++col) {
            const int x = mbx * 16 + col;
            const int blkx = col / 4;
            const int pblk = (mb_edge ? 3 : (e - 1)) * 4 + blkx;
            const int qblk = e * 4 + blkx;
            const int bs = deriveBs(pmb, cur, pblk, qblk, mb_edge);
            st.bs_hist[bs]++;
            if (bs == 0) continue;
            const int qp_avg = (pmb.qp + cur.qp + 1) >> 1;
            int p[4], q[4], p0[4], q0[4];
            for (int t = 0; t < 4; ++t) {
                p[t] = f.at_y(x, yy - 1 - t);
                q[t] = f.at_y(x, yy + t);
                p0[t] = p[t];
                q0[t] = q[t];
            }
            filterLine(p, q, bs, qp_avg, false, o.alpha_off, o.beta_off);
            for (int t = 0; t < 4; ++t) {
                if (p[t] != p0[t]) ++st.luma_modified;
                if (q[t] != q0[t]) ++st.luma_modified;
                f.at_y(x, yy - 1 - t) = static_cast<uint8_t>(p[t]);
                f.at_y(x, yy + t) = static_cast<uint8_t>(q[t]);
            }
            ++st.luma_edges;
        }
    }
}

inline void chromaVertical(Frame& f, const std::vector<MbCtx>& mbs, int mb_w, int mbx, int mby,
                           int plane, const Options& o, Stats& st) {
    const int addr = mby * mb_w + mbx;
    const MbCtx& cur = mbs[static_cast<size_t>(addr)];
    for (int e = 0; e < 2; ++e) {
        const bool mb_edge = (e == 0);
        if (mb_edge && mbx == 0) continue;
        if (!mb_edge && o.fault_no_internal_edges) continue;
        const MbCtx& pmb = mb_edge ? mbs[static_cast<size_t>(addr - 1)] : cur;
        const int cx = mbx * 8 + e * 4;
        const int luma_qblkx = e * 2;
        for (int row = 0; row < 8; ++row) {
            const int cy = mby * 8 + row;
            const int blky = row / 2;
            const int pblk = blky * 4 + (mb_edge ? 3 : (luma_qblkx - 1));
            const int qblk = blky * 4 + luma_qblkx;
            const int bs = deriveBs(pmb, cur, pblk, qblk, mb_edge);
            if (bs == 0) continue;
            const int pq = o.fault_qpy_for_qpc ? pmb.qp : qpcMap(pmb.qp, o.chroma_qp_off);
            const int qq = o.fault_qpy_for_qpc ? cur.qp : qpcMap(cur.qp, o.chroma_qp_off);
            const int qp_avg = (pq + qq + 1) >> 1;
            int p[4], q[4], p0[4], q0[4];
            for (int t = 0; t < 4; ++t) {
                p[t] = plane ? f.at_v(cx - 1 - t, cy) : f.at_u(cx - 1 - t, cy);
                q[t] = plane ? f.at_v(cx + t, cy) : f.at_u(cx + t, cy);
                p0[t] = p[t];
                q0[t] = q[t];
            }
            filterLine(p, q, bs, qp_avg, true, o.alpha_off, o.beta_off);
            for (int t = 0; t < 4; ++t) {
                if (p[t] != p0[t]) ++st.chroma_modified;
                if (q[t] != q0[t]) ++st.chroma_modified;
                if (plane) {
                    f.at_v(cx - 1 - t, cy) = static_cast<uint8_t>(p[t]);
                    f.at_v(cx + t, cy) = static_cast<uint8_t>(q[t]);
                } else {
                    f.at_u(cx - 1 - t, cy) = static_cast<uint8_t>(p[t]);
                    f.at_u(cx + t, cy) = static_cast<uint8_t>(q[t]);
                }
            }
            ++st.chroma_edges;
        }
    }
}

inline void chromaHorizontal(Frame& f, const std::vector<MbCtx>& mbs, int mb_w, int mbx, int mby,
                             int plane, const Options& o, Stats& st) {
    const int addr = mby * mb_w + mbx;
    const MbCtx& cur = mbs[static_cast<size_t>(addr)];
    for (int e = 0; e < 2; ++e) {
        const bool mb_edge = (e == 0);
        if (mb_edge && mby == 0) continue;
        if (!mb_edge && o.fault_no_internal_edges) continue;
        const MbCtx& pmb = mb_edge ? mbs[static_cast<size_t>(addr - mb_w)] : cur;
        const int cy = mby * 8 + e * 4;
        const int luma_qblky = e * 2;
        for (int col = 0; col < 8; ++col) {
            const int cx = mbx * 8 + col;
            const int blkx = col / 2;
            const int pblk = (mb_edge ? 3 : (luma_qblky - 1)) * 4 + blkx;
            const int qblk = luma_qblky * 4 + blkx;
            const int bs = deriveBs(pmb, cur, pblk, qblk, mb_edge);
            if (bs == 0) continue;
            const int pq = o.fault_qpy_for_qpc ? pmb.qp : qpcMap(pmb.qp, o.chroma_qp_off);
            const int qq = o.fault_qpy_for_qpc ? cur.qp : qpcMap(cur.qp, o.chroma_qp_off);
            const int qp_avg = (pq + qq + 1) >> 1;
            int p[4], q[4], p0[4], q0[4];
            for (int t = 0; t < 4; ++t) {
                p[t] = plane ? f.at_v(cx, cy - 1 - t) : f.at_u(cx, cy - 1 - t);
                q[t] = plane ? f.at_v(cx, cy + t) : f.at_u(cx, cy + t);
                p0[t] = p[t];
                q0[t] = q[t];
            }
            filterLine(p, q, bs, qp_avg, true, o.alpha_off, o.beta_off);
            for (int t = 0; t < 4; ++t) {
                if (p[t] != p0[t]) ++st.chroma_modified;
                if (q[t] != q0[t]) ++st.chroma_modified;
                if (plane) {
                    f.at_v(cx, cy - 1 - t) = static_cast<uint8_t>(p[t]);
                    f.at_v(cx, cy + t) = static_cast<uint8_t>(q[t]);
                } else {
                    f.at_u(cx, cy - 1 - t) = static_cast<uint8_t>(p[t]);
                    f.at_u(cx, cy + t) = static_cast<uint8_t>(q[t]);
                }
            }
            ++st.chroma_edges;
        }
    }
}

} // namespace detail

inline Stats deblockFrame(Frame& f, const std::vector<MbCtx>& mbs, int mb_w, int mb_h,
                          const Options& o) {
    Stats st;
    if (static_cast<int>(mbs.size()) != mb_w * mb_h)
        throw std::runtime_error("deblock reference: MB context count mismatch");
    if (o.disable_idc == 1) return st;
    for (int mby = 0; mby < mb_h; ++mby) {
        for (int mbx = 0; mbx < mb_w; ++mbx) {
            const int addr = mby * mb_w + mbx;
            const bool is_skip = !o.skipped_mb.empty() &&
                                 o.skipped_mb[static_cast<size_t>(addr)] != 0;
            if (o.fault_skip_skipped_mbs && is_skip) continue;
            if (o.fault_horizontal_first) {
                detail::lumaHorizontal(f, mbs, mb_w, mbx, mby, o, st);
                detail::lumaVertical(f, mbs, mb_w, mbx, mby, o, st);
                if (!o.fault_no_chroma) {
                    for (int plane = 0; plane < 2; ++plane) {
                        detail::chromaHorizontal(f, mbs, mb_w, mbx, mby, plane, o, st);
                        detail::chromaVertical(f, mbs, mb_w, mbx, mby, plane, o, st);
                    }
                }
            } else {
                detail::lumaVertical(f, mbs, mb_w, mbx, mby, o, st);
                detail::lumaHorizontal(f, mbs, mb_w, mbx, mby, o, st);
                if (!o.fault_no_chroma) {
                    for (int plane = 0; plane < 2; ++plane) {
                        detail::chromaVertical(f, mbs, mb_w, mbx, mby, plane, o, st);
                        detail::chromaHorizontal(f, mbs, mb_w, mbx, mby, plane, o, st);
                    }
                }
            }
            ++st.mbs_filtered;
            if (is_skip) ++st.skipped_mbs_filtered;
        }
    }
    return st;
}

} // namespace h264_deblock_ref
