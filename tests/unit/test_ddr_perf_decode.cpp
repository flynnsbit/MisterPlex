#include "libmisterplex/ddr_perf_counters.hpp"
#include <cstdio>
#include <cstdlib>
#include <cstring>

using namespace misterplex::ddr_perf;

static int g_fail = 0;
#define CHECK(cond) do { if (!(cond)) { std::fprintf(stderr, "FAIL %s:%d %s\n", __FILE__, __LINE__, #cond); g_fail++; } } while (0)

int main() {
    std::printf("=== test_ddr_perf_decode EXECUTED ===\n");
    uint64_t w[16] = {};
    // Build a valid page
    const uint8_t seq = 0x2a;
    w[0] = (uint64_t(0x0001) << 48) | (uint64_t(seq) << 40) | (uint64_t(kVersion) << 32) | kMagic;
    w[1] = 900000; // cycles
    w[2] = 1000;   // wr
    w[3] = 2000;   // rd
    w[4] = 100;    // stall
    w[5] = 50; w[6] = 10; w[7] = 5;
    w[8] = 2000; w[9] = 0;
    w[10] = 0; w[11] = 0;
    w[12] = 0; w[13] = 1000;
    w[15] = (uint64_t(seq) << 32) | kMagic;

    Snapshot s;
    CHECK(decode(w, s));
    CHECK(s.ok);
    CHECK(s.seq == seq);
    CHECK(s.cycles == 900000);
    CHECK(s.wr_beats == 1000);
    CHECK(s.rd_beats == 2000);
    CHECK(s.stall_cyc == 100);
    // 1000 beats * 8 * 90e6 / 900000 / 1e6 = 0.8 MB/s
    const double wr = wr_MBps(s, 90e6);
    CHECK(wr > 0.79 && wr < 0.81);
    std::printf("PASS POS decode wr_MBps=%.3f\n", wr);

    // NEG: torn seq (header vs trailer)
    w[15] = (uint64_t(seq + 1) << 32) | kMagic;
    Snapshot bad;
    CHECK(!decode(w, bad));
    std::printf("REPRO_OK NEG torn_seq rejected\n");

    // NEG: bad magic
    w[15] = (uint64_t(seq) << 32) | kMagic;
    w[0] = (w[0] & ~0xffffffffull) | 0xDEADBEEF;
    CHECK(!decode(w, bad));
    std::printf("REPRO_OK NEG bad_magic rejected\n");

    if (g_fail) {
        std::printf("FAIL test_ddr_perf_decode fails=%d\n", g_fail);
        return 1;
    }
    std::printf("PASS test_ddr_perf_decode\n");
    return 0;
}
