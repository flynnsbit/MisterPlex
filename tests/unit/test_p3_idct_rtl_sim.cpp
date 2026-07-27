// Phase 3.3l-2 prep: deterministic host-side RTL harness for the first residual
// inverse-quant + IDCT path. It drives the checked-in Annex-B vector through the
// same residual coefficients exported by slice_hdr_parser.sv, then simulates the
// new h264_iq_idct_4x4.sv equations against mb0_luma_v1.json block 0.
#include "libmisterplex/h264_cavlc.hpp"
#include "libmisterplex/h264_residual_gold.hpp"

#include <array>
#include <cctype>
#include <cstdio>
#include <cstdlib>
#include <fstream>
#include <sstream>
#include <string>
#include <vector>

namespace gold = misterplex::residual_gold;

static std::vector<uint8_t> readBinary(const char* path) {
    std::ifstream in(path, std::ios::binary);
    if (!in)
        return {};
    return std::vector<uint8_t>((std::istreambuf_iterator<char>(in)), {});
}

static std::string readText(const char* path) {
    std::ifstream in(path);
    if (!in)
        return {};
    std::ostringstream ss;
    ss << in.rdbuf();
    return ss.str();
}

static bool contains(const std::string& s, const char* needle) {
    return s.find(needle) != std::string::npos;
}

static bool sourceGuards() {
    const std::string rtl = readText("fpga/Plex_MiSTer/rtl/h264_iq_idct_4x4.sv");
    const std::string slp = readText("fpga/Plex_MiSTer/rtl/slice_hdr_parser.sv");
    const std::string qip = readText("fpga/Plex_MiSTer/files.qip");
    if (rtl.empty() || slp.empty() || qip.empty()) {
        std::printf("FAIL rtl-src: missing h264_iq_idct_4x4.sv, slice_hdr_parser.sv, or files.qip\n");
        return false;
    }
    if (!contains(qip, "set_global_assignment -name SYSTEMVERILOG_FILE rtl/h264_iq_idct_4x4.sv")) {
        std::printf("FAIL rtl-src: files.qip does not include h264_iq_idct_4x4.sv\n");
        return false;
    }

    const char* rtlNeedles[] = {
        "module h264_dequant4x4",
        "module h264_idct4x4",
        "module h264_recon4x4",
        "v = ($signed(c) * qmul + 32'sd32) >>> 6;",
        "assign dequant[1]  = (max_coeff > 5'd1)  ? dequant_one(coeff[1],  qp, 5'd1,  1'b0) : 18'sd0;",
        "assign dequant[4]  = (max_coeff > 5'd2)  ? dequant_one(coeff[2],  qp, 5'd2,  1'b0) : 18'sd0;",
        "wire signed [31:0] b0  = dequant[0] + 18'sd32;",
        "assign residual[0]  = sat18((c0_z0 + c0_z3) >>> 6);",
        "assign recon[0]  = clip8($signed({1'b0, pred[0]})  + residual[0]);",
    };
    for (const char* n : rtlNeedles) {
        if (!contains(rtl, n)) {
            std::printf("FAIL rtl-src: h264_iq_idct_4x4.sv missing signature: %s\n", n);
            return false;
        }
    }

    const char* slpNeedles[] = {
        "output reg signed [8:0] residual_coeff [0:15]",
        "cn = cn + $signed({2'b0, runv[k]}) + 6'sd1;",
        "tmpc[cn[3:0]] = lev[k];",
        "residual_coeff[j] <= tmpc[j];",
        "cs = cs ^ sat8(tmpc[j]);",
        "residual_place_pulse <= 1'b1;",
    };
    for (const char* n : slpNeedles) {
        if (!contains(slp, n)) {
            std::printf("FAIL rtl-src: slice_hdr_parser.sv missing residual signature: %s\n", n);
            return false;
        }
    }
    return true;
}

static bool extractNamedArray(const std::string& json, const std::string& key, std::vector<int>& out) {
    const std::string quoted = "\"" + key + "\"";
    size_t p = json.find(quoted);
    if (p == std::string::npos)
        return false;
    p = json.find('[', p);
    if (p == std::string::npos)
        return false;
    int depth = 0;
    size_t end = p;
    for (; end < json.size(); ++end) {
        if (json[end] == '[')
            ++depth;
        else if (json[end] == ']') {
            --depth;
            if (depth == 0)
                break;
        }
    }
    if (end >= json.size())
        return false;
    out.clear();
    const std::string body = json.substr(p + 1, end - p - 1);
    size_t i = 0;
    while (i < body.size()) {
        while (i < body.size() && !(body[i] == '-' || std::isdigit(static_cast<unsigned char>(body[i]))))
            ++i;
        if (i >= body.size())
            break;
        char* ep = nullptr;
        long v = std::strtol(body.c_str() + i, &ep, 10);
        out.push_back(static_cast<int>(v));
        i = static_cast<size_t>(ep - body.c_str());
    }
    return true;
}

static bool loadBlock0(std::array<int, 16>& pred, std::array<int, 16>& deq,
                       std::array<int, 16>& idct, std::array<int, 16>& recon) {
    const std::string json = readText("tests/fixtures/p3_host_recon/mb0_luma_v1.json");
    if (json.empty() || !contains(json, "\"format\": \"misterplex.p3.luma_mb.v1\"")) {
        std::printf("FAIL fixture: mb0_luma_v1.json missing or wrong format\n");
        return false;
    }
    size_t blocks = json.find("\"blocks\"");
    size_t block0 = json.find("\"block\": 0", blocks);
    size_t block1 = json.find("\"block\": 1", block0);
    if (blocks == std::string::npos || block0 == std::string::npos || block1 == std::string::npos) {
        std::printf("FAIL fixture: cannot isolate block 0\n");
        return false;
    }
    const std::string b0 = json.substr(block0, block1 - block0);
    std::vector<int> tmp;
    auto fill = [&](const char* key, std::array<int, 16>& dst) {
        if (!extractNamedArray(b0, key, tmp) || tmp.size() != 16) {
            std::printf("FAIL fixture: block0 %s size=%zu\n", key, tmp.size());
            return false;
        }
        for (size_t i = 0; i < 16; ++i)
            dst[i] = tmp[i];
        return true;
    };
    return fill("pred", pred) && fill("dequant", deq) && fill("idct", idct) && fill("recon", recon);
}

static int normAdjust(int qp, int i, int j) {
    static const int kNorm[6][3] = {
        {10, 13, 16}, {11, 14, 18}, {13, 16, 20},
        {14, 18, 23}, {16, 20, 25}, {18, 23, 29},
    };
    const int mi = ((i & 1) + (j & 1)) == 0 ? 0 : (((i & 1) + (j & 1)) == 1 ? 1 : 2);
    return kNorm[qp % 6][mi];
}

static void rtlDequant4x4(const int16_t coeff[16], int qp, int maxCoeff, int deq[16]) {
    static const int zz[16] = {0, 1, 4, 8, 5, 2, 3, 6, 9, 12, 13, 10, 7, 11, 14, 15};
    for (int i = 0; i < 16; ++i)
        deq[i] = 0;
    for (int scan = 0; scan < maxCoeff; ++scan) {
        if (!coeff[scan])
            continue;
        const int pos = zz[scan];
        const int row = pos / 4;
        const int col = pos % 4;
        const int qmul = (normAdjust(qp, row, col) * 16) << (qp / 6 + 2);
        int c = coeff[scan];
        if (const char* p = std::getenv("MPLEX_P3_IDCT_SIM_PERTURB")) {
            if (std::string(p) == "dequant_ac" && scan == 1)
                c = -c;
        }
        deq[pos] = (c * qmul + 32) >> 6;
    }
}

static void rtlIdct4x4(const int deq[16], int residual[16]) {
    int b[4][4];
    for (int r = 0; r < 4; ++r)
        for (int c = 0; c < 4; ++c)
            b[r][c] = deq[r * 4 + c];
    b[0][0] += 32;
    int t[4][4];
    for (int r = 0; r < 4; ++r) {
        const int z0 = b[r][0] + b[r][2];
        const int z1 = b[r][0] - b[r][2];
        const int z2 = (b[r][1] >> 1) - b[r][3];
        const int z3 = b[r][1] + (b[r][3] >> 1);
        t[r][0] = z0 + z3;
        t[r][1] = z1 + z2;
        t[r][2] = z1 - z2;
        t[r][3] = z0 - z3;
    }
    for (int c = 0; c < 4; ++c) {
        const int z0 = t[0][c] + t[2][c];
        const int z1 = t[0][c] - t[2][c];
        const int z2 = (t[1][c] >> 1) - t[3][c];
        const int z3 = t[1][c] + (t[3][c] >> 1);
        residual[0 * 4 + c] = (z0 + z3) >> 6;
        residual[1 * 4 + c] = (z1 + z2) >> 6;
        residual[2 * 4 + c] = (z1 - z2) >> 6;
        residual[3 * 4 + c] = (z0 - z3) >> 6;
    }
}

static int clip8(int v) {
    if (v < 0)
        return 0;
    if (v > 255)
        return 255;
    return v;
}

static bool compare16(const char* label, const int got[16], const std::array<int, 16>& exp) {
    for (int i = 0; i < 16; ++i) {
        if (got[i] != exp[i]) {
            std::printf("FAIL %s[%d]: got=%d want=%d\n", label, i, got[i], exp[i]);
            std::printf("  got:");
            for (int j = 0; j < 16; ++j)
                std::printf(" %d", got[j]);
            std::printf("\n  exp:");
            for (int j = 0; j < 16; ++j)
                std::printf(" %d", exp[j]);
            std::printf("\n");
            return false;
        }
    }
    return true;
}

int main() {
    if (!sourceGuards())
        return 1;

    std::array<int, 16> expPred{}, expDeq{}, expIdct{}, expRecon{};
    if (!loadBlock0(expPred, expDeq, expIdct, expRecon))
        return 1;

    const char* vecPath = "tests/fixtures/p3_host_recon/plex_real_baseline_320x240_1f.264";
    const auto annexb = readBinary(vecPath);
    if (annexb.size() != 6739) {
        std::printf("FAIL vector: size=%zu want 6739 (%s)\n", annexb.size(), vecPath);
        return 1;
    }

    auto r = misterplex::cavlc::probeFirstI16Dc(annexb.data(), annexb.size());
    if (!r.ok || r.total_coeff != gold::kTc || r.trailing_ones != gold::kT1 ||
        !gold::coeffScanMatches(r.coeff)) {
        std::printf("FAIL slice residual: ok=%d tc=%d t1=%d coeff0=%d csum=0x%02x\n",
                    r.ok ? 1 : 0, r.total_coeff, r.trailing_ones, r.ok ? r.coeff[0] : 0,
                    r.ok ? static_cast<unsigned>(gold::coeffCsum8(r.coeff)) : 0U);
        return 1;
    }

    int deq[16];
    int idct[16];
    int recon[16];
    rtlDequant4x4(r.coeff, 25, 16, deq);
    rtlIdct4x4(deq, idct);
    for (int i = 0; i < 16; ++i)
        recon[i] = clip8(expPred[i] + idct[i]);

    if (!compare16("dequant", deq, expDeq))
        return 1;
    if (!compare16("idct", idct, expIdct))
        return 1;
    if (!compare16("recon", recon, expRecon))
        return 1;

    int sum = 0;
    for (int v : recon)
        sum += v;
    const int mean = (sum + 8) / 16;
    std::printf("test_p3_idct_rtl_sim: OK vector_bytes=%zu coeff_csum=0x%02x tc=%d t1=%d "
                "dequant16/idct16/recon16 match mb0_luma_v1 block0 (y00=%d mean=%d)\n",
                annexb.size(), static_cast<unsigned>(gold::coeffCsum8(r.coeff)), r.total_coeff,
                r.trailing_ones, recon[0], mean);
    return 0;
}
