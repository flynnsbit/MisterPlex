#include "Vh264_inter_pred_tb.h"
#include "verilated.h"

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
        int mvCases = 0, lumaCases = 0, chromaCases = 0, clampCases = 0, fetchCases = 0;

        const auto ref = parseArrayAfter(js, "\"luma_ref_9x9\"");
        if (!check(ref.size() == 81, "luma_ref_9x9 size")) return 1;
        for (std::size_t i = 0; i < ref.size(); ++i) top.luma_ref[i] = static_cast<uint8_t>(ref[i]);

        std::size_t mvStart = js.find("\"mv_cases\"");
        std::size_t mvEnd = js.find("\"luma_ref_9x9\"");
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

        std::cout << "OK real RTL sim: h264_inter_pred product RTL "
                  << "mv_cases=" << mvCases << " luma_qpel=" << lumaCases
                  << " chroma_epel=" << chromaCases << " clamp=" << clampCases
                  << " fetch=" << fetchCases
                  << " fixture=" << argv[1] << "\n";
        return 0;
    } catch (const std::exception& e) {
        std::cerr << "FAIL h264_inter_pred RTL: " << e.what() << "\n";
        return 1;
    }
}
