// Unit tests: named stream target profiles (DECODE ↔ PMS ↔ present transport).
#include "libmisterplex/stream_target_profile.hpp"
#include "plex_resolve.hpp"

#include <cmath>
#include <cstdio>
#include <cstring>
#include <string>

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

    // --- Positive: 240p-spi fits SPI and applies PMS params ---
    {
        auto r = lookupStreamTargetProfile("240p-spi");
        CHECK(r.ok);
        CHECK(r.error == StreamTargetProfileError::Ok);
        CHECK(std::strcmp(r.profile.id, "240p-spi") == 0);
        CHECK(r.profile.decode_w == 320 && r.profile.decode_h == 240);
        CHECK(std::strcmp(r.profile.pms_video_resolution, "320x240") == 0);
        CHECK(r.profile.max_video_bitrate_kbps == kPlex240pWeakBitrateKbps);
        CHECK(r.profile.video_quality == 40);
        CHECK(r.profile.direct_play == 0 && r.profile.direct_stream == 0);
        CHECK(std::strcmp(r.profile.protocol, "http") == 0);
        CHECK(r.profile.required_transport == PresentTransport::SpiF1);
        CHECK(r.fits_budget);
        CHECK(r.payload_mib_s < kPresentSpiF1BudgetMiBs);

        auto sel = selectStreamTargetProfile(320, 240, PresentTransport::SpiF1);
        CHECK(sel.ok);
        CHECK(std::strcmp(sel.profile.id, "240p-spi") == 0);

        WeakLadder w;
        CHECK(applyStreamTargetProfileToWeak(r.profile, w));
        CHECK(w.videoResolution == "320x240");
        CHECK(w.maxVideoBitrateKbps == kPlex240pWeakBitrateKbps);
        CHECK(w.videoQuality == 40);
        CHECK(w.profileName == "240p-spi");
        // URL shape uses the same fields the profile table owns.
        const std::string url =
            buildUniversalTranscodeUrl("http://pms.example:32400", "/library/metadata/99",
                                       /*token*/ "", "sess-test", 0, w);
        CHECK(url.find("videoResolution=320x240") != std::string::npos);
        CHECK(url.find("maxVideoBitrate=" + std::to_string(kPlex240pWeakBitrateKbps)) !=
              std::string::npos);
        CHECK(url.find("videoQuality=40") != std::string::npos);
        CHECK(url.find("protocol=http") != std::string::npos);
        CHECK(url.find("directPlay=0") != std::string::npos);
        CHECK(url.find("directStream=0") != std::string::npos);
        CHECK(url.find("start.mp4") != std::string::npos);
    }

    // --- Positive: 480p-ddr / 720p-ddr on DdrBulk ---
    {
        auto p480 = lookupStreamTargetProfile("480p-ddr");
        CHECK(p480.ok);
        CHECK(p480.profile.decode_w == 624 && p480.profile.decode_h == 480);
        CHECK(p480.profile.required_transport == PresentTransport::DdrBulk);
        CHECK(selectStreamTargetProfile(624, 480, PresentTransport::DdrBulk).ok);

        auto p720 = lookupStreamTargetProfile("720p-ddr");
        CHECK(p720.ok);
        CHECK(p720.profile.decode_w == 1280 && p720.profile.decode_h == 720);
        CHECK(p720.profile.max_video_bitrate_kbps == kPlex720pWeakBitrateKbps);
        CHECK(p720.profile.video_quality == 70);
        CHECK(selectStreamTargetProfile(1280, 720, PresentTransport::DdrBulk).ok);
    }

    // --- NEG: 480p content on SPI must refuse (parent pfps=0 class) ---
    // A naive impl that only checks "known DECODE size" would PASS — this must FAIL.
    {
        auto bad = selectStreamTargetProfile(624, 480, PresentTransport::SpiF1);
        CHECK(!bad.ok);
        CHECK(bad.error == StreamTargetProfileError::GeometryPresentDisagree);
        CHECK(std::string(bad.reason).find("ddr_bulk") != std::string::npos);

        auto bad720 = selectStreamTargetProfile(1280, 720, PresentTransport::SpiF1);
        CHECK(!bad720.ok);
        CHECK(bad720.error == StreamTargetProfileError::GeometryPresentDisagree);
    }

    // --- NEG: illegal transport pairing names ---
    {
        auto spi480 = lookupStreamTargetProfile("480p-spi");
        CHECK(!spi480.ok);
        CHECK(spi480.error == StreamTargetProfileError::UnsupportedOversized);

        auto spi720 = lookupStreamTargetProfile("720p-spi");
        CHECK(!spi720.ok);
        CHECK(spi720.error == StreamTargetProfileError::UnsupportedOversized);
    }

    // --- NEG: 1080p / oversized ---
    {
        auto hi = lookupStreamTargetProfile("1080p");
        CHECK(!hi.ok);
        CHECK(hi.error == StreamTargetProfileError::UnsupportedOversized);

        auto hi2 = lookupStreamTargetProfile("1920x1080");
        CHECK(!hi2.ok);
        CHECK(hi2.error == StreamTargetProfileError::UnsupportedOversized);

        auto sel = selectStreamTargetProfile(1920, 1080, PresentTransport::DdrBulk);
        CHECK(!sel.ok);
        CHECK(sel.error == StreamTargetProfileError::UnsupportedOversized);
    }

    // --- NEG: unknown name ---
    {
        auto u = lookupStreamTargetProfile("not-a-real-profile");
        CHECK(!u.ok);
        CHECK(u.error == StreamTargetProfileError::UnknownName);
    }

    // --- Aliases ---
    {
        CHECK(lookupStreamTargetProfile("240p").ok);
        CHECK(std::strcmp(lookupStreamTargetProfile("240p").profile.id, "240p-spi") == 0);
        CHECK(lookupStreamTargetProfile("624x480").ok);
        CHECK(std::strcmp(lookupStreamTargetProfile("624x480").profile.id, "480p-ddr") == 0);
    }

    // --- Log line greppable fields (no token) ---
    {
        auto r = lookupStreamTargetProfile("240p-spi");
        auto line = formatStreamTargetProfileLogLine(r, PresentTransport::SpiF1, "unit");
        CHECK(line.find("STREAM_TARGET") != std::string::npos);
        CHECK(line.find("profile=240p-spi") != std::string::npos);
        CHECK(line.find("pms_videoResolution=320x240") != std::string::npos);
        CHECK(line.find("present_available=spi_f1") != std::string::npos);
        CHECK(line.find("fits=1") != std::string::npos);
        CHECK(line.find("Token") == std::string::npos);
        CHECK(line.find("token") == std::string::npos);
    }

    // --- presentTransportFromConf ---
    {
        CHECK(presentTransportFromConf("fpga", "") == PresentTransport::SpiF1);
        CHECK(presentTransportFromConf("fpga", "ddr_bulk") == PresentTransport::DdrBulk);
        CHECK(presentTransportFromConf("both", "spi_f1") == PresentTransport::SpiF1);
    }

    // Payload arithmetic sanity (parent budgets).
    {
        const double p240 = i420PayloadMiBs(320, 240, 24.0);
        const double p480 = i420PayloadMiBs(624, 480, 24.0);
        CHECK(p240 > 2.5 && p240 < 3.0);
        CHECK(p480 > 10.0 && p480 < 11.0);
        CHECK(p240 <= kPresentSpiF1BudgetMiBs);
        CHECK(p480 > kPresentSpiF1BudgetMiBs);
    }

    if (fails) {
        std::fprintf(stderr, "test_stream_target_profile: %d failures\n", fails);
        return 1;
    }
    std::printf("test_stream_target_profile: OK\n");
    return 0;
}
