#include "Vh264_inter_pred_tb.h"
#include "verilated.h"

#include <algorithm>
#include <array>
#include <cctype>
#include <cstdlib>
#include <fstream>
#include <iostream>
#include <stdexcept>
#include <string>
#include <vector>

namespace {

std::string readText(const char* path) {
    std::ifstream in(path);
    if (!in) throw std::runtime_error(std::string("cannot open fixture: ") + path);
    return std::string(std::istreambuf_iterator<char>(in), {});
}

long parseIntAt(const char*& p) {
    while (*p && (std::isspace(static_cast<unsigned char>(*p)) || *p == ':' || *p == ',')) ++p;
    char* end = nullptr;
    long v = std::strtol(p, &end, 10);
    if (end == p) throw std::runtime_error("expected integer");
    p = end;
    return v;
}

std::vector<int> parseArrayAfter(const std::string& text, const std::string& key, std::size_t start = 0) {
    std::size_t p = text.find(key, start);
    if (p == std::string::npos) throw std::runtime_error("missing key: " + key);
    p = text.find('[', p);
    std::size_t q = text.find(']', p);
    if (p == std::string::npos || q == std::string::npos) throw std::runtime_error("bad array: " + key);
    std::vector<int> out;
    const char* cur = text.c_str() + p + 1;
    const char* end = text.c_str() + q;
    while (cur < end) {
        while (cur < end && (std::isspace(static_cast<unsigned char>(*cur)) || *cur == ',')) ++cur;
        if (cur >= end) break;
        out.push_back(static_cast<int>(parseIntAt(cur)));
    }
    return out;
}

int parseIntAfter(const std::string& text, const std::string& key, std::size_t start = 0) {
    std::size_t p = text.find(key, start);
    if (p == std::string::npos) throw std::runtime_error("missing int key: " + key);
    p = text.find(':', p);
    const char* cur = text.c_str() + p + 1;
    return static_cast<int>(parseIntAt(cur));
}

bool parseBoolAfter(const std::string& text, const std::string& key, std::size_t start = 0) {
    std::size_t p = text.find(key, start);
    if (p == std::string::npos) throw std::runtime_error("missing bool key: " + key);
    p = text.find(':', p);
    ++p;
    while (p < text.size() && std::isspace(static_cast<unsigned char>(text[p]))) ++p;
    if (text.compare(p, 4, "true") == 0) return true;
    if (text.compare(p, 5, "false") == 0) return false;
    throw std::runtime_error("bad bool: " + key);
}

bool check(bool ok, const std::string& msg) {
    if (!ok) std::cerr << "FAIL h264_inter_pred RTL: " << msg << "\n";
    return ok;
}

int16_t s16(int v) { return static_cast<int16_t>(v); }

int clip1(int v) {
    return v < 0 ? 0 : (v > 255 ? 255 : v);
}

int avg2(int a, int b) {
    return (a + b + 1) >> 1;
}

int pix9(const std::array<uint8_t, 81>& ref, int r, int c) {
    return ref[static_cast<std::size_t>(r * 9 + c)];
}

int hraw9(const std::array<uint8_t, 81>& ref, int row, int col) {
    return pix9(ref, row, col - 2) - 5 * pix9(ref, row, col - 1) +
           20 * pix9(ref, row, col) + 20 * pix9(ref, row, col + 1) -
           5 * pix9(ref, row, col + 2) + pix9(ref, row, col + 3);
}

int halfH9(const std::array<uint8_t, 81>& ref, int rowoff, int coloff) {
    return clip1((hraw9(ref, 4 + rowoff, 4 + coloff) + 16) >> 5);
}

int halfV9(const std::array<uint8_t, 81>& ref, int rowoff, int coloff) {
    const int col = 4 + coloff;
    return clip1((pix9(ref, 2 + rowoff, col) - 5 * pix9(ref, 3 + rowoff, col) +
                  20 * pix9(ref, 4 + rowoff, col) + 20 * pix9(ref, 5 + rowoff, col) -
                  5 * pix9(ref, 6 + rowoff, col) + pix9(ref, 7 + rowoff, col) + 16) >> 5);
}

int halfC9(const std::array<uint8_t, 81>& ref, int rowoff, int coloff) {
    const int row = 4 + rowoff;
    const int col = 4 + coloff;
    const int sum = hraw9(ref, row - 2, col) - 5 * hraw9(ref, row - 1, col) +
                    20 * hraw9(ref, row, col) + 20 * hraw9(ref, row + 1, col) -
                    5 * hraw9(ref, row + 2, col) + hraw9(ref, row + 3, col);
    return clip1((sum + 512) >> 10);
}

uint8_t refQpel9(const std::array<uint8_t, 81>& ref, int fx, int fy) {
    const int p44 = pix9(ref, 4, 4);
    const int h0 = halfH9(ref, 0, 0);
    const int h1 = halfH9(ref, 1, 0);
    const int v0 = halfV9(ref, 0, 0);
    const int v1 = halfV9(ref, 0, 1);
    const int c = halfC9(ref, 0, 0);
    switch ((fy << 2) | fx) {
    case 0x0: return static_cast<uint8_t>(p44);
    case 0x1: return static_cast<uint8_t>(avg2(p44, h0));
    case 0x2: return static_cast<uint8_t>(h0);
    case 0x3: return static_cast<uint8_t>(avg2(h0, pix9(ref, 4, 5)));
    case 0x4: return static_cast<uint8_t>(avg2(p44, v0));
    case 0x5: return static_cast<uint8_t>(avg2(h0, v0));
    case 0x6: return static_cast<uint8_t>(avg2(h0, c));
    case 0x7: return static_cast<uint8_t>(avg2(h0, v1));
    case 0x8: return static_cast<uint8_t>(v0);
    case 0x9: return static_cast<uint8_t>(avg2(v0, c));
    case 0xa: return static_cast<uint8_t>(c);
    case 0xb: return static_cast<uint8_t>(avg2(c, v1));
    case 0xc: return static_cast<uint8_t>(avg2(v0, pix9(ref, 5, 4)));
    case 0xd: return static_cast<uint8_t>(avg2(h1, v0));
    case 0xe: return static_cast<uint8_t>(avg2(c, h1));
    default: return static_cast<uint8_t>(avg2(h1, v1));
    }
}

uint8_t refChroma(int p00, int p10, int p01, int p11, int fx, int fy) {
    return static_cast<uint8_t>(((8 - fx) * (8 - fy) * p00 + fx * (8 - fy) * p10 +
                                (8 - fx) * fy * p01 + fx * fy * p11 + 32) >> 6);
}

std::array<uint8_t, 81> makeLumaRef(int seed) {
    std::array<uint8_t, 81> out{};
    for (int r = 0; r < 9; ++r) {
        for (int c = 0; c < 9; ++c) {
            out[static_cast<std::size_t>(r * 9 + c)] =
                static_cast<uint8_t>((seed * 29 + r * 37 + c * 19 + r * c * 7 + ((r + seed) ^ (c * 11))) & 0xff);
        }
    }
    return out;
}

struct Mv { int x = 0; int y = 0; bool valid = false; };

int median3i(int a, int b, int c) {
    return a + b + c - std::min(std::min(a, b), c) - std::max(std::max(a, b), c);
}

Mv refPredPart(int mode, int idx, Mv a, Mv b, Mv c, Mv d, bool pskip) {
    Mv useC = c.valid ? c : d;
    const bool skipZero = pskip && (!a.valid || !b.valid || (a.x == 0 && a.y == 0) || (b.x == 0 && b.y == 0));
    if (skipZero) return {0, 0, true};
    Mv pred;
    int n = (a.valid ? 1 : 0) + (b.valid ? 1 : 0) + (useC.valid ? 1 : 0);
    if (n == 0) pred = {0, 0, true};
    else if (n == 1) pred = a.valid ? a : (b.valid ? b : useC);
    else pred = {median3i(a.valid ? a.x : 0, b.valid ? b.x : 0, useC.valid ? useC.x : 0),
                 median3i(a.valid ? a.y : 0, b.valid ? b.y : 0, useC.valid ? useC.y : 0), true};
    if (mode == 1 && idx == 0 && b.valid) pred = b;
    else if (mode == 1 && idx == 1 && a.valid) pred = a;
    else if (mode == 2 && idx == 0 && a.valid) pred = a;
    else if (mode == 2 && idx == 1 && c.valid) pred = c;
    pred.valid = true;
    return pred;
}

} // namespace

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    if (argc < 2) {
        std::cerr << "usage: " << argv[0] << " inter_mc_v1.json\n";
        return 2;
    }

    try {
        const std::string js = readText(argv[1]);
        Vh264_inter_pred_tb top;
        int mvCases = 0, partCases = 0, lumaCases = 0, chromaCases = 0, clampCases = 0, fetchCases = 0;
        int lumaStressCases = 0, chromaStressCases = 0, fetchStressCases = 0;

        const auto ref = parseArrayAfter(js, "\"luma_ref_9x9\"");
        if (!check(ref.size() == 81, "luma_ref_9x9 size")) return 1;
        for (std::size_t i = 0; i < ref.size(); ++i) top.luma_ref[i] = static_cast<uint8_t>(ref[i]);

        std::size_t mvStart = js.find("\"mv_cases\"");
        std::size_t partStart = js.find("\"partition_cases\"");
        std::size_t mvEnd = partStart;
        for (std::size_t p = js.find("\"name\"", mvStart); p != std::string::npos && p < mvEnd;
             p = js.find("\"name\"", p + 6)) {
            std::size_t next = js.find("\"name\"", p + 6);
            std::string c = js.substr(p, (next == std::string::npos || next > mvEnd) ? mvEnd - p : next - p);
            std::size_t avail = c.find("\"avail\"");
            std::size_t afterAvail = c.find("}", avail);
            top.avail_a = parseBoolAfter(c, "\"a\"", avail);
            top.avail_b = parseBoolAfter(c, "\"b\"", avail);
            top.avail_c = parseBoolAfter(c, "\"c\"", avail);
            top.avail_d = parseBoolAfter(c, "\"d\"", avail);
            auto a = parseArrayAfter(c, "\"a\"", afterAvail);
            auto b = parseArrayAfter(c, "\"b\"", afterAvail);
            auto cc = parseArrayAfter(c, "\"c\"", afterAvail);
            auto d = parseArrayAfter(c, "\"d\"", afterAvail);
            auto mvd = parseArrayAfter(c, "\"mvd\"");
            auto pred = parseArrayAfter(c, "\"pred\"");
            auto mv = parseArrayAfter(c, "\"mv\"");
            top.mv_a_x = s16(a[0]); top.mv_a_y = s16(a[1]);
            top.mv_b_x = s16(b[0]); top.mv_b_y = s16(b[1]);
            top.mv_c_x = s16(cc[0]); top.mv_c_y = s16(cc[1]);
            top.mv_d_x = s16(d[0]); top.mv_d_y = s16(d[1]);
            top.mvd_x = s16(mvd[0]); top.mvd_y = s16(mvd[1]);
            top.p_skip = parseBoolAfter(c, "\"p_skip\"");
            bool wantSkip = parseBoolAfter(c, "\"skip_zero\"");
            top.eval();
            int gotPredX = static_cast<int16_t>(top.pred_x);
            int gotPredY = static_cast<int16_t>(top.pred_y);
            int gotMvX = static_cast<int16_t>(top.mv_x);
            int gotMvY = static_cast<int16_t>(top.mv_y);
            if (!(gotPredX == pred[0] && gotPredY == pred[1] &&
                  gotMvX == mv[0] && gotMvY == mv[1] &&
                  static_cast<bool>(top.skip_zero) == wantSkip)) {
                std::cerr << "FAIL h264_inter_pred RTL: mv case mismatch got pred=("
                          << gotPredX << "," << gotPredY
                          << ") mv=(" << gotMvX << "," << gotMvY << ") skip="
                          << static_cast<int>(top.skip_zero) << " want pred=(" << pred[0] << ","
                          << pred[1] << ") mv=(" << mv[0] << "," << mv[1] << ") skip="
                          << wantSkip << "\n";
                return 1;
            }
            ++mvCases;
        }

        std::size_t partEnd = js.find("\"luma_ref_9x9\"");
        for (std::size_t p = js.find("\"name\"", partStart); p != std::string::npos && p < partEnd;
             p = js.find("\"name\"", p + 6)) {
            std::size_t next = js.find("\"name\"", p + 6);
            std::string c = js.substr(p, (next == std::string::npos || next > partEnd) ? partEnd - p : next - p);
            std::size_t avail = c.find("\"avail\"");
            std::size_t afterAvail = c.find("}", avail);
            top.avail_a = parseBoolAfter(c, "\"a\"", avail);
            top.avail_b = parseBoolAfter(c, "\"b\"", avail);
            top.avail_c = parseBoolAfter(c, "\"c\"", avail);
            top.avail_d = parseBoolAfter(c, "\"d\"", avail);
            auto a = parseArrayAfter(c, "\"a\"", afterAvail);
            auto b = parseArrayAfter(c, "\"b\"", afterAvail);
            auto cc = parseArrayAfter(c, "\"c\"", afterAvail);
            auto d = parseArrayAfter(c, "\"d\"", afterAvail);
            auto mvd = parseArrayAfter(c, "\"mvd\"");
            auto pred = parseArrayAfter(c, "\"pred\"");
            auto mv = parseArrayAfter(c, "\"mv\"");
            top.mv_a_x = s16(a[0]); top.mv_a_y = s16(a[1]);
            top.mv_b_x = s16(b[0]); top.mv_b_y = s16(b[1]);
            top.mv_c_x = s16(cc[0]); top.mv_c_y = s16(cc[1]);
            top.mv_d_x = s16(d[0]); top.mv_d_y = s16(d[1]);
            top.mvd_x = s16(mvd[0]); top.mvd_y = s16(mvd[1]);
            top.p_skip = parseBoolAfter(c, "\"p_skip\"");
            top.part_mode = parseIntAfter(c, "\"mode\"");
            top.part_idx = parseIntAfter(c, "\"idx\"");
            bool wantSkip = parseBoolAfter(c, "\"skip_zero\"");
            top.eval();
            int gotPredX = static_cast<int16_t>(top.part_pred_x);
            int gotPredY = static_cast<int16_t>(top.part_pred_y);
            int gotMvX = static_cast<int16_t>(top.part_mv_x);
            int gotMvY = static_cast<int16_t>(top.part_mv_y);
            if (!(gotPredX == pred[0] && gotPredY == pred[1] &&
                  gotMvX == mv[0] && gotMvY == mv[1] &&
                  static_cast<bool>(top.part_skip_zero) == wantSkip)) {
                std::cerr << "FAIL h264_inter_pred RTL: partition MV case mismatch got pred=("
                          << gotPredX << "," << gotPredY
                          << ") mv=(" << gotMvX << "," << gotMvY << ") skip="
                          << static_cast<int>(top.part_skip_zero) << " want pred=(" << pred[0] << ","
                          << pred[1] << ") mv=(" << mv[0] << "," << mv[1] << ") skip="
                          << wantSkip << "\n";
                return 1;
            }
            ++partCases;
        }

        int frameMvCases = 0;
        std::array<Mv, 39 * 30> grid{};
        int frameModeCounts[5] = {0, 0, 0, 0, 0};
        for (int frame = 1; frame <= 3; ++frame) {
            for (int y = 0; y < 30; ++y) {
                for (int x = 0; x < 39; ++x) {
                    Mv a = (x > 0) ? grid[y * 39 + (x - 1)] : Mv{};
                    Mv b = (y > 0) ? grid[(y - 1) * 39 + x] : Mv{};
                    Mv c = (y > 0 && x + 1 < 39) ? grid[(y - 1) * 39 + (x + 1)] : Mv{};
                    Mv d = (y > 0 && x > 0) ? grid[(y - 1) * 39 + (x - 1)] : Mv{};
                    int mode = (x * 3 + y * 5 + frame) % 5;
                    bool pskip = ((x + y + frame) % 4) == 0;
                    int parts = (mode == 1 || mode == 2) ? 2 : ((mode == 3 || mode == 4) ? 4 : 1);
                    Mv finalMv{};
                    for (int idx = 0; idx < parts; ++idx) {
                        int mvdx = pskip ? 0 : (((x + frame + idx) % 5) - 2);
                        int mvdy = pskip ? 0 : (((y + 2 * frame + idx) % 5) - 2);
                        Mv pred = refPredPart(mode, idx, a, b, c, d, pskip);
                        Mv want = pskip ? pred : Mv{pred.x + mvdx, pred.y + mvdy, true};
                        top.avail_a = a.valid; top.avail_b = b.valid; top.avail_c = c.valid; top.avail_d = d.valid;
                        top.mv_a_x = s16(a.x); top.mv_a_y = s16(a.y);
                        top.mv_b_x = s16(b.x); top.mv_b_y = s16(b.y);
                        top.mv_c_x = s16(c.x); top.mv_c_y = s16(c.y);
                        top.mv_d_x = s16(d.x); top.mv_d_y = s16(d.y);
                        top.mvd_x = s16(mvdx); top.mvd_y = s16(mvdy);
                        top.p_skip = pskip; top.part_mode = mode; top.part_idx = idx;
                        top.eval();
                        int gotPredX = static_cast<int16_t>(top.part_pred_x);
                        int gotPredY = static_cast<int16_t>(top.part_pred_y);
                        int gotMvX = static_cast<int16_t>(top.part_mv_x);
                        int gotMvY = static_cast<int16_t>(top.part_mv_y);
                        if (!(gotPredX == pred.x && gotPredY == pred.y && gotMvX == want.x && gotMvY == want.y)) {
                            std::cerr << "FAIL h264_inter_pred RTL: frame MV walk mismatch frame=" << frame
                                      << " mb=(" << x << "," << y << ") mode=" << mode << " idx=" << idx
                                      << " got pred=(" << gotPredX << "," << gotPredY << ") mv=("
                                      << gotMvX << "," << gotMvY << ") want pred=(" << pred.x << ","
                                      << pred.y << ") mv=(" << want.x << "," << want.y << ")\n";
                            return 1;
                        }
                        finalMv = want;
                        ++frameMvCases;
                    }
                    grid[y * 39 + x] = finalMv;
                    ++frameModeCounts[mode];
                }
            }
        }

        std::size_t lumStart = js.find("\"luma_cases\"");
        std::size_t chromaStart = js.find("\"chroma_cases\"");
        for (std::size_t p = js.find("\"frac\"", lumStart); p != std::string::npos && p < chromaStart;
             p = js.find("\"frac\"", p + 6)) {
            auto frac = parseArrayAfter(js, "\"frac\"", p);
            int want = parseIntAfter(js, "\"sample\"", p);
            top.luma_frac_x = frac[0];
            top.luma_frac_y = frac[1];
            top.eval();
            if (!check(top.luma_sample == want, "luma qpel frac mismatch")) return 1;
            ++lumaCases;
        }

        std::size_t clampStart = js.find("\"clamp_cases\"");
        for (std::size_t p = js.find("\"p\"", chromaStart); p != std::string::npos && p < clampStart;
             p = js.find("\"p\"", p + 3)) {
            auto px = parseArrayAfter(js, "\"p\"", p);
            auto frac = parseArrayAfter(js, "\"frac\"", p);
            int want = parseIntAfter(js, "\"sample\"", p);
            top.c_p00 = px[0]; top.c_p10 = px[1]; top.c_p01 = px[2]; top.c_p11 = px[3];
            top.chroma_frac_x = frac[0]; top.chroma_frac_y = frac[1];
            top.eval();
            if (!check(top.chroma_sample == want, "chroma epel mismatch")) return 1;
            ++chromaCases;
        }

        for (int seed = 0; seed < 8; ++seed) {
            const auto refStress = makeLumaRef(seed);
            for (std::size_t i = 0; i < refStress.size(); ++i) top.luma_ref[i] = refStress[i];
            for (int fy = 0; fy < 4; ++fy) {
                for (int fx = 0; fx < 4; ++fx) {
                    top.luma_frac_x = fx;
                    top.luma_frac_y = fy;
                    top.eval();
                    const uint8_t want = refQpel9(refStress, fx, fy);
                    if (top.luma_sample != want) {
                        std::cerr << "FAIL h264_inter_pred RTL: luma qpel stress mismatch seed="
                                  << seed << " frac=(" << fx << "," << fy << ") got="
                                  << int(top.luma_sample) << " want=" << int(want) << "\n";
                        return 1;
                    }
                    ++lumaStressCases;
                }
            }
        }

        for (int seed = 0; seed < 16; ++seed) {
            const int p00 = (13 + seed * 17) & 0xff;
            const int p10 = (101 + seed * 29 + (seed & 3) * 7) & 0xff;
            const int p01 = (77 + seed * 41 + (seed >> 1) * 11) & 0xff;
            const int p11 = (209 + seed * 53 + seed * seed) & 0xff;
            top.c_p00 = p00; top.c_p10 = p10; top.c_p01 = p01; top.c_p11 = p11;
            for (int fy = 0; fy < 8; ++fy) {
                for (int fx = 0; fx < 8; ++fx) {
                    top.chroma_frac_x = fx;
                    top.chroma_frac_y = fy;
                    top.eval();
                    const uint8_t want = refChroma(p00, p10, p01, p11, fx, fy);
                    if (top.chroma_sample != want) {
                        std::cerr << "FAIL h264_inter_pred RTL: chroma epel stress mismatch seed="
                                  << seed << " frac=(" << fx << "," << fy << ") got="
                                  << int(top.chroma_sample) << " want=" << int(want) << "\n";
                        return 1;
                    }
                    ++chromaStressCases;
                }
            }
        }

        std::size_t fetchStart = js.find("\"fetch_cases\"");
        for (std::size_t p = js.find("\"xy\"", clampStart); p != std::string::npos && p < fetchStart;
             p = js.find("\"xy\"", p + 4)) {
            auto xy = parseArrayAfter(js, "\"xy\"", p);
            auto wh = parseArrayAfter(js, "\"wh\"", p);
            auto want = parseArrayAfter(js, "\"clamped\"", p);
            top.clamp_x = s16(xy[0]); top.clamp_y = s16(xy[1]);
            top.clamp_w = wh[0]; top.clamp_h = wh[1];
            top.eval();
            if (!check(top.clamped_x == want[0] && top.clamped_y == want[1], "clamp mismatch")) return 1;
            ++clampCases;
        }

        for (std::size_t p = js.find("\"base\"", fetchStart); p != std::string::npos;
             p = js.find("\"base\"", p + 6)) {
            auto base = parseArrayAfter(js, "\"base\"", p);
            int tap = parseIntAfter(js, "\"tap\"", p);
            auto wh = parseArrayAfter(js, "\"wh\"", p);
            auto want = parseArrayAfter(js, "\"xy\"", p);
            top.fetch_base_x = s16(base[0]); top.fetch_base_y = s16(base[1]);
            top.fetch_tap_idx = tap; top.fetch_w = wh[0]; top.fetch_h = wh[1];
            top.eval();
            if (!check(top.fetch_x == want[0] && top.fetch_y == want[1], "fetch tap addr mismatch")) return 1;
            ++fetchCases;
        }

        for (int mby = 0; mby < 30; ++mby) {
            for (int mbx = 0; mbx < 39; ++mbx) {
                for (int tap : {0, 40, 80}) {
                    const int baseX = mbx * 16;
                    const int baseY = mby * 16;
                    const int wantX = std::max(0, std::min(623, baseX + (tap % 9) - 4));
                    const int wantY = std::max(0, std::min(479, baseY + (tap / 9) - 4));
                    top.fetch_base_x = s16(baseX);
                    top.fetch_base_y = s16(baseY);
                    top.fetch_tap_idx = tap;
                    top.fetch_w = 624;
                    top.fetch_h = 480;
                    top.eval();
                    if (top.fetch_x != wantX || top.fetch_y != wantY) {
                        std::cerr << "FAIL h264_inter_pred RTL: full-frame fetch tap mismatch mb=("
                                  << mbx << "," << mby << ") tap=" << tap << " got=("
                                  << top.fetch_x << "," << top.fetch_y << ") want=("
                                  << wantX << "," << wantY << ")\n";
                        return 1;
                    }
                    ++fetchStressCases;
                }
            }
        }

        std::cout << "OK real RTL sim: h264_inter_pred product RTL "
                  << "mv_cases=" << mvCases << " partition_cases=" << partCases
                  << " frame_mv_cases=" << frameMvCases
                  << " frame_mv_mbs=" << (3 * 39 * 30) << "/1170"
                  << " frame_modes=" << frameModeCounts[0] << "/" << frameModeCounts[1] << "/"
                  << frameModeCounts[2] << "/" << frameModeCounts[3] << "/" << frameModeCounts[4]
                  << " luma_qpel=" << lumaCases << "+" << lumaStressCases
                  << " chroma_epel=" << chromaCases << "+" << chromaStressCases
                  << " clamp=" << clampCases
                  << " fetch=" << fetchCases << "+" << fetchStressCases
                  << " fixture=" << argv[1] << "\n";
        return 0;
    } catch (const std::exception& e) {
        std::cerr << "FAIL h264_inter_pred RTL: " << e.what() << "\n";
        return 1;
    }
}
