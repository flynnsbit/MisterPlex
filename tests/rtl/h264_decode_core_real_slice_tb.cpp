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
constexpr int kReadsPerMb = 256 * 81 + 128 * 4;
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

int tapsForSample(int idx) { return idx < 256 ? 81 : 4; }

uint32_t expectedReadAddr(const Case& c, int localOrdinal) {
    int idx = 0;
    int cur = 0;
    for (; idx < 384; ++idx) {
        const int taps = tapsForSample(idx);
        if (localOrdinal < cur + taps) break;
        cur += taps;
    }
    const int tap = localOrdinal - cur;
    if (idx < 256) {
        const int sx = idx & 15;
        const int sy = idx >> 4;
        const int x = clampInt(c.mbX * 16 + sx + (tap % 9) - 4, 0, FRAME_W - 1);
        const int y = clampInt(c.mbY * 16 + sy + (tap / 9) - 4, 0, FRAME_H - 1);
        return i420Addr(REF_BASE, 0, x, y);
    }
    const int plane = idx < 320 ? 1 : 2;
    const int rel = idx < 320 ? idx - 256 : idx - 320;
    const int sx = rel & 7;
    const int sy = rel >> 3;
    const int x = clampInt(c.mbX * 8 + sx + (tap & 1), 0, C_W - 1);
    const int y = clampInt(c.mbY * 8 + sy + ((tap >> 1) & 1), 0, C_H - 1);
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

// Chroma-only residual count — luma sentinels do not cover U/V residual planes.
int chromaResidualNonzero(const Slice& slice, const Case& c) {
    int n = 0;
    for (int i = 256; i < 384; ++i) n += targetSample(slice, c, i) != refCenterSample(slice, c, i);
    return n;
}

// Distinct U vs V residual at the same sample — required so a residual plane swap can go red.
int chromaResidualUvDistinct(const Slice& slice, const Case& c) {
    int n = 0;
    for (int i = 0; i < 64; ++i) {
        const int uRes = int(targetSample(slice, c, 256 + i)) - int(refCenterSample(slice, c, 256 + i));
        const int vRes = int(targetSample(slice, c, 320 + i)) - int(refCenterSample(slice, c, 320 + i));
        n += (uRes != vRes);
    }
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
    int idx = 0;
    int cur = 0;
    for (; idx < 384; ++idx) {
        const int taps = tapsForSample(idx);
        if (localOrdinal < cur + taps) break;
        cur += taps;
    }
    if (idx < 256) return false;
    const int tap = localOrdinal - cur;
    const int rel = idx < 320 ? idx - 256 : idx - 320;
    return c.mbX * 8 + (rel & 7) + (tap & 1) > C_W - 1;
}

bool chromaBottomClampRead(const Case& c, int localOrdinal) {
    int idx = 0;
    int cur = 0;
    for (; idx < 384; ++idx) {
        const int taps = tapsForSample(idx);
        if (localOrdinal < cur + taps) break;
        cur += taps;
    }
    if (idx < 256) return false;
    const int tap = localOrdinal - cur;
    const int rel = idx < 320 ? idx - 256 : idx - 320;
    return c.mbY * 8 + (rel >> 3) + ((tap >> 1) & 1) > C_H - 1;
}

bool caseEquals(const Case& a, const Case& b) {
    return a.ref == b.ref && a.target == b.target && a.mbX == b.mbX && a.mbY == b.mbY;
}

bool caseConflicts(const Case& c, const std::vector<Case>& avoid) {
    for (const Case& a : avoid) {
        if (caseEquals(c, a)) return true;
    }
    return false;
}

Case chooseVaried(const Slice& slice, const std::vector<Case>& avoid) {
    Case best{};
    int bestScore = -1;
    for (int ref = 0; ref + 1 < slice.frames(); ++ref) {
        for (int y = 0; y < MB_H; ++y) for (int x = 0; x < MB_W; ++x) {
            Case c{ref, ref + 1, x, y, "varied-real-content"};
            if (caseConflicts(c, avoid)) continue;
            // Reject chroma-vacuous MBs: need U/V plane and residual discrimination.
            if (uvDistinct(slice, c) < 32) continue;
            if (chromaResidualNonzero(slice, c) < 8) continue;
            if (chromaResidualUvDistinct(slice, c) < 8) continue;
            int yMin = 255, yMax = 0;
            for (int i = 0; i < 256; ++i) {
                const int v = targetSample(slice, c, i);
                yMin = std::min(yMin, v);
                yMax = std::max(yMax, v);
            }
            const int score = residualNonzero(slice, c) + 8 * chromaResidualNonzero(slice, c) +
                              16 * chromaResidualUvDistinct(slice, c) + 4 * uvDistinct(slice, c) +
                              (yMin <= 10 ? 200 : 0) + (yMax >= 235 ? 200 : 0);
            if (score > bestScore) { bestScore = score; best = c; }
        }
    }
    if (bestScore < 0) throw std::runtime_error("no varied real-content MB with chroma residual discrimination");
    return best;
}

Case chooseRightEdge(const Slice& slice, const std::vector<Case>& avoid) {
    Case best{};
    int bestScore = -1;
    for (int ref = 0; ref + 1 < slice.frames(); ++ref) {
        for (int y = 0; y < MB_H; ++y) {
            Case c{ref, ref + 1, MB_W - 1, y, "right-edge-chroma-clamp"};
            if (caseConflicts(c, avoid)) continue;
            if (uvDistinct(slice, c) < 16) continue;
            if (chromaResidualUvDistinct(slice, c) < 4) continue;
            const int score = residualNonzero(slice, c) + 8 * uvDistinct(slice, c) +
                              16 * chromaResidualUvDistinct(slice, c);
            if (score > bestScore) { bestScore = score; best = c; }
        }
    }
    if (bestScore < 0) throw std::runtime_error("no right-edge chroma clamp MB with U/V discrimination");
    return best;
}

Case chooseBottomEdge(const Slice& slice, const std::vector<Case>& avoid) {
    Case best{};
    int bestScore = -1;
    for (int ref = 0; ref + 1 < slice.frames(); ++ref) {
        for (int x = 0; x < MB_W; ++x) {
            Case c{ref, ref + 1, x, MB_H - 1, "bottom-edge-chroma-clamp"};
            if (caseConflicts(c, avoid)) continue;
            if (uvDistinct(slice, c) < 16) continue;
            if (chromaResidualUvDistinct(slice, c) < 4) continue;
            const int score = residualNonzero(slice, c) + 8 * uvDistinct(slice, c) +
                              16 * chromaResidualUvDistinct(slice, c);
            if (score > bestScore) { bestScore = score; best = c; }
        }
    }
    if (bestScore < 0) throw std::runtime_error("no bottom-edge chroma clamp MB with U/V discrimination");
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
    for (int i = 0; i < 64; ++i) s.top.rbsp_byte_in[i] = 0;
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

// Score product (pre-deblock) writeback against a filter-enabled gold without
// redefining residual from the enabled pair (that would be tautologically green).
int scoreEnabledSurvival(const Sim& s, const Slice& enabled, const std::vector<Case>& cases) {
    int mbExact = 0;
    int sampleMatch = 0;
    int sampleTotal = 0;
    int yMatch = 0, yTotal = 0;
    int uMatch = 0, uTotal = 0;
    int vMatch = 0, vTotal = 0;
    int firstDiffSample = -1;
    std::string firstDiffLabel;
    int firstDiffGot = -1, firstDiffWant = -1;
    const char* firstDiffPlane = "";

    for (std::size_t ci = 0; ci < cases.size(); ++ci) {
        const Case& c = cases.at(ci);
        int mbMism = 0;
        for (int i = 0; i < 384; ++i) {
            const Write& w = s.writes.at(ci * 384 + i);
            const uint8_t want = targetSample(enabled, c, i);
            ++sampleTotal;
            const bool ok = (w.data == want);
            if (ok) ++sampleMatch;
            else {
                ++mbMism;
                if (firstDiffSample < 0) {
                    firstDiffSample = i;
                    firstDiffLabel = c.label;
                    firstDiffGot = int(w.data);
                    firstDiffWant = int(want);
                    firstDiffPlane = i < 256 ? "Y" : (i < 320 ? "U" : "V");
                }
            }
            if (i < 256) {
                ++yTotal;
                yMatch += ok;
            } else if (i < 320) {
                ++uTotal;
                uMatch += ok;
            } else {
                ++vTotal;
                vMatch += ok;
            }
        }
        if (mbMism == 0) ++mbExact;
    }

    // Vacuity guards: 100% match means the enabled gold is not discriminating
    // (or we accidentally scored the residual oracle against itself). 0% match
    // usually means frame/index misalignment rather than "deblock everywhere".
    if (sampleTotal < 1 || sampleMatch == sampleTotal) {
        std::cerr << "FAIL h264_decode_core real-slice deblock-gap: enabled-gold survival vacuous "
                  << "sample_match=" << sampleMatch << "/" << sampleTotal
                  << " (product pre-deblock writeback must diverge from filter-enabled reference)\n";
        return 1;
    }
    if (sampleMatch == 0) {
        std::cerr << "FAIL h264_decode_core real-slice deblock-gap: enabled-gold survival zero "
                  << "sample_match=0/" << sampleTotal
                  << " (likely slice misalignment, not a measured deblock cascade)\n";
        return 1;
    }
    if (mbExact == static_cast<int>(cases.size())) {
        std::cerr << "FAIL h264_decode_core real-slice deblock-gap: all "
                  << mbExact << " MBs exact against enabled gold while product path has no in-loop deblock\n";
        return 1;
    }

    std::cout << "DEBLOCK_GAP_SURVIVAL product_pre_deblock_vs_enabled_gold"
              << " mb_exact=" << mbExact << "/" << cases.size()
              << " sample_match=" << sampleMatch << "/" << sampleTotal
              << " sample_pct=" << (100.0 * sampleMatch / sampleTotal)
              << " Y=" << yMatch << "/" << yTotal
              << " U=" << uMatch << "/" << uTotal
              << " V=" << vMatch << "/" << vTotal
              << " first_diff label=" << firstDiffLabel
              << " sample=" << firstDiffSample << " plane=" << firstDiffPlane
              << " got=" << firstDiffGot << " want=" << firstDiffWant
              << " note=temporal_ref_cascade_dominates_edge_only_filter\n";
    return 0;
}

int checkScoreboard(const Sim& s, const Slice& slice, const Slice& enabled, const std::vector<Case>& cases) {
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
    int chromaRightClampReads = 0;
    int chromaBottomClampReads = 0;
    for (std::size_t i = 0; i < s.reads.size(); ++i) {
        const std::size_t caseIdx = i / kReadsPerMb;
        const int local = static_cast<int>(i % kReadsPerMb);
        chromaRightClampReads += chromaRightClampRead(cases.at(caseIdx), local);
        chromaBottomClampReads += chromaBottomClampRead(cases.at(caseIdx), local);
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
    int chromaResidualNonzeroTotal = 0;
    int chromaResidualUvDistinctTotal = 0;
    int uvDistinctTotal = 0;
    for (std::size_t ci = 0; ci < cases.size(); ++ci) {
        const Case& c = cases.at(ci);
        residualNonzeroTotal += residualNonzero(slice, c);
        chromaResidualNonzeroTotal += chromaResidualNonzero(slice, c);
        chromaResidualUvDistinctTotal += chromaResidualUvDistinct(slice, c);
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
                          << " pred=" << int(refCenterSample(slice, c, i))
                          << " residual=" << int(wantData) - int(refCenterSample(slice, c, i)) << "\n";
                return 1;
            }
        }
    }
    if (uvDistinctTotal < static_cast<int>(cases.size()) * 32) {
        std::cerr << "FAIL h264_decode_core real-slice scoreboard: uv_distinct_samples=" << uvDistinctTotal << " too weak\n";
        return 1;
    }
    if (chromaResidualNonzeroTotal < static_cast<int>(cases.size()) * 8) {
        std::cerr << "FAIL h264_decode_core real-slice scoreboard: chroma_residual_nonzero="
                  << chromaResidualNonzeroTotal << " too weak (luma cannot cover chroma)\n";
        return 1;
    }
    if (chromaResidualUvDistinctTotal < static_cast<int>(cases.size()) * 4) {
        std::cerr << "FAIL h264_decode_core real-slice scoreboard: chroma_residual_uv_distinct="
                  << chromaResidualUvDistinctTotal << " too weak for residual U/V swap detection\n";
        return 1;
    }
    if (chromaRightClampReads < 1) {
        std::cerr << "FAIL h264_decode_core real-slice scoreboard: chroma_right_clamp_reads="
                  << chromaRightClampReads << " want>=1\n";
        return 1;
    }
    if (chromaBottomClampReads < 1) {
        std::cerr << "FAIL h264_decode_core real-slice scoreboard: chroma_bottom_clamp_reads="
                  << chromaBottomClampReads << " want>=1\n";
        return 1;
    }
    // Control path: disabled-loop-filter exactness (existing green contract).
    std::cout << "test_h264_decode_core_real_slice: OK real-content disabled-loop-filter I420 slice reconstructed "
              << cases.size() << " P16 MBs exact; residual_nonzero=" << residualNonzeroTotal
              << " chroma_residual_nonzero=" << chromaResidualNonzeroTotal
              << " chroma_residual_uv_distinct=" << chromaResidualUvDistinctTotal
              << " uv_distinct_samples=" << uvDistinctTotal
              << " chroma_right_clamp_reads=" << chromaRightClampReads
              << " chroma_bottom_clamp_reads=" << chromaBottomClampReads;
    for (const Case& c : cases) {
        std::cout << " " << c.label << "=" << c.ref << "->" << c.target << "@(" << c.mbX << "," << c.mbY << ")";
    }
    std::cout << "\n";

    // Gap instrument: same product writes vs filter-enabled gold.
    if (scoreEnabledSurvival(s, enabled, cases) != 0) return 1;
    return 0;
}

} // namespace

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    const char* path = std::getenv("MPLEX_REAL_SLICE");
    if (!path) path = "tests/fixtures/derived_validation/derived_realcontent_624x480_baseline_ref1_nob_8f_i420_disabled.yuv";
    const char* enabledPath = std::getenv("MPLEX_REAL_SLICE_ENABLED");
    if (!enabledPath) {
        enabledPath = "tests/fixtures/derived_validation/derived_realcontent_624x480_baseline_ref1_nob_8f_i420_enabled.yuv";
    }
    Slice slice(readFile(path));
    Slice enabled(readFile(enabledPath));
    if (slice.frames() != kExpectedFrames) {
        std::cerr << "FAIL h264_decode_core real-slice scoreboard: frames=" << slice.frames()
                  << " want=" << kExpectedFrames << "\n";
        return 1;
    }
    if (enabled.frames() != kExpectedFrames) {
        std::cerr << "FAIL h264_decode_core real-slice scoreboard: enabled_frames=" << enabled.frames()
                  << " want=" << kExpectedFrames << "\n";
        return 1;
    }
    // Guard against accidentally pointing both paths at the same decoded stage.
    // Compare payload, not path strings (symlinks / identical copies).
    {
        bool identical = true;
        for (int f = 0; f < kExpectedFrames && identical; ++f) {
            for (int y = 0; y < 8 && identical; ++y) {
                for (int x = 0; x < 8; ++x) {
                    if (slice.sample(f, 0, x, y) != enabled.sample(f, 0, x, y) ||
                        slice.sample(f, 1, x, y) != enabled.sample(f, 1, x, y) ||
                        slice.sample(f, 2, x, y) != enabled.sample(f, 2, x, y)) {
                        identical = false;
                        break;
                    }
                }
            }
        }
        // Full-frame compare would be expensive; probe corners + one mid sample per plane/frame.
        if (identical) {
            for (int f = 0; f < kExpectedFrames && identical; ++f) {
                if (slice.sample(f, 0, FRAME_W / 2, FRAME_H / 2) != enabled.sample(f, 0, FRAME_W / 2, FRAME_H / 2) ||
                    slice.sample(f, 1, C_W / 2, C_H / 2) != enabled.sample(f, 1, C_W / 2, C_H / 2) ||
                    slice.sample(f, 2, C_W / 2, C_H / 2) != enabled.sample(f, 2, C_W / 2, C_H / 2)) {
                    identical = false;
                }
            }
        }
        if (identical) {
            std::cerr << "FAIL h264_decode_core real-slice scoreboard: disabled and enabled slices are identical "
                      << "(deblock-gap instrument would be vacuous)\n";
            return 1;
        }
    }
    std::vector<Case> cases;
    try {
        cases.push_back(chooseVaried(slice, cases));
        cases.push_back(chooseRightEdge(slice, cases));
        cases.push_back(chooseBottomEdge(slice, cases));
    } catch (const std::exception& ex) {
        std::cerr << "FAIL h264_decode_core real-slice scoreboard: case selection: " << ex.what() << "\n";
        return 1;
    }

    Sim s;
    reset(s, slice, cases);
    for (std::size_t i = 0; i < cases.size(); ++i) {
        driveCase(s, slice, cases, cases.at(i));
        if (!waitForWrites(s, slice, cases, (i + 1) * 384)) {
            std::cerr << "FAIL h264_decode_core real-slice scoreboard: case " << i << " did not return idle\n";
            return 1;
        }
    }
    return checkScoreboard(s, slice, enabled, cases);
}
