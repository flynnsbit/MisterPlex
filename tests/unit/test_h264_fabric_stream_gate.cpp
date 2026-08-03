// Fabric stream gate: Baseline/CAVLC → fabric eligible; High/CABAC/B → ARM fallback.
// Refuse is a route, not a product kill. Negative cases a naive open gate would miss.
#include "libmisterplex/h264_fabric_stream_gate.hpp"

#include <cstdio>
#include <cstdlib>
#include <fstream>
#include <string>
#include <vector>

#define CHECK(cond)                                                                            \
    do {                                                                                       \
        if (!(cond)) {                                                                         \
            std::printf("FAIL %s:%d: %s\n", __FILE__, __LINE__, #cond);                         \
            return 1;                                                                          \
        }                                                                                      \
    } while (0)

static std::vector<uint8_t> readFile(const char* path) {
    std::ifstream in(path, std::ios::binary);
    if (!in)
        return {};
    return std::vector<uint8_t>((std::istreambuf_iterator<char>(in)), {});
}

static std::vector<uint8_t> loadBaselineAnnexB() {
    const char* path = "build/plex_real_baseline.264";
    auto blob = readFile(path);
    if (!blob.empty())
        return blob;
    if (std::system("python3 scripts/gen_test_annexb_real.py build/plex_real_baseline.264") != 0)
        return {};
    return readFile(path);
}

int main() {
    using namespace misterplex;

    // --- PMS attribute pin helpers (decision XML, not bitstream) ---
    CHECK(plexVideoProfileAttrIsFabricSafe("baseline"));
    CHECK(plexVideoProfileAttrIsFabricSafe("Baseline"));
    CHECK(plexVideoProfileAttrIsFabricSafe("constrained baseline"));
    CHECK(plexVideoProfileAttrIsFabricSafe("Constrained Baseline"));
    CHECK(!plexVideoProfileAttrIsFabricSafe(""));
    CHECK(!plexVideoProfileAttrIsFabricSafe("high"));
    CHECK(!plexVideoProfileAttrIsFabricSafe("High@L4.1"));
    CHECK(!plexVideoProfileAttrIsFabricSafe("main"));
    CHECK(!plexVideoProfileAttrIsFabricSafe("Main"));
    CHECK(plexVideoProfileAttrLooksLikeCabacRisk("high"));
    CHECK(plexVideoProfileAttrLooksLikeCabacRisk("Main"));
    CHECK(!plexVideoProfileAttrLooksLikeCabacRisk("baseline"));

    // --- Positive: real Baseline annex-B (host fixture) — 98.6% library path ---
    auto base = loadBaselineAnnexB();
    CHECK(!base.empty());
    {
        auto r = gateFabricH264AnnexB(base.data(), base.size());
        CHECK(r.ok);
        CHECK(r.verdict == FabricStreamVerdict::Ok);
        CHECK(r.profile_idc == kH264ProfileBaseline);
        CHECK(!r.entropy_cabac);
        CHECK(std::string(r.reason) == "ok_baseline_cavlc");
        CHECK(fabricDecodeRoute(r) == FabricDecodeRoute::FabricBitstreamEligible);
        CHECK(fabricBitstreamPathOpen(r));
        CHECK(!armFfmpegDecodeRequired(r));
    }
    // Constrained Baseline SPS (library majority) — must open fabric path.
    {
        NalChainInfo c;
        c.sps.valid = true;
        c.sps.profile_idc = kH264ProfileBaseline;
        c.sps.constraint_flags = 0xC0; // constraint_set0+set1
        c.sps.width = 624;
        c.sps.height = 480;
        c.pps.valid = true;
        c.pps.entropy_cabac = false;
        auto r = gateFabricH264FromChain(c);
        CHECK(r.ok);
        CHECK(r.constrained_baseline || fabricProfileIdcIsBaseline(r.profile_idc));
        CHECK(fabricDecodeRoute(r) == FabricDecodeRoute::FabricBitstreamEligible);
    }

    // --- Negative: High profile_idc (naive accept-any-SPS would OK this) ---
    {
        NalChainInfo c;
        c.sps.valid = true;
        c.sps.profile_idc = kH264ProfileHigh;
        c.sps.width = 1280;
        c.sps.height = 720;
        c.pps.valid = true;
        c.pps.entropy_cabac = false;
        auto r = gateFabricH264FromChain(c);
        CHECK(!r.ok);
        CHECK(r.verdict == FabricStreamVerdict::RefuseProfile);
        CHECK(std::string(r.reason) == "refuse_profile_not_baseline");
    }

    // --- Negative: Main profile ---
    {
        NalChainInfo c;
        c.sps.valid = true;
        c.sps.profile_idc = kH264ProfileMain;
        c.pps.valid = true;
        auto r = gateFabricH264FromChain(c);
        CHECK(!r.ok);
        CHECK(r.verdict == FabricStreamVerdict::RefuseProfile);
    }

    // --- Negative: Baseline SPS + CABAC PPS (the silent-garbage case) ---
    {
        NalChainInfo c;
        c.sps.valid = true;
        c.sps.profile_idc = kH264ProfileBaseline;
        c.sps.constraint_flags = 0xC0; // constrained baseline flags
        c.pps.valid = false;
        c.pps.entropy_cabac = true;
        auto r = gateFabricH264FromChain(c);
        CHECK(!r.ok);
        CHECK(r.verdict == FabricStreamVerdict::RefuseCabac);
        CHECK(r.entropy_cabac);
        CHECK(std::string(r.reason) == "refuse_cabac");
    }

    // --- Negative: synthetic annex-B with CABAC PPS NAL only after Baseline SPS ---
    // parsePpsRbsp requires len>=2; RBSP: ue(0) ue(0) entropy=1 → 0xE0 0x00.
    {
        std::vector<uint8_t> au = base;
        const uint8_t cabacPps[] = {0x00, 0x00, 0x00, 0x01, 0x68, 0xE0, 0x00};
        au.insert(au.end(), cabacPps, cabacPps + sizeof(cabacPps));
        auto r = gateFabricH264AnnexBStrict(au.data(), au.size());
        CHECK(!r.ok);
        CHECK(r.verdict == FabricStreamVerdict::RefuseCabac);
    }

    // --- Negative: B-slice in AU ---
    {
        NalChainInfo c;
        c.sps.valid = true;
        c.sps.profile_idc = kH264ProfileBaseline;
        c.pps.valid = true;
        c.pps.entropy_cabac = false;
        c.slice.valid = true;
        c.slice.slice_type = 1; // B
        auto r = gateFabricH264FromChain(c);
        CHECK(!r.ok);
        CHECK(r.verdict == FabricStreamVerdict::RefuseBSlice);
    }

    // --- Negative: missing SPS ---
    {
        NalChainInfo c;
        auto r = gateFabricH264FromChain(c);
        CHECK(!r.ok);
        CHECK(r.verdict == FabricStreamVerdict::RefuseNoSps);
    }

    // --- Constrained Baseline flag surface ---
    {
        SpsInfo s;
        s.profile_idc = 66;
        s.constraint_flags = 0x40; // set1 only
        CHECK(s.isBaselineProfileIdc());
        CHECK(s.isConstrainedBaseline());
        s.constraint_flags = 0;
        CHECK(s.isBaselineProfileIdc());
        CHECK(!s.isConstrainedBaseline());
    }

    // --- Disposition: Refuse* is ArmFfmpegFallback, never a product hard-fail ---
    // Red twin: a naive "if (!gate.ok) abort playback" would treat High xcode as
    // outage. Lab PMS delivers High on force-xcode of rk118/119 (measured).
    {
        NalChainInfo high;
        high.sps.valid = true;
        high.sps.profile_idc = kH264ProfileHigh;
        high.pps.valid = true;
        high.pps.entropy_cabac = true;
        auto r = gateFabricH264FromChain(high);
        CHECK(!r.ok);
        CHECK(r.verdict == FabricStreamVerdict::RefuseProfile);
        CHECK(fabricDecodeRoute(r) == FabricDecodeRoute::ArmFfmpegFallback);
        CHECK(armFfmpegDecodeRequired(r));
        CHECK(!fabricBitstreamPathOpen(r));
        CHECK(std::string(fabricDecodeRouteStr(fabricDecodeRoute(r))) == "arm_ffmpeg_fallback");
    }
    {
        auto base2 = loadBaselineAnnexB();
        CHECK(!base2.empty());
        auto r = gateFabricH264AnnexB(base2.data(), base2.size());
        CHECK(r.ok);
        CHECK(fabricDecodeRoute(r) == FabricDecodeRoute::FabricBitstreamEligible);
        CHECK(fabricBitstreamPathOpen(r));
        CHECK(!armFfmpegDecodeRequired(r));
        CHECK(std::string(fabricDecodeRouteStr(fabricDecodeRoute(r))) ==
              "fabric_bitstream_eligible");
    }
    // CABAC refuse still falls back to ARM (fabric-decode track stays closed).
    {
        NalChainInfo c;
        c.sps.valid = true;
        c.sps.profile_idc = kH264ProfileBaseline;
        c.pps.entropy_cabac = true;
        auto r = gateFabricH264FromChain(c);
        CHECK(armFfmpegDecodeRequired(r));
        CHECK(!fabricBitstreamPathOpen(r));
    }

    // --- HARD INVARIANT miss #15: any transcode → ARM, even advertised CB ---
    // Parent measured: decision XML videoProfile="constrained baseline" on HD
    // xcode while ffprobe of TS bytes = Main + has_b_frames=2. Metadata lie.
    {
        const std::string lie_cb = "constrained baseline";
        CHECK(plexVideoProfileAttrIsFabricSafe(lie_cb)); // naive attr-only would OPEN
        // RED: attr-safe + transcode must NOT open fabric
        CHECK(fabricDecodeRouteForPmsDecision(/*is_transcoded=*/true, lie_cb) ==
              FabricDecodeRoute::ArmFfmpegFallback);
        auto g = gateFabricFromPmsDelivery(/*is_transcoded=*/true, lie_cb);
        CHECK(!g.ok);
        CHECK(g.refused_as_transcode);
        CHECK(g.verdict == FabricStreamVerdict::RefuseTranscodeDelivery);
        CHECK(std::string(g.reason) == "refuse_transcode_delivery");
        CHECK(fabricDecodeRoute(g) == FabricDecodeRoute::ArmFfmpegFallback);
        // Even a "perfect" baseline bitstream result cannot open fabric on xcode.
        NalChainInfo perfect;
        perfect.sps.valid = true;
        perfect.sps.profile_idc = kH264ProfileBaseline;
        perfect.sps.constraint_flags = 0xC0;
        perfect.pps.valid = true;
        perfect.pps.entropy_cabac = false;
        auto br = gateFabricH264FromChain(perfect);
        CHECK(br.ok); // bitstream alone would pass
        CHECK(fabricDecodeRouteForPmsDelivery(/*xcode=*/true, br) ==
              FabricDecodeRoute::ArmFfmpegFallback);
        CHECK(!fabricBitstreamPathOpenForPmsDelivery(true, br));
        // DP + same lie_cb (truthful on DP) → provisional fabric
        CHECK(fabricDecodeRouteForPmsDecision(/*is_transcoded=*/false, lie_cb) ==
              FabricDecodeRoute::FabricBitstreamEligible);
        auto gdp = gateFabricFromPmsDelivery(false, lie_cb);
        CHECK(gdp.ok && !gdp.refused_as_transcode);
        CHECK(std::string(gdp.reason) == "ok_direct_play_provisional");
        CHECK(fabricBitstreamPathOpenForPmsDelivery(false, br));
        // DP of Main source → ARM at decision time
        CHECK(fabricDecodeRouteForPmsDecision(false, "main") ==
              FabricDecodeRoute::ArmFfmpegFallback);
        // HD regime is delivery-only; fabric class follows xcode flag
        CHECK(fabricDecodeRouteForPmsDecision(true, "baseline") ==
              FabricDecodeRoute::ArmFfmpegFallback);
    }

    // --- Positive path (full credit): DP + real Baseline bytes → confirmed ---
    // Refusal-only implementations never close this item; this opens fabric.
    {
        auto base3 = loadBaselineAnnexB();
        CHECK(!base3.empty());
        auto chain = parseAnnexBChain(base3.data(), base3.size());
        auto conf = confirmFabricFromDeliveryAndBitstream(/*xcode=*/false, chain);
        CHECK(conf.ok);
        CHECK(std::string(conf.reason) == "ok_baseline_cavlc_confirmed");
        CHECK(fabricDecodeRouteForPmsDelivery(false, conf) ==
              FabricDecodeRoute::FabricBitstreamEligible);
        CHECK(fabricBitstreamPathOpenForPmsDelivery(false, conf));
        // SPS+PPS NAL helper (STREAM demux shape)
        // Extract first SPS and PPS from annex-B for NAL-split confirm.
        // Use full chain via annex-B when split is hard — also test xcode NEG:
        auto confX = confirmFabricFromDeliveryAndBitstream(/*xcode=*/true, chain);
        CHECK(!confX.ok);
        CHECK(confX.refused_as_transcode);
        CHECK(std::string(confX.reason) == "refuse_transcode_delivery");
        CHECK(fabricDecodeRouteForPmsDelivery(true, confX) ==
              FabricDecodeRoute::ArmFfmpegFallback);
        // Even with ok bitstream object, delivery wrapper blocks:
        CHECK(!fabricBitstreamPathOpenForPmsDelivery(true, conf));
    }

    // --- RED: advertised CB + Main bitstream under DP → refuse_profile ---
    {
        NalChainInfo main;
        main.sps.valid = true;
        main.sps.profile_idc = kH264ProfileMain;
        main.pps.valid = true;
        main.pps.entropy_cabac = false;
        auto conf = confirmFabricFromDeliveryAndBitstream(false, main);
        CHECK(!conf.ok);
        CHECK(conf.verdict == FabricStreamVerdict::RefuseProfile);
        CHECK(fabricDecodeRouteForPmsDelivery(false, conf) ==
              FabricDecodeRoute::ArmFfmpegFallback);
    }

    // --- Metadata fabric Direct Play predicate (parent TASK1 2026-08-03) ---
    // POS: rk=7-class meta (not hardcoded ratingKey) — CB / L30 / 1280x720 / ~488kbps.
    {
        FabricDirectPlayMeta ok;
        ok.codec_is_h264 = true;
        ok.video_profile = "constrained baseline";
        ok.level = 30;
        ok.width = 1280;
        ok.height = 720;
        ok.bitrate_kbps = 508;
        ok.has_b_frames = -1; // CB ⇒ B unknown allowed
        ok.chroma = "";       // PMS Media often omits chroma
        auto v = evaluateFabricDirectPlayMeta(ok);
        CHECK(v.ok);
        CHECK(std::string(v.reason) == "ok_fabric_direct_play_meta");
    }
    // POS: baseline + explicit has_b_frames=0 + yuv420p
    {
        FabricDirectPlayMeta ok;
        ok.codec_is_h264 = true;
        ok.video_profile = "baseline";
        ok.level = 30;
        ok.width = 640;
        ok.height = 360;
        ok.bitrate_kbps = 1200;
        ok.has_b_frames = 0;
        ok.chroma = "yuv420p";
        CHECK(evaluateFabricDirectPlayMeta(ok).ok);
    }
    // NEG: High profile
    {
        FabricDirectPlayMeta bad;
        bad.codec_is_h264 = true;
        bad.video_profile = "high";
        bad.level = 30;
        bad.width = 1280;
        bad.height = 720;
        bad.bitrate_kbps = 500;
        bad.has_b_frames = 0;
        bad.chroma = "yuv420p";
        auto v = evaluateFabricDirectPlayMeta(bad);
        CHECK(!v.ok);
        CHECK(std::string(v.reason) == "refuse_profile");
    }
    // NEG: level > 3.0
    {
        FabricDirectPlayMeta bad;
        bad.codec_is_h264 = true;
        bad.video_profile = "constrained baseline";
        bad.level = 31;
        bad.width = 1280;
        bad.height = 720;
        bad.bitrate_kbps = 500;
        auto v = evaluateFabricDirectPlayMeta(bad);
        CHECK(!v.ok);
        CHECK(std::string(v.reason) == "refuse_level");
    }
    // NEG: B-frames present
    {
        FabricDirectPlayMeta bad;
        bad.codec_is_h264 = true;
        bad.video_profile = "constrained baseline";
        bad.level = 30;
        bad.width = 1280;
        bad.height = 720;
        bad.bitrate_kbps = 500;
        bad.has_b_frames = 2;
        auto v = evaluateFabricDirectPlayMeta(bad);
        CHECK(!v.ok);
        CHECK(std::string(v.reason) == "refuse_b_frames");
    }
    // NEG: plain baseline without B-frame info (must not guess)
    {
        FabricDirectPlayMeta bad;
        bad.codec_is_h264 = true;
        bad.video_profile = "baseline";
        bad.level = 30;
        bad.width = 720;
        bad.height = 480;
        bad.bitrate_kbps = 1500;
        bad.has_b_frames = -1;
        auto v = evaluateFabricDirectPlayMeta(bad);
        CHECK(!v.ok);
        CHECK(std::string(v.reason) == "refuse_b_frames_unknown");
    }
    // NEG: 1080p above fabric content ceiling
    {
        FabricDirectPlayMeta bad;
        bad.codec_is_h264 = true;
        bad.video_profile = "constrained baseline";
        bad.level = 30;
        bad.width = 1920;
        bad.height = 1080;
        bad.bitrate_kbps = 500;
        auto v = evaluateFabricDirectPlayMeta(bad);
        CHECK(!v.ok);
        CHECK(std::string(v.reason) == "refuse_geometry");
    }
    // NEG: bitrate above sink ceiling
    {
        FabricDirectPlayMeta bad;
        bad.codec_is_h264 = true;
        bad.video_profile = "constrained baseline";
        bad.level = 30;
        bad.width = 1280;
        bad.height = 720;
        bad.bitrate_kbps = kFabricDirectPlayMaxBitrateKbps + 1;
        auto v = evaluateFabricDirectPlayMeta(bad);
        CHECK(!v.ok);
        CHECK(std::string(v.reason) == "refuse_bitrate");
    }
    // NEG: non-420 chroma when advertised
    {
        FabricDirectPlayMeta bad;
        bad.codec_is_h264 = true;
        bad.video_profile = "constrained baseline";
        bad.level = 30;
        bad.width = 1280;
        bad.height = 720;
        bad.bitrate_kbps = 500;
        bad.chroma = "4:4:4";
        auto v = evaluateFabricDirectPlayMeta(bad);
        CHECK(!v.ok);
        CHECK(std::string(v.reason) == "refuse_chroma");
    }
    // Level token parser
    {
        CHECK(parsePlexH264LevelToken("30") == 30);
        CHECK(parsePlexH264LevelToken("3.0") == 30);
        CHECK(parsePlexH264LevelToken("3.1") == 31);
        CHECK(parsePlexH264LevelToken("40") == 40);
        CHECK(parsePlexH264LevelToken("") == -1);
        CHECK(parsePlexH264LevelToken("nope") == -1);
    }

    std::printf("test_h264_fabric_stream_gate: OK\n");
    return 0;
}
