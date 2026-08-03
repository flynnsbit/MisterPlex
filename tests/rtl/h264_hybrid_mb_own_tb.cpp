#include "Vh264_hybrid_mb_own_tb_top.h"
#include "verilated.h"

#include <cstdint>
#include <iostream>

struct Case {
    const char* name;
    bool slice_is_i;
    bool cabac;
    bool fail;
    bool valid;
    uint8_t mb_type;
    bool is_p;
    bool p_skip;
    bool p_intra;
    bool p_inter;
    bool p_sub;
    uint8_t part;
    bool p_unsup;
    bool want_fpga;
    bool want_host;
    bool want_ok;
    uint8_t want_code;
};

static bool runCase(Vh264_hybrid_mb_own_tb_top& dut, const Case& c) {
    dut.slice_is_i = c.slice_is_i;
    dut.entropy_cabac = c.cabac;
    dut.fail_mb = c.fail;
    dut.mb_valid = c.valid;
    dut.mb_type = c.mb_type;
    dut.is_p_slice_mb = c.is_p;
    dut.p_skipped = c.p_skip;
    dut.p_is_intra = c.p_intra;
    dut.p_is_inter = c.p_inter;
    dut.p_uses_sub_mb = c.p_sub;
    dut.p_part_mode = c.part;
    dut.p_unsupported = c.p_unsup;
    dut.eval();

    bool ok = true;
    auto ck = [&](bool cond, const char* field, int got, int want) {
        if (!cond) {
            std::cerr << "FAIL hybrid_own " << c.name << " " << field
                      << " got=" << got << " want=" << want << "\n";
            ok = false;
        }
    };
    ck(dut.fpga_owned == c.want_fpga, "fpga_owned", dut.fpga_owned, c.want_fpga);
    ck(dut.host_required == c.want_host, "host_required", dut.host_required, c.want_host);
    ck(dut.product_mb_ok == c.want_ok, "product_mb_ok", dut.product_mb_ok, c.want_ok);
    ck(dut.own_code == c.want_code, "own_code", dut.own_code, c.want_code);
    return ok;
}

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    Vh264_hybrid_mb_own_tb_top dut;

    // Pre-register (default CAP_INTER_*=0, CAP_INTRA_*=1):
    //   I_NxN / I16 → FPGA; P_Skip/P16 → HOST; CABAC → HOST; IPCM → HOST.
    const Case cases[] = {
        // name, I, cabac, fail, valid, mbt, is_p, pskip, pintra, pinter, psub, part, punsup, fpga, host, ok, code
        {"I_NxN", true, false, false, true, 0, false, false, false, false, false, 0, false, true, false, true, 0},
        {"I16", true, false, false, true, 1, false, false, false, false, false, 0, false, true, false, true, 0},
        {"I16_plane", true, false, false, true, 24, false, false, false, false, false, 0, false, true, false, true, 0},
        {"IPCM", true, false, false, true, 25, false, false, false, false, false, 0, false, false, true, false, 3},
        {"I_bad_type", true, false, false, true, 40, false, false, false, false, false, 0, false, false, true, false, 4},
        {"CABAC_I", true, true, false, true, 0, false, false, false, false, false, 0, false, false, true, false, 2},
        {"FAIL_MB", true, false, true, true, 0, false, false, false, false, false, 0, false, false, true, false, 5},
        {"INVALID", true, false, false, false, 0, false, false, false, false, false, 0, false, false, true, false, 4},
        {"P_Skip", false, false, false, true, 0, true, true, false, true, false, 0, false, false, true, false, 1},
        {"P_16x16", false, false, false, true, 0, true, false, false, true, false, 0, false, false, true, false, 1},
        {"P_16x8", false, false, false, true, 1, true, false, false, true, false, 1, false, false, true, false, 1},
        {"P_intra", false, false, false, true, 5, true, false, true, false, false, 7, false, true, false, true, 0},
        {"P_unsup", false, false, false, true, 31, true, false, false, false, false, 7, true, false, true, false, 4},
    };

    int failures = 0;
    int fpga_i = 0, host_p = 0;
    for (const auto& c : cases) {
        if (!runCase(dut, c))
            ++failures;
        if (c.want_fpga && c.slice_is_i)
            ++fpga_i;
        if (c.want_host && c.is_p && (c.p_inter || c.p_skip))
            ++host_p;
    }

    if (failures) {
        std::cerr << "FAIL h264_hybrid_mb_own: " << failures << " case(s)\n";
        return 1;
    }
    std::cout << "OK h264_hybrid_mb_own RTL: cases=" << (int)(sizeof(cases) / sizeof(cases[0]))
              << " fpga_intra_ok=" << fpga_i << " host_inter_ok=" << host_p << "\n";
    return 0;
}
