// REAL RTL sim: h264_qp_y_add_delta + h264_iq_idct_seq I16 AC (max_coeff=15).
#include "Vi16_ac_qp_tb_top.h"
#include "verilated.h"
#include <cstdint>
#include <cstdio>
#include <cstdlib>

static vluint64_t main_time = 0;
double sc_time_stamp() { return (double)main_time; }

static void tick(Vi16_ac_qp_tb_top& t) {
    t.clk = 0; t.eval(); main_time++;
    t.clk = 1; t.eval(); main_time++;
}

static int qp_wrap_host(int prev, int dlt) {
    int t = prev + dlt;
    while (t < 0) t += 52;
    while (t > 51) t -= 52;
    return t;
}

static int fail_count = 0;

static void test_qp(Vi16_ac_qp_tb_top& t) {
    struct { int prev; int dlt; } cases[] = {
        {0, 0}, {25, 0}, {25, 2}, {25, -3}, {0, -1}, {51, 1},
        {50, 5}, {1, -5}, {40, -40}, {10, 100}, {0, -53}, {51, -52}
    };
    for (auto& c : cases) {
        t.qp_prev = c.prev;
        t.qp_delta = c.dlt;
        t.eval();
        int want = qp_wrap_host(c.prev, c.dlt);
        if ((int)t.qp_y != want) {
            std::printf("FAIL qp prev=%d dlt=%d got=%u want=%d\n",
                        c.prev, c.dlt, (unsigned)t.qp_y, want);
            fail_count++;
        }
    }
    std::printf("qp_wrap: %zu vectors checked\n", sizeof(cases)/sizeof(cases[0]));
}

static bool run_iq(Vi16_ac_qp_tb_top& t, const int16_t c[16], int qp,
                   int maxc, bool skip_dc, int32_t dc_val, const char* tag) {
    for (int i = 0; i < 16; i++) t.iq_coeff[i] = c[i];
    t.iq_qp = qp;
    t.iq_max_coeff = maxc;
    t.iq_skip_dc = skip_dc ? 1 : 0;
    t.iq_dc_override = skip_dc ? 1 : 0;
    t.iq_dc_value = dc_val;
    t.iq_start = 1;
    tick(t);
    t.iq_start = 0;
    int guard = 0;
    while (!t.iq_done && guard < 64) { tick(t); guard++; }
    if (!t.iq_done) {
        std::printf("FAIL %s: timeout\n", tag);
        fail_count++;
        return false;
    }
    bool ok = true;
    for (int i = 0; i < 16; i++) {
        if ((int32_t)t.iq_resid[i] != (int32_t)t.par_resid[i]) {
            std::printf("FAIL %s idx=%d seq=%d par=%d\n", tag, i,
                        (int32_t)t.iq_resid[i], (int32_t)t.par_resid[i]);
            ok = false;
            fail_count++;
            break;
        }
    }
    tick(t);
    return ok;
}

static void test_i16_ac(Vi16_ac_qp_tb_top& t) {
    int n = 0;
    {
        int16_t z[16] = {};
        run_iq(t, z, 26, 15, true, 1000, "i16_dc_only");
        n++;
    }
    {
        int16_t c[16] = {};
        c[0] = 7;
        run_iq(t, c, 18, 15, true, 200, "i16_ac0");
        n++;
    }
    {
        int16_t c[16] = {};
        for (int i = 0; i < 15; i++) c[i] = (int16_t)((i & 1) ? -3 : 4);
        run_iq(t, c, 28, 15, true, -500, "i16_ac15");
        n++;
    }
    {
        int16_t c[16] = {};
        c[0] = 5; c[1] = -2; c[4] = 3; c[14] = 1;
        for (int qp = 0; qp <= 51; qp += 3) {
            char tag[32];
            std::snprintf(tag, sizeof(tag), "i16_qp%d", qp);
            run_iq(t, c, qp, 15, true, 128, tag);
            n++;
        }
    }
    {
        uint32_t s = 0xC0FFEEu;
        for (int k = 0; k < 200; k++) {
            int16_t c[16] = {};
            for (int i = 0; i < 15; i++) {
                s = s * 1664525u + 1013904223u;
                c[i] = (int16_t)((int)(s % 21) - 10);
            }
            s = s * 1664525u + 1013904223u;
            int qp = (int)(s % 52);
            s = s * 1664525u + 1013904223u;
            int32_t dc = (int32_t)((int)(s % 4001) - 2000);
            char tag[32];
            std::snprintf(tag, sizeof(tag), "i16_rnd%d", k);
            run_iq(t, c, qp, 15, true, dc, tag);
            n++;
        }
    }
    std::printf("i16_ac iq_idct: %d blocks\n", n);
}

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    Vi16_ac_qp_tb_top top;
    top.rst = 1;
    top.iq_start = 0;
    top.qp_prev = 0;
    top.qp_delta = 0;
    for (int i = 0; i < 16; i++) top.iq_coeff[i] = 0;
    for (int i = 0; i < 4; i++) tick(top);
    top.rst = 0;
    tick(top);

    test_qp(top);
    test_i16_ac(top);

    if (fail_count) {
        std::printf("I16_AC_QP_FAIL errors=%d\n", fail_count);
        return 1;
    }
    std::printf("I16_AC_QP_OK qp_wrap+i16_ac_seq_vs_par\n");
    return 0;
}
