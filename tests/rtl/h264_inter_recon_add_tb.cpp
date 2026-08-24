#include "Vh264_inter_recon_add_tb.h"
#include "verilated.h"

#include <cstdint>
#include <iostream>

namespace {

int clipAdd(int pred, int residual) {
    const int sum = pred + residual;
    if (sum < 0) return 0;
    if (sum > 255) return 255;
    return sum;
}

int runCase(Vh264_inter_recon_add_tb& top, int pred, int residual, int want, const char* label) {
    top.pred = static_cast<uint8_t>(pred);
    top.residual = static_cast<int16_t>(residual);
    top.eval();
    const int got = static_cast<int>(top.recon);
    if (got != want) {
        std::cerr << "FAIL h264_inter_recon_add " << label
                  << " pred=" << pred << " residual=" << residual
                  << " got=" << got << " want=" << want << "\n";
        return 1;
    }
    return 0;
}

} // namespace

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    Vh264_inter_recon_add_tb top{};

    top.pred = 73;
    top.residual = 19;
    top.eval();
    const int got = static_cast<int>(top.recon);
    if (got == 73) {
        std::cerr << "FAIL h264_inter_recon_add drop-residual: recon stayed pred-only "
                  << "got=73 want=92 pred=73 residual=19\n";
        return 1;
    }

    int rc = 0;
    rc |= runCase(top, 73, 19, 92, "p16z-mb1-sample0");
    rc |= runCase(top, 73, 7, 80, "native-first-p-mb0-y");
    rc |= runCase(top, 250, 20, 255, "clip-high");
    rc |= runCase(top, 5, -20, 0, "clip-low");
    rc |= runCase(top, 128, 0, 128, "zero-residual");
    if (rc != 0) return rc;
    if (clipAdd(73, 19) != 92) return 1;
    std::cout << "OK h264_inter_recon_add: clip(pred+res) 73+19=92 73+7=80 "
              << "clip_high=255 clip_low=0 zero_res=128\n";
    return 0;
}
