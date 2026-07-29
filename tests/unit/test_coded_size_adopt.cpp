// Runtime policy for conf/argv coded-size adoption (parse + lab gate).
// Complements geometry_type_ok (compile-time tags) and the compile-fail suite.
#include "libmisterplex/coded_size.hpp"
#include "libmisterplex/ddr_frame_layout.hpp"

#include <cstdio>
#include <cstring>
#include <string>
#include <type_traits>

static int fails = 0;
#define CHECK(c)                                                                                 \
    do {                                                                                         \
        if (!(c)) {                                                                              \
            std::fprintf(stderr, "FAIL %s:%d %s\n", __FILE__, __LINE__, #c);                     \
            ++fails;                                                                             \
        }                                                                                        \
    } while (0)

#define CHECK_ST(r, expect)                                                                      \
    do {                                                                                         \
        if ((r).status != (expect)) {                                                            \
            std::fprintf(stderr,                                                                 \
                         "FAIL %s:%d status got=%s expect=%s reason=%s\n", __FILE__, __LINE__,   \
                         misterplex::codedSizeParseStatusName((r).status),                       \
                         misterplex::codedSizeParseStatusName(expect), (r).reason);              \
            ++fails;                                                                             \
        }                                                                                        \
    } while (0)

int main() {
    using namespace misterplex;

    // Default product size adopts cleanly without lab allow.
    {
        auto r = adoptExternalCodedSize("320x240", false);
        CHECK_ST(r, CodedSizeParseStatus::Ok);
        CHECK(r.size == kDefaultCodedDecodeSize);
        CHECK(r.size.wxh() == "320x240");
    }

    // Malformed / empty / trailing junk.
    CHECK_ST(parseCodedSizeString(""), CodedSizeParseStatus::Empty);
    CHECK_ST(parseCodedSizeString("nope"), CodedSizeParseStatus::Malformed);
    CHECK_ST(parseCodedSizeString("320x240x1"), CodedSizeParseStatus::Malformed);
    CHECK_ST(parseCodedSizeString("320"), CodedSizeParseStatus::Malformed);

    // Even / positive rules.
    CHECK_ST(parseCodedSizeString("0x240"), CodedSizeParseStatus::NotPositive);
    CHECK_ST(parseCodedSizeString("321x240"), CodedSizeParseStatus::NotEven);

    // Presented scanout must never parse as a coded decode size.
    {
        auto r = parseCodedSizeString("640x480");
        CHECK_ST(r, CodedSizeParseStatus::PresentedMistake);
        auto a = adoptExternalCodedSize("640x480", true);
        CHECK_ST(a, CodedSizeParseStatus::PresentedMistake);
        // allowLab480p must not override presented mistake.
        CHECK(a.status != CodedSizeParseStatus::Ok);
    }

    // Lab 480p coded: valid geometry, blocked from conf/argv without allow.
    {
        auto parsed = parseCodedSizeString("624x480");
        CHECK_ST(parsed, CodedSizeParseStatus::Ok);
        CHECK(parsed.size.width == kPlex480pCodedWidth);
        CHECK(parsed.size.height == kPlex480pCodedHeight);

        auto blocked = adoptExternalCodedSize("624x480", false);
        CHECK_ST(blocked, CodedSizeParseStatus::Lab480pBlocked);
        CHECK(blocked.size == kDefaultCodedDecodeSize); // fail-closed to product default

        auto allowed = adoptExternalCodedSize("624x480", true);
        CHECK_ST(allowed, CodedSizeParseStatus::Ok);
        CHECK(allowed.size == plex480pCodedDecodeSize());
    }

    // Frame-store reject (too large).
    CHECK_ST(parseCodedSizeString("1920x1080"), CodedSizeParseStatus::NotFrameStoreAccepted);

    // CodedSize is not brace-constructible from two bare ints (tag required).
    static_assert(!std::is_constructible<CodedSize, int, int>::value,
                  "CodedSize must not take bare ints");
    static_assert(std::is_constructible<CodedSize, CodedWidth, CodedHeight>::value,
                  "CodedSize must take tagged widths");

    if (fails) {
        std::fprintf(stderr, "test_coded_size_adopt: %d fails\n", fails);
        return 1;
    }
    std::printf("test_coded_size_adopt: OK\n");
    return 0;
}
