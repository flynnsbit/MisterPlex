// Unit: CAVLC residual + I-slice walk + recon (Phase 3.3f/g/h).
#include "libmisterplex/h264_cavlc.hpp"
#include "libmisterplex/h264_recon.hpp"
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

    // Full I-slice residual walk (3.3h) — require complete slice
    auto w = misterplex::walkISliceResiduals(blob.data(), blob.size());
    if (w.mb_decoded != w.mb_total || w.mb_total <= 0) {
        std::printf("FAIL: walk mb_decoded=%d/%d fail_mb=%d reason=%s\n", w.mb_decoded, w.mb_total,
                    w.fail_mb, w.fail_reason ? w.fail_reason : "?");
        return 1;
    }

    // Reconstruct I-slice → YUV; RGB565 smoke
    auto rec = misterplex::recon::reconISlice(blob.data(), blob.size());
    if (rec.mb_decoded != rec.mb_total || rec.y.empty()) {
        std::printf("FAIL: recon mb=%d/%d reason=%s\n", rec.mb_decoded, rec.mb_total,
                    rec.fail_reason ? rec.fail_reason : "?");
        return 1;
    }
    std::vector<uint16_t> rgb;
    misterplex::recon::yuv420ToRgb565(rec.y.data(), rec.u.data(), rec.v.data(), rec.width,
                                      rec.height, rgb);
    if (rgb.size() != static_cast<size_t>(rec.width * rec.height)) {
        std::printf("FAIL: rgb565 size\n");
        return 1;
    }

    std::printf("test_cavlc_dc: OK probe_tc=%d t1=%d walk=%d/%d FULL recon=%dx%d rgb=%zu\n",
                r.total_coeff, r.trailing_ones, w.mb_decoded, w.mb_total, rec.width, rec.height,
                rgb.size());
    return 0;
}
