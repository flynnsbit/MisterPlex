#include "Vh264_decode_core_p16z_tb.h"
#include "verilated.h"

#include <algorithm>
#include <cstdint>
#include <iostream>
#include <string>
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
constexpr int kMeasuredP16RealPCycles = 86806;
constexpr int kP16RealPTimeoutCycles = (kMeasuredP16RealPCycles * 17 + 9) / 10;

constexpr int kScheduledLumaBlocks = 16;
constexpr int kScheduledBlocks = kScheduledLumaBlocks;

int residualBlockSample(int mbIdx, int block, int pos) {
    static constexpr int kScan14[16] = {19, 11, -5, -13, 19, 11, -5, -13,
                                        19, 11, -5, -13, 19, 11, -5, -13};
    static constexpr int kScan11[16] = {7, 5, 1, -1, 7, 5, 1, -1,
                                        7, 5, 1, -1, 7, 5, 1, -1};
    static constexpr int kHighClamp[16] = {264, 262, 258, 256, 264, 262, 258, 256,
                                           264, 262, 258, 256, 264, 262, 258, 256};
    if (mbIdx == 1 && block == 0) return kHighClamp[pos];
    return (block & 1) ? kScan11[pos] : kScan14[pos];
}

const char* residualBlockBits(int mbIdx, int block) {
    if (mbIdx == 1 && block == 0) return "00010000000000000000001000001111110111"; // scan coeffs [80, 1]
    return (block & 1) ? "00100111" : "0000011100001100111"; // scan coeffs [1,1] or [1,4]
}

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
    {1, 0, 2, 0, 0, 0, 2, 0, 296, 0},
    {2, 0, 3, 0, 2, 0, 5, 0, 400, 48},
};

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
        if (block < kScheduledLumaBlocks) {
            const int pos = (sy & 3) * 4 + (sx & 3);
            return residualBlockSample(mbIdx, block, pos);
        }
    }
    return 0;
}

uint8_t clipU8(int value) {
    if (value < 0) return 0;
    if (value > 255) return 255;
    return static_cast<uint8_t>(value);
}

int hraw(const uint8_t ref[9][9], int row, int col) {
    return ref[row][col - 2] - 5 * ref[row][col - 1] + 20 * ref[row][col] +
           20 * ref[row][col + 1] - 5 * ref[row][col + 2] + ref[row][col + 3];
}

int clip1(int v) { return clampInt(v, 0, 255); }
int avg2(int a, int b) { return (a + b + 1) >> 1; }
int halfH(const uint8_t ref[9][9], int rowoff, int coloff) { return clip1((hraw(ref, 4 + rowoff, 4 + coloff) + 16) >> 5); }
int halfV(const uint8_t ref[9][9], int rowoff, int coloff) {
    const int col = 4 + coloff;
    return clip1((ref[2 + rowoff][col] - 5 * ref[3 + rowoff][col] + 20 * ref[4 + rowoff][col] +
                  20 * ref[5 + rowoff][col] - 5 * ref[6 + rowoff][col] + ref[7 + rowoff][col] + 16) >> 5);
}
int halfC(const uint8_t ref[9][9], int rowoff, int coloff) {
    const int row = 4 + rowoff;
    const int col = 4 + coloff;
    const int sum = hraw(ref, row - 2, col) - 5 * hraw(ref, row - 1, col) +
                    20 * hraw(ref, row, col) + 20 * hraw(ref, row + 1, col) -
                    5 * hraw(ref, row + 2, col) + hraw(ref, row + 3, col);
    return clip1((sum + 512) >> 10);
}

uint8_t lumaPred(const MbCase& mb, int sampleIdx) {
    const int sx = sampleIdx & 15;
    const int sy = sampleIdx >> 4;
    const int baseX = mb.mbX * 16 + sx + (mb.mvX >> 2);
    const int baseY = mb.mbY * 16 + sy + (mb.mvY >> 2);
    uint8_t ref[9][9]{};
    for (int r = 0; r < 9; ++r) {
        for (int c = 0; c < 9; ++c) ref[r][c] = refSample(0, baseX + c - 4, baseY + r - 4);
    }
    const int fx = mb.mvX & 3;
    const int fy = mb.mvY & 3;
    switch ((fy << 2) | fx) {
    case 0x0: return ref[4][4];
    case 0x1: return avg2(ref[4][4], halfH(ref, 0, 0));
    case 0x2: return halfH(ref, 0, 0);
    case 0x3: return avg2(halfH(ref, 0, 0), ref[4][5]);
    case 0x4: return avg2(ref[4][4], halfV(ref, 0, 0));
    case 0x5: return avg2(halfH(ref, 0, 0), halfV(ref, 0, 0));
    case 0x6: return avg2(halfH(ref, 0, 0), halfC(ref, 0, 0));
    case 0x7: return avg2(halfH(ref, 0, 0), halfV(ref, 0, 1));
    case 0x8: return halfV(ref, 0, 0);
    case 0x9: return avg2(halfV(ref, 0, 0), halfC(ref, 0, 0));
    case 0xa: return halfC(ref, 0, 0);
    case 0xb: return avg2(halfC(ref, 0, 0), halfV(ref, 0, 1));
    case 0xc: return avg2(halfV(ref, 0, 0), ref[5][4]);
    case 0xd: return avg2(halfH(ref, 1, 0), halfV(ref, 0, 0));
    case 0xe: return avg2(halfC(ref, 0, 0), halfH(ref, 1, 0));
    default: return avg2(halfH(ref, 1, 0), halfV(ref, 0, 1));
    }
}

uint8_t chromaPred(const MbCase& mb, int sampleIdx) {
    const int plane = (sampleIdx < 320) ? 1 : 2;
    const int rel = (sampleIdx < 320) ? sampleIdx - 256 : sampleIdx - 320;
    const int sx = rel & 7;
    const int sy = rel >> 3;
    const int baseX = mb.mbX * 8 + sx + (mb.mvX >> 3);
    const int baseY = mb.mbY * 8 + sy + (mb.mvY >> 3);
    const int fx = mb.mvX & 7;
    const int fy = mb.mvY & 7;
    const int p00 = refSample(plane, baseX, baseY);
    const int p10 = refSample(plane, baseX + 1, baseY);
    const int p01 = refSample(plane, baseX, baseY + 1);
    const int p11 = refSample(plane, baseX + 1, baseY + 1);
    const int sum = (8 - fx) * (8 - fy) * p00 + fx * (8 - fy) * p10 +
                    (8 - fx) * fy * p01 + fx * fy * p11 + 32;
    return static_cast<uint8_t>(sum >> 6);
}

uint8_t predSample(const MbCase& mb, int idx) { return (idx < 256) ? lumaPred(mb, idx) : chromaPred(mb, idx); }
uint8_t expectedRecon(int mbIdx, const MbCase& mb, int localIdx) { return clipU8(predSample(mb, localIdx) + residualSample(mbIdx, localIdx)); }

bool checkResidualFixture() {
    int nonzero = 0;
    int positionDependent = 0;
    for (int mb = 0; mb < static_cast<int>(kCases.size()); ++mb) {
        for (int block = 0; block < kScheduledBlocks; ++block) {
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
              << " scheduled luma CAVLC blocks are nonzero and position-dependent; nonzero_samples="
              << nonzero << " uv_ref_distinguishable_samples=" << uvDiff
              << " scan_order_sentinel=19/11\n";
    return true;
}

std::size_t readsPerMb() { return 256 * 81 + 128 * 4; }
std::size_t expectedReadCount() { return readsPerMb() * kCases.size(); }

uint32_t expectedReadAddr(const MbCase& mb, int localOrdinal) {
    int idx = 0;
    int tap = 0;
    int cur = 0;
    for (idx = 0; idx < 384; ++idx) {
        const int taps = (idx < 256) ? 81 : 4;
        if (localOrdinal < cur + taps) {
            tap = localOrdinal - cur;
            break;
        }
        cur += taps;
    }
    if (idx >= 384) return 0;
    if (idx < 256) {
        const int sx = idx & 15;
        const int sy = idx >> 4;
        const int col = tap % 9;
        const int row = tap / 9;
        const int x = clampInt(mb.mbX * 16 + sx + (mb.mvX >> 2) + col - 4, 0, FRAME_W - 1);
        const int y = clampInt(mb.mbY * 16 + sy + (mb.mvY >> 2) + row - 4, 0, FRAME_H - 1);
        return i420Addr(REF_BASE, 0, x, y);
    }
    const int plane = (idx < 320) ? 1 : 2;
    const int rel = (idx < 320) ? idx - 256 : idx - 320;
    const int sx = rel & 7;
    const int sy = rel >> 3;
    const int x = clampInt(mb.mbX * 8 + sx + (mb.mvX >> 3) + (tap & 1), 0, C_W - 1);
    const int y = clampInt(mb.mbY * 8 + sy + (mb.mvY >> 3) + ((tap >> 1) & 1), 0, C_H - 1);
    return i420Addr(REF_BASE, plane, x, y);
}

uint32_t expectedReadAddrForOrdinal(std::size_t ord) {
    const std::size_t mbIdx = ord / readsPerMb();
    const int localOrdinal = static_cast<int>(ord % readsPerMb());
    return expectedReadAddr(kCases.at(mbIdx), localOrdinal);
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

void loadScheduledResidualRbsp(Sim& s) {
    auto putBits = [&](int bitOffset, const char* bits) {
        for (int i = 0; bits[i] != '\0'; ++i) {
            if (bits[i] == '1') s.top.rbsp_byte_in[(bitOffset + i) >> 3] |= 1u << (7 - ((bitOffset + i) & 7));
        }
    };
    for (std::size_t mbIdx = 0; mbIdx < kCases.size(); ++mbIdx) {
        const MbCase& mb = kCases.at(mbIdx);
        int bitOffset = mb.residualBitOffset - mb.rbspWindowBase * 8;
        for (int block = 0; block < kScheduledBlocks; ++block) {
            const char* bits = residualBlockBits(static_cast<int>(mbIdx), block);
            putBits(bitOffset, bits);
            bitOffset += static_cast<int>(std::string(bits).size());
        }
    }
}

void reset(Sim& s) {
    clearInputs(s);
    loadScheduledResidualRbsp(s);
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
    for (std::size_t i = 0; i < s.reads.size(); ++i) {
        const uint32_t wantReadAddr = expectedReadAddrForOrdinal(i);
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
    std::cout << "OK h264_decode_core p16x16 real-P scoreboard: 2 MBs syntax+MV-neighbor+CAVLC-residual path "
              << "384x2 exact clipped pred+16Y scheduled-residual samples landed at DPB addresses; reads="
              << s.reads.size() << " clipped_samples=" << clipped
              << " clip_low=" << clipLow << " clip_high=" << clipHigh
              << " rbsp_request_offsets=" << s.rbspRequests.at(0) << "/" << s.rbspRequests.at(1)
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
