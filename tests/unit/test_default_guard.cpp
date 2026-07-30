// default-guard: shipping coded default must not silently move.
//
// Product contract (daily driver):
//   - coded default is 320x240 with no allow flag
//   - stale DECODE=624x480 conf cannot adopt lab 480p without DECODE_ALLOW_LAB_480P
//   - 640x480 is presented scanout, never a coded decode size
//   - CLI --decode wins over conf, both typed+policy-checked
//   - OSD O[4] selects coded 624x480 (menu label may say 640x480)
//   - weak bitrate tiers off coded size, not presented scanout
//
// Mirrors arm/misterplexd/main.cpp adoption order without linking the daemon.
#include "libmisterplex/coded_size.hpp"
#include "libmisterplex/ddr_frame_layout.hpp"
#include "libmisterplex/osd_menu.hpp"

#include <cstdio>
#include <string>

static int fails = 0;

#define CHECK_MSG(cond, msg)                                                                     \
    do {                                                                                         \
        if (!(cond)) {                                                                           \
            std::fprintf(stderr, "FAIL %s:%d: %s (%s)\n", __FILE__, __LINE__, (msg), #cond);     \
            ++fails;                                                                             \
        }                                                                                        \
    } while (0)

#define CHECK_ST_MSG(r, expect, msg)                                                             \
    do {                                                                                         \
        if ((r).status != (expect)) {                                                            \
            std::fprintf(stderr,                                                                 \
                         "FAIL %s:%d: %s status got=%s expect=%s reason=%s\n", __FILE__,         \
                         __LINE__, (msg), misterplex::codedSizeParseStatusName((r).status),      \
                         misterplex::codedSizeParseStatusName(expect), (r).reason);              \
            ++fails;                                                                             \
        }                                                                                        \
    } while (0)

namespace {

// Same order as main.cpp: start at product default; conf then CLI; reject keeps prior.
struct DecodeAdoption {
    misterplex::CodedSize size = misterplex::kDefaultCodedDecodeSize;
    std::string source = "default";
    misterplex::CodedSizeParseStatus lastStatus = misterplex::CodedSizeParseStatus::Ok;
    const char* lastReason = "default";
};

DecodeAdoption adoptLikeDaemon(const std::string& confDecode, const std::string& cliDecode,
                               bool allowLab480p) {
    DecodeAdoption out;
    if (!confDecode.empty()) {
        const auto adopted = misterplex::adoptExternalCodedSize(confDecode, allowLab480p);
        out.lastStatus = adopted.status;
        out.lastReason = adopted.reason;
        if (adopted.ok()) {
            out.size = adopted.size;
            out.source = "conf";
        }
    }
    if (!cliDecode.empty()) {
        const auto adopted = misterplex::adoptExternalCodedSize(cliDecode, allowLab480p);
        out.lastStatus = adopted.status;
        out.lastReason = adopted.reason;
        if (adopted.ok()) {
            out.size = adopted.size;
            out.source = "cli";
        }
    }
    return out;
}

} // namespace

int main() {
    using namespace misterplex;

    // ------------------------------------------------------------------
    // 1. Fresh / absent conf yields coded 320x240 (shipping default).
    // ------------------------------------------------------------------
    {
        const DecodeAdoption absent = adoptLikeDaemon(/*conf=*/"", /*cli=*/"", /*allow=*/false);
        CHECK_MSG(absent.source == "default",
                  "P1 absent conf/cli must keep source=default");
        CHECK_MSG(absent.size == kDefaultCodedDecodeSize,
                  "P1 absent conf must yield kDefaultCodedDecodeSize");
        CHECK_MSG(absent.size.width.get() == 320 && absent.size.height.get() == 240,
                  "P1 shipping default coded size must be 320x240");
        CHECK_MSG(absent.size.wxh() == "320x240", "P1 default wxh string must be 320x240");

        // Explicit product string still adopts as default geometry.
        const auto explicit240 = adoptExternalCodedSize("320x240", false);
        CHECK_ST_MSG(explicit240, CodedSizeParseStatus::Ok,
                     "P1 DECODE=320x240 must adopt without lab allow");
        CHECK_MSG(explicit240.size == kDefaultCodedDecodeSize,
                  "P1 DECODE=320x240 must equal kDefaultCodedDecodeSize");

        // Default CodedSize{} construction is the product default.
        CHECK_MSG(CodedSize{} == kDefaultCodedDecodeSize,
                  "P1 default-constructed CodedSize must be shipping 320x240");
    }

    // ------------------------------------------------------------------
    // 2. Stale DECODE=624x480 cannot adopt without allow → Lab480pBlocked.
    //    Exact corruption class that once shipped against a 320x240 core.
    // ------------------------------------------------------------------
    {
        const auto blocked = adoptExternalCodedSize("624x480", false);
        CHECK_ST_MSG(blocked, CodedSizeParseStatus::Lab480pBlocked,
                     "P2 stale DECODE=624x480 without allow must be Lab480pBlocked");
        CHECK_MSG(blocked.size == kDefaultCodedDecodeSize,
                  "P2 Lab480pBlocked must fall back to product default 320x240");
        CHECK_MSG(blocked.size.wxh() == "320x240",
                  "P2 blocked adopt size string must remain 320x240");

        const DecodeAdoption viaConf =
            adoptLikeDaemon("624x480", /*cli=*/"", /*allow=*/false);
        CHECK_MSG(viaConf.source == "default",
                  "P2 daemon path must keep source=default when conf 624x480 blocked");
        CHECK_MSG(viaConf.size == kDefaultCodedDecodeSize,
                  "P2 daemon path must not adopt stale conf 624x480");
        CHECK_MSG(viaConf.lastStatus == CodedSizeParseStatus::Lab480pBlocked,
                  "P2 daemon path lastStatus must be Lab480pBlocked");

        // Positive control: allow flag unlocks lab coded 624x480.
        const auto allowed = adoptExternalCodedSize("624x480", true);
        CHECK_ST_MSG(allowed, CodedSizeParseStatus::Ok,
                     "P2 DECODE=624x480 with allow must adopt");
        CHECK_MSG(allowed.size == plex480pCodedDecodeSize(),
                  "P2 allowed lab size must be plex480pCodedDecodeSize");
        CHECK_MSG(allowed.size.width.get() == 624 && allowed.size.height.get() == 480,
                  "P2 allowed lab coded must be 624x480 not 640x480");
    }

    // ------------------------------------------------------------------
    // 3. 640x480 as decode size is PresentedMistake (conf and CLI).
    // ------------------------------------------------------------------
    {
        const auto confPresented = adoptExternalCodedSize("640x480", false);
        CHECK_ST_MSG(confPresented, CodedSizeParseStatus::PresentedMistake,
                     "P3 conf DECODE=640x480 must be PresentedMistake");

        // allowLab480p must never launder presented scanout into coded decode.
        const auto cliPresentedAllow = adoptExternalCodedSize("640x480", true);
        CHECK_ST_MSG(cliPresentedAllow, CodedSizeParseStatus::PresentedMistake,
                     "P3 CLI --decode=640x480 must be PresentedMistake even with lab allow");

        const DecodeAdoption confPath =
            adoptLikeDaemon("640x480", /*cli=*/"", /*allow=*/true);
        CHECK_MSG(confPath.source == "default",
                  "P3 daemon conf 640x480 must not change source");
        CHECK_MSG(confPath.size == kDefaultCodedDecodeSize,
                  "P3 daemon conf 640x480 must keep shipping default");
        CHECK_MSG(confPath.lastStatus == CodedSizeParseStatus::PresentedMistake,
                  "P3 daemon conf path status must be PresentedMistake");

        const DecodeAdoption cliPath =
            adoptLikeDaemon(/*conf=*/"", "640x480", /*allow=*/true);
        CHECK_MSG(cliPath.source == "default",
                  "P3 daemon CLI 640x480 must not change source");
        CHECK_MSG(cliPath.size == kDefaultCodedDecodeSize,
                  "P3 daemon CLI 640x480 must keep shipping default");
        CHECK_MSG(cliPath.lastStatus == CodedSizeParseStatus::PresentedMistake,
                  "P3 daemon CLI path status must be PresentedMistake");

        // Frame-store would accept 640x480 as bare geometry — the presented
        // guard is what stops the footgun (mutation target).
        CHECK_MSG(ddrFrameStoreAcceptsResolution(CodedWidth{640}, CodedHeight{480}),
                  "P3 precond: frame store accepts 640x480 so PresentedMistake is the real guard");
    }

    // ------------------------------------------------------------------
    // 4. CLI --decode wins over conf; both typed and policy-checked.
    // ------------------------------------------------------------------
    {
        // Conf 320x240, CLI 320x240 → cli wins source, same size.
        const DecodeAdoption both240 = adoptLikeDaemon("320x240", "320x240", false);
        CHECK_MSG(both240.source == "cli", "P4 CLI must win source over conf when both ok");
        CHECK_MSG(both240.size == kDefaultCodedDecodeSize, "P4 both-240 size stays default");

        // Conf tries stale 624 without allow; CLI supplies valid 320 → still default via CLI ok.
        const DecodeAdoption confBadCliOk = adoptLikeDaemon("624x480", "320x240", false);
        CHECK_MSG(confBadCliOk.source == "cli",
                  "P4 CLI 320x240 must win after blocked conf 624x480");
        CHECK_MSG(confBadCliOk.size.wxh() == "320x240", "P4 size after CLI win is 320x240");
        CHECK_MSG(confBadCliOk.lastStatus == CodedSizeParseStatus::Ok,
                  "P4 last status is CLI adopt Ok");

        // Conf ok 320; CLI stale 624 without allow → conf remains (CLI rejected).
        const DecodeAdoption confOkCliBlocked = adoptLikeDaemon("320x240", "624x480", false);
        CHECK_MSG(confOkCliBlocked.source == "conf",
                  "P4 rejected CLI must leave conf adoption in place");
        CHECK_MSG(confOkCliBlocked.size == kDefaultCodedDecodeSize,
                  "P4 conf 320 remains after blocked CLI 624");
        CHECK_MSG(confOkCliBlocked.lastStatus == CodedSizeParseStatus::Lab480pBlocked,
                  "P4 blocked CLI lastStatus Lab480pBlocked");

        // Conf 320; CLI allowed 624 → CLI wins lab coded.
        const DecodeAdoption confOkCliLab = adoptLikeDaemon("320x240", "624x480", true);
        CHECK_MSG(confOkCliLab.source == "cli", "P4 CLI lab 624 must win over conf 320");
        CHECK_MSG(confOkCliLab.size == plex480pCodedDecodeSize(),
                  "P4 CLI lab win size is 624x480 coded");

        // Conf presented 640; CLI 320 → CLI repairs.
        const DecodeAdoption confPresentedCliOk = adoptLikeDaemon("640x480", "320x240", false);
        CHECK_MSG(confPresentedCliOk.source == "cli",
                  "P4 CLI must win after conf PresentedMistake");
        CHECK_MSG(confPresentedCliOk.size == kDefaultCodedDecodeSize,
                  "P4 CLI repair yields 320x240");

        // Conf 320; CLI presented 640 → conf remains.
        const DecodeAdoption confOkCliPresented = adoptLikeDaemon("320x240", "640x480", true);
        CHECK_MSG(confOkCliPresented.source == "conf",
                  "P4 presented CLI must not override good conf");
        CHECK_MSG(confOkCliPresented.lastStatus == CodedSizeParseStatus::PresentedMistake,
                  "P4 presented CLI status PresentedMistake");
    }

    // ------------------------------------------------------------------
    // 5. OSD O[4] selects coded 624x480 ladder — never presented 640.
    // ------------------------------------------------------------------
    {
        const ContentResolution osd240 = contentResolutionFromOsdWord(0x0000);
        CHECK_MSG(osd240.width.get() == 320 && osd240.height.get() == 240,
                  "P5 OSD bit4 clear must be coded 320x240");
        CHECK_MSG(std::string(osd240.label) == "320x240", "P5 OSD 240p label is 320x240");

        const ContentResolution osd480 = contentResolutionFromOsdWord(static_cast<uint16_t>(1u << 4));
        CHECK_MSG(osd480.width.get() == 624,
                  "P5 OSD bit4 set coded width must be 624 (not menu-label 640)");
        CHECK_MSG(osd480.width.get() != 640,
                  "P5 OSD bit4 set must NOT use presented width 640 as coded");
        CHECK_MSG(osd480.height.get() == 480, "P5 OSD bit4 set coded height must be 480");
        CHECK_MSG(osd480.width == kPlex480pCodedWidth,
                  "P5 OSD 480 path width tag equals kPlex480pCodedWidth");
        CHECK_MSG(std::string(osd480.label) == "624x480",
                  "P5 OSD 480 coded label must be 624x480");
        CHECK_MSG(std::string(osd480.label) != "640x480",
                  "P5 OSD coded label must not be the menu presented string 640x480");
        CHECK_MSG(osd480.weakBitrateKbps == kPlex480pWeakBitrateKbps,
                  "P5 OSD 480 path bitrate is 480p tier");

        // decodeOsdWord must agree with contentResolutionFromOsdWord on O[4].
        const auto decoded = decodeOsdWord(static_cast<uint16_t>(1u << 4));
        CHECK_MSG(decoded.contentResolution.width.get() == 624,
                  "P5 decodeOsdWord O[4] coded width 624");
        CHECK_MSG(decoded.contentResolution.width.get() != 640,
                  "P5 decodeOsdWord O[4] must not yield presented 640");
    }

    // ------------------------------------------------------------------
    // 6. Bitrate tiering keys off coded size, not presented scanout.
    // ------------------------------------------------------------------
    {
        CHECK_MSG(weakBitrateKbpsForCodedSize(CodedWidth{320}, CodedHeight{240}) ==
                      kPlex240pWeakBitrateKbps,
                  "P6 coded 320x240 bitrate is 240p tier");
        CHECK_MSG(weakBitrateKbpsForCodedSize(kPlex480pCodedWidth, kPlex480pCodedHeight) ==
                      kPlex480pWeakBitrateKbps,
                  "P6 coded 624x480 bitrate is 480p tier");
        CHECK_MSG(weakBitrateKbpsForCodedSize(CodedWidth{480}, CodedHeight{360}) ==
                      kPlex360pWeakBitrateKbps,
                  "P6 coded 480x360 bitrate is 360p tier");

        // contentResolution tiers must agree with weakBitrate helper on coded sizes.
        CHECK_MSG(contentResolutionFor240p().weakBitrateKbps == kPlex240pWeakBitrateKbps,
                  "P6 contentResolutionFor240p bitrate");
        CHECK_MSG(contentResolutionFor480p().weakBitrateKbps == kPlex480pWeakBitrateKbps,
                  "P6 contentResolutionFor480p bitrate");
        CHECK_MSG(contentResolutionFor480p().width.get() == 624,
                  "P6 480p content resolution coded width is 624");

        // If a caller wrongly feeds presented 640 through the *coded* helper, the
        // numeric tier still lands on 480p (>=624) — but adoption must have blocked
        // making 640 a decode size (P3). Pin both sides of that contract.
        CHECK_MSG(weakBitrateKbpsForCodedSize(CodedWidth{640}, CodedHeight{480}) ==
                      kPlex480pWeakBitrateKbps,
                  "P6 numeric 640x480 via coded helper still maps to 480p tier");
        CHECK_MSG(adoptExternalCodedSize("640x480", true).status ==
                      CodedSizeParseStatus::PresentedMistake,
                  "P6 presented 640x480 still cannot become adopted decode size");
    }

    if (fails) {
        std::fprintf(stderr, "test_default_guard: %d failure(s)\n", fails);
        return 1;
    }
    std::printf("test_default_guard: OK\n");
    return 0;
}
