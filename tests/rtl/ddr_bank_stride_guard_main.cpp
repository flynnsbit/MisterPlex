#include "Vddr_bank_stride_guard_tb.h"
#include "verilated.h"

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    Vddr_bank_stride_guard_tb top;
    for (int i = 0; i < 100 && !Verilated::gotFinish(); ++i) {
        top.eval();
    }
    top.final();
    return Verilated::gotFinish() ? 0 : 2;
}
