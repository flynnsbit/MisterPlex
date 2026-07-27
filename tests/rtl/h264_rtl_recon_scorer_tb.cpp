// RTL-in-the-loop reconstruction scorer — C++ Verilator driver.
// Feeds golden coefficients + prediction into the RTL dequant/IDCT/recon
// pipeline and compares output against golden reconstruction.
//
// VERIFICATION TARGET: RTL (h264_dequant4x4, h264_idct4x4, h264_recon4x4)
// This does NOT test CAVLC parsing or intra prediction derivation.
// It tests: given correct inputs, does the hardware arithmetic produce
// correct reconstruction output?

#include "Vh264_rtl_recon_scorer_tb.h"

#include <array>
#include <cstdint>
#include <cstdlib>
#include <fstream>
#include <iomanip>
#include <iostream>
#include <sstream>
#include <string>
#include <vector>

// Minimal JSON value parser (no dependencies)
namespace json {
struct Value {
    enum Type { Null, Int, Arr, Obj, Str } type = Null;
    int64_t ival = 0;
    std::string sval;
    std::vector<Value> arr;
    std::vector<std::pair<std::string, Value>> obj;
    const Value& operator[](const std::string& key) const {
        for (const auto& p : obj)
            if (p.first == key) return p.second;
        static Value null;
        return null;
    }
    const Value& operator[](std::size_t i) const {
        if (i < arr.size()) return arr[i];
        static Value null;
        return null;
    }
    int toInt() const { return static_cast<int>(ival); }
    std::size_t size() const { return type == Arr ? arr.size() : obj.size(); }
};

static void skipWs(const std::string& s, std::size_t& i) {
    while (i < s.size() && (s[i] == ' ' || s[i] == '\n' || s[i] == '\r' || s[i] == '\t')) ++i;
}

static Value parse(const std::string& s, std::size_t& i);

static Value parseStr(const std::string& s, std::size_t& i) {
    Value v; v.type = Value::Str;
    ++i; // skip opening "
    while (i < s.size() && s[i] != '"') {
        if (s[i] == '\\') { ++i; if (i < s.size()) v.sval += s[i++]; }
        else v.sval += s[i++];
    }
    if (i < s.size()) ++i; // skip closing "
    return v;
}

static Value parseNum(const std::string& s, std::size_t& i) {
    Value v; v.type = Value::Int;
    bool neg = false;
    if (s[i] == '-') { neg = true; ++i; }
    while (i < s.size() && s[i] >= '0' && s[i] <= '9')
        v.ival = v.ival * 10 + (s[i++] - '0');
    if (neg) v.ival = -v.ival;
    // skip fractional/exponent (not needed for this scorer)
    if (i < s.size() && s[i] == '.') { ++i; while (i < s.size() && s[i] >= '0' && s[i] <= '9') ++i; }
    if (i < s.size() && (s[i] == 'e' || s[i] == 'E')) { ++i; if (i < s.size() && (s[i]=='+' || s[i]=='-')) ++i; while (i < s.size() && s[i] >= '0' && s[i] <= '9') ++i; }
    return v;
}

static Value parseArr(const std::string& s, std::size_t& i) {
    Value v; v.type = Value::Arr;
    ++i; skipWs(s, i);
    while (i < s.size() && s[i] != ']') {
        v.arr.push_back(parse(s, i));
        skipWs(s, i);
        if (i < s.size() && s[i] == ',') ++i;
        skipWs(s, i);
    }
    if (i < s.size()) ++i;
    return v;
}

static Value parseObj(const std::string& s, std::size_t& i) {
    Value v; v.type = Value::Obj;
    ++i; skipWs(s, i);
    while (i < s.size() && s[i] != '}') {
        auto key = parseStr(s, i);
        skipWs(s, i);
        if (i < s.size() && s[i] == ':') ++i;
        skipWs(s, i);
        v.obj.emplace_back(key.sval, parse(s, i));
        skipWs(s, i);
        if (i < s.size() && s[i] == ',') ++i;
        skipWs(s, i);
    }
    if (i < s.size()) ++i;
    return v;
}

static Value parse(const std::string& s, std::size_t& i) {
    skipWs(s, i);
    if (i >= s.size()) return {};
    if (s[i] == '"') return parseStr(s, i);
    if (s[i] == '[') return parseArr(s, i);
    if (s[i] == '{') return parseObj(s, i);
    if (s[i] == '-' || (s[i] >= '0' && s[i] <= '9')) return parseNum(s, i);
    // null/true/false
    if (s.substr(i, 4) == "null") { i += 4; return {}; }
    if (s.substr(i, 4) == "true") { i += 4; Value v; v.type = Value::Int; v.ival = 1; return v; }
    if (s.substr(i, 5) == "false") { i += 5; Value v; v.type = Value::Int; v.ival = 0; return v; }
    ++i;
    return {};
}

Value parseFile(const std::string& path) {
    std::ifstream in(path);
    if (!in) { std::cerr << "Cannot open: " << path << "\n"; std::exit(1); }
    std::string s((std::istreambuf_iterator<char>(in)), {});
    std::size_t i = 0;
    return parse(s, i);
}
} // namespace json

int main(int argc, char** argv) {
    if (argc < 2) {
        std::cerr << "Usage: " << argv[0] << " <golden_mb0_json>\n";
        return 1;
    }

    auto golden = json::parseFile(argv[1]);
    if (golden["format"].sval != "misterplex.p3.mb_golden.v1") {
        std::cerr << "FAIL RTL_RECON_SCORER: unknown golden format: " << golden["format"].sval << "\n";
        return 1;
    }

    const int qp = golden["macroblock"]["qp"].toInt();
    const auto& blocks = golden["residual"]["luma4x4"];
    const auto& predY = golden["samples"]["pred_y"];
    const auto& reconY = golden["samples"]["recon_y"];

    if (blocks.size() != 16) {
        std::cerr << "FAIL RTL_RECON_SCORER: expected 16 luma4x4 blocks, got " << blocks.size() << "\n";
        return 1;
    }
    if (predY.size() != 256 || reconY.size() != 256) {
        std::cerr << "FAIL RTL_RECON_SCORER: expected 256 pred/recon Y samples\n";
        return 1;
    }

    Vh264_rtl_recon_scorer_tb dut;
    dut.clk = 0;
    dut.reset = 1;
    dut.inject_valid = 0;
    dut.eval();
    dut.clk = 1; dut.eval();
    dut.clk = 0; dut.eval();
    dut.reset = 0;

    int totalPixels = 0;
    int exactPixels = 0;
    int totalBlocks = 0;
    int exactBlocks = 0;
    int nonZeroResidualBlocks = 0;
    int firstBadBlock = -1;
    int firstBadPixel = -1;
    int firstBadGot = 0;
    int firstBadRef = 0;
    uint64_t sumAbsDiff = 0;

    // H.264 4x4 block raster scan order within a 16x16 macroblock:
    // Block index → (bx, by) in 4-pixel units
    static const int blockX[16] = {0,1,0,1, 2,3,2,3, 0,1,0,1, 2,3,2,3};
    static const int blockY[16] = {0,0,1,1, 0,0,1,1, 2,2,3,3, 2,2,3,3};

    for (int blk = 0; blk < 16; ++blk) {
        const auto& b = blocks[static_cast<std::size_t>(blk)];
        const auto& coeffs = b["coefficients_zigzag"];
        const auto& goldenRecon = b["recon"];  // per-block recon (16 values in raster)

        // Set coefficients (zigzag scan order as stored in golden)
        for (int i = 0; i < 16; ++i)
            dut.inject_coeff[i] = static_cast<int16_t>(coeffs[static_cast<std::size_t>(i)].toInt());

        dut.inject_qp = static_cast<uint8_t>(qp);

        // Set prediction: extract the 4x4 block from the 16x16 pred array
        const int bx = blockX[blk] * 4;
        const int by = blockY[blk] * 4;
        for (int py = 0; py < 4; ++py) {
            for (int px = 0; px < 4; ++px) {
                const int idx = (by + py) * 16 + (bx + px);
                dut.inject_pred[py * 4 + px] = static_cast<uint8_t>(predY[static_cast<std::size_t>(idx)].toInt());
            }
        }

        dut.inject_valid = 1;
        dut.clk = 0; dut.eval();
        dut.clk = 1; dut.eval();

        // Read reconstruction output and compare
        bool blockExact = true;
        bool hasNonZeroResidual = false;

        for (int i = 0; i < 16; ++i) {
            const int got = static_cast<int>(dut.recon_out[i]);
            // Golden recon from the per-block array
            int ref;
            if (goldenRecon.size() == 16) {
                ref = goldenRecon[static_cast<std::size_t>(i)].toInt();
            } else {
                // Fall back to full-MB recon array
                const int px = bx + (i % 4);
                const int py = by + (i / 4);
                ref = reconY[static_cast<std::size_t>(py * 16 + px)].toInt();
            }

            const int diff = got > ref ? got - ref : ref - got;
            sumAbsDiff += static_cast<uint64_t>(diff);
            ++totalPixels;
            if (diff == 0) {
                ++exactPixels;
            } else {
                blockExact = false;
                if (firstBadBlock < 0) {
                    firstBadBlock = blk;
                    firstBadPixel = i;
                    firstBadGot = got;
                    firstBadRef = ref;
                }
            }

            if (dut.idct_out[i] != 0) hasNonZeroResidual = true;
        }

        ++totalBlocks;
        if (blockExact) ++exactBlocks;
        if (hasNonZeroResidual) ++nonZeroResidualBlocks;
    }

    dut.inject_valid = 0;
    dut.final();

    // Degeneracy assertion: at least some blocks must have non-zero residual
    if (nonZeroResidualBlocks == 0) {
        std::cerr << "FAIL RTL_RECON_SCORER degeneracy: ALL 16 blocks have zero IDCT residual. "
                     "Transform was never exercised.\n";
        return 1;
    }

    const double mae = totalPixels > 0 ? static_cast<double>(sumAbsDiff) / totalPixels : 0.0;

    std::cout << "RTL_RECON_SCORER verification_target=RTL "
              << "module=h264_dequant4x4+h264_idct4x4+h264_recon4x4 "
              << "scope=MB0_all_luma_blocks "
              << "plane=Y "
              << "qp=" << qp
              << " blocks_exact=" << exactBlocks << "/" << totalBlocks
              << " pixels_exact=" << exactPixels << "/" << totalPixels
              << " mae=" << std::fixed << std::setprecision(6) << mae
              << " non_zero_residual_blocks=" << nonZeroResidualBlocks << "/16"
              << "\n";

    if (firstBadBlock >= 0) {
        std::cout << "RTL_RECON_SCORER first_divergence "
                  << "block=" << firstBadBlock
                  << " pixel=" << firstBadPixel
                  << " got=" << firstBadGot
                  << " ref=" << firstBadRef
                  << " diff=" << (firstBadGot - firstBadRef)
                  << "\n";
    }

    if (exactPixels == totalPixels) {
        std::cout << "RTL_RECON_SCORER PASS: all " << totalPixels
                  << " luma pixels bit-exact (RTL vs golden)\n";
        return 0;
    } else {
        std::cerr << "FAIL RTL_RECON_SCORER: " << (totalPixels - exactPixels)
                  << "/" << totalPixels << " pixels differ\n";
        return 1;
    }
}
