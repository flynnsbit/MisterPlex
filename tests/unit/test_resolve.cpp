// Unit tests for slim plex_resolve (no network required for pure helpers).
#include "libmisterplex/osd_menu.hpp"
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

    // --- PMS universal transcode profile table / 480p guard ---
    const auto& profiles = plexTranscodeProfiles();
    CHECK(profiles.size() == 2);
    const auto osd240 = contentResolutionFromOsdWord(0);
    const auto osd480 = contentResolutionFromOsdWord(1u << 4);
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
        // 720p coded must not inherit the 480p 2000 floor (2.88× pixels).
        WeakLadder w720 = w480;
        w720.videoResolution = "1280x720";
        w720.maxVideoBitrateKbps = kPlex720pWeakBitrateKbps;
        CHECK(recommendedMinVideoBitrateKbps(w720) == kPlex720pWeakBitrateKbps);
        CHECK(recommendedMinVideoBitrateKbps(w720) != kPlex480pWeakBitrateKbps);
        w720.maxVideoBitrateKbps = kPlex480pWeakBitrateKbps;
        CHECK(weakLadderBitrateBelowRecommended(w720));
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

    if (fails) {
        std::fprintf(stderr, "test_resolve: %d failures\n", fails);
        return 1;
    }
    std::printf("test_resolve: OK\n");
    return 0;
}
