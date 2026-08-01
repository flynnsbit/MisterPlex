// proc_io: parse only + VOID rchar-blind detector. No supply ratio scoring.
#include "libmisterplex/proc_io_sample.hpp"
#include "libmisterplex/ss_recvq_sample.hpp"
#include "libmisterplex/supply_bucket.hpp"

#include <cstdio>
#include <cstring>

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

    // Parent cumulative counters during healthy cast.
    const char* blob = "rchar: 1037\n"
                       "wchar: 414442429\n"
                       "syscr: 5\n"
                       "syscw: 14545\n"
                       "read_bytes: 0\n"
                       "write_bytes: 4096\n";
    ProcIoSample a{};
    CHECK(parseProcIoText(blob, &a) && a.ok);
    CHECK(a.rchar == 1037 && a.wchar == 414442429 && a.syscr == 5);
    CHECK(procIoLooksLikeRcharBlindToNetwork(a, 1u << 20));

    // Blind self-check: 12× d_rchar=0 while work advanced → NO-DATA not defect.
    int64_t zeros[12] = {};
    const auto blind = scoredCounterBlindAllZero(zeros, 12, 414000000, true);
    CHECK(blind.blind);

    CHECK(std::strcmp(weakestProvenanceTag("measured", "caller_supplied"), "caller_supplied") ==
          0);

    std::printf("PASS test_proc_io_sample void_rchar_blind=1\n");
    if (fails) {
        std::fprintf(stderr, "test_proc_io_sample: %d FAIL(s)\n", fails);
        return 1;
    }
    return 0;
}
