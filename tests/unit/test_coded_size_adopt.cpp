// Runtime policy for conf/argv coded-size adoption (parse + lab gate).
// Complements geometry_type_ok (compile-time tags) and the compile-fail suite.
#include "libmisterplex/coded_size.hpp"
#include "libmisterplex/conf_keys.hpp"
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

    // Conf-text adoption: key order independent; CRLF allow must still truthy.
    // 640x480 → presented_mistake even with allow.
    {
        const char* t =
            "DECODE=640x480\n"
            "DECODE_ALLOW_LAB_480P=1\n";
        auto a = adoptDecodeFromConfText(t);
        CHECK(a.allow_lab_480p);
        CHECK(a.decode_key_present);
        CHECK_ST(a.result, CodedSizeParseStatus::PresentedMistake);
        CHECK(a.result.status != CodedSizeParseStatus::Ok);
    }
    // 624x480 without allow → blocked (DECODE before ALLOW in file).
    {
        const char* t =
            "DECODE=624x480\n"
            "DECODE_ALLOW_LAB_480P=0\n";
        auto a = adoptDecodeFromConfText(t);
        CHECK(!a.allow_lab_480p);
        CHECK_ST(a.result, CodedSizeParseStatus::Lab480pBlocked);
        CHECK(a.result.size == kDefaultCodedDecodeSize);
    }
    // 624x480 with allow AFTER DECODE → adopted (order A).
    {
        const char* t =
            "DECODE=624x480\n"
            "DECODE_ALLOW_LAB_480P=1\n";
        auto a = adoptDecodeFromConfText(t);
        CHECK(a.allow_lab_480p);
        CHECK_ST(a.result, CodedSizeParseStatus::Ok);
        CHECK(a.result.size == plex480pCodedDecodeSize());
    }
    // 624x480 with allow BEFORE DECODE → adopted (order B).
    {
        const char* t =
            "DECODE_ALLOW_LAB_480P=1\n"
            "DECODE=624x480\n";
        auto a = adoptDecodeFromConfText(t);
        CHECK(a.allow_lab_480p);
        CHECK_ST(a.result, CodedSizeParseStatus::Ok);
        CHECK(a.result.size == plex480pCodedDecodeSize());
    }
    // CRLF + trailing CR on allow value (Windows conf / getline leftover).
    {
        const char* t =
            "DECODE=624x480\r\n"
            "DECODE_ALLOW_LAB_480P=1\r\n";
        auto a = adoptDecodeFromConfText(t);
        CHECK(a.allow_lab_480p);
        CHECK_ST(a.result, CodedSizeParseStatus::Ok);
        CHECK(a.result.size == plex480pCodedDecodeSize());
    }
    // confTruthy trim contract (loadConf path uses the same helper).
    CHECK(confTruthy("1\r"));
    CHECK(confTruthy(" true "));
    CHECK(confTruthy("\"1\""));
    CHECK(!confTruthy("1x"));
    CHECK(trimConfValue(" 624x480\r") == "624x480");
    CHECK(trimConfValue("\"624x480\"") == "624x480");

    // Indented keys + quoted allow (parent hole: column-0-only match → silent miss).
    {
        const char* t =
            "  DECODE=624x480\n"
            "  DECODE_ALLOW_LAB_480P=\"1\"\n";
        auto a = adoptDecodeFromConfText(t);
        CHECK(a.allow_lab_480p);
        CHECK(a.decode_key_present);
        CHECK_ST(a.result, CodedSizeParseStatus::Ok);
        CHECK(a.result.size == plex480pCodedDecodeSize());
    }
    // Indented DECODE without allow still blocked.
    {
        const char* t = "\tDECODE=624x480\n";
        auto a = adoptDecodeFromConfText(t);
        CHECK(!a.allow_lab_480p);
        CHECK_ST(a.result, CodedSizeParseStatus::Lab480pBlocked);
    }

    // Banner label: effective geometry; rejected conf must not look bare-default.
    {
        const std::string labBlocked =
            formatDecodeBankLabel("320x240", "624x480", /*confRejected*/ true);
        CHECK(labBlocked.rfind("320x240", 0) == 0);
        CHECK(labBlocked.find("rejected conf DECODE=624x480") != std::string::npos);
        CHECK(labBlocked.rfind("624x480", 0) != 0); // must not lead with request
        const std::string plain =
            formatDecodeBankLabel("320x240", "320x240", /*confRejected*/ false);
        CHECK(plain == "320x240");
        const std::string adopted =
            formatDecodeBankLabel("624x480", "624x480", /*confRejected*/ false);
        CHECK(adopted == "624x480");
        CHECK(adopted.find("rejected") == std::string::npos);
    }

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
