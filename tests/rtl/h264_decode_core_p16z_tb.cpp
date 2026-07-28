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
constexpr int TEST_MB_X = 1;
constexpr int TEST_MB_Y = 0;
constexpr int MV_X_QPEL = 2;
constexpr int MV_Y_QPEL = 0;
constexpr int kMeasuredP16RealPCycles = 42884;
constexpr int kP16RealPTimeoutCycles = (kMeasuredP16RealPCycles * 17 + 9) / 10;

struct Write {
    uint32_t addr = 0;
    uint8_t data = 0;
};

uint32_t i420Addr(uint32_t base, int plane, int x, int y) {
    if (plane == 0) return base + static_cast<uint32_t>(y * FRAME_W + x);
    if (plane == 1) return base + Y_BYTES + static_cast<uint32_t>(y * C_W + x);
    return base + Y_BYTES + C_BYTES + static_cast<uint32_t>(y * C_W + x);
}

uint32_t expectedWriteAddr(int mbX, int mbY, int idx) {
    if (idx < 256) {
        const int sx = idx & 15;
        const int sy = idx >> 4;
        return i420Addr(WRITE_BASE, 0, mbX * 16 + sx, mbY * 16 + sy);
    }
    if (idx < 320) {
        const int rel = idx - 256;
        const int sx = rel & 7;
        const int sy = rel >> 3;
        return i420Addr(WRITE_BASE, 1, mbX * 8 + sx, mbY * 8 + sy);
    }
    const int rel = idx - 320;
    const int sx = rel & 7;
    const int sy = rel >> 3;
    return i420Addr(WRITE_BASE, 2, mbX * 8 + sx, mbY * 8 + sy);
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

int residualSample(int idx) {
    if (idx == 0) return 19;
    int r = ((idx * 7) % 43) - 21;
    if (r == 0) r = 11;
    if (idx == 5) r = 35;
    if (idx == 6) r = -35;
    return r;
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

uint8_t lumaPred(int sampleIdx, int mvX, int mvY) {
    const int sx = sampleIdx & 15;
    const int sy = sampleIdx >> 4;
    const int baseX = TEST_MB_X * 16 + sx + (mvX >> 2);
    const int baseY = TEST_MB_Y * 16 + sy + (mvY >> 2);
    uint8_t ref[9][9]{};
    for (int r = 0; r < 9; ++r) {
        for (int c = 0; c < 9; ++c) ref[r][c] = refSample(0, baseX + c - 4, baseY + r - 4);
    }
    const int fx = mvX & 3;
    const int fy = mvY & 3;
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

uint8_t chromaPred(int sampleIdx, int mvX, int mvY) {
    const int plane = (sampleIdx < 320) ? 1 : 2;
    const int rel = (sampleIdx < 320) ? sampleIdx - 256 : sampleIdx - 320;
    const int sx = rel & 7;
    const int sy = rel >> 3;
    const int baseX = TEST_MB_X * 8 + sx + (mvX >> 3);
    const int baseY = TEST_MB_Y * 8 + sy + (mvY >> 3);
    const int fx = mvX & 7;
    const int fy = mvY & 7;
    const int p00 = refSample(plane, baseX, baseY);
    const int p10 = refSample(plane, baseX + 1, baseY);
    const int p01 = refSample(plane, baseX, baseY + 1);
    const int p11 = refSample(plane, baseX + 1, baseY + 1);
    const int sum = (8 - fx) * (8 - fy) * p00 + fx * (8 - fy) * p10 +
                    (8 - fx) * fy * p01 + fx * fy * p11 + 32;
    return static_cast<uint8_t>(sum >> 6);
}

uint8_t predSample(int idx, int mvX = MV_X_QPEL, int mvY = MV_Y_QPEL) {
    return (idx < 256) ? lumaPred(idx, mvX, mvY) : chromaPred(idx, mvX, mvY);
}

uint8_t expectedRecon(int idx) { return clipU8(predSample(idx) + residualSample(idx)); }

uint32_t expectedReadAddrForOrdinal(std::size_t ord) {
    int idx = 0;
    int tap = 0;
    std::size_t cur = 0;
    for (idx = 0; idx < 384; ++idx) {
        const int taps = (idx < 256) ? 81 : 4;
        if (ord < cur + static_cast<std::size_t>(taps)) {
            tap = static_cast<int>(ord - cur);
            break;
        }
        cur += static_cast<std::size_t>(taps);
    }
    if (idx >= 384) return 0;
    if (idx < 256) {
        const int sx = idx & 15;
        const int sy = idx >> 4;
        const int col = tap % 9;
        const int row = tap / 9;
        const int x = clampInt(TEST_MB_X * 16 + sx + (MV_X_QPEL >> 2) + col - 4, 0, FRAME_W - 1);
        const int y = clampInt(TEST_MB_Y * 16 + sy + (MV_Y_QPEL >> 2) + row - 4, 0, FRAME_H - 1);
        return i420Addr(REF_BASE, 0, x, y);
    }
    const int plane = (idx < 320) ? 1 : 2;
    const int rel = (idx < 320) ? idx - 256 : idx - 320;
    const int sx = rel & 7;
    const int sy = rel >> 3;
    const int x = clampInt(TEST_MB_X * 8 + sx + (MV_X_QPEL >> 3) + (tap & 1), 0, C_W - 1);
    const int y = clampInt(TEST_MB_Y * 8 + sy + (MV_Y_QPEL >> 3) + ((tap >> 1) & 1), 0, C_H - 1);
    return i420Addr(REF_BASE, plane, x, y);
}

std::size_t expectedReadCount() { return 256 * 81 + 128 * 4; }

class Sim {
public:
    Vh264_decode_core_p16z_tb top{};
    uint64_t cycles = 0;
    std::vector<uint32_t> reads;
    std::vector<Write> writes;
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
    s.top.p16_zero_mv_valid = 0;
    s.top.p16_mb_x = 0;
    s.top.p16_mb_y = 0;
    s.top.p16_mb_is_ref = 0;
    s.top.dpb_ref_base = REF_BASE;
    s.top.dpb_write_base = WRITE_BASE;
    s.top.p16_mv_x_qpel = MV_X_QPEL;
    s.top.p16_mv_y_qpel = MV_Y_QPEL;
    s.top.dpb_rd_valid = 0;
    s.top.dpb_rd_data = 0;
    for (int i = 0; i < 256; ++i) s.top.p16_residual_y[i] = 0;
    for (int i = 0; i < 64; ++i) {
        s.top.p16_residual_u[i] = 0;
        s.top.p16_residual_v[i] = 0;
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

void driveP16(Sim& s) {
    for (int i = 0; i < 256; ++i) s.top.p16_residual_y[i] = residualSample(i);
    for (int i = 0; i < 64; ++i) {
        s.top.p16_residual_u[i] = residualSample(256 + i);
        s.top.p16_residual_v[i] = residualSample(320 + i);
    }
    s.top.p16_mb_x = TEST_MB_X;
    s.top.p16_mb_y = TEST_MB_Y;
    s.top.p16_mb_is_ref = 1;
    s.top.dpb_ref_base = REF_BASE;
    s.top.dpb_write_base = WRITE_BASE;
    s.top.p16_mv_x_qpel = MV_X_QPEL;
    s.top.p16_mv_y_qpel = MV_Y_QPEL;
    s.top.p16_zero_mv_valid = 1;
    s.tick();
    s.top.p16_zero_mv_valid = 0;
}

bool waitForIdle(Sim& s) {
    for (int i = 0; i < kP16RealPTimeoutCycles; ++i) {
        if (!s.top.busy && s.writes.size() >= 384) return true;
        s.tick();
    }
    return !s.top.busy && s.writes.size() >= 384;
}

int checkScoreboard(const Sim& s) {
    const std::size_t wantReads = expectedReadCount();
    if (s.reads.size() != wantReads) {
        std::cerr << "FAIL h264_decode_core p16x16 real-P scoreboard: mb=(1,0) read count "
                  << s.reads.size() << " want=" << wantReads << "\n";
        return 1;
    }
    if (s.writes.size() != 384) {
        std::cerr << "FAIL h264_decode_core p16x16 real-P scoreboard: mb=(1,0) write count "
                  << s.writes.size() << " want=384\n";
        return 1;
    }
    for (std::size_t i = 0; i < s.reads.size(); ++i) {
        const uint32_t wantReadAddr = expectedReadAddrForOrdinal(i);
        if (s.reads.at(i) != wantReadAddr) {
            std::cerr << "FAIL h264_decode_core p16x16 real-P scoreboard: mb=(1,0) read_ordinal " << i
                      << " got_addr=0x" << std::hex << s.reads.at(i)
                      << " want_addr=0x" << wantReadAddr << std::dec << "\n";
            return 1;
        }
    }
    int clipped = 0;
    for (int i = 0; i < 384; ++i) {
        const Write& w = s.writes.at(i);
        const uint32_t wantWriteAddr = expectedWriteAddr(TEST_MB_X, TEST_MB_Y, i);
        if (w.addr != wantWriteAddr) {
            std::cerr << "FAIL h264_decode_core p16x16 real-P scoreboard: mb=(1,0) write sample " << i
                      << " plane=" << planeName(i)
                      << " got_addr=0x" << std::hex << w.addr
                      << " want_addr=0x" << wantWriteAddr << std::dec << "\n";
            return 1;
        }
        const int pred = predSample(i);
        const int residual = residualSample(i);
        const uint8_t want = clipU8(pred + residual);
        if (pred + residual < 0 || pred + residual > 255) ++clipped;
        if (w.data != want) {
            std::cerr << "FAIL h264_decode_core p16x16 real-P scoreboard: mb=(1,0) sample " << i
                      << " plane=" << planeName(i)
                      << " got=" << int(w.data)
                      << " want=" << int(want)
                      << " pred=" << pred
                      << " residual=" << residual << "\n";
            return 1;
        }
    }
    if (s.frameDoneSeen) {
        std::cerr << "FAIL h264_decode_core p16x16 real-P scoreboard: mb=(1,0) nonterminal frame_done asserted\n";
        return 1;
    }
    if (s.top.frame_mb_count != 1) {
        std::cerr << "FAIL h264_decode_core p16x16 real-P scoreboard: mb=(1,0) frame_mb_count="
                  << int(s.top.frame_mb_count) << " want=1\n";
        return 1;
    }
    if (clipped < 2) {
        std::cerr << "FAIL h264_decode_core p16x16 real-P scoreboard: mb=(1,0) clipped_samples="
                  << clipped << " want>=2\n";
        return 1;
    }
    std::cout << "OK h264_decode_core p16x16 real-P scoreboard: mb=(1,0) mv_qpel=(2,0) "
              << "384 exact clipped pred+residual samples landed at DPB addresses; reads="
              << s.reads.size() << " clipped_samples=" << clipped
              << " cycles=" << s.cycles << " timeout_cycles=" << kP16RealPTimeoutCycles
              << "; nonterminal frame_done stayed low\n";
    return 0;
}

} // namespace

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);

    Sim s;
    reset(s);
    driveP16(s);
    if (!waitForIdle(s)) {
        std::cerr << "FAIL h264_decode_core p16x16 real-P scoreboard: mb=(1,0) did not return idle\n";
        return 1;
    }
    return checkScoreboard(s);
}
