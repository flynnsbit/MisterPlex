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

    // --- Positive: real Baseline annex-B (host fixture) ---
    auto base = loadBaselineAnnexB();
    CHECK(!base.empty());
    {
        auto r = gateFabricH264AnnexB(base.data(), base.size());
        CHECK(r.ok);
        CHECK(r.verdict == FabricStreamVerdict::Ok);
        CHECK(r.profile_idc == kH264ProfileBaseline);
        CHECK(!r.entropy_cabac);
        CHECK(std::string(r.reason) == "ok_baseline_cavlc");
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

    std::printf("test_h264_fabric_stream_gate: OK\n");
    return 0;
}
