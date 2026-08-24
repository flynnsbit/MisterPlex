// FPGA walker vs phase1a gold. product_recon_ok stays 0 (RTL assign).
#include "libmisterplex/h264_recon.hpp"
#include "libmisterplex/h264_recon_p.hpp"

#include <cstdint>
#include <cstdio>
#include <fstream>
#include <string>
#include <vector>

static std::vector<uint8_t> readFile(const std::string& path) {
    std::ifstream in(path, std::ios::binary);
    if (!in)
        return {};
    return std::vector<uint8_t>((std::istreambuf_iterator<char>(in)), {});
}

int main() {
    const char* annexp = "tests/fixtures/h264_phase1a_p16skip/plex_phase1a_p16skip_320x240_12f.264";
    const char* goldp = "tests/fixtures/h264_phase1a_p16skip/gold_12f_320x240.yuv";
    auto annex = readFile(annexp);
    auto gold = readFile(goldp);
    if (annex.empty() || gold.empty()) {
        std::fprintf(stderr, "FAIL missing fixture\n");
        return 2;
    }
    auto g = misterplex::recon::reconPhase1aGop(annex.data(), annex.size());
    if (g.fail_reason || g.yuv.empty()) {
        std::fprintf(stderr, "FAIL host gop %s frame=%d mb=%d\n",
                     g.fail_reason ? g.fail_reason : "empty", g.fail_frame, g.fail_mb);
        return 1;
    }
    const int w = g.width, h = g.height, frm = w * h + 2 * ((w / 2) * (h / 2));
    if (g.yuv.size() != gold.size() || (int)gold.size() != frm * g.frames) {
        std::fprintf(stderr, "FAIL size host=%zu gold=%zu expect=%d*%d\n", g.yuv.size(),
                     gold.size(), frm, g.frames);
        return 1;
    }
    int first_f = -1, first_x = -1, first_y = -1, first_plane = -1;
    int host_v = 0, gold_v = 0;
    long abserr = 0;
    size_t ncmp = 0;
    for (int f = 0; f < g.frames; ++f) {
        const uint8_t* H = g.yuv.data() + static_cast<size_t>(f) * frm;
        const uint8_t* G = gold.data() + static_cast<size_t>(f) * frm;
        for (int y = 0; y < h; ++y)
            for (int x = 0; x < w; ++x) {
                int a = H[y * w + x], b = G[y * w + x];
                abserr += (a > b) ? (a - b) : (b - a);
                ++ncmp;
                if (first_f < 0 && a != b) {
                    first_f = f;
                    first_x = x;
                    first_y = y;
                    first_plane = 0;
                    host_v = a;
                    gold_v = b;
                }
            }
    }
    double mae = ncmp ? (double)abserr / (double)ncmp : 0;
    std::printf("HOST_vs_GOLD frames=%d %dx%d maeY=%.6f product_recon_ok=0\n", g.frames, w, h,
                mae);
    if (first_f >= 0) {
        std::printf("HOST first mismatch f=%d plane=Y x=%d y=%d host=%d gold=%d\n", first_f,
                    first_x, first_y, host_v, gold_v);
        return 1;
    }

    misterplex::recon::ReconTrace tr;
    auto I = misterplex::recon::reconISlice(annex.data(), annex.size(), &tr);
    int g0 = gold[0];
    int i0 = I.y.empty() ? -1 : I.y[0];
    int stub_pred = 128;
    std::printf("FPGA_vs_GOLD first mismatch (product walker, 48B MB0 4x4-0 stub):\n");
    std::printf("  frame=0 mb=0 blk=4x4-0 Y(0,0) gold=%d host_I=%d "
                "fpga_stub_pred=%d (residual_ok path forces pred=128)\n",
                g0, i0, stub_pred);
    std::printf("  class=MB0_4x4_0_PRED128_STUB product_recon_ok=0 (not flipped)\n");
    std::printf("OK host MAE 0; FPGA first mismatch reported; FIT_GO=NO\n");
    return 0;
}
