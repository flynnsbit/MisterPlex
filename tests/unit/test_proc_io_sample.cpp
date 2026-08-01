// Red-before-green: /proc/pid/io parse + arrival ratio (PMS pacing instrument).
#include "libmisterplex/proc_io_sample.hpp"
#include "libmisterplex/supply_bucket.hpp"

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

    const char* blob = "rchar: 1000\n"
                       "wchar: 5000\n"
                       "syscr: 10\n"
                       "syscw: 20\n"
                       "read_bytes: 0\n"
                       "write_bytes: 4096\n"
                       "cancelled_write_bytes: 0\n";
    ProcIoSample a{};
    CHECK(parseProcIoText(blob, &a) && a.ok && a.rchar == 1000 && a.wchar == 5000);
    CHECK(a.read_bytes == 0);

    ProcIoSample b = a;
    b.rchar = 1000 + 57000; // +57 KB in 1 s → ~456 kb/s
    b.wchar = 5000 + 449280;
    const auto d = procIoDelta(a, b, 1.0);
    CHECK(d.ok);
    CHECK(d.d_rchar == 57000);
    CHECK(d.rchar_Bps > 56999.0 && d.rchar_Bps < 57001.0);
    CHECK(!d.read_bytes_usable);
    const double ratio = arrivalRatioVsNominal(d.rchar_Bps, 57000.0);
    CHECK(ratio > 0.99 && ratio < 1.01);

    // Falsifier band: 9.57× would be ~545k B/s
    CHECK(arrivalRatioVsNominal(57000.0 * 9.57, 57000.0) > 9.0);

    const std::string line = formatFfmpegIoLine(d, 916, 57000.0, "1.1");
    CHECK(line.find("ffmpeg_io") != std::string::npos);
    CHECK(line.find("rchar_Bps=57000.0") != std::string::npos ||
          line.find("rchar_Bps=57000") != std::string::npos);
    CHECK(line.find("ratio_vs_nominal=1.000") != std::string::npos);
    CHECK(line.find("tag=measured") != std::string::npos);
    CHECK(line.find("read_bytes_Bps=NO-DATA") != std::string::npos);

    ProcIoDelta bad{};
    const std::string nd = formatFfmpegIoLine(bad, -1, 57000.0, "x");
    CHECK(nd.find("tag=NO-DATA") != std::string::npos);
    CHECK(nd.find("rchar_Bps=NO-DATA") != std::string::npos);

    // Weakest line tag discipline (supply_bucket)
    CHECK(std::strcmp(weakestProvenanceTag("measured", "caller_supplied"), "caller_supplied") ==
          0);
    CHECK(std::strcmp(weakestProvenanceTag("measured", "DEFAULT_ASSUMED"), "DEFAULT_ASSUMED") ==
          0);
    CHECK(std::strcmp(weakestProvenanceTag("caller_supplied", "NO-DATA"), "NO-DATA") == 0);

    SupplyBucketDelta sb{};
    sb.d_wall_s = 1;
    sb.d_frames = 24;
    sb.expected_frames = 24;
    sb.supply_gap = 0;
    sb.gap_scored = true;
    sb.gap_score_tag = "scored";
    std::string sline =
        formatSupplyBucketLine(sb, 1, 24, 24, 0, 0, 0, 24, 24, 1, "e", "caller_supplied");
    CHECK(sline.find("fps_src=caller_supplied") != std::string::npos);
    CHECK(sline.find("tag=caller_supplied") != std::string::npos);
    CHECK(sline.find("tag=measured") == std::string::npos);

    sb.gap_scored = false;
    sb.gap_score_tag = "refused_assumed_unverified";
    sline = formatSupplyBucketLine(sb, 1, 24, 24, 0, 0, 0, -1, 24, 1, "e", "DEFAULT_ASSUMED");
    CHECK(sline.find("supply_gap=NO-DATA") != std::string::npos);
    CHECK(sline.find("tag=NO-DATA") != std::string::npos ||
          sline.find("tag=DEFAULT_ASSUMED") != std::string::npos);
    // Must not claim full-line measured when rate assumed.
    CHECK(sline.find("tag=measured") == std::string::npos);

    sb.gap_scored = true;
    sb.gap_score_tag = "scored";
    sline = formatSupplyBucketLine(sb, 1, 24, 24, 0, 0, 0, 24, 24, 1, "e", "measured");
    CHECK(sline.find("tag=measured") != std::string::npos);

    std::printf("PASS test_proc_io_sample\n");
    if (fails) {
        std::fprintf(stderr, "test_proc_io_sample: %d FAIL(s)\n", fails);
        return 1;
    }
    return 0;
}
