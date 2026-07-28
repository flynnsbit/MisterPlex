// Full-frame gate for the product macroblock deblocking filter.
//
// Denominator policy: this bench states its scope before it states PASS.  The
// deblock evidence this replaces had a 2-macroblock denominator; a 2-MB proof
// is not a frame.  Here every macroblock of a real 624x480 P frame is filtered
// by the RTL, including every P_Skip macroblock, and the resulting picture is
// compared bit-exact against an independent frame-level reference model of
// clause 8.7 (tests/rtl/h264_deblock_ref.hpp).
//
// Measured vs assumed:
//  - MEASURED from the real bitstream: macroblock kinds (skip/inter/intra),
//    per-macroblock QP, per-4x4 luma coded-block flags, frame geometry.
//  - SYNTHETIC: the sample values.  Nothing in this project has ever decoded a
//    real frame, so there is no real reconstructed picture to filter.  The
//    samples are deterministic and deliberately blocky so real edges exist.
//  - MODELLED: the motion field.  The bitstream walk recovers MVD, not MV;
//    running the MV predictor chain is w-swap's scope.  Pass 1 therefore uses
//    the measured per-MB MVD as the motion field, and pass 2 drives a
//    deterministic varied motion field so the bS=1 path is exercised at frame
//    scope instead of being left uncovered.

#include "Vh264_deblock_mb_tb_top.h"
#include "h264_deblock_ref.hpp"
#include "h264_real_p_scope.hpp"
#include "verilated.h"

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <iostream>
#include <string>
#include <vector>

namespace {

constexpr int LUMA_DIM = 20;
constexpr int CHROMA_DIM = 12;

struct Sim {
    Vh264_deblock_mb_tb_top top;
    long long cycles = 0;

    void tick() {
        top.clk = 0;
        top.eval();
        top.clk = 1;
        top.eval();
        top.clk = 0;
        top.eval();
        ++cycles;
    }
    void resetDut() {
        top.reset = 1;
        top.start = 0;
        for (int i = 0; i < 4; ++i) tick();
        top.reset = 0;
        tick();
    }
};

void packMv(uint32_t* dst, const int* vals, int count, int bits) {
    // dst is the Verilated representation of a wide packed vector: little
    // endian 32-bit words.
    const int words = (count * bits + 31) / 32;
    for (int w = 0; w < words; ++w) dst[w] = 0;
    for (int i = 0; i < count; ++i) {
        const uint32_t masked = static_cast<uint32_t>(vals[i]) & ((bits >= 32) ? 0xffffffffu : ((1u << bits) - 1u));
        const int bit = i * bits;
        const int w = bit / 32;
        const int off = bit % 32;
        dst[w] |= masked << off;
        if (off + bits > 32) dst[w + 1] |= masked >> (32 - off);
    }
}

struct MbDrive {
    bool intra = false;
    int qp = 0;
    uint16_t nz4 = 0;
    int mvx[16] = {0};
    int mvy[16] = {0};
    int ref[16] = {0};
};

void applyCtx(Sim& s, int which, const MbDrive& m) {
    uint32_t* mvx = nullptr;
    uint32_t* mvy = nullptr;
    if (which == 0) {
        s.top.cur_intra = m.intra;
        s.top.cur_qp_y = static_cast<uint8_t>(m.qp);
        s.top.cur_nz = m.nz4;
        mvx = s.top.cur_mvx.data();
        mvy = s.top.cur_mvy.data();
        int refs[16];
        for (int i = 0; i < 16; ++i) refs[i] = m.ref[i];
        uint32_t packed = 0;
        for (int i = 0; i < 16; ++i) packed |= static_cast<uint32_t>(refs[i] & 3) << (i * 2);
        s.top.cur_ref = packed;
    } else if (which == 1) {
        s.top.left_intra = m.intra;
        s.top.left_qp_y = static_cast<uint8_t>(m.qp);
        s.top.left_nz = m.nz4;
        mvx = s.top.left_mvx.data();
        mvy = s.top.left_mvy.data();
        uint32_t packed = 0;
        for (int i = 0; i < 16; ++i) packed |= static_cast<uint32_t>(m.ref[i] & 3) << (i * 2);
        s.top.left_ref = packed;
    } else {
        s.top.top_intra = m.intra;
        s.top.top_qp_y = static_cast<uint8_t>(m.qp);
        s.top.top_nz = m.nz4;
        mvx = s.top.top_mvx.data();
        mvy = s.top.top_mvy.data();
        uint32_t packed = 0;
        for (int i = 0; i < 16; ++i) packed |= static_cast<uint32_t>(m.ref[i] & 3) << (i * 2);
        s.top.top_ref = packed;
    }
    packMv(mvx, m.mvx, 16, 12);
    packMv(mvy, m.mvy, 16, 12);
}

int frameLumaAt(const h264_deblock_ref::Frame& f, int x, int y) {
    if (x < 0 || y < 0 || x >= f.w || y >= f.h) return 0;
    return f.y[static_cast<size_t>(y) * static_cast<size_t>(f.w) + static_cast<size_t>(x)];
}
int frameChromaAt(const h264_deblock_ref::Frame& f, int plane, int x, int y) {
    const int cw = f.w / 2;
    const int ch = f.h / 2;
    if (x < 0 || y < 0 || x >= cw || y >= ch) return 0;
    const auto& src = plane ? f.v : f.u;
    return src[static_cast<size_t>(y) * static_cast<size_t>(cw) + static_cast<size_t>(x)];
}

struct RtlStats {
    long long mbs = 0;
    long long skipped_mbs = 0;
    long long luma_modified = 0;
    long long chroma_modified = 0;
    long long edge_segments = 0;
    long long bs4_segments = 0;
    int last_chroma_qp_avg = -1;
    bool pipe_error = false;
};

// Drive the RTL filter across every macroblock of `f`, in raster order,
// updating `f` in place exactly as the normative in-loop filter does.
RtlStats runRtlFrame(Sim& s, h264_deblock_ref::Frame& f, const std::vector<MbDrive>& mbs,
                     int mb_w, int mb_h, int disable_idc, int alpha_off, int beta_off,
                     int chroma_qp_off, const std::vector<uint8_t>& skipped,
                     bool skip_skipped_mbs) {
    RtlStats st;
    s.top.disable_deblocking_filter_idc = static_cast<uint8_t>(disable_idc);
    s.top.slice_alpha_c0_offset = static_cast<uint8_t>(alpha_off & 0x1f);
    s.top.slice_beta_offset = static_cast<uint8_t>(beta_off & 0x1f);
    s.top.chroma_qp_index_offset = static_cast<uint8_t>(chroma_qp_off & 0x1f);
    s.top.left_mb_other_slice = 0;
    s.top.top_mb_other_slice = 0;

    for (int mby = 0; mby < mb_h; ++mby) {
        for (int mbx = 0; mbx < mb_w; ++mbx) {
            const int addr = mby * mb_w + mbx;
            const bool is_skip = !skipped.empty() && skipped[static_cast<size_t>(addr)] != 0;
            if (skip_skipped_mbs && is_skip) continue;

            s.top.left_mb_avail = (mbx > 0) ? 1 : 0;
            s.top.top_mb_avail = (mby > 0) ? 1 : 0;
            applyCtx(s, 0, mbs[static_cast<size_t>(addr)]);
            applyCtx(s, 1, mbs[static_cast<size_t>(mbx > 0 ? addr - 1 : addr)]);
            applyCtx(s, 2, mbs[static_cast<size_t>(mby > 0 ? addr - mb_w : addr)]);

            for (int r = 0; r < LUMA_DIM; ++r)
                for (int c = 0; c < LUMA_DIM; ++c)
                    s.top.nb_y_i[r * LUMA_DIM + c] =
                        static_cast<uint8_t>(frameLumaAt(f, mbx * 16 + c - 4, mby * 16 + r - 4));
            for (int r = 0; r < CHROMA_DIM; ++r)
                for (int c = 0; c < CHROMA_DIM; ++c) {
                    const int cx = mbx * 8 + c - 4;
                    const int cy = mby * 8 + r - 4;
                    s.top.nb_u_i[r * CHROMA_DIM + c] = static_cast<uint8_t>(frameChromaAt(f, 0, cx, cy));
                    s.top.nb_v_i[r * CHROMA_DIM + c] = static_cast<uint8_t>(frameChromaAt(f, 1, cx, cy));
                }

            s.top.start = 1;
            s.tick();
            s.top.start = 0;
            long long guard = 0;
            while (!s.top.done) {
                s.tick();
                if (++guard > 4000) {
                    std::cerr << "FAIL h264_deblock_mb_filter: MB " << addr << " never asserted done\n";
                    std::exit(1);
                }
            }
            if (s.top.filter_pipe_error) st.pipe_error = true;
            st.luma_modified += s.top.luma_modified_samples;
            st.chroma_modified += s.top.chroma_modified_samples;
            st.edge_segments += s.top.edge_segments_filtered;
            st.bs4_segments += s.top.bs4_segments;
            st.last_chroma_qp_avg = s.top.last_chroma_qp_avg;

            for (int r = 0; r < LUMA_DIM; ++r) {
                const int yy = mby * 16 + r - 4;
                if (yy < 0 || yy >= f.h) continue;
                for (int c = 0; c < LUMA_DIM; ++c) {
                    const int x = mbx * 16 + c - 4;
                    if (x < 0 || x >= f.w) continue;
                    f.at_y(x, yy) = s.top.nb_y_o[r * LUMA_DIM + c];
                }
            }
            for (int r = 0; r < CHROMA_DIM; ++r) {
                const int cy = mby * 8 + r - 4;
                if (cy < 0 || cy >= f.h / 2) continue;
                for (int c = 0; c < CHROMA_DIM; ++c) {
                    const int cx = mbx * 8 + c - 4;
                    if (cx < 0 || cx >= f.w / 2) continue;
                    f.at_u(cx, cy) = s.top.nb_u_o[r * CHROMA_DIM + c];
                    f.at_v(cx, cy) = s.top.nb_v_o[r * CHROMA_DIM + c];
                }
            }
            ++st.mbs;
            if (is_skip) ++st.skipped_mbs;
            s.tick();
        }
    }
    return st;
}

void makePreFrame(h264_deblock_ref::Frame& f, int w, int h, uint32_t seed,
                  uint32_t chroma_mul = 1u) {
    f.alloc(w, h);
    uint32_t state = seed ? seed : 1u;
    auto next = [&]() {
        state ^= state << 13;
        state ^= state >> 17;
        state ^= state << 5;
        return state;
    };
    // Blocky content: a per-4x4-block DC step plus small per-sample noise.
    // The DC step is deliberately kept inside the clause 8.7.2.1 activity
    // window (|p0-q0| < alpha, |p1-p0| < beta) for mid/high QP, otherwise the
    // normative filterSamplesFlag rejects every edge and the whole frame is a
    // vacuous no-op.  Amplitude is still large enough that a do-nothing filter
    // cannot pass -- verified by the ref_luma_modified counter.
    for (int y = 0; y < h; ++y) {
        for (int x = 0; x < w; ++x) {
            const uint32_t blk = static_cast<uint32_t>((y / 4) * (w / 4) + (x / 4));
            const uint32_t dc = 100u + ((blk * 2654435761u) >> 29);
            f.at_y(x, y) = static_cast<uint8_t>((dc + (next() & 3u)) & 0xffu);
        }
    }
    for (int y = 0; y < h / 2; ++y) {
        for (int x = 0; x < w / 2; ++x) {
            const uint32_t blk = static_cast<uint32_t>((y / 2) * (w / 4) + (x / 2));
            const uint32_t dcu = 100u + ((((blk * 40503u) >> 29) & 7u) * chroma_mul);
            const uint32_t dcv = 124u + (((blk * 2246822519u) >> 29) * chroma_mul);
            f.at_u(x, y) = static_cast<uint8_t>((dcu + (next() & 1u)) & 0xffu);
            f.at_v(x, y) = static_cast<uint8_t>((dcv + (next() & 1u)) & 0xffu);
        }
    }
}

bool framesEqual(const h264_deblock_ref::Frame& a, const h264_deblock_ref::Frame& b,
                 std::string& where, int& got, int& want) {
    for (size_t i = 0; i < a.y.size(); ++i)
        if (a.y[i] != b.y[i]) {
            where = "luma@" + std::to_string(i % static_cast<size_t>(a.w)) + "," +
                    std::to_string(i / static_cast<size_t>(a.w));
            got = a.y[i];
            want = b.y[i];
            return false;
        }
    for (size_t i = 0; i < a.u.size(); ++i)
        if (a.u[i] != b.u[i]) {
            where = "chromaU@" + std::to_string(i % static_cast<size_t>(a.w / 2)) + "," +
                    std::to_string(i / static_cast<size_t>(a.w / 2));
            got = a.u[i];
            want = b.u[i];
            return false;
        }
    for (size_t i = 0; i < a.v.size(); ++i)
        if (a.v[i] != b.v[i]) {
            where = "chromaV@" + std::to_string(i % static_cast<size_t>(a.w / 2)) + "," +
                    std::to_string(i / static_cast<size_t>(a.w / 2));
            got = a.v[i];
            want = b.v[i];
            return false;
        }
    return true;
}

long long frameFnv(const h264_deblock_ref::Frame& f) {
    uint64_t h = 1469598103934665603ull;
    auto mix = [&](const std::vector<uint8_t>& d) {
        for (uint8_t b : d) {
            h ^= b;
            h *= 1099511628211ull;
        }
    };
    mix(f.y);
    mix(f.u);
    mix(f.v);
    return static_cast<long long>(h & 0x7fffffffffffffffull);
}

} // namespace

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    if (argc < 2) {
        std::cerr << "usage: h264_deblock_mb_tb <real_p_frame.264>\n";
        return 2;
    }
    const std::string fixture = argv[1];
    const auto scope = h264_real_p_scope::parseFirstPFrameScope(fixture);
    if (scope.total_mbs != 1170 || scope.skipped_mbs != 928 || scope.inter_mbs != 197 ||
        scope.intra_mbs != 45 || scope.coded_w != 624 || scope.coded_h != 480) {
        std::cerr << "FAIL h264_deblock_mb_filter: real P scope changed"
                  << " mbs=" << scope.total_mbs << " skipped=" << scope.skipped_mbs
                  << " inter=" << scope.inter_mbs << " intra=" << scope.intra_mbs
                  << " coded=" << scope.coded_w << "x" << scope.coded_h << "\n";
        return 1;
    }

    const int mb_w = scope.mb_w;
    const int mb_h = scope.mb_h;
    const int total = scope.total_mbs;

    std::vector<uint8_t> skipped(static_cast<size_t>(total), 0);
    std::vector<MbDrive> drive(static_cast<size_t>(total));
    std::vector<h264_deblock_ref::MbCtx> refctx(static_cast<size_t>(total));
    long long nz4_blocks = 0;
    for (int a = 0; a < total; ++a) {
        const auto& mb = scope.mbs[static_cast<size_t>(a)];
        MbDrive d;
        d.intra = h264_real_p_scope::isIntra(mb);
        d.qp = mb.qp;
        d.nz4 = mb.nz4;
        for (int b = 0; b < 16; ++b) {
            d.mvx[b] = mb.mvx;
            d.mvy[b] = mb.mvy;
            d.ref[b] = mb.ref & 3;
            if ((mb.nz4 >> b) & 1u) ++nz4_blocks;
        }
        drive[static_cast<size_t>(a)] = d;
        skipped[static_cast<size_t>(a)] = h264_real_p_scope::isSkip(mb) ? 1 : 0;
        h264_deblock_ref::MbCtx c;
        c.intra = d.intra;
        c.qp = d.qp;
        c.nz4 = d.nz4;
        for (int b = 0; b < 16; ++b) {
            c.mvx[b] = d.mvx[b];
            c.mvy[b] = d.mvy[b];
            c.ref[b] = d.ref[b];
        }
        refctx[static_cast<size_t>(a)] = c;
    }

    const char* mode = std::getenv("DEBLOCK_MB_MODE");
    const std::string run_mode = mode ? mode : "frame";

    Sim sim;
    sim.resetDut();

    // ── Pass 1: measured real-P coding context, measured MVD motion field ──
    h264_deblock_ref::Frame pre;
    makePreFrame(pre, scope.coded_w, scope.coded_h, 0x5eedu);

    h264_deblock_ref::Frame ref_frame = pre;
    h264_deblock_ref::Options opt;
    opt.skipped_mb = skipped;
    if (run_mode == "ref_no_chroma") opt.fault_no_chroma = true;
    if (run_mode == "ref_qpy_for_qpc") opt.fault_qpy_for_qpc = true;
    if (run_mode == "ref_horiz_first") opt.fault_horizontal_first = true;
    if (run_mode == "ref_skip_skipped") opt.fault_skip_skipped_mbs = true;
    if (run_mode == "ref_mb_edges_only") opt.fault_no_internal_edges = true;
    const auto refstats = h264_deblock_ref::deblockFrame(ref_frame, refctx, mb_w, mb_h, opt);

    h264_deblock_ref::Frame rtl_frame = pre;
    const bool harness_skip_skipped = (run_mode == "harness_skip_skipped");
    const auto rtlstats = runRtlFrame(sim, rtl_frame, drive, mb_w, mb_h, 0, 0, 0, 0, skipped,
                                      harness_skip_skipped);

    std::cout << "Scope: deblock_mb_filter_mbs=" << rtlstats.mbs << "/" << total
              << " skipped_mbs_filtered=" << rtlstats.skipped_mbs << "/" << scope.skipped_mbs
              << " luma_samples_in_frame=" << pre.y.size()
              << " chroma_samples_in_frame=" << (pre.u.size() + pre.v.size())
              << " rtl_luma_modified=" << rtlstats.luma_modified
              << " rtl_chroma_modified=" << rtlstats.chroma_modified
              << " rtl_edge_segments_filtered=" << rtlstats.edge_segments
              << " rtl_bs4_segments=" << rtlstats.bs4_segments
              << " ref_luma_modified=" << refstats.luma_modified
              << " ref_chroma_modified=" << refstats.chroma_modified
              << " measured_nz4_blocks=" << nz4_blocks << "/" << (total * 16)
              << " qp_range=" << scope.qp_min << ".." << scope.qp_max
              << " coded=" << scope.coded_w << "x" << scope.coded_h
              << " display=" << scope.display_w << "x" << scope.display_h
              << " cycles=" << sim.cycles
              << " pre_fnv=" << frameFnv(pre)
              << " rtl_fnv=" << frameFnv(rtl_frame)
              << " mode=" << run_mode << "\n";

    if (rtlstats.pipe_error) {
        std::cerr << "FAIL h264_deblock_mb_filter: edge pipe valid_o did not align with capture state\n";
        return 1;
    }

    std::string where;
    int got = 0, want = 0;
    if (!framesEqual(rtl_frame, ref_frame, where, got, want)) {
        std::cerr << "FAIL h264_deblock_mb_filter full-frame mismatch at " << where
                  << " got=" << got << " want=" << want
                  << " mode=" << run_mode << "\n";
        return 1;
    }

    if (run_mode != "frame") {
        std::cerr << "FAIL h264_deblock_mb_filter: fault mode " << run_mode
                  << " did not change the picture; the gate cannot see this class of defect\n";
        return 1;
    }

    if (rtlstats.mbs != total || rtlstats.skipped_mbs != scope.skipped_mbs) {
        std::cerr << "FAIL h264_deblock_mb_filter: frame denominator mismatch mbs=" << rtlstats.mbs
                  << " skipped=" << rtlstats.skipped_mbs << "\n";
        return 1;
    }
    if (rtlstats.luma_modified <= 0 || rtlstats.chroma_modified <= 0) {
        std::cerr << "FAIL h264_deblock_mb_filter: vacuous filter luma_modified="
                  << rtlstats.luma_modified << " chroma_modified=" << rtlstats.chroma_modified << "\n";
        return 1;
    }
    if (rtlstats.bs4_segments <= 0) {
        std::cerr << "FAIL h264_deblock_mb_filter: no bS=4 segments at real-frame scope\n";
        return 1;
    }
    if (rtl_frame.y == pre.y) {
        std::cerr << "FAIL h264_deblock_mb_filter: luma plane unchanged by a full frame of filtering\n";
        return 1;
    }
    if (rtl_frame.u == pre.u || rtl_frame.v == pre.v) {
        std::cerr << "FAIL h264_deblock_mb_filter: a chroma plane was left untouched\n";
        return 1;
    }

    std::cout << "OK h264_deblock_mb_filter full-frame: " << rtlstats.mbs << "/" << total
              << " real P-frame macroblocks filtered by product RTL (luma+chroma), "
              << rtlstats.skipped_mbs << "/" << scope.skipped_mbs
              << " P_Skip macroblocks included, bit-exact against the independent"
              << " clause 8.7 frame reference\n";

    // ── Pass 2: varied synthetic motion field so bS=1 is covered ──
    std::vector<MbDrive> drive_mv = drive;
    std::vector<h264_deblock_ref::MbCtx> refctx_mv = refctx;
    for (int a = 0; a < total; ++a) {
        for (int b = 0; b < 16; ++b) {
            const int mx = ((a * 7 + b * 13) % 17) - 8;
            const int my = ((a * 11 + b * 5) % 19) - 9;
            const int rf = ((a + b) % 3 == 0) ? 1 : 0;
            drive_mv[static_cast<size_t>(a)].mvx[b] = mx;
            drive_mv[static_cast<size_t>(a)].mvy[b] = my;
            drive_mv[static_cast<size_t>(a)].ref[b] = rf;
            refctx_mv[static_cast<size_t>(a)].mvx[b] = mx;
            refctx_mv[static_cast<size_t>(a)].mvy[b] = my;
            refctx_mv[static_cast<size_t>(a)].ref[b] = rf;
        }
        // Clear coded-block flags on a third of the MBs so bS=1 (motion-only)
        // decisions are reachable instead of always being masked by bS=2.
        if (a % 3 == 0) {
            drive_mv[static_cast<size_t>(a)].nz4 = 0;
            refctx_mv[static_cast<size_t>(a)].nz4 = 0;
        }
    }
    h264_deblock_ref::Frame pre2;
    makePreFrame(pre2, scope.coded_w, scope.coded_h, 0x1234abcdu);
    h264_deblock_ref::Frame ref2 = pre2;
    h264_deblock_ref::Options opt2;
    opt2.skipped_mb = skipped;
    const auto refstats2 = h264_deblock_ref::deblockFrame(ref2, refctx_mv, mb_w, mb_h, opt2);
    h264_deblock_ref::Frame rtl2 = pre2;
    const auto rtlstats2 = runRtlFrame(sim, rtl2, drive_mv, mb_w, mb_h, 0, 0, 0, 0, skipped, false);
    std::cout << "Scope: motion_pass_mbs=" << rtlstats2.mbs << "/" << total
              << " ref_bs1_lines=" << refstats2.bs_hist[1]
              << " ref_bs2_lines=" << refstats2.bs_hist[2]
              << " ref_bs3_lines=" << refstats2.bs_hist[3]
              << " ref_bs4_lines=" << refstats2.bs_hist[4]
              << " ref_bs0_lines=" << refstats2.bs_hist[0]
              << " rtl_luma_modified=" << rtlstats2.luma_modified
              << " rtl_chroma_modified=" << rtlstats2.chroma_modified << "\n";
    if (!framesEqual(rtl2, ref2, where, got, want)) {
        std::cerr << "FAIL h264_deblock_mb_filter motion-field pass mismatch at " << where
                  << " got=" << got << " want=" << want << "\n";
        return 1;
    }
    if (refstats2.bs_hist[1] <= 0) {
        std::cerr << "FAIL h264_deblock_mb_filter: motion pass never produced a bS=1 edge\n";
        return 1;
    }
    std::cout << "OK h264_deblock_mb_filter motion pass: bS=1 motion-only edges covered at frame scope\n";

    // ── Pass 3: high-QP chroma trap.  Below qPI 30 the QPy and QPc tables
    //    agree, so only a high-QP frame can tell them apart. ──
    std::vector<MbDrive> drive_hi = drive;
    std::vector<h264_deblock_ref::MbCtx> refctx_hi = refctx;
    for (int a = 0; a < total; ++a) {
        drive_hi[static_cast<size_t>(a)].qp = 40;
        refctx_hi[static_cast<size_t>(a)].qp = 40;
    }
    h264_deblock_ref::Frame pre3;
    // Larger chroma DC steps than the other passes: with tiny steps the
    // clause 8.7.2.3 delta never reaches tc, so tc0(indexA) -- the only place
    // QPc differs from QPy -- cancels out and the trap would be vacuous.
    makePreFrame(pre3, scope.coded_w, scope.coded_h, 0x0badc0deu, 3u);
    h264_deblock_ref::Frame ref3 = pre3;
    h264_deblock_ref::Options opt3;
    opt3.skipped_mb = skipped;
    h264_deblock_ref::deblockFrame(ref3, refctx_hi, mb_w, mb_h, opt3);
    h264_deblock_ref::Frame ref3_qpy = pre3;
    h264_deblock_ref::Options opt3_qpy = opt3;
    opt3_qpy.fault_qpy_for_qpc = true;
    h264_deblock_ref::deblockFrame(ref3_qpy, refctx_hi, mb_w, mb_h, opt3_qpy);
    h264_deblock_ref::Frame rtl3 = pre3;
    const auto rtlstats3 = runRtlFrame(sim, rtl3, drive_hi, mb_w, mb_h, 0, 0, 0, 0, skipped, false);
    std::cout << "Scope: chroma_qpc_trap_mbs=" << rtlstats3.mbs << "/" << total
              << " qpy=40 expected_qpc=" << h264_deblock_ref::qpcMap(40, 0)
              << " rtl_last_chroma_qp_avg=" << rtlstats3.last_chroma_qp_avg
              << " rtl_chroma_modified=" << rtlstats3.chroma_modified << "\n";
    if (!framesEqual(rtl3, ref3, where, got, want)) {
        std::cerr << "FAIL h264_deblock_mb_filter high-QP chroma mismatch at " << where
                  << " got=" << got << " want=" << want << "\n";
        return 1;
    }
    if (ref3.u == ref3_qpy.u && ref3.v == ref3_qpy.v) {
        std::cerr << "FAIL h264_deblock_mb_filter: the QPy/QPc trap is vacuous at QPy=40\n";
        return 1;
    }
    if (rtlstats3.last_chroma_qp_avg != h264_deblock_ref::qpcMap(40, 0)) {
        std::cerr << "FAIL h264_deblock_mb_filter: chroma edges used qp_avg="
                  << rtlstats3.last_chroma_qp_avg << " want QPc="
                  << h264_deblock_ref::qpcMap(40, 0) << "\n";
        return 1;
    }
    std::cout << "OK h264_deblock_mb_filter chroma QPc: QPy=40 maps to QPc="
              << h264_deblock_ref::qpcMap(40, 0)
              << " on chroma edges at full-frame scope; substituting QPy changes the picture\n";

    // ── Pass 4: disable_deblocking_filter_idc=1 must be a true bypass ──
    h264_deblock_ref::Frame pre4;
    makePreFrame(pre4, scope.coded_w, scope.coded_h, 0x77u);
    h264_deblock_ref::Frame rtl4 = pre4;
    runRtlFrame(sim, rtl4, drive, mb_w, mb_h, 1, 0, 0, 0, skipped, false);
    if (!(rtl4.y == pre4.y && rtl4.u == pre4.u && rtl4.v == pre4.v)) {
        std::cerr << "FAIL h264_deblock_mb_filter: disable_deblocking_filter_idc=1 still modified samples\n";
        return 1;
    }
    std::cout << "OK h264_deblock_mb_filter bypass: disable_deblocking_filter_idc=1 leaves all "
              << (pre4.y.size() + pre4.u.size() + pre4.v.size())
              << " frame samples untouched\n";

    return 0;
}
