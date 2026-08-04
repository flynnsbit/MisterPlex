// Verilator driver: PPC=2 must emit distinct RGB when adjacent Y differ.
#include "Vyuv_bt601_npx_ppc2_tb_top.h"
#include "verilated.h"
#include <cstdint>
#include <cstdio>
#include <cstdlib>

static void tick(Vyuv_bt601_npx_ppc2_tb_top* t) {
    t->clk = 0;
    t->eval();
    t->clk = 1;
    t->eval();
}

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    auto* t = new Vyuv_bt601_npx_ppc2_tb_top;

    t->clk = 0;
    t->reset = 1;
    t->in_valid = 0;
    t->src_x0 = 0;
    t->y_qword = 0;
    t->u_qword = 0;
    t->v_qword = 0;
    t->eval();
    for (int i = 0; i < 4; i++) tick(t);

    t->reset = 0;
    t->eval();
    tick(t);

    // Y bytes: even idx=10, odd idx=200 → lanes at x0=0 see Y=10 and Y=200
    uint64_t yq = 0;
    for (int i = 0; i < 8; i++) {
        uint8_t y = (i & 1) ? 200 : 10;
        yq |= (uint64_t)y << (8 * i);
    }
    uint64_t cq = 0x8080808080808080ULL; // neutral chroma
    t->y_qword = yq;
    t->u_qword = cq;
    t->v_qword = cq;
    t->src_x0 = 0;
    t->in_valid = 1;
    t->eval(); // settle comb before edge
    tick(t);   // capture
    // out_* update on this edge; read after eval already in tick

    if (!t->out_valid) {
        std::fprintf(stderr, "FAIL npx_ppc2: out_valid=0 after first capture\n");
        // try hold
        tick(t);
        if (!t->out_valid) {
            std::fprintf(stderr, "FAIL npx_ppc2: out_valid still 0\n");
            return 1;
        }
    }

    uint8_t r0 = t->out_r & 0xff;
    uint8_t r1 = (t->out_r >> 8) & 0xff;
    uint8_t g0 = t->out_g & 0xff;
    uint8_t g1 = (t->out_g >> 8) & 0xff;
    uint8_t b0 = t->out_b & 0xff;
    uint8_t b1 = (t->out_b >> 8) & 0xff;

    uint32_t csum0 = (uint32_t)r0 * 3u + (uint32_t)g0 * 5u + (uint32_t)b0 * 7u;
    uint32_t csum1 = (uint32_t)r1 * 3u + (uint32_t)g1 * 5u + (uint32_t)b1 * 7u;
    std::printf("npx_ppc2 lanes r=%u/%u g=%u/%u b=%u/%u csum=%u/%u\n",
                r0, r1, g0, g1, b0, b1, csum0, csum1);

    if (csum0 == csum1) {
        std::fprintf(stderr,
            "FAIL npx_ppc2: lane checksums equal (%u) — looks like scalar replicate\n",
            csum0);
        return 1;
    }
    if (r0 == r1 && g0 == g1 && b0 == b1) {
        std::fprintf(stderr, "FAIL npx_ppc2: RGB lanes identical\n");
        return 1;
    }
    if (!(r1 > r0)) {
        std::fprintf(stderr, "FAIL npx_ppc2: expected r1>r0 for Y 200 vs 10 (got %u %u)\n",
                     r0, r1);
        return 1;
    }
    std::printf("PASS yuv_bt601_npx_ppc2 odd/even distinct\n");
    delete t;
    return 0;
}
