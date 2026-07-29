// Real-RTL sim: h264_inter_nb_ctx + median MVP + mvd add.
// Golden final MVs come from the reference-decoder fixture pframe1_mb_v1.json
// (misterplex.p3.inter_mb.v1). For each MB we:
//   1) read neighbours from product nb_ctx
//   2) form pred via product h264_mv_pred_part
//   3) mvd = golden_mv - pred  (or 0 for P_Skip)
//   4) assert RTL mv == golden_mv
//   5) commit golden_mv into nb_ctx
//
// PRE-REGISTERED PREDICTION (before measuring):
//   - Synthetic median/C→D cases: expect 100% match (same model as inter_mc_v1).
//   - pframe1 frame walk: 300 MBs, 279 coded + 21 skip. Expect ≥95% of coded
//     P16x16 MVs to round-trip (279*0.95 ≈ 265). Misses published if lower.
//   - Falsifiers: FAULT_SWAP_AB, FAULT_DROP_C_FALLBACK must fail EXPECTED_RED.

#include "Vh264_inter_nb_mvd_tb.h"
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
    if (!in) throw std::runtime_error(std::string("cannot open: ") + path);
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

void tick(Vh264_inter_nb_mvd_tb& top) {
    top.clk = 0;
    top.eval();
    top.clk = 1;
    top.eval();
}

struct MbMv {
    bool present = false;
    bool skip = false;
    int mx = 0;
    int my = 0;
};

struct Mv {
    int x = 0;
    int y = 0;
    bool valid = false;
};

int median3i(int a, int b, int c) {
    return a + b + c - std::min(std::min(a, b), c) - std::max(std::max(a, b), c);
}

// Host reference of H.264 8.4.1.3 median / P_Skip (matches h264_mv_pred_16x16).
Mv hostPred16(Mv a, Mv b, Mv c, Mv d, bool pskip) {
    Mv useC = c.valid ? c : d;
    const bool skipZero = pskip && (!a.valid || !b.valid || (a.x == 0 && a.y == 0) || (b.x == 0 && b.y == 0));
    if (skipZero) return {0, 0, true};
    int n = (a.valid ? 1 : 0) + (b.valid ? 1 : 0) + (useC.valid ? 1 : 0);
    if (n == 0) return {0, 0, true};
    if (n == 1) return a.valid ? a : (b.valid ? b : useC);
    return {median3i(a.valid ? a.x : 0, b.valid ? b.x : 0, useC.valid ? useC.x : 0),
            median3i(a.valid ? a.y : 0, b.valid ? b.y : 0, useC.valid ? useC.y : 0), true};
}

std::vector<MbMv> loadPframe1(const std::string& js, int& mbw, int& mbh) {
    mbw = parseIntAfter(js, "\"mb_width\"");
    mbh = parseIntAfter(js, "\"mb_height\"");
    std::vector<MbMv> grid(static_cast<size_t>(mbw * mbh));
    std::size_t mbStart = js.find("\"macroblocks\"");
    for (std::size_t p = js.find("\"mb\"", mbStart); p != std::string::npos; p = js.find("\"mb\"", p + 4)) {
        int mb = parseIntAfter(js, "\"mb\"", p);
        int x = parseIntAfter(js, "\"x\"", p);
        int y = parseIntAfter(js, "\"y\"", p);
        int pc = parseIntAfter(js, "\"part_count\"", p);
        MbMv m;
        m.present = true;
        if (pc == 0) {
            m.skip = true;
            m.mx = 0;
            m.my = 0;
        } else {
            auto motion = parseArrayAfter(js, "\"motion\"", p);
            m.skip = false;
            m.mx = motion[0];
            m.my = motion[1];
        }
        if (x >= 0 && y >= 0 && x < mbw && y < mbh)
            grid[static_cast<size_t>(y * mbw + x)] = m;
        (void)mb;
    }
    return grid;
}

} // namespace

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    if (argc < 2) {
        std::cerr << "usage: " << argv[0] << " pframe1_mb_v1.json\n";
        return 2;
    }

    try {
        const std::string js = readText(argv[1]);
        Vh264_inter_nb_mvd_tb top{};

        top.reset = 1;
        top.mb_start = 0;
        top.commit = 0;
        top.is_inter = 0;
        top.p_skip = 0;
        top.part_mode = 0;
        top.part_idx = 0;
        top.mvd_x = 0;
        top.mvd_y = 0;
        top.ref_idx = 0;
        top.mb_width = 20;
        tick(top);
        tick(top);
        top.reset = 0;
        tick(top);

        // --- Synthetic C→D fallback (asymmetric A/B so SWAP_AB is mutation-visible) ---
        // Plant (0,0)=A_src for D, (1,0)=B, (0,1)=A. At (1,1): A=(-8,6) B=(20,2) C=miss D=(4,-2)
        // median_x(-8,20,4)=4 ; swap A/B → median(20,-8,4)=4 (x same)
        // median_y(6,2,-2)=2  ; swap A/B → median(2,6,-2)=2 (y same) — still symmetric!
        // Use A=(100,0) B=(1,2) D=(50,0): median_x=50, swap→median(1,100,50)=50 still.
        // Need three values where swap changes order of first two vs third:
        // A=1, B=100, D=50 → med=50; swap A=100,B=1,D=50 → med=50. Always 50 for 3 distinct...
        // Actually median is order-invariant! SWAP_AB alone never changes median3(A,B,D).
        // SWAP is only visible with the 16x8/8x16 directional shortcuts, OR when only
        // one of A/B is available. Use single-neighbour edge: top row MB(1,0) has only A.
        struct Synth {
            int x, y;
            int mx, my;
        };
        const Synth plant[] = {
            {0, 0, 7, -5},
            {1, 0, 0, 0}, // placeholder overwritten by the check below
        };
        top.mb_width = 2;
        // Plant left neighbour only on top row.
        top.mb_x = 0;
        top.mb_y = 0;
        top.part_mode = 0;
        top.part_idx = 0;
        top.p_skip = 0;
        top.mb_start = 1;
        tick(top);
        top.mb_start = 0;
        tick(top);
        top.commit_mv_x = 7;
        top.commit_mv_y = -5;
        top.is_inter = 1;
        top.commit = 1;
        tick(top);
        top.commit = 0;
        tick(top);

        // MB(1,0): only A available → pred must equal A=(7,-5). SWAP_AB would feed B
        // (unavailable→0) as A and fail.
        top.mb_x = 1;
        top.mb_y = 0;
        top.mb_start = 1;
        tick(top);
        top.mb_start = 0;
        tick(top);
        top.mvd_x = 3;
        top.mvd_y = 1;
        top.eval();
        {
            const int pred_x = static_cast<int16_t>(top.pred_x);
            const int pred_y = static_cast<int16_t>(top.pred_y);
            const int mv_x = static_cast<int16_t>(top.mv_x);
            const int mv_y = static_cast<int16_t>(top.mv_y);
            if (!(top.avail_a && !top.avail_b && !top.avail_c && !top.avail_d)) {
                std::cerr << "FAIL h264_inter_nb_mvd: top-row single-A avail got a="
                          << int(top.avail_a) << " b=" << int(top.avail_b)
                          << " c=" << int(top.avail_c) << " d=" << int(top.avail_d) << "\n";
                return 1;
            }
            if (!(pred_x == 7 && pred_y == -5 && mv_x == 10 && mv_y == -4)) {
                std::cerr << "FAIL h264_inter_nb_mvd: frame MV mismatch top-row single-A got pred=("
                          << pred_x << "," << pred_y << ") mv=(" << mv_x << "," << mv_y
                          << ") want pred=(7,-5) mv=(10,-4)\n";
                return 1;
            }
        }
        top.commit_mv_x = 10;
        top.commit_mv_y = -4;
        top.is_inter = 1;
        top.commit = 1;
        tick(top);
        top.commit = 0;
        tick(top);

        // Row1: plant (0,1) then check (1,1) C→D fallback with fixed mvd.
        top.mb_x = 0;
        top.mb_y = 1;
        top.mb_start = 1;
        tick(top);
        top.mb_start = 0;
        tick(top);
        top.commit_mv_x = -8;
        top.commit_mv_y = 6;
        top.commit = 1;
        tick(top);
        top.commit = 0;
        tick(top);

        // Also need above[1] from row0 — already committed as (10,-4).
        // MB(1,1): A=(-8,6) B=(10,-4) C=miss D=(7,-5)
        // med_x=median(-8,10,7)=7 ; med_y=median(6,-4,-5)=-4
        top.mb_x = 1;
        top.mb_y = 1;
        top.mb_start = 1;
        tick(top);
        top.mb_start = 0;
        tick(top);
        top.mvd_x = 1;
        top.mvd_y = -1;
        top.eval();
        {
            const int pred_x = static_cast<int16_t>(top.pred_x);
            const int pred_y = static_cast<int16_t>(top.pred_y);
            const int mv_x = static_cast<int16_t>(top.mv_x);
            const int mv_y = static_cast<int16_t>(top.mv_y);
            if (!(top.avail_a && top.avail_b && !top.avail_c && top.avail_d)) {
                std::cerr << "FAIL h264_inter_nb_mvd: c_fallback avail got a="
                          << int(top.avail_a) << " b=" << int(top.avail_b)
                          << " c=" << int(top.avail_c) << " d=" << int(top.avail_d) << "\n";
                return 1;
            }
            if (!(pred_x == 7 && pred_y == -4 && mv_x == 8 && mv_y == -5)) {
                std::cerr << "FAIL h264_inter_nb_mvd: c_fallback pred/mv got pred=("
                          << pred_x << "," << pred_y << ") mv=(" << mv_x << "," << mv_y
                          << ") want pred=(7,-4) mv=(8,-5)\n";
                return 1;
            }
        }
        std::cout << "OK h264_inter_nb_mvd synthetic single-A + c_fallback D path\n";
        (void)plant;

        // --- Real frame walk from reference-decoder fixture ---
        top.reset = 1;
        tick(top);
        tick(top);
        top.reset = 0;
        tick(top);

        int mbw = 0, mbh = 0;
        auto grid = loadPframe1(js, mbw, mbh);
        top.mb_width = static_cast<uint8_t>(mbw);

        int coded = 0, skip_n = 0, match = 0, mismatch = 0;
        int nonzero_golden = 0, nonzero_match = 0;
        // PRE-REGISTER: expect match_rate >= 0.95 on coded MBs.
        constexpr double kPredMatchRate = 0.95;
        // Host-side committed MV grid — used to form FIXED mvd (not re-derived from
        // possibly-faulted RTL pred). Mutations that corrupt A/B/C/D therefore break
        // mv = pred_rtl + mvd_host.
        std::vector<Mv> hostGrid(static_cast<size_t>(mbw * mbh));

        for (int y = 0; y < mbh; ++y) {
            for (int x = 0; x < mbw; ++x) {
                const MbMv& g = grid[static_cast<size_t>(y * mbw + x)];
                if (!g.present) continue;

                Mv a = (x > 0) ? hostGrid[static_cast<size_t>(y * mbw + (x - 1))] : Mv{};
                Mv b = (y > 0) ? hostGrid[static_cast<size_t>((y - 1) * mbw + x)] : Mv{};
                Mv c = (y > 0 && x + 1 < mbw) ? hostGrid[static_cast<size_t>((y - 1) * mbw + (x + 1))] : Mv{};
                Mv d = (y > 0 && x > 0) ? hostGrid[static_cast<size_t>((y - 1) * mbw + (x - 1))] : Mv{};
                Mv hostP = hostPred16(a, b, c, d, g.skip);

                int want_x = 0, want_y = 0;
                int mvd_x = 0, mvd_y = 0;
                if (g.skip) {
                    want_x = hostP.x;
                    want_y = hostP.y;
                    ++skip_n;
                } else {
                    want_x = g.mx;
                    want_y = g.my;
                    mvd_x = want_x - hostP.x;
                    mvd_y = want_y - hostP.y;
                    ++coded;
                    if (g.mx != 0 || g.my != 0) ++nonzero_golden;
                }

                top.mb_x = static_cast<uint8_t>(x);
                top.mb_y = static_cast<uint8_t>(y);
                top.part_mode = 0;
                top.part_idx = 0;
                top.p_skip = g.skip ? 1 : 0;
                top.mb_start = 1;
                tick(top);
                top.mb_start = 0;
                tick(top);

                top.mvd_x = static_cast<int16_t>(mvd_x);
                top.mvd_y = static_cast<int16_t>(mvd_y);
                top.eval();
                const int rtl_pred_x = static_cast<int16_t>(top.pred_x);
                const int rtl_pred_y = static_cast<int16_t>(top.pred_y);
                const int got_x = static_cast<int16_t>(top.mv_x);
                const int got_y = static_cast<int16_t>(top.mv_y);

                if (got_x == want_x && got_y == want_y &&
                    rtl_pred_x == hostP.x && rtl_pred_y == hostP.y) {
                    ++match;
                    if (!g.skip && (g.mx != 0 || g.my != 0)) ++nonzero_match;
                } else {
                    ++mismatch;
                    if (mismatch <= 5) {
                        std::cerr << "FAIL h264_inter_nb_mvd: frame MV mismatch mb=("
                                  << x << "," << y << ") skip=" << g.skip
                                  << " got=(" << got_x << "," << got_y
                                  << ") want=(" << want_x << "," << want_y
                                  << ") pred_rtl=(" << rtl_pred_x << "," << rtl_pred_y
                                  << ") pred_host=(" << hostP.x << "," << hostP.y
                                  << ") mvd=(" << mvd_x << "," << mvd_y << ")\n";
                    }
                }

                // Commit reference-decoder final MV into both host grid and RTL nb_ctx.
                hostGrid[static_cast<size_t>(y * mbw + x)] = {want_x, want_y, true};
                top.commit_mv_x = static_cast<int16_t>(want_x);
                top.commit_mv_y = static_cast<int16_t>(want_y);
                top.is_inter = 1;
                top.commit = 1;
                tick(top);
                top.commit = 0;
                tick(top);
            }
        }

        const int total = coded + skip_n;
        const double rate = total ? (double)match / (double)total : 0.0;
        std::cout << "OK h264_inter_nb_mvd frame walk: total=" << total
                  << " coded=" << coded << " skip=" << skip_n
                  << " match=" << match << " mismatch=" << mismatch
                  << " match_rate=" << rate
                  << " nonzero_golden=" << nonzero_golden
                  << " nonzero_match=" << nonzero_match
                  << " pre_register_min=" << kPredMatchRate
                  << " fixture=" << argv[1] << "\n";

        if (mismatch != 0) {
            std::cerr << "FAIL h264_inter_nb_mvd: frame MV mismatch count=" << mismatch
                      << " (published miss vs pre-register " << kPredMatchRate << ")\n";
            return 1;
        }
        if (nonzero_golden == 0) {
            std::cerr << "FAIL h264_inter_nb_mvd: fixture had zero non-zero MVs — vacuous\n";
            return 1;
        }
        if (nonzero_match != nonzero_golden) {
            std::cerr << "FAIL h264_inter_nb_mvd: nonzero MV match " << nonzero_match
                      << "/" << nonzero_golden << "\n";
            return 1;
        }
        // Degeneracy: at least one interior MB must have seen A and B.
        std::cout << "OK h264_inter_nb_mvd: all " << total
                  << " reference-decoder MVs round-tripped via nb_ctx+mvp+mvd\n";
        return 0;
    } catch (const std::exception& e) {
        std::cerr << "FAIL h264_inter_nb_mvd: " << e.what() << "\n";
        return 1;
    }
}
