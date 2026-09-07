// Unit tests for slim plex_resolve (no network required for pure helpers).
#include "plex_resolve.hpp"
#include "libmisterplex/p720_transcode_vf.hpp"

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <string>
#include <sys/stat.h>
#include <unistd.h>
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

    const bool hadBackend = std::getenv("MPX_VIDEO_BACKEND") != nullptr;
    const std::string savedBackend = hadBackend ? std::getenv("MPX_VIDEO_BACKEND") : "";
    const bool hadPath = std::getenv("PATH") != nullptr;
    const std::string savedPath = hadPath ? std::getenv("PATH") : "";
    const auto probeDir = std::filesystem::absolute(
        "build/session/resolve-probe-" + std::to_string(::getpid()));
    std::filesystem::create_directories(probeDir);
    const auto probe = probeDir / "ffmpeg";
    const auto marker = probeDir / "ffmpeg.invoked";
    {
        std::ofstream script(probe);
        script << "#!/bin/sh\nprintf invoked > \"$0.invoked\"\n"
                  "printf '%s\\n' 'Stream #0:0: Video: h264, yuv420p, "
                  "320x240 [SAR 1:1 DAR 4:3], 24 fps'\n";
    }
    CHECK(::chmod(probe.c_str(), 0700) == 0);
    ::setenv("PATH", (probeDir.string() + ":" + savedPath).c_str(), 1);
    if (::access("/media/fat/misterplex/bin/ffmpeg", X_OK) != 0) {
        ::setenv("MPX_VIDEO_BACKEND", "legacy-software", 1);
        CHECK(resolvePlayTarget("/missing-probe-control.mp4", "", "", 0, true).ok);
        CHECK(std::filesystem::exists(marker));
        std::filesystem::remove(marker);
    }
    ::setenv("MPX_VIDEO_BACKEND", "fpga-h264", 1);
    const auto localFpga = resolvePlayTarget("/missing-fpga-local.mp4", "", "", 0, true);
    CHECK(localFpga.ok && localFpga.playable == "/missing-fpga-local.mp4");
    CHECK(!std::filesystem::exists(marker));
    CHECK(localFpga.fpsNum == 0 && localFpga.fpsDen == 0);
    CHECK(localFpga.mediaWidth == 0 && localFpga.mediaHeight == 0);
    CHECK(!localFpga.sourceAspect.valid);
    CHECK(localFpga.detail.find("sole compressed demux") != std::string::npos);
    if (hadBackend) ::setenv("MPX_VIDEO_BACKEND", savedBackend.c_str(), 1);
    else ::unsetenv("MPX_VIDEO_BACKEND");
    if (hadPath) ::setenv("PATH", savedPath.c_str(), 1);
    else ::unsetenv("PATH");
    std::filesystem::remove_all(probeDir);

    // rk 40868 must not short-circuit to the identity cache file.
    auto fp = resolvePlayTarget("/media/fat/misterplex/cache/farpoint_1280x720.mp4",
                                "http://127.0.0.1:32400", "tok", 0, true);
    CHECK(!fp.ok);
    CHECK(fp.playable.empty());
    CHECK(fp.transcoded == false);
    CHECK(std::string(fp.detail).find("farpoint_1280x720.mp4") != std::string::npos);
    CHECK(misterplex::libraryKeyMustNotSpawnLocalFile(
        "/library/metadata/40868", "/media/fat/misterplex/cache/farpoint_1280x720.mp4"));
    CHECK(!misterplex::libraryKeyMustNotSpawnLocalFile(
        "/library/metadata/40868",
        "http://127.0.0.1:9324/video/:/transcode/universal/start.mp4?videoResolution=1280x720"));

    auto t = resolvePlayTarget("testsrc", "", "", 0, true);
    CHECK(t.ok && t.playable == "testsrc");
    CHECK(t.sourceFpsHint == 30 && t.fpsNum == 30 && t.fpsDen == 1);

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
    WeakLadder fpgaProfile;
    CHECK(applyFpgaPlexProfile(fpgaProfile, "ip", 24, 1, false));
    CHECK(fpgaProfile.clientProfileName == "MiSTerPlex-FPGA-IP-240p-24-filter-on");
    CHECK(fpgaProfile.videoResolution == "320x240");
    CHECK(fpgaProfile.h264Profile == "baseline");
    CHECK(validateWeakLadder(fpgaProfile));
    CHECK(fitWeakLadderToAspect(fpgaProfile, {16, 9, true}).videoResolution == "320x240");
    CHECK(fitWeakLadderToAspect(fpgaProfile, {9, 16, true}).videoResolution == "320x240");
    CHECK(fitWeakLadderToAspect(w240, {16, 9, true}).videoResolution == "320x180");
    const auto metadataDar = sourceAspectFromPlexMetadata(
        R"(<Video><Media aspectRatio="1.66"><Part><Stream streamType="1" sar="1:1"/></Part></Media></Video>)",
        320, 212);
    CHECK(metadataDar.valid);
    CHECK(metadataDar.x * 100 > metadataDar.y * 165);
    CHECK(metadataDar.x * 100 < metadataDar.y * 167);
    CHECK(fitWeakLadderToAspect(fpgaProfile, metadataDar).videoResolution == "320x240");
    CHECK(applyFpgaPlexProfile(fpgaProfile, "idr", 24000, 1001, true));
    CHECK(fpgaProfile.clientProfileName == "MiSTerPlex-FPGA-IDR-240p-23976-filter-off");
    CHECK(!plexSendClientLadderCaps(fpgaProfile));
    const auto fpgaStart = buildUniversalTranscodeUrl(
        "http://pms.example:32400", "/library/metadata/3", "header-only-token",
        "fpga-session", 0, fpgaProfile);
    const auto fpgaDecision = buildUniversalDecisionUrl(
        fpgaStart, "fpga-session", "header-only-token", fpgaProfile);
    for (const auto& url : {fpgaStart, fpgaDecision}) {
        CHECK(!url.empty());
        CHECK(url.find("directPlay=0&directStream=0") != std::string::npos);
        CHECK(url.find("container=mpegts") != std::string::npos);
        CHECK(url.find("audioChannels=2") != std::string::npos);
        CHECK(url.find("videoResolution=320x240") != std::string::npos);
        CHECK(url.find("videoFrameRate=24000%2F1001") != std::string::npos);
        CHECK(url.find("X-Plex-Token") == std::string::npos);
        CHECK(url.find("header-only-token") == std::string::npos);
    }
    const auto fpgaHeaders = plexFfmpegHeaders("fpga-session", "header-only-token", fpgaProfile);
    CHECK(fpgaHeaders.find("X-Plex-Token: header-only-token\r\n") != std::string::npos);
    CHECK(fpgaHeaders.find("X-Plex-Client-Profile-Name: " + fpgaProfile.clientProfileName) !=
          std::string::npos);
    CHECK(fpgaHeaders.find("X-Plex-Client-Profile-Extra") == std::string::npos);
    CHECK(fpgaHeaders.find("X-Plex-Client-Capabilities") == std::string::npos);
    {
        const auto curlDir = std::filesystem::absolute(
            "build/session/resolve-profile-" + std::to_string(::getpid()));
        std::filesystem::create_directories(curlDir);
        const auto fakeCurl = curlDir / "curl";
        {
            std::ofstream script(fakeCurl);
            script << "#!/bin/sh\nprintf '%s\\n' \"$@\" > \"$0.args\"\n"
                      "printf '%s\\n' '<MediaContainer transcodeDecisionCode=\"1001\"/>'\n";
        }
        CHECK(::chmod(fakeCurl.c_str(), 0700) == 0);
        ::setenv("PATH", (curlDir.string() + ":" + savedPath).c_str(), 1);
        WeakLadder generic;
        generic.clientProfileName = "Generic";
        for (const auto& selected : {fpgaProfile, WeakLadder{}, generic}) {
            const auto start = buildUniversalTranscodeUrl(
                "http://pms.example:32400", "/library/metadata/3", "fixture-token",
                "profile-test", 0, selected);
            CHECK(ensureUniversalDecision(start, "profile-test", "fixture-token", selected));
            std::ifstream arguments(fakeCurl.string() + ".args");
            std::string argument;
            unsigned profilesSent = 0;
            while (std::getline(arguments, argument)) {
                if (argument.rfind("X-Plex-Client-Profile-Name:", 0) != 0)
                    continue;
                ++profilesSent;
                CHECK(argument == "X-Plex-Client-Profile-Name: " + selected.clientProfileName);
            }
            CHECK(profilesSent == 1);
        }
        if (hadPath) ::setenv("PATH", savedPath.c_str(), 1);
        else ::unsetenv("PATH");
        std::filesystem::remove_all(curlDir);
    }
    CHECK(!applyFpgaPlexProfile(fpgaProfile, "ip", 30, 1, false));
    CHECK(!applyFpgaPlexProfile(fpgaProfile, "auto", 24, 1, false));

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
    // Resolution alias selects the 480p profile too.
    WeakLadder byRes;
    CHECK(applyPlexTranscodeProfile("640x480", byRes));
    CHECK(byRes.profileName == "480p");

    WeakLadder w720;
    CHECK(applyPlexTranscodeProfile("720p", w720));
    CHECK(w720.profileName == "720p");
    CHECK(w720.videoResolution == "1280x720");
    CHECK(w720.maxVideoBitrateKbps == 8000);
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
    CHECK(start480.find("autoAdjustQuality=0") != std::string::npos);
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
    CHECK(!plexSendClientLadderCaps(w480));
    WeakLadder w720caps;
    CHECK(applyPlexTranscodeProfile("720p", w720caps));
    CHECK(plexSendClientLadderCaps(w720caps));
    const auto headers720 = plexFfmpegHeaders("sess720", "tok", w720caps);
    CHECK(headers720.find("X-Plex-Client-Capabilities: ") != std::string::npos);
    CHECK(headers720.find("resolution:1280x720") != std::string::npos);
    CHECK(headers720.find("X-Plex-Client-Profile-Extra: ") != std::string::npos);
    CHECK(headers720.find("name=video.width&value=1280") != std::string::npos);

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
        CHECK(parseExactFps("", "24000/1001", n, d) && n == 24000 && d == 1001);
        CHECK(parseExactFps("", "48/2", n, d) && n == 24 && d == 1);
        CHECK(!parseExactFps("", "24garbage", n, d));
        CHECK(!parseExactFps("", "24000/1001junk", n, d));
        CHECK(!parseExactFps("", "24/0", n, d));
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
        // Preserve the shipping metadata-only NTSC-film fallback; numeric Stream
        // frameRate still selects genuine 24/1 independently.
        CHECK(parseExactFps("24p", "", n, d) && n == 24000 && d == 1001);
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
