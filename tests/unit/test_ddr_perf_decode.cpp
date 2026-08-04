#include "libmisterplex/ddr_perf_counters.hpp"
#include <cstdio>
#include <cstdlib>
#include <cstring>

using namespace misterplex::ddr_perf;

static int g_fail = 0;
#define CHECK(cond) do { if (!(cond)) { std::fprintf(stderr, "FAIL %s:%d %s\n", __FILE__, __LINE__, #cond); g_fail++; } } while (0)

int main() {
    std::printf("=== test_ddr_perf_decode EXECUTED ===\n");
    uint64_t w[kNumQwords] = {};
    const uint8_t seq = 0x2a;
    w[0] = (uint64_t(0x0001) << 48) | (uint64_t(seq) << 40) | (uint64_t(kVersion) << 32) | kMagic;
    w[1] = 900000;
    w[2] = 1000;
    w[3] = 2000;
    w[4] = 100;
    w[5] = 50; w[6] = 10; w[7] = 5;
    w[8] = 2000; w[9] = 0;
    w[10] = 0; w[11] = 0;
    w[12] = 0; w[13] = 1000;
    w[14] = 3; // bin0
    w[15] = 1; // bin1
    w[16] = 1; // bin2
    w[20] = 10; // rd_cmds
    w[21] = 40; // burst_sum → mean 4
    w[22] = (uint64_t(5000) << 32) | 2; // issue=5000, single=2
    w[23] = (uint64_t(seq) << 32) | kMagic;

    Snapshot s;
    CHECK(decode(w, s));
    CHECK(s.ok);
    CHECK(s.seq == seq);
    CHECK(s.ver == kVersion);
    CHECK(s.cycles == 900000);
    CHECK(s.wr_beats == 1000);
    CHECK(s.rd_beats == 2000);
    CHECK(s.stall_cyc == 100);
    CHECK(s.lat_bin[0] == 3 && s.lat_bin[1] == 1 && s.lat_bin[2] == 1);
    CHECK(s.rd_cmds == 10);
    CHECK(s.burst_sum == 40);
    CHECK(s.single_cmds == 2);
    CHECK(s.issue_cyc == 5000);
    CHECK(mean_burst(s) > 3.9 && mean_burst(s) < 4.1);
    const double wr = wr_MBps(s, 90e6);
    CHECK(wr > 0.79 && wr < 0.81);
    std::printf("PASS POS decode wr_MBps=%.3f mean_burst=%.2f bin0=%u\n",
                wr, mean_burst(s), s.lat_bin[0]);

    w[23] = (uint64_t(seq + 1) << 32) | kMagic;
    Snapshot bad;
    CHECK(!decode(w, bad));
    std::printf("REPRO_OK NEG torn_seq rejected\n");

    w[23] = (uint64_t(seq) << 32) | kMagic;
    w[0] = (w[0] & ~0xffffffffull) | 0xDEADBEEF;
    CHECK(!decode(w, bad));
    std::printf("REPRO_OK NEG bad_magic rejected\n");

    // NEG: wrong version
    w[0] = (uint64_t(0x0001) << 48) | (uint64_t(seq) << 40) | (uint64_t(1) << 32) | kMagic;
    CHECK(!decode(w, bad));
    std::printf("REPRO_OK NEG bad_version rejected\n");

    if (g_fail) {
        std::printf("FAIL test_ddr_perf_decode fails=%d\n", g_fail);
        return 1;
    }
    std::printf("PASS test_ddr_perf_decode\n");
    return 0;
}
