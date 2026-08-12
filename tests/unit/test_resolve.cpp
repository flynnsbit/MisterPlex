// Unit tests for slim plex_resolve (no network required for pure helpers).
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

    const auto wide = sourceAspectFromMetadata("1.777778", "", 0, 0, false);
    CHECK(wide.valid && wide.x == 16 && wide.y == 9);
    const auto fourThree = sourceAspectFromMetadata("", "", 1440, 1080, true);
    CHECK(fourThree.valid && fourThree.x == 4 && fourThree.y == 3);
    const auto custom = sourceAspectFromMetadata("1.6", "", 0, 0, false);
    CHECK(custom.valid && custom.x == 8 && custom.y == 5);
    const auto anamorphicWide =
        sourceAspectFromMetadata("", "32:27", 720, 480, false);
    CHECK(anamorphicWide.valid && anamorphicWide.x == 16 && anamorphicWide.y == 9);
    const auto unknownAnamorphic =
        sourceAspectFromMetadata("", "", 720, 480, false);
    CHECK(!unknownAnamorphic.valid);
    const auto implausible = sourceAspectFromMetadata("20.0", "", 0, 0, false);
    CHECK(!implausible.valid);
    CHECK(sourceAspectFromText("47:20").valid);
    CHECK(sourceAspectFromText("16/9").x == 16);
    CHECK(sourceAspectFromFfmpegProbeText(
              "Stream #0:0: Video: h264, yuv420p, 720x480 [SAR 32:27 DAR 16:9]")
              .x == 16);
    const auto aspectPacket = encodeSourceAspectPacket(wide, 0x5a);
    CHECK(aspectPacket[0] == 'P' && aspectPacket[1] == 'L' &&
          aspectPacket[2] == 'X' && aspectPacket[3] == 'A');
    CHECK(aspectPacket[4] == 16 && aspectPacket[5] == 0 &&
          aspectPacket[6] == 9 && aspectPacket[7] == 0);
    CHECK(aspectPacket[8] == 0x5a);
    SourceAspectAck decodedAck;
    const uint64_t ackWord =
        (static_cast<uint64_t>(0x5a) << 56) |
        (static_cast<uint64_t>(9) << 44) |
        (static_cast<uint64_t>(16) << 32) |
        mailbox_abi::kPlxjMagic;
    CHECK(decodeSourceAspectAckWord(ackWord, decodedAck));
    CHECK(decodedAck.aspect.valid && decodedAck.aspect.x == 16 &&
          decodedAck.aspect.y == 9 && decodedAck.token == 0x5a);
    SourceAspectAck tornAck;
    CHECK(!decodeStableSourceAspectAck(
        static_cast<uint32_t>(ackWord), static_cast<uint32_t>(ackWord >> 32),
        static_cast<uint32_t>(ackWord), static_cast<uint32_t>(ackWord >> 32) ^ 1u,
        tornAck));

    const auto xmlWide = sourceAspectFromPlexMetadata(
        "<MediaContainer><Video aspectRatio=\"1.78\"><Media width=\"720\" "
        "height=\"480\"><Part><Stream streamType=\"1\" anamorphic=\"true\" "
        "pixelAspectRatio=\"8:9\"/></Part></Media></Video></MediaContainer>",
        720, 480);
    CHECK(xmlWide.valid && xmlWide.x == 16 && xmlWide.y == 9);
    const auto xmlMediaWide = sourceAspectFromPlexMetadata(
        "<MediaContainer><Video ratingKey=\"143\"><Media width=\"1280\" "
        "height=\"720\" aspectRatio=\"1.78\" videoCodec=\"h264\"/></Video>"
        "</MediaContainer>",
        1280, 720);
    CHECK(xmlMediaWide.valid && xmlMediaWide.x == 16 && xmlMediaWide.y == 9);
    const auto xmlSar = sourceAspectFromPlexMetadata(
        "<MediaContainer><Video><Media width=\"720\" height=\"480\">"
        "<Part><Stream streamType=\"1\" anamorphic=\"true\" "
        "sampleAspectRatio=\"32:27\"/></Part></Media></Video></MediaContainer>",
        720, 480);
    CHECK(xmlSar.valid && xmlSar.x == 16 && xmlSar.y == 9);
    const auto xmlSquare = sourceAspectFromPlexMetadata(
        "<MediaContainer><Video><Media width=\"1440\" height=\"1080\">"
        "<Part><Stream streamType=\"1\" anamorphic=\"false\"/></Part>"
        "</Media></Video></MediaContainer>",
        1440, 1080);
    CHECK(xmlSquare.valid && xmlSquare.x == 4 && xmlSquare.y == 3);
    const auto xmlUnknown = sourceAspectFromPlexMetadata(
        "<MediaContainer><Video><Media width=\"720\" height=\"480\">"
        "<Part><Stream streamType=\"1\"/></Part></Media></Video></MediaContainer>",
        720, 480);
    CHECK(!xmlUnknown.valid);

    auto h = plexFfmpegHeaders("sess1", "tok");
    CHECK(h.find("X-Plex-Session-Identifier: sess1") != std::string::npos);
    CHECK(h.find("X-Plex-Token: tok") != std::string::npos);

    // --- PMS universal transcode profile table (240p/480p/720p) ---
    const auto& profiles = plexTranscodeProfiles();
    CHECK(profiles.size() == 3);
    WeakLadder w240;
    CHECK(applyPlexTranscodeProfile("240p", w240));
    CHECK(w240.profileName == "240p");
    CHECK(w240.videoResolution == "320x240");
    CHECK(w240.maxVideoBitrateKbps == 1000);
    CHECK(w240.h264Profile == "baseline");
    CHECK(w240.h264Level == 30);
    CHECK(validateWeakLadder(w240));

    WeakLadder w480;
    CHECK(applyPlexTranscodeProfile("480p", w480));
    CHECK(w480.profileName == "480p");
    CHECK(w480.videoResolution == "640x480");
    CHECK(w480.maxVideoBitrateKbps == 2500);
    CHECK(w480.videoQuality == 60);
    CHECK(w480.videoCodec == "h264");
    CHECK(w480.audioCodec == "aac");
    CHECK(w480.h264Profile == "baseline");
    CHECK(w480.h264Level == 30);
    CHECK(w480.clientProfileName == "MiSTerPlex");
    CHECK(validateWeakLadder(w480));
    CHECK(fitWeakLadderToAspect(w480, {16, 9, true}).videoResolution == "640x360");
    CHECK(fitWeakLadderToAspect(w480, {4, 3, true}).videoResolution == "572x428");
    CHECK(fitWeakLadderToAspect(w480, {1, 1, true}).videoResolution == "480x480");
    CHECK(fitWeakLadderToAspect(w480, {}).videoResolution == "640x480");
    // Resolution alias selects the 480p profile too.
    WeakLadder byRes;
    CHECK(applyPlexTranscodeProfile("640x480", byRes));
    CHECK(byRes.profileName == "480p");

    WeakLadder w720;
    CHECK(applyPlexTranscodeProfile("720p", w720));
    CHECK(w720.profileName == "720p");
    CHECK(w720.videoResolution == "1280x720");
    CHECK(w720.maxVideoBitrateKbps == 20000);
    CHECK(w720.h264Profile == "main");
    CHECK(w720.h264Level == 31);
    CHECK(validateWeakLadder(w720));
    WeakLadder by720;
    CHECK(applyPlexTranscodeProfile("1280x720", by720));
    CHECK(by720.profileName == "720p");

    const auto start480 =
        buildUniversalTranscodeUrl("http://pms.example:32400", "/library/metadata/3", "tok",
                                   "sess480", 1500, w480);
    CHECK(start480.find("/video/:/transcode/universal/start.mp4") != std::string::npos);
    CHECK(start480.find("videoResolution=640x480") != std::string::npos);
    CHECK(start480.find("maxVideoBitrate=2500") != std::string::npos);
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
    CHECK(extra480.find("name=video.width&value=640") != std::string::npos);
    CHECK(extra480.find("name=video.height&value=480") != std::string::npos);
    const auto caps480 = plexClientCapabilities(w480);
    CHECK(caps480.find("videoDecoders=h264{profile:baseline&resolution:640x480&level:30}") !=
          std::string::npos);
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
    bad480.maxVideoBitrateKbps = 1000;
    CHECK(!validateWeakLadder(bad480));
    bad480 = w480;
    bad480.h264Level = 31;
    CHECK(!validateWeakLadder(bad480));

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
