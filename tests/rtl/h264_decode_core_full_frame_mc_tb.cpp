// Full-frame product motion-compensation scoreboard.
//
// Deliverable scope: every macroblock of a real 624x480 frame is driven through
// the *product* h264_decode_core P16x16 path as an inter macroblock with a
// non-trivial motion vector, and every predicted sample written to the DPB is
// compared against an independent H.264 qpel/epel model evaluated directly on
// the reference picture (not on the RTL's fetched window).
//
// Denominator: 1170/1170 macroblocks (39x30), 449280/449280 predicted samples
// (256 Y + 64 U + 64 V per macroblock).

#include "Vh264_decode_core_p16z_tb.h"
#include "verilated.h"

#include <algorithm>
#include <cstdint>
#include <cstdlib>
#include <fstream>
#include <iostream>
#include <map>
#include <string>
#include <vector>

namespace {

constexpr int FRAME_W = 624;
constexpr int FRAME_H = 480;
constexpr int MB_W = FRAME_W / 16;   // 39
constexpr int MB_H = FRAME_H / 16;   // 30
constexpr int MB_COUNT = MB_W * MB_H;  // 1170
constexpr int Y_BYTES = FRAME_W * FRAME_H;
constexpr int C_W = FRAME_W / 2;
constexpr int C_H = FRAME_H / 2;
constexpr int C_BYTES = C_W * C_H;
constexpr int FRAME_BYTES = Y_BYTES + 2 * C_BYTES;
constexpr int kSamplesPerMb = 384;
constexpr int kLumaWinSamples = 21 * 21;
constexpr int kChromaWinSamples = 9 * 9;
constexpr int kReadsPerMb = kLumaWinSamples + 2 * kChromaWinSamples;  // 603
constexpr uint32_t REF_BASE = 0x100000;
constexpr uint32_t WRITE_BASE = 0x400000;
constexpr int kTimeoutCycles = 40000;

int clampInt(int v, int lo, int hi) { return std::max(lo, std::min(v, hi)); }

std::vector<uint8_t> readFile(const char* path) {
    std::ifstream f(path, std::ios::binary);
    if (!f) throw std::runtime_error(std::string("open failed: ") + path);
    return std::vector<uint8_t>((std::istreambuf_iterator<char>(f)), std::istreambuf_iterator<char>());
}

class Picture {
public:
    explicit Picture(std::vector<uint8_t> bytes) : data(std::move(bytes)) {}
    int frames() const { return static_cast<int>(data.size() / FRAME_BYTES); }
    // Edge-extended sample fetch, matching H.264 reference-picture clamping.
    int sample(int frame, int plane, int x, int y) const {
        const int w = plane == 0 ? FRAME_W : C_W;
        const int h = plane == 0 ? FRAME_H : C_H;
        x = clampInt(x, 0, w - 1);
        y = clampInt(y, 0, h - 1);
        const std::size_t base = static_cast<std::size_t>(frame) * FRAME_BYTES;
        if (plane == 0) return data.at(base + static_cast<std::size_t>(y) * FRAME_W + x);
        if (plane == 1) return data.at(base + Y_BYTES + static_cast<std::size_t>(y) * C_W + x);
        return data.at(base + Y_BYTES + C_BYTES + static_cast<std::size_t>(y) * C_W + x);
    }
private:
    std::vector<uint8_t> data;
};

uint32_t i420Addr(uint32_t base, int plane, int x, int y) {
    if (plane == 0) return base + static_cast<uint32_t>(y * FRAME_W + x);
    if (plane == 1) return base + Y_BYTES + static_cast<uint32_t>(y * C_W + x);
    return base + Y_BYTES + C_BYTES + static_cast<uint32_t>(y * C_W + x);
}

struct MbCase {
    int mbX = 0;
    int mbY = 0;
    int mvX = 0;  // quarter-pel
    int mvY = 0;
};

// Deterministic motion field: covers every luma quarter-pel phase, every chroma
// eighth-pel phase, negative and positive integer displacement, and drives the
// frame borders into reference clamping.
MbCase makeCase(int mbIdx) {
    MbCase c;
    c.mbX = mbIdx % MB_W;
    c.mbY = mbIdx / MB_W;
    c.mvX = ((mbIdx * 7) % 41) - 20;
    c.mvY = ((mbIdx * 13) % 37) - 18;
    return c;
}

// ---------------------------------------------------------------------------
// Independent H.264 luma quarter-pel / chroma eighth-pel model.
// Evaluated straight off the reference picture with edge extension; it never
// looks at the RTL's fetched window, so a window-addressing bug cannot be
// masked by a matching bug in the model.
// ---------------------------------------------------------------------------

int clip1(int v) { return clampInt(v, 0, 255); }
int avg2(int a, int b) { return (a + b + 1) >> 1; }

int refY(const Picture& pic, int frame, int x, int y) { return pic.sample(frame, 0, x, y); }

int hraw(const Picture& pic, int frame, int x, int y) {
    return refY(pic, frame, x - 2, y) - 5 * refY(pic, frame, x - 1, y) +
           20 * refY(pic, frame, x, y) + 20 * refY(pic, frame, x + 1, y) -
           5 * refY(pic, frame, x + 2, y) + refY(pic, frame, x + 3, y);
}

int halfH(const Picture& pic, int frame, int x, int y) { return clip1((hraw(pic, frame, x, y) + 16) >> 5); }

int halfV(const Picture& pic, int frame, int x, int y) {
    const int raw = refY(pic, frame, x, y - 2) - 5 * refY(pic, frame, x, y - 1) +
                    20 * refY(pic, frame, x, y) + 20 * refY(pic, frame, x, y + 1) -
                    5 * refY(pic, frame, x, y + 2) + refY(pic, frame, x, y + 3);
    return clip1((raw + 16) >> 5);
}

int halfC(const Picture& pic, int frame, int x, int y) {
    const int raw = hraw(pic, frame, x, y - 2) - 5 * hraw(pic, frame, x, y - 1) +
                    20 * hraw(pic, frame, x, y) + 20 * hraw(pic, frame, x, y + 1) -
                    5 * hraw(pic, frame, x, y + 2) + hraw(pic, frame, x, y + 3);
    return clip1((raw + 512) >> 10);
}

int lumaPred(const Picture& pic, int frame, const MbCase& c, int idx) {
    const int fx = c.mvX & 3;
    const int fy = c.mvY & 3;
    const int x = c.mbX * 16 + (idx & 15) + (c.mvX >> 2);
    const int y = c.mbY * 16 + (idx >> 4) + (c.mvY >> 2);
    switch ((fy << 2) | fx) {
        case 0x0: return refY(pic, frame, x, y);
        case 0x1: return avg2(refY(pic, frame, x, y), halfH(pic, frame, x, y));
        case 0x2: return halfH(pic, frame, x, y);
        case 0x3: return avg2(halfH(pic, frame, x, y), refY(pic, frame, x + 1, y));
        case 0x4: return avg2(refY(pic, frame, x, y), halfV(pic, frame, x, y));
        case 0x5: return avg2(halfH(pic, frame, x, y), halfV(pic, frame, x, y));
        case 0x6: return avg2(halfH(pic, frame, x, y), halfC(pic, frame, x, y));
        case 0x7: return avg2(halfH(pic, frame, x, y), halfV(pic, frame, x + 1, y));
        case 0x8: return halfV(pic, frame, x, y);
        case 0x9: return avg2(halfV(pic, frame, x, y), halfC(pic, frame, x, y));
        case 0xa: return halfC(pic, frame, x, y);
        case 0xb: return avg2(halfC(pic, frame, x, y), halfV(pic, frame, x + 1, y));
        case 0xc: return avg2(halfV(pic, frame, x, y), refY(pic, frame, x, y + 1));
        case 0xd: return avg2(halfH(pic, frame, x, y + 1), halfV(pic, frame, x, y));
        case 0xe: return avg2(halfC(pic, frame, x, y), halfH(pic, frame, x, y + 1));
        default:  return avg2(halfH(pic, frame, x, y + 1), halfV(pic, frame, x + 1, y));
    }
}

int chromaPred(const Picture& pic, int frame, const MbCase& c, int plane, int rel) {
    const int fx = c.mvX & 7;
    const int fy = c.mvY & 7;
    const int x = c.mbX * 8 + (rel & 7) + (c.mvX >> 3);
    const int y = c.mbY * 8 + (rel >> 3) + (c.mvY >> 3);
    const int p00 = pic.sample(frame, plane, x, y);
    const int p10 = pic.sample(frame, plane, x + 1, y);
    const int p01 = pic.sample(frame, plane, x, y + 1);
    const int p11 = pic.sample(frame, plane, x + 1, y + 1);
    return ((8 - fx) * (8 - fy) * p00 + fx * (8 - fy) * p10 +
            (8 - fx) * fy * p01 + fx * fy * p11 + 32) >> 6;
}

int expectedSample(const Picture& pic, int frame, const MbCase& c, int idx) {
    if (idx < 256) return lumaPred(pic, frame, c, idx);
    if (idx < 320) return chromaPred(pic, frame, c, 1, idx - 256);
    return chromaPred(pic, frame, c, 2, idx - 320);
}

uint32_t expectedWriteAddr(const MbCase& c, int idx) {
    if (idx < 256) return i420Addr(WRITE_BASE, 0, c.mbX * 16 + (idx & 15), c.mbY * 16 + (idx >> 4));
    if (idx < 320) {
        const int rel = idx - 256;
        return i420Addr(WRITE_BASE, 1, c.mbX * 8 + (rel & 7), c.mbY * 8 + (rel >> 3));
    }
    const int rel = idx - 320;
    return i420Addr(WRITE_BASE, 2, c.mbX * 8 + (rel & 7), c.mbY * 8 + (rel >> 3));
}

uint32_t expectedReadAddr(const MbCase& c, int localOrdinal) {
    if (localOrdinal < kLumaWinSamples) {
        const int x = clampInt(c.mbX * 16 + (c.mvX >> 2) + (localOrdinal % 21) - 2, 0, FRAME_W - 1);
        const int y = clampInt(c.mbY * 16 + (c.mvY >> 2) + (localOrdinal / 21) - 2, 0, FRAME_H - 1);
        return i420Addr(REF_BASE, 0, x, y);
    }
    const bool isU = localOrdinal < kLumaWinSamples + kChromaWinSamples;
    const int rel = isU ? localOrdinal - kLumaWinSamples
                        : localOrdinal - kLumaWinSamples - kChromaWinSamples;
    const int plane = isU ? 1 : 2;
    const int x = clampInt(c.mbX * 8 + (c.mvX >> 3) + (rel % 9), 0, C_W - 1);
    const int y = clampInt(c.mbY * 8 + (c.mvY >> 3) + (rel / 9), 0, C_H - 1);
    return i420Addr(REF_BASE, plane, x, y);
}

struct Write { uint32_t addr = 0; uint8_t data = 0; };

class Sim {
public:
    Vh264_decode_core_p16z_tb top{};
    const Picture* pic = nullptr;
    int refFrame = 0;
    uint64_t cycles = 0;
    std::size_t readCount = 0;
    std::size_t readMismatches = 0;
    std::size_t firstBadReadOrdinal = 0;
    uint32_t firstBadReadGot = 0;
    uint32_t firstBadReadWant = 0;
    std::vector<Write> writes;
    bool pendingValid = false;
    uint8_t pendingData = 0;

    uint8_t refFromAddr(uint32_t addr) const {
        const uint32_t off = addr - REF_BASE;
        if (off < static_cast<uint32_t>(Y_BYTES))
            return static_cast<uint8_t>(pic->sample(refFrame, 0, off % FRAME_W, off / FRAME_W));
        if (off < static_cast<uint32_t>(Y_BYTES + C_BYTES)) {
            const uint32_t p = off - Y_BYTES;
            return static_cast<uint8_t>(pic->sample(refFrame, 1, p % C_W, p / C_W));
        }
        const uint32_t p = off - Y_BYTES - C_BYTES;
        return static_cast<uint8_t>(pic->sample(refFrame, 2, p % C_W, p / C_W));
    }

    void tick() {
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
            const std::size_t ordinal = readCount++;
            const MbCase c = makeCase(static_cast<int>(std::min<std::size_t>(ordinal / kReadsPerMb, MB_COUNT - 1)));
            const uint32_t want = expectedReadAddr(c, static_cast<int>(ordinal % kReadsPerMb));
            if (readAddr != want) {
                if (readMismatches == 0) {
                    firstBadReadOrdinal = ordinal;
                    firstBadReadGot = readAddr;
                    firstBadReadWant = want;
                }
                ++readMismatches;
            }
            pendingData = refFromAddr(readAddr);
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

void resetDut(Sim& s) {
    clearInputs(s);
    s.top.reset = 1;
    s.tick();
    s.tick();
    s.top.reset = 0;
    s.tick();
}

bool driveMb(Sim& s, const MbCase& c, std::size_t wantWrites) {
    s.top.p16_mb_x = static_cast<uint8_t>(c.mbX);
    s.top.p16_mb_y = static_cast<uint8_t>(c.mbY);
    s.top.p16_mb_is_ref = 1;
    s.top.dpb_ref_base = REF_BASE;
    s.top.dpb_write_base = WRITE_BASE;
    s.top.p16_mv_x_qpel = static_cast<int16_t>(c.mvX);
    s.top.p16_mv_y_qpel = static_cast<int16_t>(c.mvY);
    s.top.p16_ref_idx_l0 = 0;
    s.top.p16_zero_mv_valid = 1;
    s.tick();
    s.top.p16_zero_mv_valid = 0;
    for (int i = 0; i < kTimeoutCycles; ++i) {
        if (!s.top.busy && s.writes.size() >= wantWrites) return true;
        s.tick();
    }
    return false;
}

}  // namespace

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    const char* slicePath = std::getenv("MPLEX_REAL_SLICE");
    if (!slicePath) {
        std::cerr << "FAIL h264_decode_core full-frame MC: MPLEX_REAL_SLICE is not set\n";
        return 2;
    }
    Picture pic(readFile(slicePath));
    if (pic.frames() < 1) {
        std::cerr << "FAIL h264_decode_core full-frame MC: reference picture has no frames\n";
        return 2;
    }

    std::cout << "Scope: product h264_decode_core P16x16 motion compensation over "
              << MB_COUNT << "/" << MB_COUNT << " macroblocks of a real "
              << FRAME_W << "x" << FRAME_H << " frame (" << MB_W << "x" << MB_H << " MBs), "
              << MB_COUNT * kSamplesPerMb << "/" << MB_COUNT * kSamplesPerMb
              << " predicted samples checked against an independent qpel/epel model\n";

    Sim s;
    s.pic = &pic;
    s.refFrame = 0;
    resetDut(s);

    std::map<int, int> lumaPhaseHist;
    std::map<int, int> chromaPhaseHist;
    long long clampedMbs = 0;
    long long nonzeroMv = 0;

    for (int mbIdx = 0; mbIdx < MB_COUNT; ++mbIdx) {
        const MbCase c = makeCase(mbIdx);
        lumaPhaseHist[((c.mvY & 3) << 2) | (c.mvX & 3)]++;
        chromaPhaseHist[((c.mvY & 7) << 3) | (c.mvX & 7)]++;
        if (c.mvX || c.mvY) ++nonzeroMv;
        const int x0 = c.mbX * 16 + (c.mvX >> 2) - 2;
        const int y0 = c.mbY * 16 + (c.mvY >> 2) - 2;
        if (x0 < 0 || y0 < 0 || x0 + 20 > FRAME_W - 1 || y0 + 20 > FRAME_H - 1) ++clampedMbs;

        const std::size_t want = static_cast<std::size_t>(mbIdx + 1) * kSamplesPerMb;
        if (!driveMb(s, c, want)) {
            std::cerr << "FAIL h264_decode_core full-frame MC: macroblock " << mbIdx
                      << " (" << c.mbX << "," << c.mbY << ") timed out after "
                      << kTimeoutCycles << " cycles; writes=" << s.writes.size()
                      << " want=" << want << "\n";
            return 1;
        }
    }

    if (s.readCount != static_cast<std::size_t>(MB_COUNT) * kReadsPerMb) {
        std::cerr << "FAIL h264_decode_core full-frame MC: read count " << s.readCount
                  << " want=" << static_cast<std::size_t>(MB_COUNT) * kReadsPerMb << "\n";
        return 1;
    }
    if (s.readMismatches) {
        std::cerr << "FAIL h264_decode_core full-frame MC: " << s.readMismatches
                  << " reference read addresses wrong; first read_ordinal " << s.firstBadReadOrdinal
                  << " got_addr=0x" << std::hex << s.firstBadReadGot
                  << " want_addr=0x" << s.firstBadReadWant << std::dec << "\n";
        return 1;
    }
    if (s.writes.size() != static_cast<std::size_t>(MB_COUNT) * kSamplesPerMb) {
        std::cerr << "FAIL h264_decode_core full-frame MC: write count " << s.writes.size()
                  << " want=" << static_cast<std::size_t>(MB_COUNT) * kSamplesPerMb << "\n";
        return 1;
    }

    long long checkedY = 0, checkedU = 0, checkedV = 0;
    long long fracLumaSamples = 0;
    long long differsFromColocated = 0;
    int minPred = 255, maxPred = 0;
    for (int mbIdx = 0; mbIdx < MB_COUNT; ++mbIdx) {
        const MbCase c = makeCase(mbIdx);
        for (int i = 0; i < kSamplesPerMb; ++i) {
            const Write& w = s.writes.at(static_cast<std::size_t>(mbIdx) * kSamplesPerMb + i);
            const uint32_t wantAddr = expectedWriteAddr(c, i);
            const int wantData = expectedSample(pic, s.refFrame, c, i);
            if (w.addr != wantAddr || int(w.data) != wantData) {
                const char* plane = i < 256 ? "Y" : (i < 320 ? "U" : "V");
                std::cerr << "FAIL h264_decode_core full-frame MC: mb=" << mbIdx
                          << " (" << c.mbX << "," << c.mbY << ") mv=(" << c.mvX << "," << c.mvY
                          << ") sample " << i << " plane=" << plane
                          << " got_addr=0x" << std::hex << w.addr << " want_addr=0x" << wantAddr << std::dec
                          << " got=" << int(w.data) << " want=" << wantData << "\n";
                return 1;
            }
            if (i < 256) {
                ++checkedY;
                if ((c.mvX & 3) || (c.mvY & 3)) ++fracLumaSamples;
                const int colocated = pic.sample(s.refFrame, 0, c.mbX * 16 + (i & 15), c.mbY * 16 + (i >> 4));
                if (wantData != colocated) ++differsFromColocated;
                minPred = std::min(minPred, wantData);
                maxPred = std::max(maxPred, wantData);
            } else if (i < 320) {
                ++checkedU;
            } else {
                ++checkedV;
            }
        }
    }

    // Anti-vacuity: the proof is worthless if the motion field is degenerate or
    // the prediction is indistinguishable from a co-located copy.
    if (lumaPhaseHist.size() != 16) {
        std::cerr << "FAIL h264_decode_core full-frame MC: motion field covered only "
                  << lumaPhaseHist.size() << "/16 luma quarter-pel phases\n";
        return 1;
    }
    if (chromaPhaseHist.size() != 64) {
        std::cerr << "FAIL h264_decode_core full-frame MC: motion field covered only "
                  << chromaPhaseHist.size() << "/64 chroma eighth-pel phases\n";
        return 1;
    }
    if (nonzeroMv < MB_COUNT - MB_COUNT / 32) {
        std::cerr << "FAIL h264_decode_core full-frame MC: only " << nonzeroMv
                  << "/" << MB_COUNT << " macroblocks had a non-zero motion vector\n";
        return 1;
    }
    if (clampedMbs < 1) {
        std::cerr << "FAIL h264_decode_core full-frame MC: no macroblock exercised reference edge clamping\n";
        return 1;
    }
    if (differsFromColocated * 2 < checkedY) {
        std::cerr << "FAIL h264_decode_core full-frame MC: only " << differsFromColocated
                  << "/" << checkedY << " luma predictions differ from a co-located copy;"
                  << " the scoreboard would not catch a dropped motion vector\n";
        return 1;
    }
    if (maxPred - minPred < 128) {
        std::cerr << "FAIL h264_decode_core full-frame MC: predicted luma range " << minPred
                  << ".." << maxPred << " is too flat to be real content\n";
        return 1;
    }

    std::cout << "OK h264_decode_core full-frame MC: " << MB_COUNT << "/" << MB_COUNT
              << " P16x16 macroblocks predicted exactly; samples Y=" << checkedY
              << " U=" << checkedU << " V=" << checkedV
              << " total=" << checkedY + checkedU + checkedV
              << "; reads=" << s.readCount << " (all addresses exact)"
              << "; luma_qpel_phases=" << lumaPhaseHist.size() << "/16"
              << " chroma_epel_phases=" << chromaPhaseHist.size() << "/64"
              << " sub_pel_luma_samples=" << fracLumaSamples
              << " edge_clamped_mbs=" << clampedMbs
              << " differ_from_colocated=" << differsFromColocated << "/" << checkedY
              << " pred_range=" << minPred << ".." << maxPred
              << " cycles=" << s.cycles << "\n";
    return 0;
}
