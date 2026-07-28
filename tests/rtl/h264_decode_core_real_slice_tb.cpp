#include "Vh264_decode_core_p16z_tb.h"
#include "verilated.h"

#include <algorithm>
#include <cstdint>
#include <cstdlib>
#include <fstream>
#include <iostream>
#include <string>
#include <vector>

namespace {

constexpr int FRAME_W = 624;
constexpr int FRAME_H = 480;
constexpr int MB_W = FRAME_W / 16;
constexpr int MB_H = FRAME_H / 16;
constexpr int Y_BYTES = FRAME_W * FRAME_H;
constexpr int C_W = FRAME_W / 2;
constexpr int C_H = FRAME_H / 2;
constexpr int C_BYTES = C_W * C_H;
constexpr int FRAME_BYTES = Y_BYTES + 2 * C_BYTES;
constexpr int kExpectedFrames = 8;
constexpr int kLumaWinSamples = 21 * 21;
constexpr int kChromaWinSamples = 9 * 9;
constexpr int kReadsPerMb = kLumaWinSamples + 2 * kChromaWinSamples;
constexpr uint32_t REF_BASE = 0x4000;
constexpr uint32_t WRITE_BASE = 0x1000;
constexpr int kTimeoutCycles = 70000;

struct Write { uint32_t addr = 0; uint8_t data = 0; };
struct Case { int ref = 0; int target = 1; int mbX = 0; int mbY = 0; std::string label; };

int clampInt(int v, int lo, int hi) { return std::max(lo, std::min(v, hi)); }

std::vector<uint8_t> readFile(const char* path) {
    std::ifstream f(path, std::ios::binary);
    if (!f) throw std::runtime_error(std::string("open failed: ") + path);
    return std::vector<uint8_t>((std::istreambuf_iterator<char>(f)), std::istreambuf_iterator<char>());
}

class Slice {
public:
    explicit Slice(std::vector<uint8_t> bytes) : data(std::move(bytes)) {}
    uint8_t sample(int frame, int plane, int x, int y) const {
        x = clampInt(x, 0, plane == 0 ? FRAME_W - 1 : C_W - 1);
        y = clampInt(y, 0, plane == 0 ? FRAME_H - 1 : C_H - 1);
        const std::size_t base = static_cast<std::size_t>(frame) * FRAME_BYTES;
        if (plane == 0) return data.at(base + y * FRAME_W + x);
        if (plane == 1) return data.at(base + Y_BYTES + y * C_W + x);
        return data.at(base + Y_BYTES + C_BYTES + y * C_W + x);
    }
    int frames() const { return static_cast<int>(data.size() / FRAME_BYTES); }
private:
    std::vector<uint8_t> data;
};

uint32_t i420Addr(uint32_t base, int plane, int x, int y) {
    if (plane == 0) return base + static_cast<uint32_t>(y * FRAME_W + x);
    if (plane == 1) return base + Y_BYTES + static_cast<uint32_t>(y * C_W + x);
    return base + Y_BYTES + C_BYTES + static_cast<uint32_t>(y * C_W + x);
}

uint8_t refFromAddr(const Slice& slice, const Case& c, uint32_t addr) {
    const uint32_t off = addr - REF_BASE;
    if (off < Y_BYTES) return slice.sample(c.ref, 0, off % FRAME_W, off / FRAME_W);
    if (off < Y_BYTES + C_BYTES) {
        const uint32_t p = off - Y_BYTES;
        return slice.sample(c.ref, 1, p % C_W, p / C_W);
    }
    const uint32_t p = off - Y_BYTES - C_BYTES;
    return slice.sample(c.ref, 2, p % C_W, p / C_W);
}

// Block MC fetches one 21x21 luma reference window plus one 9x9 window per
// chroma plane per macroblock; these cases are zero-MV so the window origin is
// the macroblock origin minus the 2-sample qpel margin (luma) / 0 (chroma).
uint32_t expectedReadAddr(const Case& c, int localOrdinal) {
    if (localOrdinal < kLumaWinSamples) {
        const int x = clampInt(c.mbX * 16 + (localOrdinal % 21) - 2, 0, FRAME_W - 1);
        const int y = clampInt(c.mbY * 16 + (localOrdinal / 21) - 2, 0, FRAME_H - 1);
        return i420Addr(REF_BASE, 0, x, y);
    }
    const bool isU = localOrdinal < kLumaWinSamples + kChromaWinSamples;
    const int rel = isU ? localOrdinal - kLumaWinSamples
                        : localOrdinal - kLumaWinSamples - kChromaWinSamples;
    const int plane = isU ? 1 : 2;
    const int x = clampInt(c.mbX * 8 + (rel % 9), 0, C_W - 1);
    const int y = clampInt(c.mbY * 8 + (rel / 9), 0, C_H - 1);
    return i420Addr(REF_BASE, plane, x, y);
}

uint32_t expectedWriteAddr(const Case& c, int idx) {
    if (idx < 256) return i420Addr(WRITE_BASE, 0, c.mbX * 16 + (idx & 15), c.mbY * 16 + (idx >> 4));
    if (idx < 320) {
        const int rel = idx - 256;
        return i420Addr(WRITE_BASE, 1, c.mbX * 8 + (rel & 7), c.mbY * 8 + (rel >> 3));
    }
    const int rel = idx - 320;
    return i420Addr(WRITE_BASE, 2, c.mbX * 8 + (rel & 7), c.mbY * 8 + (rel >> 3));
}

uint8_t targetSample(const Slice& slice, const Case& c, int idx) {
    if (idx < 256) return slice.sample(c.target, 0, c.mbX * 16 + (idx & 15), c.mbY * 16 + (idx >> 4));
    if (idx < 320) {
        const int rel = idx - 256;
        return slice.sample(c.target, 1, c.mbX * 8 + (rel & 7), c.mbY * 8 + (rel >> 3));
    }
    const int rel = idx - 320;
    return slice.sample(c.target, 2, c.mbX * 8 + (rel & 7), c.mbY * 8 + (rel >> 3));
}

uint8_t refCenterSample(const Slice& slice, const Case& c, int idx) {
    if (idx < 256) return slice.sample(c.ref, 0, c.mbX * 16 + (idx & 15), c.mbY * 16 + (idx >> 4));
    if (idx < 320) {
        const int rel = idx - 256;
        return slice.sample(c.ref, 1, c.mbX * 8 + (rel & 7), c.mbY * 8 + (rel >> 3));
    }
    const int rel = idx - 320;
    return slice.sample(c.ref, 2, c.mbX * 8 + (rel & 7), c.mbY * 8 + (rel >> 3));
}

int residualNonzero(const Slice& slice, const Case& c) {
    int n = 0;
    for (int i = 0; i < 384; ++i) n += targetSample(slice, c, i) != refCenterSample(slice, c, i);
    return n;
}

int uvDistinct(const Slice& slice, const Case& c) {
    int n = 0;
    for (int i = 0; i < 64; ++i) {
        const int sx = i & 7;
        const int sy = i >> 3;
        n += slice.sample(c.target, 1, c.mbX * 8 + sx, c.mbY * 8 + sy) !=
             slice.sample(c.target, 2, c.mbX * 8 + sx, c.mbY * 8 + sy);
    }
    return n;
}

bool chromaRightClampRead(const Case& c, int localOrdinal) {
    if (localOrdinal < kLumaWinSamples) return false;
    const bool isU = localOrdinal < kLumaWinSamples + kChromaWinSamples;
    const int rel = isU ? localOrdinal - kLumaWinSamples
                        : localOrdinal - kLumaWinSamples - kChromaWinSamples;
    return c.mbX * 8 + (rel % 9) > C_W - 1;
}

Case chooseVaried(const Slice& slice) {
    Case best{};
    int bestScore = -1;
    for (int ref = 0; ref + 1 < slice.frames(); ++ref) {
        for (int y = 0; y < MB_H; ++y) for (int x = 0; x < MB_W; ++x) {
            Case c{ref, ref + 1, x, y, "varied-real-content"};
            int yMin = 255, yMax = 0;
            for (int i = 0; i < 256; ++i) {
                const int v = targetSample(slice, c, i);
                yMin = std::min(yMin, v);
                yMax = std::max(yMax, v);
            }
            const int score = residualNonzero(slice, c) + 4 * uvDistinct(slice, c) + (yMin <= 10 ? 200 : 0) + (yMax >= 235 ? 200 : 0);
            if (score > bestScore) { bestScore = score; best = c; }
        }
    }
    return best;
}

Case chooseRightEdge(const Slice& slice, const Case& avoid) {
    Case best{};
    int bestScore = -1;
    for (int ref = 0; ref + 1 < slice.frames(); ++ref) {
        for (int y = 0; y < MB_H; ++y) {
            Case c{ref, ref + 1, MB_W - 1, y, "right-edge-chroma-clamp"};
            if (c.ref == avoid.ref && c.mbX == avoid.mbX && c.mbY == avoid.mbY) continue;
            const int score = residualNonzero(slice, c) + 8 * uvDistinct(slice, c);
            if (score > bestScore) { bestScore = score; best = c; }
        }
    }
    return best;
}

class Sim {
public:
    Vh264_decode_core_p16z_tb top{};
    uint64_t cycles = 0;
    std::vector<uint32_t> reads;
    std::vector<Write> writes;
    bool pendingValid = false;
    uint8_t pendingData = 0;

    void tick(const Slice& slice, const std::vector<Case>& cases) {
        top.clk = 0;
        top.dpb_rd_valid = pendingValid ? 1 : 0;
        top.dpb_rd_data = pendingData;
        top.eval();
        top.clk = 1;
        top.eval();
        if (top.dpb_wr_en) writes.push_back({top.dpb_wr_addr, static_cast<uint8_t>(top.dpb_wr_data)});
        const bool sawRead = top.dpb_rd_en;
        const uint32_t readAddr = top.dpb_rd_addr;
        top.clk = 0;
        top.eval();
        ++cycles;
        pendingValid = sawRead;
        if (sawRead) {
            reads.push_back(readAddr);
            const std::size_t caseIdx = std::min((reads.size() - 1) / kReadsPerMb, cases.size() - 1);
            pendingData = refFromAddr(slice, cases.at(caseIdx), readAddr);
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
    for (int i = 0; i < 128; ++i) s.top.rbsp_byte_in[i] = 0;
    for (int i = 0; i < 256; ++i) s.top.p16_residual_y[i] = 0;
    for (int i = 0; i < 64; ++i) {
        s.top.p16_residual_u[i] = 0;
        s.top.p16_residual_v[i] = 0;
    }
}

void reset(Sim& s, const Slice& slice, const std::vector<Case>& cases) {
    clearInputs(s);
    s.top.reset = 1;
    s.tick(slice, cases);
    s.tick(slice, cases);
    s.top.reset = 0;
    s.tick(slice, cases);
}

void driveCase(Sim& s, const Slice& slice, const std::vector<Case>& cases, const Case& c) {
    for (int i = 0; i < 256; ++i) s.top.p16_residual_y[i] = int(targetSample(slice, c, i)) - int(refCenterSample(slice, c, i));
    for (int i = 0; i < 64; ++i) {
        s.top.p16_residual_u[i] = int(targetSample(slice, c, 256 + i)) - int(refCenterSample(slice, c, 256 + i));
        s.top.p16_residual_v[i] = int(targetSample(slice, c, 320 + i)) - int(refCenterSample(slice, c, 320 + i));
    }
    s.top.p16_mb_x = c.mbX;
    s.top.p16_mb_y = c.mbY;
    s.top.p16_mb_is_ref = 1;
    s.top.dpb_ref_base = REF_BASE;
    s.top.dpb_write_base = WRITE_BASE;
    s.top.p16_mv_x_qpel = 0;
    s.top.p16_mv_y_qpel = 0;
    s.top.p16_ref_idx_l0 = 0;
    s.top.p16_zero_mv_valid = 1;
    s.tick(slice, cases);
    s.top.p16_zero_mv_valid = 0;
}

bool waitForWrites(Sim& s, const Slice& slice, const std::vector<Case>& cases, std::size_t wantWrites) {
    for (int i = 0; i < kTimeoutCycles; ++i) {
        if (!s.top.busy && s.writes.size() >= wantWrites) return true;
        s.tick(slice, cases);
    }
    return !s.top.busy && s.writes.size() >= wantWrites;
}

int checkScoreboard(const Sim& s, const Slice& slice, const std::vector<Case>& cases) {
    if (s.reads.size() != cases.size() * kReadsPerMb) {
        std::cerr << "FAIL h264_decode_core real-slice scoreboard: read count " << s.reads.size()
                  << " want=" << cases.size() * kReadsPerMb << "\n";
        return 1;
    }
    if (s.writes.size() != cases.size() * 384) {
        std::cerr << "FAIL h264_decode_core real-slice scoreboard: write count " << s.writes.size()
                  << " want=" << cases.size() * 384 << "\n";
        return 1;
    }
    int chromaClampReads = 0;
    for (std::size_t i = 0; i < s.reads.size(); ++i) {
        const std::size_t caseIdx = i / kReadsPerMb;
        const int local = static_cast<int>(i % kReadsPerMb);
        chromaClampReads += chromaRightClampRead(cases.at(caseIdx), local);
        const uint32_t want = expectedReadAddr(cases.at(caseIdx), local);
        if (s.reads.at(i) != want) {
            const Case& c = cases.at(caseIdx);
            std::cerr << "FAIL h264_decode_core real-slice scoreboard: " << c.label
                      << " slice=" << c.ref << "->" << c.target << " mb=(" << c.mbX << "," << c.mbY
                      << ") read_ordinal " << i << " got_addr=0x" << std::hex << s.reads.at(i)
                      << " want_addr=0x" << want << std::dec << "\n";
            return 1;
        }
    }
    int residualNonzeroTotal = 0;
    int uvDistinctTotal = 0;
    for (std::size_t ci = 0; ci < cases.size(); ++ci) {
        const Case& c = cases.at(ci);
        residualNonzeroTotal += residualNonzero(slice, c);
        uvDistinctTotal += uvDistinct(slice, c);
        for (int i = 0; i < 384; ++i) {
            const Write& w = s.writes.at(ci * 384 + i);
            const uint32_t wantAddr = expectedWriteAddr(c, i);
            const uint8_t wantData = targetSample(slice, c, i);
            if (w.addr != wantAddr || w.data != wantData) {
                const char* plane = i < 256 ? "Y" : (i < 320 ? "U" : "V");
                std::cerr << "FAIL h264_decode_core real-slice scoreboard: " << c.label
                          << " slice=" << c.ref << "->" << c.target << " mb=(" << c.mbX << "," << c.mbY
                          << ") sample " << i << " plane=" << plane
                          << " got_addr=0x" << std::hex << w.addr << " want_addr=0x" << wantAddr << std::dec
                          << " got=" << int(w.data) << " want=" << int(wantData)
                          << " residual=" << int(wantData) - int(refCenterSample(slice, c, i)) << "\n";
                return 1;
            }
        }
    }
    if (uvDistinctTotal < static_cast<int>(cases.size()) * 64) {
        std::cerr << "FAIL h264_decode_core real-slice scoreboard: uv_distinct_samples=" << uvDistinctTotal << " too weak\n";
        return 1;
    }
    if (chromaClampReads < 1) {
        std::cerr << "FAIL h264_decode_core real-slice scoreboard: chroma_right_clamp_reads=" << chromaClampReads << " want>=1\n";
        return 1;
    }
    std::cout << "test_h264_decode_core_real_slice: OK real-content disabled-loop-filter I420 slice reconstructed "
              << cases.size() << " P16 MBs exact; residual_nonzero=" << residualNonzeroTotal
              << " uv_distinct_samples=" << uvDistinctTotal
              << " chroma_right_clamp_reads=" << chromaClampReads;
    for (const Case& c : cases) {
        std::cout << " " << c.label << "=" << c.ref << "->" << c.target << "@(" << c.mbX << "," << c.mbY << ")";
    }
    std::cout << "\n";
    return 0;
}

} // namespace

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    const char* path = std::getenv("MPLEX_REAL_SLICE");
    if (!path) path = "tests/fixtures/derived_validation/derived_realcontent_624x480_baseline_ref1_nob_8f_i420_disabled.yuv";
    Slice slice(readFile(path));
    if (slice.frames() != kExpectedFrames) {
        std::cerr << "FAIL h264_decode_core real-slice scoreboard: frames=" << slice.frames()
                  << " want=" << kExpectedFrames << "\n";
        return 1;
    }
    std::vector<Case> cases;
    cases.push_back(chooseVaried(slice));
    cases.push_back(chooseRightEdge(slice, cases.front()));

    Sim s;
    reset(s, slice, cases);
    for (std::size_t i = 0; i < cases.size(); ++i) {
        driveCase(s, slice, cases, cases.at(i));
        if (!waitForWrites(s, slice, cases, (i + 1) * 384)) {
            std::cerr << "FAIL h264_decode_core real-slice scoreboard: case " << i << " did not return idle\n";
            return 1;
        }
    }
    return checkScoreboard(s, slice, cases);
}
