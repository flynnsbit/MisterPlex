// Fabric H.264 bitstream gate — route selector, not a product hard-fail.
//
// *** HARD INVARIANT (parent miss #15, 2026-08-03) — encode, do not heuristic ***
//   Direct play  ⇒ source bytes preserved (lab: Constrained Baseline, 0 B-frames)
//                  ⇒ may be FabricBitstreamEligible after AU/bitstream gate.
//   Any transcode ⇒ measured Main + has_b_frames=2 on real bytes even when
//                  decision XML advertises videoProfile="constrained baseline".
//                  ⇒ ALWAYS ArmFfmpegFallback. No pin, Extra, or metadata
//                  attribute suppresses this. Never open fabric on xcode.
//
// Parent miss #13: prefer DP so the 98.6% CB library reaches fabric; pin cannot
// force baseline on xcode. miss #15: decision XML profile is a LIE on xcode —
// probe bytes (ffprobe profile/has_b_frames), not advertised attributes.
//
// Disposition:
//   DP + Ok (baseline/CB + CAVLC + no B) → FabricBitstreamEligible
//   Any transcode OR any Refuse*         → ArmFfmpegFallback (not product kill)
//
// 720p@30 for SD = DP native + fabric upscale (ascal), never PMS xcode pixels.
//
// Use before any fabric bitstream path consumes an AU. Host FFmpeg pixel path
// must ignore Refuse* as a kill switch.
#pragma once

#include "libmisterplex/h264_nal.hpp"

#include <cctype>
#include <cstdint>
#include <cstring>
#include <string>

namespace misterplex {

// H.264 profile_idc values (ITU-T H.264 Table A-1).
constexpr uint8_t kH264ProfileBaseline = 66;
constexpr uint8_t kH264ProfileMain = 77;
constexpr uint8_t kH264ProfileExtended = 88;
constexpr uint8_t kH264ProfileHigh = 100;

enum class FabricStreamVerdict : uint8_t {
    Ok = 0,
    RefuseNoSps,
    RefuseNoPps,
    RefuseProfile,            // Main/High/Extended/other — not Baseline (bitstream)
    RefuseCabac,              // PPS entropy_coding_mode_flag=1
    RefuseBSlice,             // B-slice type in AU (CB has none)
    RefuseUnsupportedPps,
    RefuseTranscodeDelivery,  // HARD: any PMS universal/xcode — ignore advertised CB
};

// Product decode route after the bitstream gate. Refuse is fallback, not outage.
enum class FabricDecodeRoute : uint8_t {
    FabricBitstreamEligible = 0,
    ArmFfmpegFallback = 1,
};

struct FabricStreamGateResult {
    bool ok = false;
    FabricStreamVerdict verdict = FabricStreamVerdict::RefuseNoSps;
    const char* reason = "refuse_no_sps";
    uint8_t profile_idc = 0;
    bool entropy_cabac = false;
    bool constrained_baseline = false;
    // True when route was closed solely because delivery is a PMS transcode
    // (miss #15) — advertised profile must not be consulted.
    bool refused_as_transcode = false;
};

// Map gate verdict → product route. ok=false never means "stop playback".
// Bitstream-only helper — callers that know PMS delivery class MUST use
// fabricDecodeRouteForPmsDelivery() so xcode cannot pass on a lying XML profile.
inline FabricDecodeRoute fabricDecodeRoute(const FabricStreamGateResult& r) {
    return r.ok ? FabricDecodeRoute::FabricBitstreamEligible
                : FabricDecodeRoute::ArmFfmpegFallback;
}

// HARD INVARIANT: is_transcoded=true ⇒ ArmFfmpegFallback, full stop.
// Bitstream result is ignored on xcode (even if AU looked baseline).
inline FabricDecodeRoute fabricDecodeRouteForPmsDelivery(bool is_transcoded,
                                                         const FabricStreamGateResult& bitstream) {
    if (is_transcoded)
        return FabricDecodeRoute::ArmFfmpegFallback;
    return fabricDecodeRoute(bitstream);
}

inline const char* fabricDecodeRouteStr(FabricDecodeRoute route) {
    switch (route) {
    case FabricDecodeRoute::FabricBitstreamEligible:
        return "fabric_bitstream_eligible";
    case FabricDecodeRoute::ArmFfmpegFallback:
        return "arm_ffmpeg_fallback";
    }
    return "arm_ffmpeg_fallback";
}

inline bool fabricBitstreamPathOpen(const FabricStreamGateResult& r) {
    return fabricDecodeRoute(r) == FabricDecodeRoute::FabricBitstreamEligible;
}

// Host FFmpeg / present path must stay open whenever fabric bitstream is closed.
inline bool armFfmpegDecodeRequired(const FabricStreamGateResult& r) {
    return fabricDecodeRoute(r) == FabricDecodeRoute::ArmFfmpegFallback;
}

// Product open check: DP + bitstream ok. Xcode never opens.
inline bool fabricBitstreamPathOpenForPmsDelivery(bool is_transcoded,
                                                  const FabricStreamGateResult& bitstream) {
    return fabricDecodeRouteForPmsDelivery(is_transcoded, bitstream) ==
           FabricDecodeRoute::FabricBitstreamEligible;
}

inline const char* fabricStreamVerdictStr(FabricStreamVerdict v) {
    switch (v) {
    case FabricStreamVerdict::Ok:
        return "ok_baseline_cavlc";
    case FabricStreamVerdict::RefuseNoSps:
        return "refuse_no_sps";
    case FabricStreamVerdict::RefuseNoPps:
        return "refuse_no_pps";
    case FabricStreamVerdict::RefuseProfile:
        return "refuse_profile_not_baseline";
    case FabricStreamVerdict::RefuseCabac:
        return "refuse_cabac";
    case FabricStreamVerdict::RefuseBSlice:
        return "refuse_b_slice";
    case FabricStreamVerdict::RefuseUnsupportedPps:
        return "refuse_unsupported_pps";
    case FabricStreamVerdict::RefuseTranscodeDelivery:
        return "refuse_transcode_delivery";
    }
    return "refuse_unknown";
}

// True when profile_idc is Baseline (66). Constrained Baseline is Baseline + set1.
inline bool fabricProfileIdcIsBaseline(uint8_t profile_idc) {
    return profile_idc == kH264ProfileBaseline;
}

// Plex decision/Media @videoProfile / @profile string from XML — NOT bitstream.
// Accepts baseline / "constrained baseline"; rejects high/main/extended/empty-noise.
//
// WARNING (miss #15): On PMS *transcode* decisions this attribute is untrusted —
// lab advertised "constrained baseline" while ffprobe of the TS was Main+B=2.
// NEVER call this alone to open the fabric path. Use gateFabricFromPmsDelivery /
// fabricDecodeRouteForPmsDecision with is_transcoded.
inline bool plexVideoProfileAttrIsFabricSafe(const std::string& attr) {
    std::string s;
    s.reserve(attr.size());
    for (unsigned char c : attr) {
        if (std::isspace(c))
            continue;
        s.push_back(static_cast<char>(std::tolower(c)));
    }
    if (s.empty())
        return false;
    if (s == "baseline" || s == "constrainedbaseline" || s == "cb" ||
        s.find("baseline") != std::string::npos) {
        // "baseline" ok; "high@L4.1" style without baseline → reject below
        if (s.find("high") != std::string::npos && s.find("baseline") == std::string::npos)
            return false;
        if (s.find("main") != std::string::npos && s.find("baseline") == std::string::npos)
            return false;
        return true;
    }
    return false;
}

// Negative helper: strings a naive "any non-empty profile is fine" check would accept.
inline bool plexVideoProfileAttrLooksLikeCabacRisk(const std::string& attr) {
    std::string s;
    for (unsigned char c : attr)
        s.push_back(static_cast<char>(std::tolower(c)));
    return s.find("high") != std::string::npos || s.find("main") != std::string::npos ||
           s.find("cabac") != std::string::npos;
}

// Decision-time route before any AU: xcode always ARM; DP uses advertised
// profile only as a weak prefilter (empty = provisional fabric until bitstream).
// RED: advertised "constrained baseline" + is_transcoded=true → ARM (miss #15).
inline FabricDecodeRoute fabricDecodeRouteForPmsDecision(
    bool is_transcoded, const std::string& advertised_video_profile) {
    if (is_transcoded)
        return FabricDecodeRoute::ArmFfmpegFallback;
    if (!advertised_video_profile.empty() &&
        !plexVideoProfileAttrIsFabricSafe(advertised_video_profile))
        return FabricDecodeRoute::ArmFfmpegFallback;
    return FabricDecodeRoute::FabricBitstreamEligible;
}

// Decision-time gate result (logging / resolve). Never trusts xcode metadata.
inline FabricStreamGateResult gateFabricFromPmsDelivery(
    bool is_transcoded, const std::string& advertised_video_profile) {
    FabricStreamGateResult r;
    if (is_transcoded) {
        r.ok = false;
        r.verdict = FabricStreamVerdict::RefuseTranscodeDelivery;
        r.reason = fabricStreamVerdictStr(FabricStreamVerdict::RefuseTranscodeDelivery);
        r.refused_as_transcode = true;
        return r;
    }
    // Direct play: weak advertised filter only when present.
    if (!advertised_video_profile.empty() &&
        !plexVideoProfileAttrIsFabricSafe(advertised_video_profile)) {
        r.ok = false;
        r.verdict = FabricStreamVerdict::RefuseProfile;
        r.reason = fabricStreamVerdictStr(FabricStreamVerdict::RefuseProfile);
        return r;
    }
    // Provisional OK until AU bitstream gate runs on the Part path.
    r.ok = true;
    r.verdict = FabricStreamVerdict::Ok;
    r.reason = "ok_direct_play_provisional";
    return r;
}

// B-slice types: 1, 6 (and SI/SP not CB product). I=2,7 P=0,5.
inline bool h264SliceTypeIsB(uint8_t slice_type) {
    const uint8_t t = static_cast<uint8_t>(slice_type % 5);
    return t == 1;
}

inline FabricStreamGateResult gateFabricH264FromChain(const NalChainInfo& chain) {
    FabricStreamGateResult r;
    r.profile_idc = chain.sps.profile_idc;
    r.entropy_cabac = chain.pps.entropy_cabac;
    r.constrained_baseline = chain.sps.isConstrainedBaseline();

    if (!chain.sps.valid) {
        r.verdict = FabricStreamVerdict::RefuseNoSps;
        r.reason = fabricStreamVerdictStr(r.verdict);
        return r;
    }
    if (!fabricProfileIdcIsBaseline(chain.sps.profile_idc)) {
        r.verdict = FabricStreamVerdict::RefuseProfile;
        r.reason = fabricStreamVerdictStr(r.verdict);
        return r;
    }
    // PPS: CABAC leaves entropy_cabac=true and valid=false (parsePpsRbsp contract).
    if (chain.pps.entropy_cabac) {
        r.verdict = FabricStreamVerdict::RefuseCabac;
        r.reason = fabricStreamVerdictStr(r.verdict);
        return r;
    }
    if (!chain.pps.valid) {
        // Distinguish missing PPS NAL from unsupported non-CABAC PPS (FMO etc.).
        if (chain.pps.pps_id == 0 && chain.pps.sps_id == 0 && !chain.pps.deblock_ctrl &&
            chain.pps.num_ref_idx_l0_default == 0 && chain.pps.pic_init_qp == 0) {
            r.verdict = FabricStreamVerdict::RefuseNoPps;
        } else {
            r.verdict = FabricStreamVerdict::RefuseUnsupportedPps;
        }
        r.reason = fabricStreamVerdictStr(r.verdict);
        return r;
    }
    if (chain.slice.valid && h264SliceTypeIsB(chain.slice.slice_type)) {
        r.verdict = FabricStreamVerdict::RefuseBSlice;
        r.reason = fabricStreamVerdictStr(r.verdict);
        return r;
    }

    r.ok = true;
    r.verdict = FabricStreamVerdict::Ok;
    r.reason = fabricStreamVerdictStr(r.verdict);
    return r;
}

inline FabricStreamGateResult gateFabricH264AnnexB(const uint8_t* data, size_t n) {
    return gateFabricH264FromChain(parseAnnexBChain(data, n));
}

// Scan annex-B for first PPS only (detect CABAC without requiring full chain).
inline FabricStreamGateResult gateFabricH264AnnexBStrict(const uint8_t* data, size_t n) {
    auto chain = parseAnnexBChain(data, n);
    auto r = gateFabricH264FromChain(chain);
    // Extra: walk all PPS NALs so a CAVLC SPS+ first PPS cannot mask a later CABAC PPS.
    if (!data || n < 5)
        return r;
    size_t i = 0;
    while (i + 3 < n) {
        size_t sc = 0;
        if (i + 3 < n && data[i] == 0 && data[i + 1] == 0 && data[i + 2] == 0 && data[i + 3] == 1)
            sc = 4;
        else if (data[i] == 0 && data[i + 1] == 0 && data[i + 2] == 1)
            sc = 3;
        else {
            ++i;
            continue;
        }
        size_t j = i + sc;
        while (j + 3 < n) {
            if (data[j] == 0 && data[j + 1] == 0 &&
                (data[j + 2] == 1 || (j + 3 < n && data[j + 2] == 0 && data[j + 3] == 1)))
                break;
            ++j;
        }
        if (j + 3 >= n)
            j = n;
        if (i + sc < j) {
            const uint8_t hdr = data[i + sc];
            if ((hdr & 0x1f) == 8) {
                PpsInfo pps = parsePpsRbsp(data + i + sc + 1, j - (i + sc + 1));
                if (pps.entropy_cabac) {
                    r.ok = false;
                    r.entropy_cabac = true;
                    r.verdict = FabricStreamVerdict::RefuseCabac;
                    r.reason = fabricStreamVerdictStr(r.verdict);
                    return r;
                }
            }
        }
        i = j;
    }
    return r;
}

} // namespace misterplex
