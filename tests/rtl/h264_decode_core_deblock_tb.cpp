// Core-level in-loop deblocking gate driver (W-DEBLOCK-O5).
#include <array>
//
// Denominator: every macroblock of a 624x480 frame (39x30 = 1170) is driven
// through h264_decode_core with DEBLOCK_IN_LOOP=1 and every one of the
// 1170*384 = 449280 DPB sample writes is captured in wb_idx order.
//
// What this proves that the standalone filter gate cannot:
//   * the bytes the *core* hands to the DPB are POST-deblock,
//   * chroma is filtered on that path too,
//   * disable_deblocking_filter_idc=1 is a true bypass on that path,
//   * the PRE/POST + promotion ordering contract still holds with a real
//     filter in the writeback path.
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

#include "Vh264_decode_core_deblock_tb.h"
#include "verilated.h"

#include "h264_deblock_ref.hpp"

namespace {

constexpr int FRAME_W = 624;
constexpr int FRAME_H = 480;
constexpr int MB_W = FRAME_W / 16;
constexpr int MB_H = FRAME_H / 16;
constexpr int MB_COUNT = MB_W * MB_H;
constexpr int SAMPLES_PER_MB = 384;

struct MbSyntax {
    int cbp_luma;
    int mb_type;
    bool skip;
};

MbSyntax syntaxFor(int k) {
    MbSyntax s{};
    s.skip = (k % 4) == 1;
    s.mb_type = ((k % 7) == 0) ? 5 : 0;      // every 7th MB is intra -> bS=4/3
    s.cbp_luma = ((k % 3) == 0) ? 0x0 : 0xf; // vary coded-block flags -> bS 2 vs 0/1
    if (s.skip) s.cbp_luma = 0x0;
    return s;
}

void makePreFrame(h264_deblock_ref::Frame& f, uint32_t seed) {
    f.alloc(FRAME_W, FRAME_H);
    uint32_t state = seed ? seed : 1u;
    auto next = [&]() {
        state ^= state << 13;
        state ^= state >> 17;
        state ^= state << 5;
        return state;
    };
    for (int y = 0; y < FRAME_H; ++y)
        for (int x = 0; x < FRAME_W; ++x) {
            const uint32_t blk = static_cast<uint32_t>((y / 4) * (FRAME_W / 4) + (x / 4));
            f.at_y(x, y) = static_cast<uint8_t>((100u + ((blk * 2654435761u) >> 29) + (next() & 3u)) & 0xffu);
        }
    for (int y = 0; y < FRAME_H / 2; ++y)
        for (int x = 0; x < FRAME_W / 2; ++x) {
            const uint32_t blk = static_cast<uint32_t>((y / 2) * (FRAME_W / 4) + (x / 2));
            f.at_u(x, y) = static_cast<uint8_t>((100u + ((((blk * 40503u) >> 29) & 7u) * 3u) + (next() & 1u)) & 0xffu);
            f.at_v(x, y) = static_cast<uint8_t>((124u + (((blk * 2246822519u) >> 29) * 3u) + (next() & 1u)) & 0xffu);
        }
}

struct Obs {
    long long commits = 0;
    long long sample_valids = 0;
    long long wb_valids = 0;
    long long boundaries = 0;
    long long ref_ready_pulses = 0;
    long long frame_dones = 0;
    long long commit_order_errors = 0;
    long long pipe_errors = 0;
    long long luma_modified = 0;
    long long chroma_modified = 0;
    int last_chroma_qp = -1;
    // contract violations
    long long promote_without_boundary = 0;
    long long commit_with_ref_ready = 0;
    long long frame_done_without_pulse = 0;
    long long short_sample_runs = 0;
};

struct Sim {
    Vh264_decode_core_deblock_tb top;
    Obs obs;
    std::vector<std::array<uint8_t, SAMPLES_PER_MB>> mb_writes;
    int prev_boundary = 0;
    int prev_pulse = 0;
    long long samples_since_commit = 0;

    Sim() { mb_writes.assign(MB_COUNT, {}); }

    void observe(int mb_index, int& widx) {
        if (top.dpb_wr_en) {
            if (widx < SAMPLES_PER_MB && mb_index >= 0)
                mb_writes[static_cast<size_t>(mb_index)][static_cast<size_t>(widx)] = top.dpb_wr_data;
            ++widx;
        }
        if (top.obs_filtered_sample_valid) { ++obs.sample_valids; ++samples_since_commit; }
        if (top.obs_filtered_mb_valid) {
            ++obs.commits;
            if (samples_since_commit != SAMPLES_PER_MB) ++obs.short_sample_runs;
            samples_since_commit = 0;
            if (top.obs_ref_ready_pulse) ++obs.commit_with_ref_ready;
        }
        if (top.obs_wb_valid) ++obs.wb_valids;
        if (top.obs_frame_boundary) ++obs.boundaries;
        if (top.obs_ref_ready_pulse) {
            ++obs.ref_ready_pulses;
            if (!prev_boundary) ++obs.promote_without_boundary;
        }
        if (top.frame_done) {
            ++obs.frame_dones;
            if (!prev_pulse) ++obs.frame_done_without_pulse;
        }
        if (top.obs_commit_order_error) ++obs.commit_order_errors;
        if (top.obs_filter_pipe_error) ++obs.pipe_errors;
        prev_boundary = top.obs_frame_boundary;
        prev_pulse = top.obs_ref_ready_pulse;
    }

    void tick(int mb_index, int& widx) {
        top.clk = 0;
        top.eval();
        top.clk = 1;
        top.eval();
        observe(mb_index, widx);
    }
};

void runFrame(Sim& s, const h264_deblock_ref::Frame& pre, int disable_idc, int qp) {
    s.top.reset = 1;
    s.top.slice_start = 0;
    s.top.recon_mb_valid = 0;
    s.top.mb_type_valid = 0;
    s.top.slice_disable_deblocking_filter_idc = static_cast<uint8_t>(disable_idc);
    s.top.slice_alpha_c0_offset = 0;
    s.top.slice_beta_offset = 0;
    s.top.pps_chroma_qp_index_offset = 0;
    s.top.slice_qp_y = static_cast<uint8_t>(qp);
    s.top.slice_is_idr = 1;
    s.top.slice_is_i = 0;
    s.top.dpb_write_base = 0;
    int dummy = 0;
    for (int i = 0; i < 4; ++i) s.tick(-1, dummy);
    s.top.reset = 0;
    s.top.slice_start = 1;
    s.tick(-1, dummy);
    s.top.slice_start = 0;
    s.tick(-1, dummy);

    for (int k = 0; k < MB_COUNT; ++k) {
        const int mbx = k % MB_W;
        const int mby = k / MB_W;
        for (int i = 0; i < 256; ++i)
            s.top.recon_y[i] = pre.y[static_cast<size_t>((mby * 16 + i / 16) * FRAME_W + mbx * 16 + (i % 16))];
        for (int i = 0; i < 64; ++i) {
            s.top.recon_u[i] = pre.u[static_cast<size_t>((mby * 8 + i / 8) * (FRAME_W / 2) + mbx * 8 + (i % 8))];
            s.top.recon_v[i] = pre.v[static_cast<size_t>((mby * 8 + i / 8) * (FRAME_W / 2) + mbx * 8 + (i % 8))];
        }
        const MbSyntax syn = syntaxFor(k);
        s.top.cbp_luma = static_cast<uint8_t>(syn.cbp_luma);
        s.top.mb_type = static_cast<uint8_t>(syn.mb_type);
        s.top.mb_skip = static_cast<uint8_t>(syn.skip ? 1 : 0);
        s.top.mb_type_valid = 1;
        s.top.recon_mb_valid = 1;
        s.top.recon_mb_x = static_cast<uint8_t>(mbx);
        s.top.recon_mb_y = static_cast<uint8_t>(mby);
        s.top.recon_mb_is_ref = 1;
        int widx = 0;
        s.tick(k, widx);
        s.top.mb_type_valid = 0;
        s.top.recon_mb_valid = 0;
        int guard = 0;
        while (guard++ < 200000) {
            s.tick(k, widx);
            if (!s.top.busy) break;
        }
        if (widx != SAMPLES_PER_MB) {
            std::fprintf(stderr,
                         "FAIL h264_decode_core deblock: macroblock %d produced %d DPB writes, want %d\n",
                         k, widx, SAMPLES_PER_MB);
            std::exit(1);
        }
        s.obs.luma_modified += s.top.obs_luma_modified;
        s.obs.chroma_modified += s.top.obs_chroma_modified;
        s.obs.last_chroma_qp = s.top.obs_last_chroma_qp;
    }
    int dummy2 = 0;
    for (int i = 0; i < 8; ++i) s.tick(-1, dummy2);
}

void preMbBytes(const h264_deblock_ref::Frame& pre, int k, std::array<uint8_t, SAMPLES_PER_MB>& out) {
    const int mbx = k % MB_W;
    const int mby = k / MB_W;
    for (int i = 0; i < 256; ++i)
        out[static_cast<size_t>(i)] =
            pre.y[static_cast<size_t>((mby * 16 + i / 16) * FRAME_W + mbx * 16 + (i % 16))];
    for (int i = 0; i < 64; ++i) {
        out[static_cast<size_t>(256 + i)] =
            pre.u[static_cast<size_t>((mby * 8 + i / 8) * (FRAME_W / 2) + mbx * 8 + (i % 8))];
        out[static_cast<size_t>(320 + i)] =
            pre.v[static_cast<size_t>((mby * 8 + i / 8) * (FRAME_W / 2) + mbx * 8 + (i % 8))];
    }
}

} // namespace

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    const int qp = 40;

    h264_deblock_ref::Frame pre;
    makePreFrame(pre, 0xdeb10c5u);

    Sim on;
    runFrame(on, pre, 0, qp);
    Sim off;
    runFrame(off, pre, 1, qp);

    long long luma_diff = 0, chroma_diff = 0, bypass_diff = 0;
    std::array<uint8_t, SAMPLES_PER_MB> want{};
    for (int k = 0; k < MB_COUNT; ++k) {
        preMbBytes(pre, k, want);
        for (int i = 0; i < SAMPLES_PER_MB; ++i) {
            if (off.mb_writes[static_cast<size_t>(k)][static_cast<size_t>(i)] != want[static_cast<size_t>(i)])
                ++bypass_diff;
            if (on.mb_writes[static_cast<size_t>(k)][static_cast<size_t>(i)] != want[static_cast<size_t>(i)]) {
                if (i < 256) ++luma_diff; else ++chroma_diff;
            }
        }
    }

    std::printf("Scope: core_deblock_mbs=%d/%d dpb_sample_writes=%lld/%d "
                "post_deblock_luma_samples=%lld post_deblock_chroma_samples=%lld "
                "bypass_mismatches=%lld/%d rtl_luma_modified=%lld rtl_chroma_modified=%lld "
                "last_chroma_qp=%d qpy=%d expected_qpc=%d commits=%lld sample_valids=%lld "
                "wb_valids=%lld boundaries=%lld ref_ready_pulses=%lld frame_dones=%lld "
                "coded=%dx%d\n",
                MB_COUNT, MB_COUNT,
                static_cast<long long>(MB_COUNT) * SAMPLES_PER_MB, MB_COUNT * SAMPLES_PER_MB,
                luma_diff, chroma_diff, bypass_diff, MB_COUNT * SAMPLES_PER_MB,
                on.obs.luma_modified, on.obs.chroma_modified, on.obs.last_chroma_qp,
                qp, h264_deblock_ref::qpcMap(qp, 0), on.obs.commits, on.obs.sample_valids,
                on.obs.wb_valids, on.obs.boundaries, on.obs.ref_ready_pulses,
                on.obs.frame_dones, FRAME_W, FRAME_H);

    if (bypass_diff != 0) {
        std::fprintf(stderr, "FAIL h264_decode_core deblock: disable_deblocking_filter_idc=1 "
                             "changed %lld DPB samples; the bypass is not a bypass\n", bypass_diff);
        return 1;
    }
    if (luma_diff <= 0) {
        std::fprintf(stderr, "FAIL h264_decode_core deblock: DPB luma stream is PRE-deblock "
                             "(0 samples differ from the reconstructed macroblock)\n");
        return 1;
    }
    if (chroma_diff <= 0) {
        std::fprintf(stderr, "FAIL h264_decode_core deblock: DPB chroma stream is PRE-deblock; "
                             "chroma deblocking is not on the core writeback path\n");
        return 1;
    }
    if (on.obs.last_chroma_qp != h264_deblock_ref::qpcMap(qp, 0)) {
        std::fprintf(stderr, "FAIL h264_decode_core deblock: chroma edges used qp_avg=%d, want QPc=%d\n",
                     on.obs.last_chroma_qp, h264_deblock_ref::qpcMap(qp, 0));
        return 1;
    }
    if (on.obs.pipe_errors != 0 || on.obs.commit_order_errors != 0) {
        std::fprintf(stderr, "FAIL h264_decode_core deblock: pipe_errors=%lld commit_order_errors=%lld\n",
                     on.obs.pipe_errors, on.obs.commit_order_errors);
        return 1;
    }

    // ── ordering contract ──
    if (on.obs.commits != MB_COUNT) {
        std::fprintf(stderr, "FAIL h264_decode_core deblock ordering: %lld macroblock commits, want %d\n",
                     on.obs.commits, MB_COUNT);
        return 1;
    }
    if (on.obs.sample_valids != static_cast<long long>(MB_COUNT) * SAMPLES_PER_MB) {
        std::fprintf(stderr, "FAIL h264_decode_core deblock ordering: %lld filtered_sample_valid cycles, want %lld\n",
                     on.obs.sample_valids, static_cast<long long>(MB_COUNT) * SAMPLES_PER_MB);
        return 1;
    }
    if (on.obs.short_sample_runs != 0) {
        std::fprintf(stderr, "FAIL h264_decode_core deblock ordering: %lld macroblock commits did not "
                             "follow a complete 384-sample filtered_sample_valid run\n",
                     on.obs.short_sample_runs);
        return 1;
    }
    if (on.obs.commit_with_ref_ready != 0) {
        std::fprintf(stderr, "FAIL h264_decode_core deblock ordering: %lld commits happened while "
                             "ref_ready_pulse was high; the terminal commit must precede promotion\n",
                     on.obs.commit_with_ref_ready);
        return 1;
    }
    if (on.obs.ref_ready_pulses != 1) {
        std::fprintf(stderr, "FAIL h264_decode_core deblock ordering: %lld ref_ready pulses for one frame, want 1\n",
                     on.obs.ref_ready_pulses);
        return 1;
    }
    if (on.obs.promote_without_boundary != 0) {
        std::fprintf(stderr, "FAIL h264_decode_core deblock ordering: %lld ref_ready pulses were not "
                             "preceded by frame_boundary; DPB promotion escaped the boundary\n",
                     on.obs.promote_without_boundary);
        return 1;
    }
    if (on.obs.frame_dones != 1 || on.obs.frame_done_without_pulse != 0) {
        std::fprintf(stderr, "FAIL h264_decode_core deblock ordering: frame_done=%lld (want 1) not driven "
                             "from the deblock ref_ready pulse (%lld stray assertions)\n",
                     on.obs.frame_dones, on.obs.frame_done_without_pulse);
        return 1;
    }

    // ── independent bit-exact anchor: macroblock 0 has no left/top neighbour,
    //    so its committed samples must equal the clause 8.7 reference run over
    //    a standalone 16x16 picture (internal 4x4 edges only). ──
    {
        h264_deblock_ref::Frame one;
        one.alloc(16, 16);
        for (int y = 0; y < 16; ++y)
            for (int x = 0; x < 16; ++x) one.at_y(x, y) = pre.at_y(x, y);
        for (int y = 0; y < 8; ++y)
            for (int x = 0; x < 8; ++x) {
                one.at_u(x, y) = pre.at_u(x, y);
                one.at_v(x, y) = pre.at_v(x, y);
            }
        std::vector<h264_deblock_ref::MbCtx> ctx(1);
        const MbSyntax syn = syntaxFor(0);
        ctx[0].qp = qp;
        ctx[0].intra = (syn.mb_type >= 5);
        ctx[0].nz4 = syn.cbp_luma ? 0xffff : 0;
        for (int b = 0; b < 16; ++b) { ctx[0].mvx[b] = 0; ctx[0].mvy[b] = 0; ctx[0].ref[b] = 0; }
        h264_deblock_ref::Options o;
        h264_deblock_ref::deblockFrame(one, ctx, 1, 1, o);
        int mism = 0;
        for (int i = 0; i < 256; ++i)
            if (on.mb_writes[0][static_cast<size_t>(i)] != one.y[static_cast<size_t>(i)]) ++mism;
        for (int i = 0; i < 64; ++i) {
            if (on.mb_writes[0][static_cast<size_t>(256 + i)] != one.u[static_cast<size_t>(i)]) ++mism;
            if (on.mb_writes[0][static_cast<size_t>(320 + i)] != one.v[static_cast<size_t>(i)]) ++mism;
        }
        std::printf("Scope: core_mb0_anchor_mismatches=%d/%d\n", mism, SAMPLES_PER_MB);
        if (mism != 0) {
            std::fprintf(stderr, "FAIL h264_decode_core deblock: macroblock 0 committed samples do not "
                                 "match the independent clause 8.7 reference (%d/%d mismatches)\n",
                         mism, SAMPLES_PER_MB);
            return 1;
        }
    }

    std::printf("OK h264_decode_core deblock: %d/%d macroblocks, %lld/%d DPB sample writes are POST-deblock "
                "(%lld luma + %lld chroma samples changed by the filter), bypass exact, "
                "PRE/POST and promotion ordering held\n",
                MB_COUNT, MB_COUNT, static_cast<long long>(MB_COUNT) * SAMPLES_PER_MB,
                MB_COUNT * SAMPLES_PER_MB, luma_diff, chroma_diff);
    return 0;
}
