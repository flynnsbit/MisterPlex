#include "Vh264_dpb_mc_tb.h"
#include "verilated.h"

#include <algorithm>
#include <array>
#include <cstdint>
#include <fstream>
#include <iostream>
#include <stdexcept>
#include <string>
#include <vector>

namespace {

constexpr int W = 624;
constexpr int H = 480;
constexpr int CW = W / 2;
constexpr int CH = H / 2;
constexpr int Y_BYTES = W * H;
constexpr int C_BYTES = CW * CH;
constexpr int FRAME_BYTES = Y_BYTES + 2 * C_BYTES;
constexpr int DPB_BYTES = 2 * FRAME_BYTES;

struct Sim {
    Vh264_dpb_mc_tb top;
    std::vector<uint8_t> mem = std::vector<uint8_t>(DPB_BYTES, 0xee);
    struct ReadTag {
        bool valid = false;
        int plane = 0;
        int idx = 0;
        uint64_t issuedCycle = 0;
    };
    // Match decode_stub's product DPB store latency: h264_dpb registers
    // mem_rd/mem_raddr on one edge; decode_stub samples them on the next edge
    // into dpb_mem_rvalid/dpb_mem_raddr_q, and rdata is combinational from the
    // registered address. Therefore mem_rvalid/mem_rdata reach h264_dpb two
    // edges after mem_rd, aligned with h264_dpb's pending_*_d1 metadata.
    bool pendingRead = false;
    bool pendingReadD1 = false;
    uint32_t pendingAddr = 0;
    uint32_t pendingAddrD1 = 0;
    ReadTag readTag = {};
    ReadTag readTagD1 = {};
    int nextFetchRead = 0;
    uint64_t cycle = 0;

    ReadTag tagForIssuedRead() {
        if (nextFetchRead >= 441 + 81 + 81) {
            throw std::runtime_error("read latency contract: unexpected extra DPB fetch read at cycle " +
                                     std::to_string(cycle));
        }
        // Current h264_dpb implementation order is luma[441], then U[81],
        // then V[81]. This is an implementation-order guard, not an H.264
        // external contract; update this scoreboard if the RTL is deliberately
        // reworked to issue a different legal order.
        int n = nextFetchRead++;
        ReadTag tag;
        tag.valid = true;
        tag.issuedCycle = cycle;
        if (n < 441) {
            tag.plane = 0;
            tag.idx = n;
        } else if (n < 441 + 81) {
            tag.plane = 1;
            tag.idx = n - 441;
        } else {
            tag.plane = 2;
            tag.idx = n - 441 - 81;
        }
        return tag;
    }

    void checkReadLatencyResponse(const ReadTag& expected) {
        if (top.mem_rvalid != expected.valid) {
            throw std::runtime_error("read latency contract: mem_rvalid observed " +
                                     std::to_string(int(top.mem_rvalid)) + " at cycle " +
                                     std::to_string(cycle) + " but two-edge response valid is " +
                                     std::to_string(int(expected.valid)));
        }

        bool luma = top.luma_window_valid;
        bool chromaU = top.chroma_u_window_valid;
        bool chromaV = top.chroma_v_window_valid;
        int validCount = int(luma) + int(chromaU) + int(chromaV);
        if (!expected.valid) {
            if (validCount != 0) {
                throw std::runtime_error("read latency contract: window valid without two-edge response at cycle " +
                                         std::to_string(cycle));
            }
            return;
        }
        if (validCount != 1) {
            throw std::runtime_error("read latency contract: expected exactly one window valid for read issued at cycle " +
                                     std::to_string(expected.issuedCycle) + ", got " + std::to_string(validCount));
        }

        int gotPlane = luma ? 0 : (chromaU ? 1 : 2);
        int gotIdx = luma ? int(top.luma_window_idx) : int(top.chroma_window_idx);
        if (gotPlane != expected.plane || gotIdx != expected.idx) {
            throw std::runtime_error("read latency contract: response metadata mismatch got plane=" +
                                     std::to_string(gotPlane) + " idx=" + std::to_string(gotIdx) +
                                     " want plane=" + std::to_string(expected.plane) +
                                     " idx=" + std::to_string(expected.idx));
        }
    }

    void tick() {
        if (top.fetch_start) nextFetchRead = 0;
        ReadTag expectedResponse = readTagD1;
        top.mem_rvalid = pendingReadD1;
        top.mem_rdata = pendingReadD1 && pendingAddrD1 < mem.size() ? mem[pendingAddrD1] : 0;
        top.clk = 0;
        top.eval();
        top.clk = 1;
        top.eval();
        checkReadLatencyResponse(expectedResponse);
        if (top.mem_we) {
            if (top.mem_waddr >= mem.size()) throw std::runtime_error("write address out of DPB range");
            mem[top.mem_waddr] = static_cast<uint8_t>(top.mem_wdata);
        }
        pendingReadD1 = pendingRead;
        pendingAddrD1 = pendingAddr;
        pendingRead = top.mem_rd;
        pendingAddr = top.mem_raddr;
        readTagD1 = readTag;
        readTag = top.mem_rd ? tagForIssuedRead() : ReadTag{};
        top.clk = 0;
        top.eval();
        ++cycle;
    }
};

int countAnnexBNals(const std::string& path) {
    std::ifstream in(path, std::ios::binary);
    if (!in) throw std::runtime_error("cannot open NAL fixture: " + path);
    std::vector<uint8_t> b((std::istreambuf_iterator<char>(in)), {});
    int n = 0;
    for (std::size_t i = 2; i < b.size(); ++i) {
        if (b[i - 2] == 0 && b[i - 1] == 0 && b[i] == 1) ++n;
        else if (i >= 3 && b[i - 3] == 0 && b[i - 2] == 0 && b[i - 1] == 0 && b[i] == 1) ++n;
    }
    return n;
}

uint32_t i420Addr(uint32_t base, int plane, int x, int y) {
    if (plane == 0) return base + y * W + x;
    if (plane == 1) return base + Y_BYTES + y * CW + x;
    return base + Y_BYTES + C_BYTES + y * CW + x;
}

uint8_t yPattern(int x, int y) { return static_cast<uint8_t>((17 + x * 3 + y * 5) & 0xff); }
uint8_t uPattern(int x, int y) { return static_cast<uint8_t>((83 + x * 7 + y * 11) & 0xff); }
uint8_t vPattern(int x, int y) { return static_cast<uint8_t>((191 + x * 13 + y * 3) & 0xff); }

void assertDistinctChromaPatterns() {
    int distinct = 0;
    for (int y = 0; y < 8; ++y) {
        for (int x = 0; x < 8; ++x) {
            if (uPattern(x, y) != vPattern(x, y)) ++distinct;
        }
    }
    if (distinct == 0) {
        throw std::runtime_error("chroma fixture degeneracy: U and V patterns alias across 8x8 probe");
    }
}

uint8_t planePattern(int plane, int x, int y) {
    if (plane == 0) return yPattern(x, y);
    if (plane == 1) return uPattern(x, y);
    return vPattern(x, y);
}

uint32_t mbSampleAddr(int mbx, int mby, int plane, int idx) {
    if (plane == 0) {
        int x = mbx * 16 + (idx & 15);
        int y = mby * 16 + (idx >> 4);
        return i420Addr(0, plane, x, y);
    }
    int x = mbx * 8 + (idx & 7);
    int y = mby * 8 + (idx >> 3);
    return i420Addr(0, plane, x, y);
}

void writeSample(Sim& s, int mbx, int mby, int plane, int idx) {
    int x = plane == 0 ? mbx * 16 + (idx & 15) : mbx * 8 + (idx & 7);
    int y = plane == 0 ? mby * 16 + (idx >> 4) : mby * 8 + (idx >> 3);
    s.top.filtered_sample_valid = 1;
    s.top.filtered_mb_x = mbx;
    s.top.filtered_mb_y = mby;
    s.top.filtered_plane = plane;
    s.top.filtered_sample_idx = idx;
    s.top.filtered_sample = planePattern(plane, x, y);
    s.tick();
    uint32_t want = mbSampleAddr(mbx, mby, plane, idx);
    if (!s.top.mem_we || s.top.mem_waddr != want || s.top.mem_wdata != planePattern(plane, x, y)) {
        std::cerr << "FAIL h264_dpb_mc RTL: filtered I420 writeback mismatch plane=" << plane
                  << " mb=(" << mbx << "," << mby << ") idx=" << idx
                  << " got we=" << int(s.top.mem_we) << " addr=" << s.top.mem_waddr
                  << " data=" << int(s.top.mem_wdata) << " want addr=" << want
                  << " data=" << int(planePattern(plane, x, y)) << "\n";
        throw std::runtime_error("filtered I420 writeback mismatch");
    }
}

int clip1(int v) { return std::max(0, std::min(255, v)); }
int avg2(int a, int b) { return (a + b + 1) >> 1; }

int wpix(const std::array<uint8_t, 441>& w, int r, int c) { return w.at(static_cast<size_t>(r * 21 + c)); }
int hraw(const std::array<uint8_t, 441>& w, int r, int c) {
    return wpix(w, r, c - 2) - 5 * wpix(w, r, c - 1) + 20 * wpix(w, r, c) +
           20 * wpix(w, r, c + 1) - 5 * wpix(w, r, c + 2) + wpix(w, r, c + 3);
}
int halfH(const std::array<uint8_t, 441>& w, int r, int c) { return clip1((hraw(w, r, c) + 16) >> 5); }
int halfV(const std::array<uint8_t, 441>& w, int r, int c) {
    return clip1((wpix(w, r - 2, c) - 5 * wpix(w, r - 1, c) + 20 * wpix(w, r, c) +
                  20 * wpix(w, r + 1, c) - 5 * wpix(w, r + 2, c) + wpix(w, r + 3, c) + 16) >> 5);
}
int halfC(const std::array<uint8_t, 441>& w, int r, int c) {
    int sum = hraw(w, r - 2, c) - 5 * hraw(w, r - 1, c) + 20 * hraw(w, r, c) +
              20 * hraw(w, r + 1, c) - 5 * hraw(w, r + 2, c) + hraw(w, r + 3, c);
    return clip1((sum + 512) >> 10);
}

uint8_t qpel(const std::array<uint8_t, 441>& w, int x, int y, int fx, int fy) {
    int r = y + 2;
    int c = x + 2;
    switch ((fy << 2) | fx) {
    case 0x0: return wpix(w, r, c);
    case 0x1: return avg2(wpix(w, r, c), halfH(w, r, c));
    case 0x2: return halfH(w, r, c);
    case 0x3: return avg2(halfH(w, r, c), wpix(w, r, c + 1));
    case 0x4: return avg2(wpix(w, r, c), halfV(w, r, c));
    case 0x5: return avg2(halfH(w, r, c), halfV(w, r, c));
    case 0x6: return avg2(halfH(w, r, c), halfC(w, r, c));
    case 0x7: return avg2(halfH(w, r, c), halfV(w, r, c + 1));
    case 0x8: return halfV(w, r, c);
    case 0x9: return avg2(halfV(w, r, c), halfC(w, r, c));
    case 0xa: return halfC(w, r, c);
    case 0xb: return avg2(halfC(w, r, c), halfV(w, r, c + 1));
    case 0xc: return avg2(halfV(w, r, c), wpix(w, r + 1, c));
    case 0xd: return avg2(halfH(w, r + 1, c), halfV(w, r, c));
    case 0xe: return avg2(halfC(w, r, c), halfH(w, r + 1, c));
    default: return avg2(halfH(w, r + 1, c), halfV(w, r, c + 1));
    }
}

uint8_t chroma(const std::array<uint8_t, 81>& w, int x, int y, int fx, int fy) {
    int p00 = w.at(static_cast<size_t>(y * 9 + x));
    int p10 = w.at(static_cast<size_t>(y * 9 + x + 1));
    int p01 = w.at(static_cast<size_t>((y + 1) * 9 + x));
    int p11 = w.at(static_cast<size_t>((y + 1) * 9 + x + 1));
    return static_cast<uint8_t>(((8 - fx) * (8 - fy) * p00 + fx * (8 - fy) * p10 +
                                 (8 - fx) * fy * p01 + fx * fy * p11 + 32) >> 6);
}

void reset(Sim& s) {
    s.top.reset = 1;
    s.top.idr_start = 0;
    s.top.frame_done = 0;
    s.top.filtered_sample_valid = 0;
    s.top.filtered_mb_valid = 0;
    s.top.filtered_mb_addr = 0;
    s.top.filtered_mb_is_ref = 0;
    s.top.filtered_frame_done = 0;
    s.top.frame_slot_i = 0;
    s.top.frame_boundary = 0;
    s.top.fetch_start = 0;
    s.top.recon_mb_start = 0;
    s.top.recon_mb_x = 0;
    s.top.recon_mb_y = 0;
    s.top.recon_mb_addr = 0;
    s.top.recon_mb_is_ref = 0;
    s.top.recon_mb_is_intra = 0;
    s.top.recon_frame_done = 0;
    s.top.recon_qp_y = 0;
    s.top.recon_qp_c = 0;
    s.top.recon_nz_luma = 0;
    s.top.recon_mv_x = 0;
    s.top.recon_mv_y = 0;
    s.top.recon_ref_idx = 0;
    s.top.recon_sample_valid = 0;
    s.top.recon_sample_idx = 0;
    s.top.recon_sample = 0;
    s.top.recon_sample_done = 0;
    s.top.slice_start = 0;
    s.top.disable_deblocking = 0;
    s.top.slice_alpha_c0_offset = 0;
    s.top.slice_beta_offset = 0;
    s.tick();
    s.tick();
    s.top.reset = 0;
    s.tick();
}

void commitFilteredMb(Sim& s, int mbAddr, bool terminal) {
    s.top.filtered_sample_valid = 0;
    s.top.filtered_mb_valid = 1;
    s.top.filtered_mb_addr = mbAddr;
    s.top.filtered_mb_is_ref = 1;
    s.top.filtered_frame_done = terminal;
    s.top.frame_slot_i = 0;
    s.tick();
    s.top.filtered_mb_valid = 0;
    s.top.filtered_frame_done = 0;
}

int runDeblockDpbSeam(const std::string& nalFixture) {
    int nals = countAnnexBNals(nalFixture);
    if (nals < 2) {
        std::cerr << "FAIL h264_dpb_mc RTL: deblock-DPB seam bench requires >=2 NAL units, got " << nals << "\n";
        return 1;
    }

    Sim s;
    reset(s);
    s.top.filtered_mb_valid = 1;
    s.top.filtered_mb_addr = 0;
    s.top.filtered_mb_is_ref = 1;
    s.top.filtered_frame_done = 0;
    s.tick();
    if (s.top.deblock_wb_valid || !s.top.deblock_commit_order_error || s.top.ref_ready) {
        std::cerr << "FAIL h264_dpb_mc RTL: deblock-DPB seam MB commit before all filtered samples"
                  << " wb=" << int(s.top.deblock_wb_valid)
                  << " order_error=" << int(s.top.deblock_commit_order_error)
                  << " ref_ready=" << int(s.top.ref_ready) << "\n";
        return 1;
    }
    s.top.filtered_mb_valid = 0;
    s.tick();

    for (int i = 0; i < 256; ++i) writeSample(s, 0, 0, 0, i);
    for (int i = 0; i < 64; ++i) writeSample(s, 0, 0, 1, i);
    for (int i = 0; i < 64; ++i) writeSample(s, 0, 0, 2, i);
    commitFilteredMb(s, 0, false);
    if (!s.top.deblock_wb_valid || s.top.deblock_wb_mb_addr != 0 || s.top.ref_ready) {
        std::cerr << "FAIL h264_dpb_mc RTL: deblock-DPB seam nonterminal commit mismatch"
                  << " wb=" << int(s.top.deblock_wb_valid)
                  << " addr=" << int(s.top.deblock_wb_mb_addr)
                  << " ref_ready=" << int(s.top.ref_ready) << "\n";
        return 1;
    }
    s.tick();

    for (int i = 0; i < 256; ++i) writeSample(s, 38, 29, 0, i);
    for (int i = 0; i < 64; ++i) writeSample(s, 38, 29, 1, i);
    for (int i = 0; i < 64; ++i) writeSample(s, 38, 29, 2, i);
    commitFilteredMb(s, 1169, true);
    if (!s.top.deblock_wb_valid || s.top.deblock_wb_mb_addr != 1169 || s.top.ref_ready) {
        std::cerr << "FAIL h264_dpb_mc RTL: deblock-DPB seam terminal commit/ref_ready order"
                  << " wb=" << int(s.top.deblock_wb_valid)
                  << " addr=" << int(s.top.deblock_wb_mb_addr)
                  << " ref_ready=" << int(s.top.ref_ready) << "\n";
        return 1;
    }
    s.top.frame_boundary = 1;
    s.tick();
    s.top.frame_boundary = 0;
    if (!s.top.deblock_ref_ready_pulse || s.top.ref_ready) {
        std::cerr << "FAIL h264_dpb_mc RTL: deblock-DPB seam terminal commit/ref_ready order phase"
                  << " pulse=" << int(s.top.deblock_ref_ready_pulse)
                  << " ref_ready=" << int(s.top.ref_ready) << "\n";
        return 1;
    }
    s.tick();
    if (!s.top.ref_ready || s.top.reference_base != 0 || s.top.current_base != FRAME_BYTES) {
        std::cerr << "FAIL h264_dpb_mc RTL: deblock-DPB seam frame_done before terminal filtered MB commit"
                  << " ref_ready=" << int(s.top.ref_ready)
                  << " ref_base=" << s.top.reference_base
                  << " cur_base=" << s.top.current_base << "\n";
        return 1;
    }

    std::cout << "OK h264_dpb_mc deblock-DPB seam: filtered samples precede wb_valid; "
              << "terminal wb_valid precedes frame_done/ref_ready"
              << " nals=" << nals << " fixture=" << nalFixture << "\n";
    return 0;
}

bool wantLumaValid(int idx, int w, int h) {
    return (idx % 16) < w && (idx / 16) < h;
}

bool wantChromaValid(int idx, int w, int h) {
    return (idx % 8) < (w / 2) && (idx / 8) < (h / 2);
}

void checkPartMc(Sim& s, const std::array<uint8_t, 441>& luma, const std::array<uint8_t, 81>& u,
                 const std::array<uint8_t, 81>& v, int w, int h, int fx, int fy) {
    s.top.fetch_part_w = w;
    s.top.fetch_part_h = h;
    s.top.eval();
    for (int y = 0; y < 16; ++y) {
        for (int x = 0; x < 16; ++x) {
            int idx = y * 16 + x;
            bool valid = wantLumaValid(idx, w, h);
            uint8_t want = valid ? qpel(luma, x, y, fx, fy) : 0;
            if (static_cast<bool>(s.top.pred_y_valid[idx]) != valid || s.top.pred_y[idx] != want) {
                std::cerr << "FAIL h264_dpb_mc RTL: part luma prediction/mask mismatch"
                          << " part=" << w << "x" << h << " idx=" << idx
                          << " valid=" << int(s.top.pred_y_valid[idx]) << " want_valid=" << valid
                          << " got=" << int(s.top.pred_y[idx]) << " want=" << int(want) << "\n";
                throw std::runtime_error("part luma prediction/mask mismatch");
            }
        }
    }
    for (int y = 0; y < 8; ++y) {
        for (int x = 0; x < 8; ++x) {
            int idx = y * 8 + x;
            bool valid = wantChromaValid(idx, w, h);
            uint8_t wantU = valid ? chroma(u, x, y, fx & 7, fy & 7) : 0;
            uint8_t wantV = valid ? chroma(v, x, y, fx & 7, fy & 7) : 0;
            if (static_cast<bool>(s.top.pred_u_valid[idx]) != valid ||
                static_cast<bool>(s.top.pred_v_valid[idx]) != valid ||
                s.top.pred_u[idx] != wantU || s.top.pred_v[idx] != wantV) {
                std::cerr << "FAIL h264_dpb_mc RTL: part chroma prediction/mask mismatch"
                          << " part=" << w << "x" << h << " idx=" << idx
                          << " u_valid=" << int(s.top.pred_u_valid[idx])
                          << " v_valid=" << int(s.top.pred_v_valid[idx])
                          << " want_valid=" << valid
                          << " got=(" << int(s.top.pred_u[idx]) << "," << int(s.top.pred_v[idx])
                          << ") want=(" << int(wantU) << "," << int(wantV) << ")\n";
                throw std::runtime_error("part chroma prediction/mask mismatch");
            }
        }
    }
}


// Filterable vertical edge recon. H.264 only filters when |p0-q0| < alpha(QP)
// and the beta neighbour tests pass. QP=28 → alpha=20, beta=7, so a step of
// 16 with flat sides is filtered (bS=3 internal intra), while 16↔240 is not
// (content edge). Left half 100 / right half 116 is the measurable witness
// that POST-deblock samples diverge from PRE before DPB storage.
uint8_t edgeReconY(int idx) {
    int x = idx & 15;
    return static_cast<uint8_t>(x < 8 ? 100 : 116);
}
uint8_t edgeReconC(int /*idx*/) { return 128; }

void streamReconMb(Sim& s, int mbx, int mby, int mbAddr, bool terminal, bool intra,
                   uint16_t nz, int16_t mvx, int16_t mvy) {
    s.top.recon_mb_start = 1;
    s.top.recon_mb_x = mbx;
    s.top.recon_mb_y = mby;
    s.top.recon_mb_addr = mbAddr;
    s.top.recon_mb_is_ref = 1;
    s.top.recon_mb_is_intra = intra ? 1 : 0;
    s.top.recon_frame_done = terminal ? 1 : 0;
    s.top.recon_qp_y = 28;
    s.top.recon_qp_c = 28;
    s.top.recon_nz_luma = nz;
    s.top.recon_mv_x = mvx;
    s.top.recon_mv_y = mvy;
    s.top.recon_ref_idx = 0;
    s.tick();
    s.top.recon_mb_start = 0;

    for (int i = 0; i < 384; ++i) {
        s.top.recon_sample_valid = 1;
        s.top.recon_sample_idx = i;
        if (i < 256) s.top.recon_sample = edgeReconY(i);
        else s.top.recon_sample = edgeReconC(i);
        s.top.recon_sample_done = (i == 383);
        s.tick();
    }
    s.top.recon_sample_valid = 0;
    s.top.recon_sample_done = 0;

    // Wait for deblock_mb_done (or immediate commit under SKIP fault).
    bool sawDone = false;
    for (int guard = 0; guard < 4000 && !sawDone; ++guard) {
        s.tick();
        sawDone = sawDone || s.top.deblock_mb_done || s.top.deblock_wb_valid;
    }
    if (!sawDone) {
        throw std::runtime_error("ref-commit: deblock/mb commit never completed mb=" +
                                 std::to_string(mbAddr));
    }
    // Drain a few cycles so writeback_ctrl samples settle.
    for (int i = 0; i < 4; ++i) s.tick();
}

int runGenuineRefCommit(const std::string& nalFixture) {
    int nals = countAnnexBNals(nalFixture);
    if (nals < 2) {
        std::cerr << "FAIL h264_dpb_mc RTL: genuine ref-commit requires >=2 NAL units, got "
                  << nals << "\n";
        return 1;
    }

    Sim s;
    reset(s);
    s.top.slice_start = 1;
    s.tick();
    s.top.slice_start = 0;
    s.tick();

    if (s.top.ref_ready) {
        std::cerr << "FAIL h264_dpb_mc RTL: genuine ref-commit early reference before any MB\n";
        return 1;
    }

    // Two adjacent intra MBs with a strong internal vertical edge. MB0 alone
    // filters its internal edge; MB1 filters against MB0's left neighbour so
    // the POST store is a real deblocked reference picture, not a diagnostic
    // XOR pattern.
    std::vector<uint8_t> preSnap(DPB_BYTES, 0xee);
    auto capturePre = [&](int mbx, int mby) {
        for (int i = 0; i < 256; ++i) {
            int x = mbx * 16 + (i & 15);
            int y = mby * 16 + (i >> 4);
            preSnap[i420Addr(0, 0, x, y)] = edgeReconY(i);
        }
        for (int i = 0; i < 64; ++i) {
            int x = mbx * 8 + (i & 7);
            int y = mby * 8 + (i >> 3);
            preSnap[i420Addr(0, 1, x, y)] = edgeReconC(i);
            preSnap[i420Addr(0, 2, x, y)] = edgeReconC(i);
        }
    };
    capturePre(0, 0);
    capturePre(1, 0);

    streamReconMb(s, 0, 0, 0, false, true, 0xFFFF, 0, 0);
    if (s.top.ref_ready || s.top.deblock_ref_ready_pulse) {
        std::cerr << "FAIL h264_dpb_mc RTL: genuine ref-commit promoted before frame boundary"
                  << " ref_ready=" << int(s.top.ref_ready)
                  << " pulse=" << int(s.top.deblock_ref_ready_pulse) << "\n";
        return 1;
    }
    streamReconMb(s, 1, 0, 1, true, true, 0xFFFF, 0, 0);
    if (s.top.ref_ready) {
        std::cerr << "FAIL h264_dpb_mc RTL: genuine ref-commit ref_ready before frame_boundary\n";
        return 1;
    }

    s.top.frame_boundary = 1;
    s.tick();
    s.top.frame_boundary = 0;
    if (!s.top.deblock_ref_ready_pulse) {
        std::cerr << "FAIL h264_dpb_mc RTL: genuine ref-commit missing ref_ready_pulse at boundary\n";
        return 1;
    }
    // One-cycle delayed promote into DPB.
    s.tick();
    s.tick();
    if (!s.top.ref_ready || s.top.reference_base != 0) {
        std::cerr << "FAIL h264_dpb_mc RTL: genuine ref-commit promotion mismatch"
                  << " ref_ready=" << int(s.top.ref_ready)
                  << " ref_base=" << s.top.reference_base << "\n";
        return 1;
    }

    // POST-deblock must differ from PRE on the strong vertical edge columns.
    int edgeDiff = 0;
    for (int y = 0; y < 16; ++y) {
        for (int x : {6, 7, 8, 9}) {
            uint32_t a = i420Addr(0, 0, x, y);
            if (s.mem[a] != preSnap[a]) ++edgeDiff;
        }
    }
    if (edgeDiff < 8) {
        std::cerr << "FAIL h264_dpb_mc RTL: genuine ref-commit stored PRE/unfiltered samples"
                  << " edge_px_changed=" << edgeDiff
                  << " (deblock did not modify the internal vertical edge before DPB write)\n";
        return 1;
    }

    // MC fetch from the promoted POST-deblock reference must return the stored
    // samples (zero-MV integer fetch of MB0).
    s.top.fetch_mb_x = 0;
    s.top.fetch_mb_y = 0;
    s.top.fetch_part_mode = 0;
    s.top.fetch_part_idx = 0;
    s.top.fetch_part_w = 16;
    s.top.fetch_part_h = 16;
    s.top.fetch_mv_x_qpel = 0;
    s.top.fetch_mv_y_qpel = 0;
    s.top.fetch_start = 1;
    s.tick();
    s.top.fetch_start = 0;

    std::array<uint8_t, 441> luma{};
    std::array<bool, 441> lSeen{};
    int lc = 0;
    bool sawDone = false;
    for (int guard = 0; guard < 800 && (lc < 441 || !sawDone); ++guard) {
        s.tick();
        if (s.top.luma_window_valid) {
            int idx = s.top.luma_window_idx;
            // origin (0,0), window offset -2..+18
            int sx = std::clamp((idx % 21) - 2, 0, W - 1);
            int sy = std::clamp((idx / 21) - 2, 0, H - 1);
            uint8_t want = s.mem[i420Addr(0, 0, sx, sy)];
            if (s.top.luma_window_sample != want) {
                std::cerr << "FAIL h264_dpb_mc RTL: genuine ref-commit MC fetch mismatch idx="
                          << idx << " got=" << int(s.top.luma_window_sample)
                          << " want=" << int(want) << " src=(" << sx << "," << sy << ")\n";
                return 1;
            }
            if (!lSeen[static_cast<size_t>(idx)]) {
                lSeen[static_cast<size_t>(idx)] = true;
                ++lc;
            }
            luma[static_cast<size_t>(idx)] = s.top.luma_window_sample;
        }
        sawDone = sawDone || s.top.fetch_done;
    }
    if (lc != 441 || !sawDone) {
        std::cerr << "FAIL h264_dpb_mc RTL: genuine ref-commit incomplete fetch luma="
                  << lc << " done=" << sawDone << "\n";
        return 1;
    }

    // IDR must invalidate.
    s.top.idr_start = 1;
    s.tick();
    s.top.idr_start = 0;
    s.tick();
    if (s.top.ref_ready) {
        std::cerr << "FAIL h264_dpb_mc RTL: genuine ref-commit IDR did not invalidate prior reference\n";
        return 1;
    }
    s.top.fetch_start = 1;
    s.tick();
    s.top.fetch_start = 0;
    if (!s.top.fetch_error_no_ref) {
        std::cerr << "FAIL h264_dpb_mc RTL: genuine ref-commit fetch without ref did not error\n";
        return 1;
    }

    std::cout << "OK h264_dpb_mc genuine ref-commit: recon→deblock→DPB→promote→MC"
              << " edge_px_changed=" << edgeDiff
              << " luma_window=" << lc
              << " reference_picture_state=decoded_deblocked_via_h264_dpb_ref_commit"
              << " nals=" << nals
              << " fixture=" << nalFixture << "\n";
    return 0;
}

} // namespace

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    try {
        bool seamOnly = false;
        bool genuineRef = false;
        std::string nalFixture = "tests/fixtures/p3_inter_pred/plex_inter_p16_baseline_624x480_12f.264";
        for (int i = 1; i < argc; ++i) {
            const std::string arg = argv[i];
            if (arg == "--deblock-dpb-seam")
                seamOnly = true;
            else if (arg == "--genuine-ref-commit")
                genuineRef = true;
            else
                nalFixture = arg;
        }
        if (seamOnly)
            return runDeblockDpbSeam(nalFixture);
        if (genuineRef)
            return runGenuineRefCommit(nalFixture);
        int nals = countAnnexBNals(nalFixture);
        if (nals < 2) {
            std::cerr << "FAIL h264_dpb_mc RTL: bench requires >=2 NAL units, got " << nals << "\n";
            return 1;
        }
        assertDistinctChromaPatterns();

        Sim s;
        reset(s);
        if (s.top.ref_ready) {
            std::cerr << "FAIL h264_dpb_mc RTL: early reference publication before frame boundary\n";
            return 1;
        }

        for (int mby = 0; mby < 2; ++mby) {
            for (int mbx = 0; mbx < 2; ++mbx) {
                for (int i = 0; i < 256; ++i) writeSample(s, mbx, mby, 0, i);
                for (int i = 0; i < 64; ++i) writeSample(s, mbx, mby, 1, i);
                for (int i = 0; i < 64; ++i) writeSample(s, mbx, mby, 2, i);
            }
        }
        s.top.filtered_sample_valid = 0;
        s.tick();
        if (s.top.ref_ready) {
            std::cerr << "FAIL h264_dpb_mc RTL: reference became ready before frame_done\n";
            return 1;
        }

        s.top.frame_done = 1;
        s.tick();
        s.top.frame_done = 0;
        s.tick();
        if (!s.top.ref_ready || s.top.reference_base != 0 || s.top.current_base != FRAME_BYTES) {
            std::cerr << "FAIL h264_dpb_mc RTL: frame-boundary promotion mismatch ref_ready="
                      << int(s.top.ref_ready) << " ref_base=" << s.top.reference_base
                      << " cur_base=" << s.top.current_base << "\n";
            return 1;
        }

        s.top.fetch_mb_x = 0;
        s.top.fetch_mb_y = 0;
        s.top.fetch_part_mode = 0;
        s.top.fetch_part_idx = 0;
        s.top.fetch_part_w = 16;
        s.top.fetch_part_h = 16;
        s.top.fetch_mv_x_qpel = static_cast<int16_t>(-5);
        s.top.fetch_mv_y_qpel = static_cast<int16_t>(-7);
        s.top.fetch_start = 1;
        s.tick();
        s.top.fetch_start = 0;

        std::array<uint8_t, 441> luma{};
        std::array<uint8_t, 81> u{};
        std::array<uint8_t, 81> v{};
        std::array<bool, 441> lSeen{};
        std::array<bool, 81> uSeen{};
        std::array<bool, 81> vSeen{};
        int lc = 0, uc = 0, vc = 0;
        bool sawDone = false;
        for (int guard = 0; guard < 800 && (lc < 441 || uc < 81 || vc < 81 || !sawDone); ++guard) {
            s.tick();
            if (s.top.luma_window_valid) {
                int idx = s.top.luma_window_idx;
                // H.264 8.4.2.1 / 6-tap support: sample at origin + win - 2,
                // with out-of-picture coordinates clamped to the edge sample
                // (not wrapped). origin already includes mb*16 + mv>>2.
                const int ox = static_cast<int16_t>(s.top.luma_origin_x);
                const int oy = static_cast<int16_t>(s.top.luma_origin_y);
                int sx = std::clamp(ox + (idx % 21) - 2, 0, W - 1);
                int sy = std::clamp(oy + (idx / 21) - 2, 0, H - 1);
                uint8_t want = s.mem[i420Addr(0, 0, sx, sy)];
                if (s.top.luma_window_sample != want) {
                    std::cerr << "FAIL h264_dpb_mc RTL: luma window clamp mismatch idx=" << idx
                              << " got=" << int(s.top.luma_window_sample) << " want=" << int(want)
                              << " src=(" << sx << "," << sy << ")\n";
                    return 1;
                }
                if (!lSeen[idx]) { lSeen[idx] = true; ++lc; }
                luma[idx] = s.top.luma_window_sample;
            }
            if (s.top.chroma_u_window_valid || s.top.chroma_v_window_valid) {
                int idx = s.top.chroma_window_idx;
                const int cx0 = static_cast<int16_t>(s.top.chroma_origin_x);
                const int cy0 = static_cast<int16_t>(s.top.chroma_origin_y);
                int sx = std::clamp(cx0 + (idx % 9), 0, CW - 1);
                int sy = std::clamp(cy0 + (idx / 9), 0, CH - 1);
                int plane = s.top.chroma_u_window_valid ? 1 : 2;
                uint8_t want = s.mem[i420Addr(0, plane, sx, sy)];
                if (s.top.chroma_window_sample != want) {
                    std::cerr << "FAIL h264_dpb_mc RTL: chroma window clamp mismatch plane=" << plane
                              << " idx=" << idx << " got=" << int(s.top.chroma_window_sample)
                              << " want=" << int(want) << "\n";
                    return 1;
                }
                if (plane == 1) {
                    if (!uSeen[idx]) { uSeen[idx] = true; ++uc; }
                    u[idx] = s.top.chroma_window_sample;
                } else {
                    if (!vSeen[idx]) { vSeen[idx] = true; ++vc; }
                    v[idx] = s.top.chroma_window_sample;
                }
            }
            sawDone = sawDone || s.top.fetch_done;
        }
        if (lc != 441 || uc != 81 || vc != 81 || !sawDone) {
            std::cerr << "FAIL h264_dpb_mc RTL: incomplete DPB fetch luma=" << lc
                      << " u=" << uc << " v=" << vc << " done=" << sawDone << "\n";
            return 1;
        }
        if (static_cast<int16_t>(s.top.luma_origin_x) != -2 || static_cast<int16_t>(s.top.luma_origin_y) != -2 ||
            static_cast<int16_t>(s.top.chroma_origin_x) != -1 || static_cast<int16_t>(s.top.chroma_origin_y) != -1 ||
            s.top.luma_frac_x != 3 || s.top.luma_frac_y != 1 ||
            s.top.chroma_frac_x != 3 || s.top.chroma_frac_y != 1) {
            std::cerr << "FAIL h264_dpb_mc RTL: MV origin/frac mismatch\n";
            return 1;
        }

        for (int i = 0; i < 441; ++i) s.top.luma_ref_win[i] = luma[i];
        for (int i = 0; i < 81; ++i) {
            s.top.chroma_u_ref_win[i] = u[i];
            s.top.chroma_v_ref_win[i] = v[i];
        }
        s.top.eval();
        for (int y = 0; y < 16; ++y) {
            for (int x = 0; x < 16; ++x) {
                int idx = y * 16 + x;
                uint8_t want = qpel(luma, x, y, 3, 1);
                if (s.top.pred_y[idx] != want) {
                    std::cerr << "FAIL h264_dpb_mc RTL: MC luma prediction mismatch idx=" << idx
                              << " got=" << int(s.top.pred_y[idx]) << " want=" << int(want) << "\n";
                    return 1;
                }
            }
        }
        for (int y = 0; y < 8; ++y) {
            for (int x = 0; x < 8; ++x) {
                int idx = y * 8 + x;
                uint8_t wantU = chroma(u, x, y, 3, 1);
                uint8_t wantV = chroma(v, x, y, 3, 1);
                if (s.top.pred_u[idx] != wantU || s.top.pred_v[idx] != wantV) {
                    std::cerr << "FAIL h264_dpb_mc RTL: MC chroma prediction mismatch idx=" << idx
                              << " got=(" << int(s.top.pred_u[idx]) << "," << int(s.top.pred_v[idx])
                              << ") want=(" << int(wantU) << "," << int(wantV) << ")\n";
                    return 1;
                }
            }
        }
        checkPartMc(s, luma, u, v, 16, 8, 3, 1);
        checkPartMc(s, luma, u, v, 8, 16, 3, 1);
        checkPartMc(s, luma, u, v, 8, 8, 3, 1);
        checkPartMc(s, luma, u, v, 8, 4, 3, 1);
        checkPartMc(s, luma, u, v, 4, 8, 3, 1);
        checkPartMc(s, luma, u, v, 4, 4, 3, 1);

        auto edgeSentinel = [](int plane, int x, int y) {
            return static_cast<uint8_t>(1 + plane * 80 + (x & 7) * 9 + (y & 7));
        };
        for (int y = H - 4; y < H; ++y) {
            for (int x = W - 4; x < W; ++x) {
                s.mem[i420Addr(0, 0, x, y)] = edgeSentinel(0, x, y);
            }
        }
        for (int y = CH - 4; y < CH; ++y) {
            for (int x = CW - 4; x < CW; ++x) {
                s.mem[i420Addr(0, 1, x, y)] = edgeSentinel(1, x, y);
                s.mem[i420Addr(0, 2, x, y)] = edgeSentinel(2, x, y);
            }
        }
        s.top.fetch_mb_x = static_cast<uint16_t>(W / 16 - 1);
        s.top.fetch_mb_y = static_cast<uint16_t>(H / 16 - 1);
        s.top.fetch_part_mode = 0;
        s.top.fetch_part_idx = 0;
        s.top.fetch_part_w = 16;
        s.top.fetch_part_h = 16;
        s.top.fetch_mv_x_qpel = static_cast<int16_t>(20);
        s.top.fetch_mv_y_qpel = static_cast<int16_t>(20);
        s.top.fetch_start = 1;
        s.tick();
        s.top.fetch_start = 0;

        int upperLc = 0, upperUc = 0, upperVc = 0;
        std::array<bool, 441> upperLSeen{};
        std::array<bool, 81> upperUSeen{};
        std::array<bool, 81> upperVSeen{};
        bool upperDone = false;
        const int upperLumaOriginX = (W / 16 - 1) * 16 + (20 >> 2);
        const int upperLumaOriginY = (H / 16 - 1) * 16 + (20 >> 2);
        const int upperChromaOriginX = (W / 16 - 1) * 8 + (20 >> 3);
        const int upperChromaOriginY = (H / 16 - 1) * 8 + (20 >> 3);
        for (int guard = 0; guard < 800 && (upperLc < 441 || upperUc < 81 || upperVc < 81 || !upperDone); ++guard) {
            s.tick();
            if (s.top.luma_window_valid) {
                int idx = s.top.luma_window_idx;
                int sx = std::clamp(upperLumaOriginX + (idx % 21) - 2, 0, W - 1);
                int sy = std::clamp(upperLumaOriginY + (idx / 21) - 2, 0, H - 1);
                uint8_t want = s.mem[i420Addr(0, 0, sx, sy)];
                if (s.top.luma_window_sample != want) {
                    std::cerr << "FAIL h264_dpb_mc RTL: upper luma window clamp mismatch idx=" << idx
                              << " got=" << int(s.top.luma_window_sample) << " want=" << int(want)
                              << " src=(" << sx << "," << sy << ")\n";
                    return 1;
                }
                if (!upperLSeen[idx]) { upperLSeen[idx] = true; ++upperLc; }
            }
            if (s.top.chroma_u_window_valid || s.top.chroma_v_window_valid) {
                int idx = s.top.chroma_window_idx;
                int sx = std::clamp(upperChromaOriginX + (idx % 9), 0, CW - 1);
                int sy = std::clamp(upperChromaOriginY + (idx / 9), 0, CH - 1);
                int plane = s.top.chroma_u_window_valid ? 1 : 2;
                uint8_t want = s.mem[i420Addr(0, plane, sx, sy)];
                if (s.top.chroma_window_sample != want) {
                    std::cerr << "FAIL h264_dpb_mc RTL: upper chroma window clamp mismatch plane=" << plane
                              << " idx=" << idx << " got=" << int(s.top.chroma_window_sample)
                              << " want=" << int(want) << "\n";
                    return 1;
                }
                if (plane == 1) {
                    if (!upperUSeen[idx]) { upperUSeen[idx] = true; ++upperUc; }
                } else {
                    if (!upperVSeen[idx]) { upperVSeen[idx] = true; ++upperVc; }
                }
            }
            upperDone = upperDone || s.top.fetch_done;
        }
        if (upperLc != 441 || upperUc != 81 || upperVc != 81 || !upperDone) {
            std::cerr << "FAIL h264_dpb_mc RTL: incomplete upper-bound DPB fetch luma=" << upperLc
                      << " u=" << upperUc << " v=" << upperVc << " done=" << upperDone << "\n";
            return 1;
        }

        s.top.idr_start = 1;
        s.tick();
        s.top.idr_start = 0;
        s.tick();
        if (s.top.ref_ready) {
            std::cerr << "FAIL h264_dpb_mc RTL: IDR did not invalidate prior reference\n";
            return 1;
        }
        s.top.fetch_start = 1;
        s.tick();
        s.top.fetch_start = 0;
        if (!s.top.fetch_error_no_ref) {
            std::cerr << "FAIL h264_dpb_mc RTL: fetch without reference did not raise error\n";
            return 1;
        }

        std::cout << "OK real RTL sim: h264_dpb_mc product RTL"
                  << " nals=" << nals
                  << " i420_writes=" << (4 * (256 + 64 + 64))
                  << " luma_window=" << lc
                  << " chroma_windows=" << uc << "/" << vc
                  << " mc_pixels=256/64/64"
                  << " part_modes=16x8/8x16/8x8/8x4/4x8/4x4"
                  << " fixture=" << nalFixture << "\n";
        return 0;
    } catch (const std::exception& e) {
        std::cerr << "FAIL h264_dpb_mc RTL: " << e.what() << "\n";
        return 1;
    }
}
