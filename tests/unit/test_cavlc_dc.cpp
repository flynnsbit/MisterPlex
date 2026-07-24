// Unit: CAVLC first residual + I-slice walk (Phase 3.3f/g/h).
#include "libmisterplex/h264_cavlc.hpp"
#include "libmisterplex/h264_slice_walk.hpp"

#include <cstdio>
#include <cstdlib>
#include <fstream>
#include <vector>

static std::vector<uint8_t> readFile(const char* path) {
    std::ifstream in(path, std::ios::binary);
    if (!in)
        return {};
    return std::vector<uint8_t>((std::istreambuf_iterator<char>(in)), {});
}

int main(int argc, char** argv) {
    const char* path = argc > 1 ? argv[1] : "/tmp/plex_real_baseline.h264";
    auto blob = readFile(path);
    if (blob.empty()) {
        if (std::system("python3 scripts/gen_test_annexb_real.py /tmp/plex_real_baseline.h264") !=
            0) {
            std::printf("FAIL: no bitstream\n");
            return 1;
        }
        blob = readFile("/tmp/plex_real_baseline.h264");
    }

    // First residual probe (I_NxN first coded 4x4 or I16 DC)
    auto r = misterplex::cavlc::probeFirstI16Dc(blob.data(), blob.size());
    if (!r.ok || r.total_coeff < 0 || r.total_coeff > 16) {
        std::printf("FAIL: residual probe ok=%d tc=%d\n", r.ok, r.total_coeff);
        return 1;
    }

    // Full I-slice residual walk (3.3h). Require ≥4 MBs; full 300 is the goal.
    auto w = misterplex::walkISliceResiduals(blob.data(), blob.size());
    if (w.mb_decoded < 4) {
        std::printf("FAIL: walk mb_decoded=%d/%d fail_mb=%d reason=%s\n", w.mb_decoded, w.mb_total,
                    w.fail_mb, w.fail_reason ? w.fail_reason : "?");
        return 1;
    }
    std::printf("test_cavlc_dc: OK probe_tc=%d t1=%d walk=%d/%d%s\n", r.total_coeff,
                r.trailing_ones, w.mb_decoded, w.mb_total,
                (w.mb_decoded == w.mb_total) ? " FULL" : "");
    if (w.mb_decoded != w.mb_total)
        std::printf("  (partial) fail_mb=%d reason=%s first_tc=%d\n", w.fail_mb,
                    w.fail_reason ? w.fail_reason : "?", w.first_residual_tc);
    return 0;
}
