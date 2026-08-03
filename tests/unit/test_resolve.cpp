// Unit tests for slim plex_resolve (no network required for pure helpers).
#include "libmisterplex/ddr_frame_layout.hpp"
#include "libmisterplex/ddr_present_bank.hpp"
#include "libmisterplex/osd_menu.hpp"
#include "libmisterplex/plxg_record.hpp"
#include "libmisterplex/pms_delivery_geom.hpp"
#include "plex_resolve.hpp"

#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

static int fails = 0;
#define CHECK(cond)                                                                              \
    do {                                                                                         \
        if (!(cond)) {                                                                           \
            std::fprintf(stderr, "FAIL %s:%d: %s\n", __FILE__, __LINE__, #cond);                 \
            ++fails;                                                                             \
        }                                                                                        \
    } while (0)

static void checkProfileMatchesContentResolution(const char* path,
                                                 const misterplex::WeakLadder& weak,
                                                 const misterplex::ContentResolution& content) {
    const bool same = weak.videoResolution == content.label &&
                      weak.maxVideoBitrateKbps == content.weakBitrateKbps;
    if (!same) {
        std::fprintf(stderr,
                     "FAIL transcode profile path divergence: %s weak=%s bitrate=%d "
                     "content=%dx%d/%s bitrate=%d\n",
                     path, weak.videoResolution.c_str(), weak.maxVideoBitrateKbps,
                     content.width.get(), content.height.get(), content.label, content.weakBitrateKbps);
        ++fails;
    }
}

int main() {
    using namespace misterplex;

    CHECK(urlDecode("a%2Fb") == "a/b");
    CHECK(urlDecode("hello+world") == "hello world");
    CHECK(urlEncodeQuery("a/b").find("a") != std::string::npos);

    // Docker-bridge hosts rejected without LAN fallback
    auto bad = buildPlexBase("http", "172.17.0.1", "32400", "");
    CHECK(bad.empty());

    auto good = buildPlexBase("http", "pms.lan", "32400", "");
    CHECK(good == "http://pms.lan:32400");

    auto rewritten = buildPlexBase("http", "172-17-0-1.abc.plex.direct", "32400", "pms.lan");
    CHECK(rewritten.find("pms.lan") != std::string::npos);

    // Local path resolve (no network)
    auto r = resolvePlayTarget("/media/fat/mistercast/test.mp4", "", "", 0, true);
    CHECK(r.ok);
    CHECK(r.playable == "/media/fat/mistercast/test.mp4");

    auto t = resolvePlayTarget("testsrc", "", "", 0, true);
    CHECK(t.ok && t.playable == "testsrc");
    CHECK(t.sourceFpsHint == 30 && t.fpsNum == 30 && t.fpsDen == 1);

    auto h = plexFfmpegHeaders("sess1", "tok");
    CHECK(h.find("X-Plex-Session-Identifier: sess1") != std::string::npos);
    CHECK(h.find("X-Plex-Token: tok") != std::string::npos);

    // --- PMS universal transcode profile table / 360p+480p+540p+720p guard ---
    const auto& profiles = plexTranscodeProfiles();
    CHECK(profiles.size() == 5);
    const auto osd240 = contentResolutionFromOsdWord(0);
    const auto osd480 = contentResolutionFromOsdWord(1u << 4);
    const auto path720 = contentResolutionFor720p();
    WeakLadder w240;
    CHECK(applyPlexTranscodeProfile("240p", w240));
    CHECK(w240.profileName == "240p");
    checkProfileMatchesContentResolution("built-in profile 240p", w240, osd240);
    CHECK(w240.h264Profile == "baseline");
    CHECK(w240.h264Level == 30);
    CHECK(validateWeakLadder(w240));

    WeakLadder w480;
    CHECK(applyPlexTranscodeProfile("480p", w480));
    CHECK(w480.profileName == "480p");
    checkProfileMatchesContentResolution("built-in profile 480p", w480, osd480);
    CHECK(w480.videoQuality == 60);
    CHECK(w480.videoCodec == "h264");
    CHECK(w480.audioCodec == "aac");
    CHECK(w480.h264Profile == "baseline");
    CHECK(w480.h264Level == 30);
    CHECK(w480.clientProfileName == "MiSTerPlex");
    CHECK(validateWeakLadder(w480));
    // Resolution alias selects the 480p profile too.
    WeakLadder byRes;
    CHECK(applyPlexTranscodeProfile(osd480.label, byRes));
    CHECK(byRes.profileName == "480p");
    checkProfileMatchesContentResolution("resolution alias 480p", byRes, osd480);

    // Path-720p aggressive tier (DECODE/TRANSCODE_PROFILE — not OSD reserved bit).
    WeakLadder w720;
    CHECK(applyPlexTranscodeProfile("720p", w720));
    CHECK(w720.profileName == "720p");
    checkProfileMatchesContentResolution("built-in profile 720p", w720, path720);
    CHECK(w720.videoResolution == "1280x720");
    CHECK(w720.maxVideoBitrateKbps == kPlex720pWeakBitrateKbps);
    CHECK(w720.videoQuality == 70);
    CHECK(w720.h264Profile == "baseline");
    CHECK(w720.h264Level == 30);
    CHECK(w720.h264Level == kPlex720pH264Level);
    CHECK(validateWeakLadder(w720));
    WeakLadder byRes720;
    CHECK(applyPlexTranscodeProfile("1280x720", byRes720));
    CHECK(byRes720.profileName == "720p");
    checkProfileMatchesContentResolution("resolution alias 720p", byRes720, path720);
    // NEG: 480p and 720p must not accept L>3.0; 720p must not accept L4.0 / high.
    {
        WeakLadder bad480lvl = w480;
        bad480lvl.h264Level = 31;
        CHECK(!validateWeakLadder(bad480lvl));
        WeakLadder bad720lvl = w720;
        bad720lvl.h264Level = 31;
        CHECK(!validateWeakLadder(bad720lvl));
        bad720lvl = w720;
        bad720lvl.h264Level = 40;
        CHECK(!validateWeakLadder(bad720lvl));
        WeakLadder bad720hi = w720;
        bad720hi.h264Profile = "high";
        CHECK(!validateWeakLadder(bad720hi));
        // NEG: 1920x1080 above product ceiling
        WeakLadder bad1080 = w720;
        bad1080.videoResolution = "1920x1080";
        std::string why1080;
        CHECK(!validateWeakLadder(bad1080, &why1080));
        CHECK(why1080.find("1280x720") != std::string::npos);
        // NEG: bitrate below measured true-720 knee must hard-fail (not advisory)
        WeakLadder lowBr = w720;
        lowBr.maxVideoBitrateKbps = 1500;
        std::string whyBr;
        CHECK(!validateWeakLadder(lowBr, &whyBr));
        CHECK(whyBr.find("3100") != std::string::npos);
        lowBr.maxVideoBitrateKbps = 3000;
        CHECK(!validateWeakLadder(lowBr));
        // POS: floor accepted
        lowBr.maxVideoBitrateKbps = 3100;
        CHECK(validateWeakLadder(lowBr));
    }

    // Content-tier full re-apply (doPlay weakForContentResolution contract): an
    // explicit 480p conf ladder must not leave quality/name sticky when OSD/DECODE
    // is 240p — only videoResolution was overwritten before this fix.
    {
        WeakLadder sticky480;
        CHECK(applyPlexTranscodeProfile("480p", sticky480));
        CHECK(sticky480.videoQuality == 60);
        WeakLadder play240 = sticky480;
        CHECK(applyPlexTranscodeProfile(osd240.label, play240));
        CHECK(play240.profileName == "240p");
        CHECK(play240.videoQuality == 40);
        checkProfileMatchesContentResolution("content-tier reapply 240p", play240, osd240);
        WeakLadder play480 = play240;
        CHECK(applyPlexTranscodeProfile(osd480.label, play480));
        CHECK(play480.profileName == "480p");
        CHECK(play480.videoQuality == 60);
        checkProfileMatchesContentResolution("content-tier reapply 480p", play480, osd480);
    }

    const auto start480 =
        buildUniversalTranscodeUrl("http://pms.example:32400", "/library/metadata/3", "tok",
                                   "sess480", 1500, w480);
    CHECK(start480.find("/video/:/transcode/universal/start.mp4") != std::string::npos);
    CHECK(start480.find(std::string("videoResolution=") + osd480.label) != std::string::npos);
    CHECK(start480.find("maxVideoBitrate=" + std::to_string(osd480.weakBitrateKbps)) !=
          std::string::npos);
    CHECK(start480.find("videoQuality=60") != std::string::npos);
    CHECK(start480.find("videoCodec=h264") != std::string::npos);
    CHECK(start480.find("audioCodec=aac") != std::string::npos);
    CHECK(start480.find("videoProfile=baseline") != std::string::npos);
    CHECK(start480.find("videoLevel=30") != std::string::npos);
    CHECK(start480.find("offset=2") != std::string::npos);
    // Universal path forces directPlay=0 — geometry comes from transcoder ceiling.
    CHECK(start480.find("directPlay=0") != std::string::npos);
    CHECK(start480.find("directStream=0") != std::string::npos);
    // No exact width=/height= pin in the start URL (ceiling is videoResolution only).
    CHECK(start480.find("&width=") == std::string::npos);
    CHECK(start480.find("&height=") == std::string::npos);

    // --- RK6 proven: SAR 160:117 on 624x480 ⇒ DAR 16:9 ⇒ fit 624x350 ---
    // PRE-REGISTER (lab decision matrix): 624x480→624x350, 640x480→640x360,
    // 853x480→852x480 (true 480 rows, wider than DDR bank 624).
    {
        const double dar =
            displayAspectFromCodedAndSar(624, 480, 160, 117);
        CHECK(std::fabs(dar - (16.0 / 9.0)) < 1e-9);
        const double dar2 = resolveContentDar(624, 480, "160:117", "1.78");
        CHECK(std::fabs(dar2 - (16.0 / 9.0)) < 1e-9);
        const auto fit = pmsSquarePixelFitInCeiling(16.0 / 9.0, 624, 480);
        CHECK(fit.ok);
        CHECK(fit.w == 624);
        CHECK(fit.h == 350); // 351 even-floored — matches PMS decision
        const auto fit640 = pmsSquarePixelFitInCeiling(16.0 / 9.0, 640, 480);
        CHECK(fit640.ok && fit640.w == 640 && fit640.h == 360);
        const int w_at_480 = squarePixelWidthForHeight(16.0 / 9.0, 480);
        CHECK(w_at_480 >= 852 && w_at_480 <= 854); // ~853.33
        CHECK(w_at_480 > 624); // cannot fit square-pixel 16:9@480h in DDR bank
        CHECK(std::fabs(verticalDetailFraction(350, 480) - (350.0 / 480.0)) < 1e-12);
        CHECK(!desyncModelApplicable(false)); // identity_skip=0 kills 1.371 model
        CHECK(desyncModelApplicable(true));
        // Asset-class split (lab library): AdvReal 624x480 ar=1.33 → fit stays ~480;
        // rk6 ar=1.78+SAR → 350; genuine 4:3 square SAR must not be letterboxed.
        const auto fit43 = pmsSquarePixelFitInCeiling(4.0 / 3.0, 624, 480);
        CHECK(fit43.ok);
        CHECK(fit43.h >= 468 && fit43.h <= 480); // full-height class, not 350
        CHECK(fit43.h != 350);
        const double dar_rk6 = resolveContentDar(624, 480, "160:117", "1.78");
        const auto fit_rk6 = pmsSquarePixelFitInCeiling(dar_rk6, 624, 480);
        CHECK(fit_rk6.h == 350);
        const double dar_adv = resolveContentDar(624, 480, "", "1.33");
        const auto fit_adv = pmsSquarePixelFitInCeiling(dar_adv, 624, 480);
        CHECK(fit_adv.h >= 468); // AdvReal class
        std::printf("GREEN_PMS_FIT dar=16/9 fit624=%dx%d fit640=%dx%d w_at_480=%d "
                    "detail=%.3f fit43=%dx%d fit_adv=%dx%d\n",
                    fit.w, fit.h, fit640.w, fit640.h, w_at_480,
                    verticalDetailFraction(350, 480), fit43.w, fit43.h, fit_adv.w,
                    fit_adv.h);
    }

    const auto extra480 = plexClientProfileExtra(w480);
    CHECK(extra480.find("container=mpegts") != std::string::npos);
    CHECK(extra480.find("videoCodec=h264") != std::string::npos);
    CHECK(extra480.find("audioCodec=aac") != std::string::npos);
    CHECK(extra480.find("name=video.profile&list=baseline") != std::string::npos);
    CHECK(extra480.find("name=video.level&value=30") != std::string::npos);
    CHECK(extra480.find("scope=videoTranscodeTarget&scopeName=h264") != std::string::npos);
    CHECK(extra480.find("name=video.width&value=" + std::to_string(osd480.width.get())) !=
          std::string::npos);
    CHECK(extra480.find("name=video.height&value=" + std::to_string(osd480.height.get())) !=
          std::string::npos);
    const auto caps480 = plexClientCapabilities(w480);
    CHECK(caps480.find(std::string("videoDecoders=h264{profile:baseline&resolution:") +
                        osd480.label + "&level:30}") != std::string::npos);
    const auto headers480 = plexFfmpegHeaders("sess480", "tok", w480);
    CHECK(headers480.find("X-Plex-Client-Profile-Name: MiSTerPlex") != std::string::npos);
    CHECK(headers480.find("X-Plex-Client-Profile-Name: Generic") == std::string::npos);
    CHECK(headers480.find("X-Plex-Client-Profile-Name: Chrome") == std::string::npos);
    CHECK(headers480.find("X-Plex-Client-Capabilities: ") == std::string::npos);
    // 480p leaves maxVideoFrameRate=0 → no Extra on MiSTerPlex (encode flags stay in XML).
    CHECK(w480.maxVideoFrameRate == 0);
    CHECK(headers480.find("X-Plex-Client-Profile-Extra: ") == std::string::npos);

    w480.clientProfileName = "Generic";
    const auto genericHeaders480 = plexFfmpegHeaders("sess480", "tok", w480);
    CHECK(genericHeaders480.find("X-Plex-Client-Profile-Name: Generic") != std::string::npos);
    CHECK(genericHeaders480.find("X-Plex-Client-Capabilities: ") != std::string::npos);
    CHECK(genericHeaders480.find("X-Plex-Client-Profile-Extra: ") != std::string::npos);

    WeakLadder bad480 = w480;
    bad480.h264Profile = "high";
    CHECK(!validateWeakLadder(bad480));
    bad480 = w480;
    bad480.h264Level = 31;
    CHECK(!validateWeakLadder(bad480));

    // 480p bitrate floor was a quality/link heuristic hard-fail — retired.
    // Explicit WEAK_BITRATE=1000 (or 900) on 480p must validate so slow links
    // can request under 2000 kbps. Decoder contracts (baseline / L3.0) stay hard.
    {
        WeakLadder lowBr = w480;
        lowBr.maxVideoBitrateKbps = 1000;
        CHECK(validateWeakLadder(lowBr));
        CHECK(recommendedMinVideoBitrateKbps(lowBr) == kPlex480pWeakBitrateKbps);
        CHECK(weakLadderBitrateBelowRecommended(lowBr));
        std::string det;
        CHECK(weakLadderBitrateBelowRecommended(lowBr, &det));
        CHECK(det.find("recommended_min=2000") != std::string::npos);
        CHECK(det.find("maxVideoBitrateKbps=1000") != std::string::npos);
        // Wire URL must carry the explicit bitrate (not silently 2000).
        const auto url900 = buildUniversalTranscodeUrl("http://pms:32400", "/library/metadata/1",
                                                       "tok", "sess", 0, [&] {
                                                           WeakLadder w = w480;
                                                           w.maxVideoBitrateKbps = 900;
                                                           return w;
                                                       }());
        CHECK(url900.find("maxVideoBitrate=900") != std::string::npos);
        CHECK(url900.find("maxVideoBitrate=2000") == std::string::npos);
        CHECK(validateWeakLadder([&] {
            WeakLadder w = w480;
            w.maxVideoBitrateKbps = 900;
            return w;
        }()));
        // Default 480p is at the recommended floor — not below.
        CHECK(!weakLadderBitrateBelowRecommended(w480));
        // Zero still hard-fails (positive required).
        lowBr.maxVideoBitrateKbps = 0;
        CHECK(!validateWeakLadder(lowBr));
        // 240p below legacy soft 750 is advisory only, not a hard fail.
        WeakLadder low240 = w240;
        low240.maxVideoBitrateKbps = 500;
        CHECK(validateWeakLadder(low240));
        CHECK(weakLadderBitrateBelowRecommended(low240));
        // Ladder step-down (geometry unchanged) — discrete steps, no link speed.
        CHECK(nextLowerLadderBitrateKbps(4000) == 3500);
        CHECK(nextLowerLadderBitrateKbps(3500) == 3100);
        CHECK(nextLowerLadderBitrateKbps(3100) == 3000);
        CHECK(nextLowerLadderBitrateKbps(3000) == 2500);
        CHECK(nextLowerLadderBitrateKbps(2500) == 2000);
        CHECK(nextLowerLadderBitrateKbps(2000) == 1500);
        CHECK(nextLowerLadderBitrateKbps(1500) == 1000);
        CHECK(nextLowerLadderBitrateKbps(1000) == 750);
        CHECK(nextLowerLadderBitrateKbps(750) == 500);
        CHECK(nextLowerLadderBitrateKbps(500) == 400);
        CHECK(nextLowerLadderBitrateKbps(400) == 0);
        CHECK(nextLowerLadderBitrateKbps(900) == 750); // between steps → next below
        CHECK(!starveStepdownReady(7));
        CHECK(starveStepdownReady(8));
        CHECK(starveStepdownReady(3, 3));
        // Optional link capacity clamp — capacity unset must not invent a floor.
        CHECK(applyLinkCapacityCapKbps(2000, 0, 85) == 2000);
        CHECK(applyLinkCapacityCapKbps(2000, -1, 85) == 2000);
        // Parent greedy goodput ~1153 kbit/s → 85% headroom = 980; clamps 2000→980.
        CHECK(applyLinkCapacityCapKbps(2000, 1153, 85) == 980);
        CHECK(applyLinkCapacityCapKbps(900, 1153, 85) == 900); // already under cap
        CHECK(applyLinkCapacityCapKbps(2000, 1153, 100) == 1153);
        // Bad headroom falls back to default 85.
        CHECK(applyLinkCapacityCapKbps(2000, 1000, 0) == 850);
        CHECK(applyLinkCapacityCapKbps(2000, 1000, 200) == 850);
        std::printf("PASS 480p WEAK_BITRATE below recommended + link capacity clamp\n");
    }

    // --- Phase 4 multi-server conf helpers (no network) ---
    CHECK(normalizePlexBase("http://pms.lan:32400/") == "http://pms.lan:32400");
    CHECK(normalizePlexBase("pms2.lan:32400") == "http://pms2.lan:32400");
    CHECK(normalizePlexBase("pms2.lan") == "http://pms2.lan:32400");
    CHECK(normalizePlexBase("  https://pms.lan:32400  ") == "https://pms.lan:32400");
    CHECK(normalizePlexBase("").empty());

    auto list = parsePlexServerList("http://a:32400,http://b:32400; http://c:32400");
    CHECK(list.size() == 3);
    CHECK(list[0] == "http://a:32400");
    CHECK(list[1] == "http://b:32400");
    CHECK(list[2] == "http://c:32400");

    // Dedup + bare host
    auto dedup = parsePlexServerList("pms3.lan, http://pms3.lan:32400, pms3.lan:32400");
    CHECK(dedup.size() == 1);
    CHECK(dedup[0] == "http://pms3.lan:32400");

    // merge: PLEX_SERVERS first, then extra PLEX_BASE lines
    std::vector<std::string> bases = {"http://extra:32400", "http://a:32400"};
    auto merged = mergePlexServers("http://a:32400,http://b:32400", bases);
    CHECK(merged.size() == 3);
    CHECK(merged[0] == "http://a:32400");
    CHECK(merged[1] == "http://b:32400");
    CHECK(merged[2] == "http://extra:32400");

    // Empty merge
    auto empty = mergePlexServers("", {});
    CHECK(empty.empty());

    // Invalid / empty play-queue ids fail without network (P4-SCRUB edges)
    auto pq = fetchPlayQueue("not-a-queue", "http://127.0.0.1:32400", "tok");
    CHECK(!pq.ok);

    // --- Seek/resume: companion ms → PMS universal offset= seconds ---
    // Resume @ 3:54 (234000 ms) must become offset=234, not double-seek with -ss.
    CHECK(universalOffsetSeconds(0) == 0);
    CHECK(universalOffsetSeconds(-1) == 0);
    CHECK(universalOffsetSeconds(500) == 1);     // half-up
    CHECK(universalOffsetSeconds(499) == 0);
    CHECK(universalOffsetSeconds(1000) == 1);
    CHECK(universalOffsetSeconds(234000) == 234); // Trek ~3:54
    CHECK(universalOffsetSeconds(234499) == 234);
    CHECK(universalOffsetSeconds(234500) == 235);
    auto pqEmpty = fetchPlayQueue("", "http://127.0.0.1:32400", "tok");
    CHECK(!pqEmpty.ok);
    auto pqLib = fetchPlayQueue("/library/metadata/9", "http://127.0.0.1:32400", "tok");
    CHECK(!pqLib.ok); // must not treat metadata key as queue
    auto pqNoBase = fetchPlayQueue("/playQueues/1", "", "tok");
    CHECK(!pqNoBase.ok);
    // Bare numeric id is accepted as queue id shape (network would still fail/empty)
    auto pqBare = fetchPlayQueue("42", "", "tok");
    CHECK(!pqBare.ok); // no PMS base

    // --- Phase 4 Content FPS / SOURCE_FPS helpers (no network) ---
    CHECK(contentFpsHint("24p", "") == 24);
    CHECK(contentFpsHint("NTSC", "") == 30);
    CHECK(contentFpsHint("60p", "") == 60);
    CHECK(contentFpsHint("", "23.976") == 24);
    CHECK(contentFpsHint("", "29.970") == 30);
    CHECK(contentFpsHint("", "59.94") == 60);
    CHECK(contentFpsHint("film", "") == 24);
    CHECK(contentFpsHint("", "") == 0);
    // Numeric frameRate wins over token
    CHECK(contentFpsHint("NTSC", "23.976") == 24);

    CHECK(applySourceFpsConf("auto", 24) == 24);
    CHECK(applySourceFpsConf("", 30) == 30);
    CHECK(applySourceFpsConf("off", 24) == 0);
    CHECK(applySourceFpsConf("60", 24) == 60);
    CHECK(applySourceFpsConf("24", 0) == 24);
    CHECK(applySourceFpsConf("auto", 0) == 0);

    // --- Two-regime + DP default + full identity headers (parent 720p content) ---
    // PMS content ceiling 1280×720; native 720 DP-eligible; >720 → xcode 720p tier.
    // 1ppc beam math remains honest (routeBContentDeFitsFps) but does not block PMS.
    {
        using misterplex::PlayDeliveryRegime;
        using misterplex::clampCodedSizeToRouteBHostCap;
        using misterplex::mediaExceedsRouteBHostContentCap;
        using misterplex::mediaIsHdAbove720p;
        using misterplex::playDeliveryRegimeName;
        using misterplex::routeBContentDeFitsFps;
        using misterplex::routeBTotalPixelsPerSec;
        using misterplex::selectPlayDeliveryRegime;
        CHECK(!mediaIsHdAbove720p(624, 480));
        CHECK(!mediaIsHdAbove720p(960, 540));
        CHECK(!mediaIsHdAbove720p(1280, 720)); // exact 720 is DP content, not "above"
        CHECK(mediaIsHdAbove720p(1920, 1080));
        CHECK(mediaIsHdAbove720p(1440, 1080));
        CHECK(!mediaIsHdAbove720p(0, 0));
        CHECK(!mediaExceedsRouteBHostContentCap(1280, 720, /*multi*/ true));
        CHECK(mediaExceedsRouteBHostContentCap(1920, 1080, /*multi*/ true));
        CHECK(selectPlayDeliveryRegime(624, 480, true, true) ==
              PlayDeliveryRegime::DirectPlaySd);
        CHECK(selectPlayDeliveryRegime(320, 240, true, true) ==
              PlayDeliveryRegime::DirectPlaySd);
        CHECK(selectPlayDeliveryRegime(960, 540, true, true) ==
              PlayDeliveryRegime::DirectPlaySd);
        // POS: native 720 → DP (rk=7 cheapest); full-HD → xcode 720 tier
        CHECK(selectPlayDeliveryRegime(1280, 720, true, true) ==
              PlayDeliveryRegime::DirectPlaySd);
        CHECK(selectPlayDeliveryRegime(1920, 1080, true, true) ==
              PlayDeliveryRegime::TranscodeHd720);
        CHECK(selectPlayDeliveryRegime(1280, 720, true, true, /*multi*/ true) ==
              PlayDeliveryRegime::DirectPlaySd);
        // NEG: never hardcode rk — geometry alone selects HD xcode for >720.
        CHECK(selectPlayDeliveryRegime(1920, 1080, true, true) !=
              PlayDeliveryRegime::DirectPlaySd);
        CHECK(selectPlayDeliveryRegime(624, 480, false, true) ==
              PlayDeliveryRegime::ForceUniversal);
        CHECK(selectPlayDeliveryRegime(624, 480, true, false) ==
              PlayDeliveryRegime::ForceUniversal);
        CHECK(std::string(playDeliveryRegimeName(PlayDeliveryRegime::DirectPlaySd)) ==
              "direct_play_sd");
        CHECK(std::string(playDeliveryRegimeName(PlayDeliveryRegime::TranscodeHd720)) ==
              "transcode_hd_720");
        // Beam math still honest (1ppc cannot scan full 1280@24) — separate from PMS.
        CHECK(routeBContentDeFitsFps(960, 540, 24));
        CHECK(routeBContentDeFitsFps(960, 540, 30));
        CHECK(routeBContentDeFitsFps(624, 480, 24));
        CHECK(!routeBContentDeFitsFps(1280, 720, 24));
        CHECK(!routeBContentDeFitsFps(1280, 720, 30));
        CHECK(routeBTotalPixelsPerSec(1280, 720, 24) > 20000000LL);
        CHECK(routeBTotalPixelsPerSec(960, 540, 24) <= 20000000LL);
        int cw = 1280, ch = 720;
        CHECK(clampCodedSizeToRouteBHostCap(cw, ch, false));
        CHECK(cw == 960 && ch == 540);
        cw = 1280;
        ch = 720;
        CHECK(!clampCodedSizeToRouteBHostCap(cw, ch, /*multi*/ true));
        CHECK(cw == 1280 && ch == 720);

        // resolve → PMS target is always real 720p tier
        using misterplex::routeBDefaultDecisionResolution;
        using misterplex::routeBHdTranscodeTargetSize;
        using misterplex::routeBResolvedSizeLegal;
        int tw = 0, th = 0;
        CHECK(std::string(routeBHdTranscodeTargetSize(false, &tw, &th)) == "720p");
        CHECK(tw == 1280 && th == 720);
        CHECK(routeBResolvedSizeLegal(tw, th, 24, false));
        CHECK(std::string(routeBDefaultDecisionResolution(false)) == "1280x720");
        CHECK(std::string(routeBDefaultDecisionResolution(true)) == "1280x720");
        CHECK(routeBResolvedSizeLegal(1280, 720, 24, false));
        // NEG: 1080 content size illegal on product ladder
        CHECK(!routeBResolvedSizeLegal(1920, 1080, 24, false));
        tw = th = 0;
        CHECK(std::string(routeBHdTranscodeTargetSize(true, &tw, &th)) == "720p");
        CHECK(tw == 1280 && th == 720);

        // Cross-contract: HD target → storage geom (content 720)
        {
            using misterplex::DdrPublishFrame;
            using misterplex::DdrPublishPlan;
            using misterplex::ddrFrameGeometryForFpgaPresent;
            using misterplex::makeDdrPublishPlan;
            using misterplex::unpackPlxgQ2;
            using misterplex::yuv420pFrameBytes;
            int rw = 0, rh = 0;
            routeBHdTranscodeTargetSize(false, &rw, &rh);
            CHECK(rw == 1280 && rh == 720);
            const auto g = ddrFrameGeometryForFpgaPresent(rw, rh);
            CHECK(g.coded_width.get() == 1280 && g.coded_height.get() == 720);
            CHECK(routeBResolvedSizeLegal(g.coded_width.get(), g.coded_height.get(), 24, false));
            const size_t bytes = yuv420pFrameBytes(g.coded_width, g.coded_height);
            std::vector<uint8_t> yuv(bytes, 0x10);
            DdrPublishFrame f{yuv.data(), yuv.size(), g, misterplex::DdrFrameFormat::Yuv420p};
            DdrPublishPlan plan{};
            std::string err;
            CHECK(makeDdrPublishPlan(f, 0, plan, &err));
            int pcw = 0, pch = 0, deW = 0, deH = 0;
            unpackPlxgQ2(plan.plxg_q[2], &deW, &deH, &pcw, &pch);
            CHECK(pcw == 1280 && pch == 720);
            CHECK(deW == 1280 && deH == 720);
            // Beam 1ppc still cannot scan 1280@24 — honest, separate contract
            CHECK(!routeBContentDeFitsFps(1280, 720, 24, false));
            CHECK(!routeBResolvedSizeLegal(1920, 1080, 24, false));
        }

        // miss #15: HD xcode class is ARM for fabric even if attr says CB
        CHECK(!plexDeliveryIsFabricEligible(true, "constrained baseline"));
        CHECK(plexDeliveryIsFabricEligible(false, "constrained baseline"));
        CHECK(!plexDeliveryIsFabricEligible(false, "main"));

        const auto full = plexFfmpegHeaders("sess-full", "tok", WeakLadder{});
        CHECK(plexClientIdentityHeadersComplete(full));
        const auto thin = plexThinClientIdentityHeadersForTest("sess-thin", "tok");
        CHECK(!plexClientIdentityHeadersComplete(thin)); // NEG: thin must not pass
        CHECK(thin.find("X-Plex-Product:") == std::string::npos);
        CHECK(thin.find("X-Plex-Client-Identifier:") == std::string::npos);

        // Product 720 profile builds universal URLs (parent top priority).
        WeakLadder w720;
        applyPlexTranscodeProfile("720p", w720);
        const auto decDp =
            buildUniversalDecisionUrl("http://pms.example:32400", "/library/metadata/36", "tok",
                                      "sid-dp", w720, /*allow_direct=*/true);
        CHECK(decDp.find("/video/:/transcode/universal/decision") != std::string::npos);
        CHECK(decDp.find("directPlay=1") != std::string::npos);
        CHECK(decDp.find("directStream=1") != std::string::npos);
        CHECK(decDp.find("hasMDE=1") != std::string::npos);
        CHECK(decDp.find("location=lan") != std::string::npos);
        CHECK(decDp.find("videoResolution=1280x720") != std::string::npos);
        WeakLadder wDef;
        wDef.videoResolution = routeBDefaultDecisionResolution(false);
        const auto decDef =
            buildUniversalDecisionUrl("http://pms.example:32400", "/library/metadata/36", "tok",
                                      "sid-def", wDef, /*allow_direct=*/true);
        CHECK(decDef.find("videoResolution=1280x720") != std::string::npos);
        CHECK(decDef.find("videoResolution=960x540") == std::string::npos);
        const auto decXc =
            buildUniversalDecisionUrl("http://pms.example:32400", "/library/metadata/2", "tok",
                                      "sid-xc", w720, /*allow_direct=*/false);
        CHECK(decXc.find("directPlay=0") != std::string::npos);
        CHECK(decXc.find("directStream=0") != std::string::npos);

        // Decision attribute parse (no network) — parent 400/DP recipe
        const std::string dpXml =
            R"(<MediaContainer><VideoStream decision="directplay" videoProfile="constrained baseline"/></MediaContainer>)";
        const std::string xcXml =
            R"(<MediaContainer><VideoStream decision="transcode" videoProfile="constrained baseline"/></MediaContainer>)";
        CHECK(plexParseDecisionAttr(dpXml) == "directplay");
        CHECK(plexDecisionXmlIsDirectPlay(dpXml));
        CHECK(!plexDecisionXmlIsTranscode(dpXml));
        CHECK(plexParseDecisionAttr(xcXml) == "transcode");
        CHECK(plexDecisionXmlIsTranscode(xcXml));
        CHECK(!plexDecisionXmlIsDirectPlay(xcXml));
        // Case fold
        CHECK(plexDecisionXmlIsDirectPlay(
            R"(<Video decision="DirectPlay" />)"));
        CHECK(plexParseDecisionAttr("").empty());
        CHECK(!plexDecisionXmlIsDirectPlay(""));
    }

    // --- STREAM preferDirectH264 helpers (no network) ---
    CHECK(mediaVideoIsH264("") == false);
    CHECK(mediaVideoIsH264("<Media videoCodec=\"h264\" />") == true);
    CHECK(mediaVideoIsH264("<Media videoCodec=\"hevc\" />") == false);
    CHECK(mediaVideoIsH264("<Media videoCodec=\"avc\" />") == true);
    CHECK(mediaVideoIsH264("<Media videoCodec=\"x264\" />") == true);
    CHECK(mediaVideoIsH264("<Media videoCodec=\"H264\" />") == true);
    CHECK(mediaVideoIsH264(
              "<Stream streamType=\"1\" codec=\"h264\" type=\"video\" />") == true);
    CHECK(mediaVideoIsH264(
              "<Stream type=\"video\" codec=\"avc1\" />") == true);
    CHECK(mediaVideoIsH264(
              "<Stream streamType=\"2\" codec=\"aac\" /><Media videoCodec=\"hevc\"/>") == false);
    // Local path + direct URL still resolve without preferDirect flag
    auto directLocal =


        resolvePlayTarget("/media/fat/misterplex/plex_real_baseline.264", "", "", 0, true, {},
                          true);
    CHECK(directLocal.ok &&
          directLocal.playable == "/media/fat/misterplex/plex_real_baseline.264");


    // preferDirectH264 does not alter local/http passthrough detail
    auto directUrl =
        resolvePlayTarget("http://pms.lan:32400/library/parts/1/file.mkv", "", "", 0, true, {},
                          true);
    CHECK(directUrl.ok && directUrl.detail == "direct URL");
    auto localPath = resolvePlayTarget("/media/fat/misterplex/clip.mp4", "", "", 0, true, {}, true);
    CHECK(localPath.ok && localPath.detail == "local path");

    // --- exact rational content rate (A/V pacing) ---
    // PMS reports Media@videoFrameRate="24p" for 23.976 content; the Stream@frameRate
    // value is the truthful one and must win.
    {
        int n = 0, d = 0;
        CHECK(parseExactFps("24p", "23.976", n, d) && n == 24000 && d == 1001);
        n = d = 0;
        CHECK(parseExactFps("", "23.976023", n, d) && n == 24000 && d == 1001);
        n = d = 0;
        CHECK(parseExactFps("", "24.000", n, d) && n == 24 && d == 1);
        n = d = 0;
        CHECK(parseExactFps("", "29.97", n, d) && n == 30000 && d == 1001);
        n = d = 0;
        CHECK(parseExactFps("", "59.94", n, d) && n == 60000 && d == 1001);
        n = d = 0;
        CHECK(parseExactFps("", "25", n, d) && n == 25 && d == 1);
        n = d = 0;
        CHECK(parseExactFps("PAL", "", n, d) && n == 25 && d == 1);
        n = d = 0;
        CHECK(parseExactFps("NTSC", "", n, d) && n == 30000 && d == 1001);
        n = d = 0;
        // Fall back to the videoFrameRate bucket only when Stream@frameRate is absent.
        CHECK(parseExactFps("24p", "", n, d) && n == 24 && d == 1);
        n = d = 0;
        CHECK(parseExactFps("", "", n, d) == false && n == 0 && d == 0);
        n = d = 0;
        CHECK(parseExactFps("", "garbage", n, d) == false);
        // Non-standard rate is kept as-is (no snap), not rejected.
        n = d = 0;
        CHECK(parseExactFps("", "23.0", n, d) && n == 23000 && d == 1000);
    }
    {
        // Conf override wins over metadata; "auto"/empty leaves it alone.
        int n = 24000, d = 1001;
        CHECK(applyContentFpsConf("auto", n, d) == false && n == 24000 && d == 1001);
        CHECK(applyContentFpsConf("", n, d) == false && n == 24000 && d == 1001);
        CHECK(applyContentFpsConf("25", n, d) && n == 25 && d == 1);
        CHECK(applyContentFpsConf("24000/1001", n, d) && n == 24000 && d == 1001);
        CHECK(applyContentFpsConf("29.97", n, d) && n == 30000 && d == 1001);
        n = 24; d = 1;
        CHECK(applyContentFpsConf("junk", n, d) == false && n == 24 && d == 1);
    }

    // --- Path-720p: URL + genuine delivery gate (measured lab PMS rk7) ---
    {
        WeakLadder w720;
        CHECK(applyPlexTranscodeProfile("720p", w720));
        const auto start720 =
            buildUniversalTranscodeUrl("http://pms.example:32400", "/library/metadata/7", "tok",
                                       "sess720", 0, w720);
        CHECK(start720.find("videoResolution=1280x720") != std::string::npos);
        CHECK(start720.find("maxVideoBitrate=3100") != std::string::npos);
        CHECK(start720.find("videoLevel=30") != std::string::npos);
        CHECK(start720.find("videoProfile=baseline") != std::string::npos);
        CHECK(start720.find("directPlay=0") != std::string::npos);
        // Request pin string stays baseline; delivery truth is bitstream gate route.
        CHECK(std::string(kPlexH264ProfilePin) == "baseline");
        CHECK(w720.h264Profile == kPlexH264ProfilePin);
        // Defense-in-depth: even if WeakLadder is mutated to high after validate,
        // the universal URL still emits videoProfile=baseline (never High).
        {
            WeakLadder evil = w720;
            evil.h264Profile = "high";
            CHECK(!validateWeakLadder(evil));
            const auto evilUrl =
                buildUniversalTranscodeUrl("http://pms.example:32400", "/library/metadata/7",
                                           "tok", "sessEvil", 0, evil);
            CHECK(evilUrl.find("videoProfile=baseline") != std::string::npos);
            CHECK(evilUrl.find("videoProfile=high") == std::string::npos);
        }
        // Decision/Media @videoProfile attribute gate (honest refuse, not garbage).
        CHECK(plexDeliveryProfileIsFabricSafe("baseline"));
        CHECK(plexDeliveryProfileIsFabricSafe("constrained baseline"));
        CHECK(!plexDeliveryProfileIsFabricSafe("high"));
        CHECK(!plexDeliveryProfileIsFabricSafe("High"));
        CHECK(!plexDeliveryProfileIsFabricSafe("main"));
        CHECK(!plexDeliveryProfileIsFabricSafe(""));
        CHECK(recommendedMinVideoBitrateKbps(w720) == kPlex720pWeakBitrateKbps);
        CHECK(kPlex720pWeakBitrateKbps == 3100);
        CHECK(kPlex720pDecodeOptimalBitrateKbps == 1500);
        CHECK(kPlex720pH264Level == 30);
        // Universal @1500 is the 720x404 trap class — HARD reject on validateWeakLadder.
        // Decode-optimal 1500 remains a DP/content constant only (not a universal pin).
        WeakLadder low720 = w720;
        low720.maxVideoBitrateKbps = kPlex720pDecodeOptimalBitrateKbps;
        CHECK(!validateWeakLadder(low720));
        CHECK(!pmsBitrateLikelyTrue720p(kPlex720pDecodeOptimalBitrateKbps));
        CHECK(!pmsBitrateLikelyTrue720p(2000));
        CHECK(!pmsBitrateLikelyTrue720p(3000));
        CHECK(pmsBitrateLikelyTrue720p(3100));
        CHECK(pmsBitrateLikelyTrue720p(3500));
        CHECK(pmsBitrateLikelyTrue720p(4000));
        // NEGATIVE: shorter coded height must NOT be treated as true 720p.
        // Lab fine matrix: maxBR=3000 → 720x404; maxBR=3100 → 1280x720.
        CHECK(isGenuine720pDelivery(1280, 720));
        CHECK(!isGenuine720pDelivery(720, 404));
        CHECK(!isGenuine720pDelivery(624, 350));
        CHECK(!isGenuine720pDelivery(1280, 718));
        CHECK(!isGenuine720pDelivery(1278, 720));
        CHECK(!isGenuine720pDelivery(0, 720));
        // 16:9 square-pixel fit into 1280x720 ceiling stays full tier.
        const auto fit720 = pmsSquarePixelFitInCeiling(16.0 / 9.0, 1280, 720);
        CHECK(fit720.ok && fit720.w == 1280 && fit720.h == 720);
        // Content-tier re-apply must not leave 720 sticky when returning to 480p.
        WeakLadder sticky720 = w720;
        WeakLadder play480 = sticky720;
        CHECK(applyPlexTranscodeProfile(osd480.label, play480));
        CHECK(play480.profileName == "480p");
        CHECK(play480.h264Level == 30);
        checkProfileMatchesContentResolution("content-tier reapply 480p from 720", play480,
                                             osd480);
        std::printf("GREEN_PATH_720p url+genuine_delivery+bitrate_gate\n");
    }

    // Shippable 720p *glass* source tier (parent proxy 5/5): 960x540 + fabric upscale.
    // NEVER claim true 720p source. Negatives: shorter coded height is not genuine 540p.
    {
        WeakLadder w540;
        CHECK(applyPlexTranscodeProfile("540p", w540));
        CHECK(w540.videoResolution == std::string("960x540"));
        CHECK(w540.maxVideoBitrateKbps == kPlex540pWeakBitrateKbps);
        CHECK(w540.h264Level == kPlex540pH264Level);
        CHECK(w540.h264Profile == kPlexH264ProfilePin);
        CHECK(w540.maxVideoFrameRate == kPlex540pMaxVideoFrameRate);
        CHECK(kPlex540pMaxVideoFrameRate == 24);
        CHECK(validateWeakLadder(w540));
        // Hard knee: maxBR<2000 → PMS 720x404 class — must not validate.
        {
            WeakLadder low540 = w540;
            low540.maxVideoBitrateKbps = 1500;
            CHECK(!validateWeakLadder(low540)); // NEG: 720x404 trap
            std::string why;
            CHECK(!validateWeakLadder(low540, &why));
            CHECK(why.find("2000") != std::string::npos);
        }
        WeakLadder byRes;
        CHECK(applyPlexTranscodeProfile("960x540", byRes));
        CHECK(byRes.videoResolution == std::string("960x540"));
        CHECK(byRes.maxVideoFrameRate == 24);
        const auto url540 =
            buildUniversalTranscodeUrl("http://pms.example:32400", "/library/metadata/9", "tok",
                                       "sess540", 0, w540);
        CHECK(url540.find("videoResolution=960x540") != std::string::npos);
        CHECK(url540.find("videoProfile=baseline") != std::string::npos);
        CHECK(url540.find("videoLevel=31") != std::string::npos);
        CHECK(url540.find("maxVideoBitrate=2000") != std::string::npos);
        // Query fps params are NOT the lever (measured MISS). Cap is Extra only.
        CHECK(url540.find("maxFrameRate=") == std::string::npos);
        CHECK(url540.find("frameRate=") == std::string::npos);
        const auto fr540 = plexClientProfileFrameRateExtra(w540);
        CHECK(fr540.find("name=video.frameRate&value=24") != std::string::npos);
        CHECK(fr540.find("scope=videoTranscodeTarget") != std::string::npos);
        // MiSTerPlex path: frame-rate-only Extra (not full Extra / no Capabilities).
        const auto hdr540 = plexFfmpegHeaders("sess540", "tok", w540);
        CHECK(hdr540.find("X-Plex-Client-Profile-Name: MiSTerPlex") != std::string::npos);
        CHECK(hdr540.find("X-Plex-Client-Capabilities: ") == std::string::npos);
        CHECK(hdr540.find("X-Plex-Client-Profile-Extra: ") != std::string::npos);
        CHECK(hdr540.find("name=video.frameRate&value=24") != std::string::npos);
        // NEG: full Extra encode-target rewrite must not ride on MiSTerPlex 540 path.
        CHECK(hdr540.find("add-transcode-target(type=videoProfile") == std::string::npos);
        // NEG: 480p must not inherit a sticky 24 fps Extra after 540 apply.
        WeakLadder back480 = w540;
        CHECK(applyPlexTranscodeProfile("480p", back480));
        CHECK(back480.maxVideoFrameRate == 0);
        CHECK(plexClientProfileFrameRateExtra(back480).empty());
        CHECK(plexFfmpegHeaders("s", "t", back480)
                  .find("X-Plex-Client-Profile-Extra: ") == std::string::npos);
        const auto c540 = contentResolutionFor540pFabric720p();
        CHECK(c540.presentPolicy == ContentPresentPolicy::Source540pFabric720p);
        CHECK(std::string(c540.userLabel).find("720p source") == std::string::npos);
        CHECK(std::string(c540.userLabel).find("540p") != std::string::npos);
        CHECK(std::string(c540.userLabel).find("720p glass") != std::string::npos);
        CHECK(isGenuine540pDelivery(960, 540));
        CHECK(!isGenuine540pDelivery(960, 536)); // NEG shorter height
        CHECK(!isGenuine540pDelivery(854, 480));
        CHECK(!isGenuine540pDelivery(720, 404)); // NEG: maxBR starvation (measured)
        CHECK(!isGenuine540pDelivery(720, 540)); // NEG: 4:3 HD fit (rk83 class)
        CHECK(!isGenuine540pDelivery(960, 544)); // NEG: SPS MB height is NOT publish size
        CHECK(!isGenuine720pDelivery(960, 540)); // NEG: 540p is not true 720 source
        CHECK(kPlex540pYuv420pBytes == 777600);
        CHECK(kPlex540pYuv420pBytes < kPlex720pYuv420pBytes);
        // SPS MB 544 with crop 4 → display 540; bank uses display I420 only.
        CHECK(kPlex540pSpsMbHeight == 544);
        CHECK(kPlex540pSpsCropBottomLuma == 4);
        CHECK(kPlex540pSpsMbHeight - kPlex540pSpsCropBottomLuma == 540);
        CHECK(kPlex540pSpsMbYuv420pBytes == 783360);
        CHECK(kPlex540pYuv420pBytes != kPlex540pSpsMbYuv420pBytes);
        CHECK(kPmsTrue540pMinBitrateKbpsMeasured == 2000);
        CHECK(pmsBitrateLikelyTrue540p(2000));
        CHECK(pmsBitrateLikelyTrue540p(2500));
        CHECK(!pmsBitrateLikelyTrue540p(1500)); // NEG: measured → 720x404
        CHECK(w540.maxVideoBitrateKbps >= kPmsTrue540pMinBitrateKbpsMeasured);
        // Parent corrected budget (decode+sws+copy), not optimistic -f null.
        CHECK(kPlex540pTotalMsPerFrame < kPlex24fpsDeadlineMs);
        CHECK(kPlex540pMarginMs > 7.0 && kPlex540pMarginMs < 7.3);
        // Product URL must ask PMS for 960x540 — never ship a 720 request as the
        // 540p glass path (ARM downscale-from-720 is 1.74× worse, parent-measured FAIL).
        CHECK(url540.find("videoResolution=1280x720") == std::string::npos);
        CHECK(c540.width.get() == 960 && c540.height.get() == 540);
        std::printf("GREEN_PATH_540p_fabric720_glass url+honest_label+genuine_gate\n");
    }

    // Motion 720p glass: 640x360 exact 2×. No fps Extra; knee maxBR≥1000.
    {
        WeakLadder w360;
        CHECK(applyPlexTranscodeProfile("360p", w360));
        CHECK(w360.videoResolution == std::string("640x360"));
        CHECK(w360.maxVideoBitrateKbps == kPlex360pWeakBitrateKbps);
        CHECK(w360.h264Level == kPlex360pH264Level);
        CHECK(w360.maxVideoFrameRate == 0); // pass-through 29.97
        CHECK(validateWeakLadder(w360));
        {
            WeakLadder low360 = w360;
            low360.maxVideoBitrateKbps = 750;
            CHECK(!validateWeakLadder(low360)); // NEG: sub-360 trap
        }
        WeakLadder byRes360;
        CHECK(applyPlexTranscodeProfile("640x360", byRes360));
        CHECK(byRes360.videoResolution == std::string("640x360"));
        const auto url360 =
            buildUniversalTranscodeUrl("http://pms.example:32400", "/library/metadata/10", "tok",
                                       "sess360", 0, w360);
        CHECK(url360.find("videoResolution=640x360") != std::string::npos);
        CHECK(url360.find("maxVideoBitrate=1500") != std::string::npos);
        CHECK(url360.find("videoLevel=30") != std::string::npos);
        const auto hdr360 = plexFfmpegHeaders("sess360", "tok", w360);
        // MiSTerPlex + no fps cap → no Extra (encode flags stay in XML).
        CHECK(hdr360.find("X-Plex-Client-Profile-Extra: ") == std::string::npos);
        const auto c360 = contentResolutionFor360pFabric720p();
        CHECK(c360.presentPolicy == ContentPresentPolicy::Source360pFabric720p);
        CHECK(std::string(c360.userLabel).find("360p") != std::string::npos);
        CHECK(std::string(c360.userLabel).find("720p source") == std::string::npos);
        CHECK(isGenuine360pDelivery(640, 360));
        CHECK(!isGenuine360pDelivery(480, 270)); // NEG maxBR=750 class
        CHECK(!isGenuine360pDelivery(320, 180)); // NEG maxBR=400 class
        CHECK(!isGenuine360pDelivery(640, 368)); // NEG SPS MB height
        CHECK(!isGenuine360pDelivery(640, 480)); // NEG presented-ish
        CHECK(!isGenuine540pDelivery(640, 360));
        CHECK(kPlex360pYuv420pBytes == 345600);
        CHECK(kPlex360pSpsMbHeight == 368);
        CHECK(kPlex360pSpsCropBottomLuma == 8);
        CHECK(kPmsTrue360pMinBitrateKbpsMeasured == 1000);
        CHECK(pmsBitrateLikelyTrue360p(1000));
        CHECK(!pmsBitrateLikelyTrue360p(750));
        CHECK(w360.maxVideoBitrateKbps >= kPmsTrue360pMinBitrateKbpsMeasured);
        // Budget estimate constants (device-class, not soak).
        CHECK(kPlex360pTotalMsPerFrame < kPlex30fpsDeadlineMs);
        CHECK(kPlex360pMarginMsAt30 > 15.0 && kPlex360pMarginMsAt30 < 15.5);
        // fps-aware glass helper
        CHECK(contentResolutionFor720GlassBySourceFps(30).label ==
              std::string("640x360"));
        CHECK(contentResolutionFor720GlassBySourceFps(24).label ==
              std::string("960x540"));
        CHECK(contentResolutionFor720GlassBySourceFps(23).label ==
              std::string("960x540"));
        // DECODE=640x360 must not collapse to 480p canvas (w=640 >= 624 trap).
        const auto fromDecode = contentResolutionFromCodedSize(CodedWidth{640}, CodedHeight{360});
        CHECK(fromDecode.label == std::string("640x360"));
        CHECK(fromDecode.presentPolicy == ContentPresentPolicy::Source360pFabric720p);
        std::printf("GREEN_PATH_360p_fabric720_2x url+genuine_gate+fps_helper\n");
    }

    // Source-aware PMS request — fabric store alignment (w-mem rt_raw_ok).
    // Parent: fixed 640x360 on 624x480 → 468x360 (468%16=4) STORE REJECT.
    {
        // Majority library class: identity request stays 16-aligned.
        const auto s624 = selectSourceAwarePmsRequest(624, 480, 960, 540);
        CHECK(s624.request_w == 624 && s624.request_h == 480);
        CHECK(s624.videoResolution == std::string("624x480"));
        CHECK(isFabricStoreAligned(s624.store_w, s624.store_h));
        CHECK(i420FitsLegacyBank(s624.store_w, s624.store_h));

        // HD clamped into product 960x540 box.
        const auto sHd = selectSourceAwarePmsRequest(1920, 1080, 960, 540);
        CHECK(sHd.request_w == 960 && sHd.request_h == 540);
        CHECK(isFabricStoreAligned(sHd.store_w, sHd.store_h));
        CHECK(!i420FitsLegacyBank(sHd.store_w, sHd.store_h)); // needs Option-C

        // 320x240 native — already aligned.
        const auto s320 = selectSourceAwarePmsRequest(320, 240, 960, 540);
        CHECK(s320.request_w == 320 && s320.request_h == 240);
        CHECK(isFabricStoreAligned(s320.store_w, s320.store_h));

        // 426x240: W%16=10 → request floor 416; PMS AR-fits H → 416x234 (measured).
        // Store must match delivery, not claim 416x240 (rd-duck native mismatch).
        // NEG: align-up 432 does NOT work (PMS keeps 426) — never select 432.
        const auto s426 = selectSourceAwarePmsRequest(426, 240, 960, 540);
        CHECK(s426.request_w == 416);
        CHECK(s426.request_h == 234);
        CHECK(s426.store_w == 416);
        CHECK(s426.store_h == 234);
        CHECK(isFabricStoreAligned(s426.store_w, s426.store_h));
        CHECK(s426.store_w != 432);
        CHECK(s426.store_h != 240); // red: old store_h=request_h before AR-fit predict

        // 720x480: identity; bank spare check (parent 1792 B).
        const auto s720 = selectSourceAwarePmsRequest(720, 480, 960, 540);
        CHECK(s720.request_w == 720 && s720.request_h == 480);
        CHECK(isFabricStoreAligned(s720.store_w, s720.store_h));
        CHECK(i420PayloadBytes(720, 480) == 518400u);
        CHECK(kLegBankUsableBytes - i420PayloadBytes(720, 480) == 1792u);
        CHECK(i420FitsLegacyBank(720, 480));

        // NEG: AR-fit class that must NOT be selected as a request target.
        // 468x360 is what PMS delivers for 624x480@640x360 — store rejects.
        CHECK(!isFabricStoreAligned(468, 360));
        CHECK(!isFabricStoreAligned(426, 240));
        CHECK(!isFabricStoreAligned(638, 358));
        CHECK(isFabricStoreAligned(640, 360));
        CHECK(isFabricStoreAligned(624, 350)); // even H, 16-W — anamorphic 480 class OK

        // No upscale of request beyond source when max > source.
        const auto sNoUp = selectSourceAwarePmsRequest(320, 240, 960, 540);
        CHECK(sNoUp.request_w <= 320 && sNoUp.request_h <= 240);

        // Max-box fallback when media unknown.
        const auto sFb = selectSourceAwarePmsRequest(0, 0, 960, 540);
        CHECK(sFb.request_w == 960 && sFb.request_h == 540);
        CHECK(std::string(sFb.policy).find("max_box") != std::string::npos);

        std::printf("GREEN_PATH_source_aware_snap16_store_align\n");
    }

    // Direct Part native bank (rd-duck): DP returns before PMS source-aware;
    // pad-only align-up so raw bank matches Part samples (not tier canvas).
    {
        const auto d320 = selectDirectPartStoreGeometry(320, 240);
        CHECK(d320.request_w == 320 && d320.request_h == 240);
        CHECK(d320.store_w == 320 && d320.store_h == 240);
        CHECK(isFabricStoreAligned(d320.store_w, d320.store_h));
        {
            const auto g = ddrStorageGeometryForContent(d320.store_w, d320.store_h);
            CHECK(g.coded_width.get() == 320 && g.coded_height.get() == 240);
        }

        // 426 Part samples stay 426; bank pads UP to 432 — never floor 416 (PMS path).
        const auto d426 = selectDirectPartStoreGeometry(426, 240);
        CHECK(d426.request_w == 426 && d426.request_h == 240);
        CHECK(d426.store_w == 432 && d426.store_h == 240);
        CHECK(d426.store_w != 416);
        CHECK(d426.request_w != 416); // red: must not reuse universal floor-snap
        CHECK(isFabricStoreAligned(d426.store_w, d426.store_h));
        {
            // rd-duck: store-only identity loses display 426 / crop_left=2.
            // Content geom: coded=432 canvas H_DE=432, display=426, present_x=cropL=2.
            const auto gStoreOnly =
                ddrStorageGeometryForContent(d426.store_w, d426.store_h);
            CHECK(gStoreOnly.coded_width.get() == 432 &&
                  gStoreOnly.coded_height.get() == 240);
            // NEG: identity-on-432 must NOT be the product path for DP content.
            CHECK(gStoreOnly.display_width.get() == 432); // bare store is identity
            CHECK(gStoreOnly.crop_left == 0);

            const auto gMedia = ddrStorageGeometryForContent(426, 240);
            CHECK(gMedia.coded_width.get() == 432 && gMedia.coded_height.get() == 240);
            CHECK(gMedia.display_width.get() == 426 && gMedia.display_height.get() == 240);
            CHECK(gMedia.presented_width.get() == 432 &&
                  gMedia.presented_height.get() == 240);
            CHECK(gMedia.crop_left == 2);
            CHECK(gMedia.crop_right == 4);
            CHECK(gMedia.present_x == 2 && gMedia.present_y == 0);
            CHECK(gMedia.crop_top == 0 && gMedia.crop_bottom == 0);

            // Explicit store pair (main/resolver precomputed bank).
            const auto gPair =
                ddrStorageGeometryForContent(426, 240, d426.store_w, d426.store_h);
            CHECK(gPair.coded_width.get() == 432);
            CHECK(gPair.display_width.get() == 426);
            CHECK(gPair.present_x == 2);
            CHECK(gPair.crop_left == 2 && gPair.crop_right == 4);

            // Present helper (daemon outW=content) must match.
            const auto gPresent = ddrFrameGeometryForFpgaPresent(426, 240);
            CHECK(gPresent.coded_width.get() == 432);
            CHECK(gPresent.display_width.get() == 426);
            CHECK(gPresent.present_x == 2);
            CHECK(gPresent.crop_left == 2);

            // PLXG: q1 content@x2, q2 H_DE=432 canvas, q3 display=426, q4 cropL=2.
            const auto layout = makeDdrFrameLayout(gMedia);
            CHECK(ddrFrameLayoutValid(layout));
            const auto rec = makePlxgRecordFromGeometry(gMedia, layout, /*seq*/ 1);
            CHECK(rec.valid);
            int q1w = 0, q1h = 0, q1x = 0;
            int q2deW = 0, q2deH = 0, q2cw = 0, q2ch = 0;
            int q3dw = 0, q4px = 0, q4py = 0, q4cl = 0, q4ct = 0;
            unpackPlxgQ1(rec.q[1], &q1w, &q1h, &q1x, nullptr);
            unpackPlxgQ2(rec.q[2], &q2deW, &q2deH, &q2cw, &q2ch);
            unpackPlxgQ3(rec.q[3], nullptr, nullptr, &q3dw, nullptr);
            unpackPlxgQ4(rec.q[4], &q4px, &q4py, &q4cl, &q4ct);
            CHECK(q1w == 426 && q1h == 240 && q1x == 2);
            CHECK(q2deW == 432 && q2deH == 240);
            CHECK(q2cw == 432 && q2ch == 240);
            CHECK(q3dw == 426);
            CHECK(q4px == 2 && q4cl == 2 && q4ct == 0);
            // NEG: all-432 PLXG would squeeze content 426/432 under DAR.
            CHECK(!(q1w == 432 && q2cw == 432 && q4cl == 0));
            CHECK(plxgMuxIsPad426In432(plxgMuxLatchVisual(rec)));
            // NEG: 624/618 product fixture is NOT the 426 oracle.
            CHECK(!plxgMuxIsPad426In432(plxgMuxLatchVisual(makePlxgRecordLegacy480(1))));
        }

        const auto d720 = selectDirectPartStoreGeometry(720, 480);
        CHECK(d720.request_w == 720 && d720.request_h == 480);
        CHECK(d720.store_w == 720 && d720.store_h == 480);
        CHECK(isFabricStoreAligned(d720.store_w, d720.store_h));
        {
            const auto g = ddrStorageGeometryForContent(d720.store_w, d720.store_h);
            CHECK(g.coded_width.get() == 720 && g.coded_height.get() == 480);
        }

        // NEG: empty media → no store (main must not treat as applied).
        const auto d0 = selectDirectPartStoreGeometry(0, 0);
        CHECK(d0.store_w == 0 && d0.store_h == 0);

        std::printf("GREEN_PATH_direct_part_native_pad_bank\n");
    }

    // rd-duck: universal is ARM-scale fallback — never fabric_native at plan time.
    // source_snap only picks the bank; force-scale + unverified claim keep ARM scale.
    {
        CHECK(classifyPathScaleClass("transcode_request", false, true, false) ==
              PathScaleClass::ArmScaleFallback);
        CHECK(classifyPathScaleClass("transcode_request", false, false, false) ==
              PathScaleClass::ArmScaleFallback);
        // RED: even if someone wrongly sets verified on a request claim, basis wins.
        CHECK(classifyPathScaleClass("transcode_request", true, false, true) ==
              PathScaleClass::ArmScaleFallback);
        CHECK(std::string(pathScaleClassName(PathScaleClass::ArmScaleFallback)) ==
              "arm_scale_fallback");
        CHECK(!pathMayBeFabricNative("transcode_request", false));
        CHECK(!pathMayBeFabricNative("transcode_request", true));
        CHECK(pmsMayTweakAlignedRequestDelivery()); // 624x352→626x352 class

        // DP verified + no scale → fabric_native.
        CHECK(classifyPathScaleClass("direct_play_part", true, false, true) ==
              PathScaleClass::FabricNative);
        CHECK(pathMayBeFabricNative("direct_play_part", true));
        // DP with pad/scale still ARM fallback until pad-only is modeled separately.
        CHECK(classifyPathScaleClass("direct_play_part", true, true, false) ==
              PathScaleClass::ArmScaleFallback);

        // Source-aware bank selection must not imply fabric_native for universal.
        const auto sa = selectSourceAwarePmsRequest(624, 352, 960, 540);
        CHECK(isFabricStoreAligned(sa.store_w, sa.store_h));
        CHECK(classifyPathScaleClass("transcode_request", false, true, false) ==
              PathScaleClass::ArmScaleFallback);

        std::printf("GREEN_PATH_universal_arm_scale_fallback_not_fabric_native\n");
    }

    if (fails) {
        std::fprintf(stderr, "test_resolve: %d failures\n", fails);
        return 1;
    }
    std::printf("test_resolve: OK\n");
    return 0;
}
