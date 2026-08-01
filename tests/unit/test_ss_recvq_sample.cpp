// Red-before-green: ss Recv-Q parse + campaign score + blindness self-check.
// Fixtures from parent RESULT_pms_supply_not_the_limiter.md (measured on device).
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

    // Parent-captured ss shape (Recv-Q held ~0.5 MB).
    const char* ss_blob =
        "ESTAB 494010 0 192.168.1.183:50346 192.168.1.24:32400 users:((\"ffmpeg\",pid=13172,fd=5))\n"
        "\tbytes_received:2442203 rcv_ssthresh:180248 app_limited\n";

    SsSocketSample s{};
    CHECK(parseSsTinpText(ss_blob, 13172, 5, &s));
    CHECK(s.ok && s.recv_q == 494010);
    CHECK(s.fd == 5 && s.pid == 13172);
    CHECK(s.bytes_received == 2442203);
    CHECK(s.app_limited);

    // Wrong fd → fail
    SsSocketSample bad{};
    CHECK(!parseSsTinpText(ss_blob, 13172, 7, &bad));

    // Explicit Recv-Q token form
    const char* ss2 =
        "ESTAB Recv-Q 485187 Send-Q 0 192.168.1.183:50346 -> 192.168.1.24:32400 "
        "users:((\"ffmpeg\",pid=13172,fd=5))\n"
        "      bytes_received:1835283 app_limited\n";
    CHECK(parseSsTinpText(ss2, 13172, 5, &s));
    CHECK(s.recv_q == 485187);
    CHECK(s.bytes_received == 1835283);

    // Parent 10-sample campaign (min 482895) → NOT_SUPPLY_LIMITED
    const int64_t parent_rq[] = {494010, 484065, 484065, 484065, 497160,
                                 497160, 497160, 482895, 482895, 482895};
    const auto camp = scoreRecvQCampaign(parent_rq, 10, /*backlog_min=*/100000);
    CHECK(camp.ok_n == 10);
    CHECK(camp.held_n == 10);
    CHECK(camp.min_recv_q == 482895);
    CHECK(std::strcmp(camp.verdict, "NOT_SUPPLY_LIMITED") == 0);
    CHECK(classifyRecvQ(482895, 100000) == RecvQClass::BacklogHeld);
    CHECK(classifyRecvQ(0, 100000) == RecvQClass::QueueEmpty);
    CHECK(std::strcmp(recvQClassName(RecvQClass::QueueEmpty), "QUEUE_EMPTY") == 0);

    // QUEUE_EMPTY majority → INCONCLUSIVE (not a defect / not STALL)
    const int64_t empty_rq[] = {0, 0, 0, 0};
    const auto e = scoreRecvQCampaign(empty_rq, 4, 100000);
    CHECK(std::strcmp(e.verdict, "INCONCLUSIVE") == 0);
    CHECK(e.empty_n == 4);

    // --- Blindness self-check (rchar VOID pattern) ---
    // Parent: d_rchar=0 × 12 while wchar advanced → must be blind, not STALL.
    int64_t rchar_zeros[12];
    for (int i = 0; i < 12; ++i)
        rchar_zeros[i] = 0;
    const auto blind =
        scoredCounterBlindAllZero(rchar_zeros, 12, /*work_delta=*/414442429 - 1000,
                                  /*process_alive=*/true);
    CHECK(blind.blind);
    CHECK(std::strcmp(blind.reason, "all_zero_while_work_advanced") == 0);

    // Nonzero counter → not blind
    int64_t mixed[] = {0, 0, 494010};
    CHECK(!scoredCounterBlindAllZero(mixed, 3, 1000, true).blind);

    // Dead process → do not call blind
    CHECK(!scoredCounterBlindAllZero(rchar_zeros, 12, 1000, false).blind);

    const std::string line =
        formatRecvQSampleLine(0, 2.0, 494010, 2442203, 13172, 5, RecvQClass::BacklogHeld, "YES");
    CHECK(line.find("recv_q=494010") != std::string::npos);
    CHECK(line.find("class=BACKLOG_HELD") != std::string::npos);
    CHECK(line.find("tag=measured") != std::string::npos);
    // Must not mention rchar or nominal
    CHECK(line.find("rchar") == std::string::npos);
    CHECK(line.find("nominal") == std::string::npos);

    std::printf("PASS test_ss_recvq_sample parent_min_rq=482895 verdict=NOT_SUPPLY_LIMITED "
                "rchar_blind_self_check=1\n");
    if (fails) {
        std::fprintf(stderr, "test_ss_recvq_sample: %d FAIL(s)\n", fails);
        return 1;
    }
    return 0;
}
