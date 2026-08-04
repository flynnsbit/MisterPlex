// TB for ddr_frame_base_mux.
//
// GREEN fixed (DYN_BASE_EN=0, product default):
//   fill_bank_base == (bank ? base_w1 : base_w0) for all bank in {0,1}
//   using_dyn == 0 always
// NEGATIVE fixed: dyn_valid=1 and dyn_base deliberately DIFFERENT from fixed.
//   A naive "always prefer dyn when valid" bug PASSES a test that never sets
//   dyn_valid, but FAILS this case — correct fixed mode must ignore dyn_*.
//
// GREEN dyn (compile -GDYN_BASE_EN=1):
//   dyn_valid=1 -> dyn_base; dyn_valid=0 -> fixed fallback
// NEGATIVE dyn: dyn_valid=0 with non-zero dyn_base must NOT select dyn.

#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include "Vddr_frame_base_mux.h"
#include "verilated.h"

#ifndef DYN_BASE_EN_TB
#define DYN_BASE_EN_TB 0
#endif

static int fails = 0;

static void check(const char* tag, bool ok) {
    if (!ok) {
        std::fprintf(stderr, "FAIL %s\n", tag);
        fails++;
    }
}

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    auto* top = new Vddr_frame_base_mux;

    const uint32_t W0 = 0x06000000u >> 3; // PHYS_BASE-like qword
    const uint32_t W1 = 0x06080000u >> 3; // +0x80000 stride
    const uint32_t D0 = 0x0A000000u >> 3; // tempting dyn (≠ W0)
    const uint32_t D1 = 0x0B000000u >> 3;

    top->base_w0 = W0;
    top->base_w1 = W1;
    top->dyn_base0 = D0;
    top->dyn_base1 = D1;

#if DYN_BASE_EN_TB == 0
    // ---- FIXED product mode ----
    // Exhaustive bank × dyn_valid
    for (int bank = 0; bank < 2; bank++) {
        for (int v0 = 0; v0 < 2; v0++) {
            for (int v1 = 0; v1 < 2; v1++) {
                top->bank = bank;
                top->dyn_valid0 = v0;
                top->dyn_valid1 = v1;
                top->eval();
                const uint32_t want = bank ? W1 : W0;
                char tag[128];
                std::snprintf(tag, sizeof(tag),
                              "fixed bank=%d v0=%d v1=%d base=0x%x want=0x%x using=%d",
                              bank, v0, v1, top->fill_bank_base, want, top->using_dyn);
                check(tag, top->fill_bank_base == want && top->using_dyn == 0);
            }
        }
    }

    // NEGATIVE: strongest temptation — both dyn valid, dyn bases nonzero, bank flips.
    // Wrong impl that ORs dyn_valid into select would emit D0/D1.
    top->bank = 0;
    top->dyn_valid0 = 1;
    top->dyn_valid1 = 1;
    top->eval();
    check("NEG fixed ignores dyn bank0",
          top->fill_bank_base == W0 && top->fill_bank_base != D0 && top->using_dyn == 0);
    top->bank = 1;
    top->eval();
    check("NEG fixed ignores dyn bank1",
          top->fill_bank_base == W1 && top->fill_bank_base != D1 && top->using_dyn == 0);

    if (fails) {
        std::fprintf(stderr, "FAIL ddr_frame_base_mux_tb fixed fails=%d\n", fails);
        return 1;
    }
    std::printf("PASS ddr_frame_base_mux_tb fixed_identity+NEG_ignore_dyn DYN_BASE_EN=0\n");

#else
    // ---- DYN mode ----
    // bank0 valid -> D0
    top->bank = 0;
    top->dyn_valid0 = 1;
    top->dyn_valid1 = 0;
    top->eval();
    check("dyn bank0 valid", top->fill_bank_base == D0 && top->using_dyn == 1);

    // bank0 invalid -> W0 fallback (NEGATIVE if dyn_base still non-zero)
    top->dyn_valid0 = 0;
    top->eval();
    check("NEG dyn bank0 invalid must fallback fixed not D0",
          top->fill_bank_base == W0 && top->fill_bank_base != D0 && top->using_dyn == 0);

    // bank1 valid -> D1
    top->bank = 1;
    top->dyn_valid1 = 1;
    top->eval();
    check("dyn bank1 valid", top->fill_bank_base == D1 && top->using_dyn == 1);

    // bank1 invalid -> W1
    top->dyn_valid1 = 0;
    top->eval();
    check("NEG dyn bank1 invalid must fallback fixed not D1",
          top->fill_bank_base == W1 && top->fill_bank_base != D1 && top->using_dyn == 0);

    // Cross-bank: bank0 must not use dyn_valid1
    top->bank = 0;
    top->dyn_valid0 = 0;
    top->dyn_valid1 = 1;
    top->eval();
    check("NEG dyn bank0 must not take bank1 valid",
          top->fill_bank_base == W0 && top->using_dyn == 0);

    if (fails) {
        std::fprintf(stderr, "FAIL ddr_frame_base_mux_tb dyn fails=%d\n", fails);
        return 1;
    }
    std::printf("PASS ddr_frame_base_mux_tb dyn_select+NEG_fallback DYN_BASE_EN=1\n");
#endif

    delete top;
    return 0;
}
