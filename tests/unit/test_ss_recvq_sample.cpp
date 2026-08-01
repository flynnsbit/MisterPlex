// Red-before-green: 4-tuple pin, reconnect, depth_s, no nominal, parent fixtures.
#include "libmisterplex/ss_recvq_sample.hpp"

#include <cstdio>
#include <cstring>
#include <string>

static int fails = 0;
#define CHECK(c)                                                                                 \
    do {                                                                                         \
        if (!(c)) {                                                                              \
            std::fprintf(stderr, "FAIL %s:%d: %s\n", __FILE__, __LINE__, #c);                     \
            ++fails;                                                                             \
        }                                                                                        \
    } while (0)

int main() {
    using namespace misterplex;

    const char* ss_blob =
        "ESTAB 494010 0 192.168.1.183:50346 192.168.1.24:32400 users:((\"ffmpeg\",pid=13172,fd=5))\n"
        "\tbytes_received:2442203 rcv_ssthresh:180248 app_limited\n";

    SsSocketSample s{};
    CHECK(parseSsTinpTextByTuple(ss_blob, 13172, nullptr, &s));
    CHECK(s.ok && s.recv_q == 494010);
    CHECK(s.bytes_received == 2442203);
    CHECK(s.rcv_ssthresh == 180248);
    CHECK(std::strstr(s.four_tuple, "192.168.1.183:50346") != nullptr);
    CHECK(std::strstr(s.four_tuple, "192.168.1.24:32400") != nullptr);

    // Pin by 4-tuple
    CHECK(parseSsTinpTextByTuple(ss_blob, 13172, s.four_tuple, &s));
    CHECK(s.recv_q == 494010);
    CHECK(!parseSsTinpTextByTuple(ss_blob, 13172, "1.2.3.4:9 5.6.7.8:32400", &s));

    // Parent rate arithmetic: 2442203 → 2619531 over 18 s ⇒ ~9851 B/s
    // depth at 482895 / 9851 ≈ 49 s
    const double cons =
        deriveConsumeBps(/*pr*/ 494010, /*cr*/ 482895, /*pb*/ 2442203, /*cb*/ 2619531,
                         /*dw*/ 18.0, /*recon*/ false);
    CHECK(cons > 9000.0 && cons < 11000.0);
    const double depth = backlogDepthSeconds(482895, cons);
    CHECK(depth > 40.0 && depth < 60.0);

    // Reconnect marker
    CHECK(bytesReceivedIndicatesReconnect(2619531, 1000));
    CHECK(!bytesReceivedIndicatesReconnect(1000, 2000));
    CHECK(deriveConsumeBps(100, 100, 5000, 1000, 2.0, true) < 0.0);

    // rcv_ssthresh ratio ~2.7 (parent); not app_limited
    const double ratio = recvQOverSsthresh(482895, 180248);
    CHECK(ratio > 2.5 && ratio < 2.9);

    // Campaign parent series
    const int64_t parent_rq[] = {494010, 484065, 484065, 484065, 497160,
                                 497160, 497160, 482895, 482895, 482895};
    const auto camp = scoreRecvQCampaign(parent_rq, 10, 100000);
    CHECK(std::strcmp(camp.verdict, "NOT_SUPPLY_LIMITED") == 0);
    CHECK(camp.min_recv_q == 482895);

    // depth-based verdict even if below byte min
    const int64_t small_rq[] = {50000, 50000, 50000};
    const double depths[] = {49.0, 48.0, 50.0};
    const auto dcamp = scoreRecvQCampaign(small_rq, 3, /*min*/ 100000, nullptr, depths);
    CHECK(std::strcmp(dcamp.verdict, "NOT_SUPPLY_LIMITED") == 0);

    // VOID rchar pattern → blind
    int64_t zeros[12] = {};
    CHECK(scoredCounterBlindAllZero(zeros, 12, 414000000, true).blind);

    // stall floor trap: 9851 < 0.4*57000 — document we do NOT classify that as STALL
    CHECK(9851.0 < 0.4 * 57000.0);

    const std::string line = formatRecvQSampleLine(0, 6.0, 494010, 2442203, 180248, 9851.0, 50.1,
                                                   s.four_tuple, 13172, 5, RecvQClass::BacklogHeld,
                                                   "YES");
    CHECK(line.find("backlog_depth_s=50.10") != std::string::npos ||
          line.find("backlog_depth_s=50.1") != std::string::npos);
    CHECK(line.find("rcv_ssthresh=180248") != std::string::npos);
    CHECK(line.find("pin=four_tuple") != std::string::npos);
    CHECK(line.find("NOMINAL_BPS") == std::string::npos);
    CHECK(line.find("ratio_vs_nominal") == std::string::npos);
    CHECK(line.find("rchar") == std::string::npos);
    CHECK(line.find("no_nominal_bps") != std::string::npos);

    std::printf("PASS test_ss_recvq_sample depth_s~49 pin=four_tuple reconnect=1 "
                "no_nominal=1 parent_NOT_SUPPLY_LIMITED=1\n");
    if (fails) {
        std::fprintf(stderr, "test_ss_recvq_sample: %d FAIL(s)\n", fails);
        return 1;
    }
    return 0;
}
