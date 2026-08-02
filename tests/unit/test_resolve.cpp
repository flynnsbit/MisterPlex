// Unit tests for slim plex_resolve (no network required for pure helpers).
#include "libmisterplex/osd_menu.hpp"
#include "plex_resolve.hpp"

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

    // 480p bitrate floor was a quality heuristic hard-fail — retired.
    // Explicit WEAK_BITRATE=1000 on 480p must validate so slow links can request
    // under 2000 kbps (parent: greedy path ~1.15 Mbit/s; 2000k starves).
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
        CHECK(!weakLadderBitrateBelowRecommended(w480));
        lowBr.maxVideoBitrateKbps = 0;
        CHECK(!validateWeakLadder(lowBr));
        WeakLadder low240 = w240;
        low240.maxVideoBitrateKbps = 500;
        CHECK(validateWeakLadder(low240));
        CHECK(weakLadderBitrateBelowRecommended(low240));

        // LINK_CAP_KBIT consumer: clamps tier default; WEAK_BITRATE wins absolute.
        auto s0 = selectMaxVideoBitrateKbps(2000, false, 2000, 0);
        CHECK(s0.kbps == 2000);
        CHECK(!s0.clampedByLinkCap);
        auto s1 = selectMaxVideoBitrateKbps(2000, false, 2000, 1150);
        CHECK(s1.kbps == 1150);
        CHECK(s1.clampedByLinkCap);
        CHECK(std::string(s1.source).find("LINK_CAP") != std::string::npos);
        auto s2 = selectMaxVideoBitrateKbps(2000, true, 900, 1150);
        CHECK(s2.kbps == 900);
        CHECK(std::string(s2.source) == "WEAK_BITRATE");
        auto s3 = selectMaxVideoBitrateKbps(2000, true, 1500, 1150);
        CHECK(s3.kbps == 1500); // operator above cap — warn path, not clamp
        CHECK(s3.clampedByLinkCap);

        // RED-before-GREEN gate (parent HW 2026-08-02):
        // maxVideoBitrate=397 on 624x480 target → PMS delivered 312x240 (HALF).
        // maxVideoBitrate=2000 → 624x480. Source bitrate is NOT a safe cap.
        // Auto select for 624x480 decode target must never request below the
        // resolution-preserving floor (provisional = ref knee @ 624x480).
        {
            const int tw = kPlex480pCodedWidth.get();
            const int th = kPlex480pCodedHeight.get();
            CHECK(tw == 624);
            CHECK(th == 480);
            const int floor = resolutionPreservingMinBitrateKbps(tw, th);
            CHECK(floor > 397); // must exceed the falsified source-cap value
            // Simulate e6a3fb2f defect path: tier 2000 + known source 397.
            auto bad = selectMaxVideoBitrateKbps(2000, false, 2000, 0, 397, tw, th);
            CHECK(bad.kbps >= floor);
            CHECK(bad.kbps != 397); // must NOT anti-inflate to source
            // Even LINK_CAP below floor must not win over resolution preserve.
            auto vsLink = selectMaxVideoBitrateKbps(2000, false, 2000, 1150, 397, tw, th);
            CHECK(vsLink.kbps >= floor);
            // Operator WEAK_BITRATE may still force below floor (knee sweep / lab).
            auto op = selectMaxVideoBitrateKbps(2000, true, 397, 0, 397, tw, th);
            CHECK(op.kbps == 397);
            CHECK(std::string(op.source) == "WEAK_BITRATE");
            std::printf("PASS resolution-preserving bitrate floor @ %dx%d floor=%d\n", tw, th,
                        floor);
        }

        // Metadata parse retained for logging only (not a request cap).
        const char* meta =
            "<MediaContainer><Video><Media bitrate=\"450\" width=\"624\" height=\"480\" "
            "videoCodec=\"h264\">"
            "<Part><Stream streamType=\"1\" codec=\"h264\" bitrate=\"397\" width=\"624\" "
            "height=\"480\"/>"
            "<Stream streamType=\"2\" codec=\"aac\" bitrate=\"49\"/>"
            "</Part></Media></Video></MediaContainer>";
        CHECK(parseSourceVideoBitrateKbps(meta) == 397);
        CHECK(parseSourceVideoBitrateKbps("") == 0);
        CHECK(parseSourceVideoBitrateKbps("<Media bitrate=\"450\"/>") == 450);
        std::printf("PASS bitrate select: LINK_CAP + resolution-preserving floor\n");
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
