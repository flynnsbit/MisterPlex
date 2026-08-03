#pragma once
// PMS universal delivery geometry — host-side math only (no network).
//
// Product fact (measured on lab PMS, RK6, 2026-08-02):
//   videoResolution=WxH is a CEILING for aspect-preserving square-pixel fit,
//   not an exact coded size. Anamorphic sources (non-1:1 SAR) whose *display*
//   aspect is 16:9 fit to ~624x350 inside a 624x480 bound.
//
// See .agent-work/w-geom/PMS_350_TRUE_480_RCA.md for the decision matrix.

#include <cmath>
#include <cstdint>
#include <cstdlib>
#include <string>

namespace misterplex {

struct RationalAspect {
    int num = 0;
    int den = 0;
    bool valid() const { return num > 0 && den > 0; }
    double asDouble() const {
        if (!valid())
            return 0.0;
        return static_cast<double>(num) / static_cast<double>(den);
    }
};

// Parse "160:117" or "1.78" style ratios. Colon form preferred (exact).
inline bool parseAspectRatioToken(const std::string& s, RationalAspect& out) {
    out = {};
    if (s.empty())
        return false;
    const auto colon = s.find(':');
    if (colon != std::string::npos) {
        const int n = std::atoi(s.c_str());
        const int d = std::atoi(s.c_str() + colon + 1);
        if (n <= 0 || d <= 0)
            return false;
        out.num = n;
        out.den = d;
        return true;
    }
    // Decimal (Media@aspectRatio="1.78") — approximate as n/100 when possible.
    char* end = nullptr;
    const double v = std::strtod(s.c_str(), &end);
    if (end == s.c_str() || v <= 0.0)
        return false;
    // Keep hundredths; 1.78 → 178/100.
    out.num = static_cast<int>(std::lround(v * 100.0));
    out.den = 100;
    if (out.num <= 0)
        return false;
    return true;
}

// Display aspect = (coded_w/coded_h) * (sar_n/sar_d). SAR 1:1 → storage aspect.
inline double displayAspectFromCodedAndSar(int coded_w, int coded_h, int sar_n, int sar_d) {
    if (coded_w <= 0 || coded_h <= 0 || sar_n <= 0 || sar_d <= 0)
        return 0.0;
    return (static_cast<double>(coded_w) / static_cast<double>(coded_h)) *
           (static_cast<double>(sar_n) / static_cast<double>(sar_d));
}

// Prefer Stream@pixelAspectRatio; else Media@aspectRatio as DAR directly.
inline double resolveContentDar(int coded_w, int coded_h, const std::string& pixelAspectRatio,
                                const std::string& mediaAspectRatio) {
    RationalAspect sar;
    if (parseAspectRatioToken(pixelAspectRatio, sar) && sar.valid()) {
        const double dar = displayAspectFromCodedAndSar(coded_w, coded_h, sar.num, sar.den);
        if (dar > 0.0)
            return dar;
    }
    RationalAspect mar;
    if (parseAspectRatioToken(mediaAspectRatio, mar) && mar.valid())
        return mar.asDouble();
    if (coded_w > 0 && coded_h > 0)
        return static_cast<double>(coded_w) / static_cast<double>(coded_h);
    return 0.0;
}

struct SquarePixelFit {
    int w = 0;
    int h = 0;
    bool ok = false;
};

// Even-floor (PMS/x264 style) after aspect-fit into max_w x max_h ceiling.
// Matches lab decision: 16:9 into 624x480 → 624x350 (351 even-floored).
inline SquarePixelFit pmsSquarePixelFitInCeiling(double dar, int max_w, int max_h) {
    SquarePixelFit out;
    if (!(dar > 0.0) || max_w <= 0 || max_h <= 0)
        return out;
    // Width-limited candidate.
    double h_from_w = static_cast<double>(max_w) / dar;
    // Height-limited candidate.
    double w_from_h = static_cast<double>(max_h) * dar;
    int w = 0, h = 0;
    if (h_from_w <= static_cast<double>(max_h) + 1e-9) {
        w = max_w;
        h = static_cast<int>(std::floor(h_from_w));
    } else {
        h = max_h;
        w = static_cast<int>(std::floor(w_from_h));
    }
    // Even floor (chroma / macroblock-friendly).
    if (w & 1)
        --w;
    if (h & 1)
        --h;
    if (w <= 0 || h <= 0)
        return out;
    out.w = w;
    out.h = h;
    out.ok = true;
    return out;
}

// True 480 rows of *square-pixel* 16:9 need width ≈ 480*(16/9) = 853.33.
// That exceeds the synthesis-fixed DDR coded width 624 — impossible in-bank.
inline int squarePixelWidthForHeight(double dar, int height) {
    if (!(dar > 0.0) || height <= 0)
        return 0;
    int w = static_cast<int>(std::lround(static_cast<double>(height) * dar));
    if (w & 1)
        ++w; // even up for chroma
    return w;
}

// Fraction of requested vertical samples retained after square-pixel fit.
inline double verticalDetailFraction(int delivered_h, int requested_h) {
    if (delivered_h <= 0 || requested_h <= 0)
        return 0.0;
    return static_cast<double>(delivered_h) / static_cast<double>(requested_h);
}

// pipeDesyncRisk requires identity_skip — scale_mode=always sessions cannot
// use producer/reader byte ratios as a desync model (parent correction).
inline bool desyncModelApplicable(bool identity_skip) { return identity_skip; }

// Genuine tier delivery: PMS videoResolution is a CEILING. A 720p *request* that
// lands as 720x404 (bitrate-starved) or 624x350 (16:9 fit into 480 ceiling) is
// NOT true 720p — ARM must not identity_skip or claim path-720 success.
// Exact WxH match only (no "close enough" / no SAR compensation here).
inline bool isGenuineTierDelivery(int delivered_w, int delivered_h, int tier_w, int tier_h) {
    if (delivered_w <= 0 || delivered_h <= 0 || tier_w <= 0 || tier_h <= 0)
        return false;
    return delivered_w == tier_w && delivered_h == tier_h;
}

inline bool isGenuine720pDelivery(int delivered_w, int delivered_h) {
    return isGenuineTierDelivery(delivered_w, delivered_h, 1280, 720);
}

// Exact 960x540 **display/ffmpeg** size — shippable fabric→720 glass source
// (not true 720 source). Match against decoder output after H.264 frame_crop
// (SPS MB may be 960x544; ARM never publishes the uncropped MB buffer).
// Negatives: 720x404 (maxBR starvation), 720x540 (4:3 fit), 960x536, 854x480.
inline bool isGenuine540pDelivery(int delivered_w, int delivered_h) {
    return isGenuineTierDelivery(delivered_w, delivered_h, 960, 540);
}

// Exact 640x360 display after libav crop (SPS MB 368 / crop 8). Exact 2× glass.
// Negatives: 480x270 (maxBR=750), 320x180 (maxBR=400), 640x368 MB height.
inline bool isGenuine360pDelivery(int delivered_w, int delivered_h) {
    return isGenuineTierDelivery(delivered_w, delivered_h, 640, 360);
}

// Lab-measured maxVideoBitrate knee for genuine 960x540 on 16:9 HD sources
// (daemon path + unique session, local PMS 2026-08-03):
//   rk2/rk7: maxBR=1500 → 720x404; maxBR≥2000 → 960x540 SAR 1:1.
// Product weak = kPlex540pWeakBitrateKbps (2000) sits on the measured knee.
inline constexpr int kPmsTrue540pMinBitrateKbpsMeasured = 2000;

inline bool pmsBitrateLikelyTrue540p(int maxVideoBitrateKbps) {
    return maxVideoBitrateKbps >= kPmsTrue540pMinBitrateKbpsMeasured;
}

// Lab knee for genuine 640x360 (rk2/rk142, ceiling 640x360, 2026-08-03):
//   maxBR=400 → 320x180; 750 → 480x270; ≥1000 → 640x360 SAR 1:1.
inline constexpr int kPmsTrue360pMinBitrateKbpsMeasured = 1000;

inline bool pmsBitrateLikelyTrue360p(int maxVideoBitrateKbps) {
    return maxVideoBitrateKbps >= kPmsTrue360pMinBitrateKbpsMeasured;
}

// Lab-measured maxVideoBitrate gate for true 1280x720 on 16:9 HD sources
// (daemon URL builder + unique session, lab PMS 2026-08-03 fine matrix):
//   rk2: maxBR=3000 → 720x404; maxBR=3100 → 1280x720 SAR 1:1 (start.mp4 ffprobe).
//   Decision content bitrate @ maxBR=3100 ≈ 2585 kbps (cap under-run).
//   maxBR=1500/2000/2500/3000 → 720x404 — cannot force full height below the step.
//   rk7 @2500 → 720x404; decision @3200+ → 1280x720.
//   rk83 4:3 @4000 → coded **960x720** (square-pixel fit — not full width).
// Parent device decode of *already* 1280x720@1500k is a content/DP tier, not this gate.
// Product universal weak = kPlex720pWeakBitrateKbps (3100 geometry floor).
inline constexpr int kPmsTrue720pMinBitrateKbpsMeasured = 3100;

inline bool pmsBitrateLikelyTrue720p(int maxVideoBitrateKbps) {
    return maxVideoBitrateKbps >= kPmsTrue720pMinBitrateKbpsMeasured;
}

// Play-time delivery basis string for GEOM / identity_skip.
// Direct Play Part: file samples = delivery (verified). Universal/transcode:
// request or library claim only (unverified until measured).
inline const char* deliveryBasisForResolve(bool ok, bool transcoded, int media_w,
                                           int media_h, bool has_transcode_request_wh) {
    if (!ok)
        return "unknown";
    if (transcoded)
        return has_transcode_request_wh ? "transcode_request" : "unknown";
    if (media_w > 0 && media_h > 0)
        return "direct_play_part";
    return "unknown";
}

// ---- Path scale class (rd-duck 2026-08-03) ---------------------------------
//
// Universal/transcode is **ARM-scale fallback**, not fabric-native:
//   - main sets delivery_verified=0 for basis=transcode_request
//   - media_player keeps DDR YUV force-scale ON → Always scale mode
//   - ffmpeg_vf emits scale+pad for unverified exact claims (cannot identity_skip)
//   - vf is frozen before the ffmpeg banner; measured delivery cannot rebuild it
//   - parent ±2 macroblock tweak: request 624x352 can deliver 626x352 (unaligned)
//     even when the request was fabric-aligned — source_snap only picks the bank
//
// fabric_native requires verified delivery (DP Part or measured) AND no ARM
// resample into the bank. Until preflight/manifest verification or a dynamic
// post-banner pad-only rebuild exists, NEVER count universal as fabric_native.

enum class PathScaleClass {
    Unknown = 0,
    ArmScaleFallback = 1, // universal / unverified / force-scale path
    FabricNative = 2,     // verified delivery, identity or pad-only into bank
};

inline const char* pathScaleClassName(PathScaleClass c) {
    switch (c) {
    case PathScaleClass::FabricNative:
        return "fabric_native";
    case PathScaleClass::ArmScaleFallback:
        return "arm_scale_fallback";
    default:
        return "unknown";
    }
}

// Plan-time classification from resolve basis + vf plan outcome.
// scale_applied=true ⇒ always ARM fallback (resample ran).
// identity_skip/pad-only without scale only counts fabric_native when verified.
inline PathScaleClass classifyPathScaleClass(const char* delivery_basis,
                                             bool delivery_verified, bool scale_applied,
                                             bool identity_skip) {
    // Universal request claim — never fabric-native at plan time (rd-duck).
    if (delivery_basis) {
        const std::string b(delivery_basis);
        if (b == "transcode_request" || b == "library_media" || b == "unknown")
            return PathScaleClass::ArmScaleFallback;
    } else {
        return PathScaleClass::ArmScaleFallback;
    }
    if (!delivery_verified)
        return PathScaleClass::ArmScaleFallback;
    if (scale_applied)
        return PathScaleClass::ArmScaleFallback;
    // Verified DP/measured and no scale: identity_skip or crop/pad-only.
    if (identity_skip || !scale_applied)
        return PathScaleClass::FabricNative;
    return PathScaleClass::ArmScaleFallback;
}

// True when this path may still claim fabric-native (DP only at plan time).
inline bool pathMayBeFabricNative(const char* delivery_basis, bool delivery_verified) {
    return classifyPathScaleClass(delivery_basis, delivery_verified, /*scale*/ false,
                                  /*identity*/ true) == PathScaleClass::FabricNative;
}

// --- Two-regime play policy (parent 2026-08-03, miss #13 + #15) ---
// Library census N=142: 98.6% constrained baseline; PMS never transcodes *to*
// baseline, but DP preserves source profile. SD majority → DP native.
//
// Parent 2026-08-03 FACT: glass is already video_mode=0 1280×720@60 via ascal.
// Product target is CONTENT 1280×720 (PMS request + bank), not "make HDMI 720p".
//
// Split two contracts that were conflated under "Route-B 540":
//   A) PMS / content ladder ceiling = 1280×720 (this file's HD xcode target).
//   B) Present 1ppc beam DE budget (w-clock) — may still clamp scanout; does NOT
//      forbid asking PMS for a real 720p tier. Bank stride for 1.38 MiB frames
//      is w-mem (HELD). Do not silently down-request 540 forever.
//
// miss #15: ANY transcode is ARM-fallback for fabric decode (bytes = Main+B=2).
// Native ≤1280×720 H.264 tries Direct Play first (rk=7 cheapest path).
//
// Enum tag TranscodeHd720 = source above 720 → PMS xcode to 1280×720 tier.
enum class PlayDeliveryRegime : uint8_t {
    Unknown = 0,
    DirectPlaySd = 1,   // native ≤1280×720 H.264 Part — fabric iff CB/CAVLC/no-B
    TranscodeHd720 = 2, // source above 720 → PMS universal 1280×720 tier
    ForceUniversal = 3, // conf / non-H.264 / missing Part — ARM decode class
};

// Route-B product beam budget (1ppc). Matches w-clock clamp mins.
inline constexpr int kRouteBPixelClockHz = 20000000;
inline constexpr int kRouteBMinHBlank = 32;
inline constexpr int kRouteBMinVBlank = 16;
// Legacy 1ppc present-DE soft ceiling (w-clock Route-B analysis). Kept for
// beam math helpers; PMS content ladder uses kPlex720p* (1280×720) instead.
inline constexpr int kRouteBHostContentMaxW = 960;
inline constexpr int kRouteBHostContentMaxH = 540;
// Product content / PMS request ceiling (parent 720p programme).
inline constexpr int kPmsContentMaxW = 1280;
inline constexpr int kPmsContentMaxH = 720;

inline long long routeBActivePixelsPerSec(int h_de, int v_de, int fps) {
    if (h_de <= 0 || v_de <= 0 || fps <= 0)
        return 0;
    return 1LL * h_de * v_de * fps;
}

inline long long routeBTotalPixelsPerSec(int h_de, int v_de, int fps) {
    if (h_de <= 0 || v_de <= 0 || fps <= 0)
        return 0;
    const int h_total = h_de + kRouteBMinHBlank;
    const int v_total = v_de + kRouteBMinVBlank;
    return 1LL * h_total * v_total * fps;
}

// True when content DE×fps fits Route-B 1ppc beam (active AND blanked totals).
// multi_pixel=true skips the 960×540 host ceiling (fitted multi-pixel path only).
inline bool routeBContentDeFitsFps(int h_de, int v_de, int fps,
                                   bool present_multi_pixel = false) {
    if (h_de <= 0 || v_de <= 0 || fps <= 0)
        return false;
    if (!present_multi_pixel &&
        (h_de > kRouteBHostContentMaxW || v_de > kRouteBHostContentMaxH))
        return false;
    if (routeBActivePixelsPerSec(h_de, v_de, fps) > kRouteBPixelClockHz)
        return false;
    if (routeBTotalPixelsPerSec(h_de, v_de, fps) > kRouteBPixelClockHz)
        return false;
    return true;
}

// Host may emit this coded/store size under Route-B defaults (fps=24 class).
inline bool routeBHostMayEmitContentSize(int w, int h, int fps = 24,
                                         bool present_multi_pixel = false) {
    return routeBContentDeFitsFps(w, h, fps, present_multi_pixel);
}

// Clamp coded WxH down to Route-B host cap. Returns true when clamped.
// multi_pixel: no clamp (caller owns 1280 DE).
inline bool clampCodedSizeToRouteBHostCap(int& w, int& h,
                                          bool present_multi_pixel = false) {
    if (present_multi_pixel || w <= 0 || h <= 0)
        return false;
    if (w <= kRouteBHostContentMaxW && h <= kRouteBHostContentMaxH)
        return false;
    w = kRouteBHostContentMaxW;
    h = kRouteBHostContentMaxH;
    return true;
}

inline const char* playDeliveryRegimeName(PlayDeliveryRegime r) {
    switch (r) {
    case PlayDeliveryRegime::DirectPlaySd:
        return "direct_play_sd";
    case PlayDeliveryRegime::TranscodeHd720:
        return "transcode_hd_720";
    case PlayDeliveryRegime::ForceUniversal:
        return "force_universal";
    default:
        return "unknown";
    }
}

// True when library media exceeds product content ceiling (needs down-xcode).
// >1280×720 → universal 720p tier. Exact 1280×720 is DP-eligible (rk=7).
// present_multi_pixel retained for API compat; ceiling is always kPmsContent*.
inline bool mediaExceedsRouteBHostContentCap(int media_w, int media_h,
                                             bool present_multi_pixel = false) {
    (void)present_multi_pixel;
    if (media_w <= 0 || media_h <= 0)
        return false;
    return media_w > kPmsContentMaxW || media_h > kPmsContentMaxH;
}

// True when media is strictly above 1280×720 (full-HD+ needs down-xcode).
inline bool mediaIsHdAbove720p(int media_w, int media_h) {
    return mediaExceedsRouteBHostContentCap(media_w, media_h, /*multi*/ false);
}

// Select regime from *item* geometry (and optional allow_direct). Profile main/high
// does not force xcode here — DP preserves bits; fabric gate → ARM fallback.
inline PlayDeliveryRegime selectPlayDeliveryRegime(int media_w, int media_h,
                                                   bool allow_direct_h264,
                                                   bool source_is_h264,
                                                   bool present_multi_pixel = false) {
    if (!source_is_h264)
        return PlayDeliveryRegime::ForceUniversal;
    if (mediaExceedsRouteBHostContentCap(media_w, media_h, present_multi_pixel))
        return PlayDeliveryRegime::TranscodeHd720;
    if (allow_direct_h264)
        return PlayDeliveryRegime::DirectPlaySd;
    return PlayDeliveryRegime::ForceUniversal;
}

// Product HD xcode target = real 720p PMS tier (parent top priority 2026-08-03).
// present_multi_pixel ignored for target size — always 1280×720 / "720p".
// Returns profile name; fills request/store WxH.
inline const char* routeBHdTranscodeTargetSize(bool present_multi_pixel, int* out_w,
                                              int* out_h) {
    (void)present_multi_pixel;
    if (out_w)
        *out_w = kPmsContentMaxW;
    if (out_h)
        *out_h = kPmsContentMaxH;
    return "720p";
}

// Default decision/start ceiling when conf left videoResolution empty = 720p.
inline const char* routeBDefaultDecisionResolution(bool present_multi_pixel) {
    (void)present_multi_pixel;
    return "1280x720";
}

// Content/store size legal for product PMS ladder (≤1280×720). Separate from
// 1ppc beam DE math (routeBContentDeFitsFps) — do not conflate.
inline bool routeBResolvedSizeLegal(int coded_w, int coded_h, int fps = 24,
                                    bool present_multi_pixel = false) {
    (void)fps;
    (void)present_multi_pixel;
    if (coded_w <= 0 || coded_h <= 0)
        return false;
    return coded_w <= kPmsContentMaxW && coded_h <= kPmsContentMaxH;
}

// PMS may tweak an already 16-aligned request by ±2 (MB) — measured class:
// 624x352 request → 626x352 delivery. Aligned request ≠ aligned delivery guarantee.
// Universal path must keep ARM scale/pad until measured geometry is known.
inline bool pmsMayTweakAlignedRequestDelivery() { return true; }

// ---- Source-aware PMS request (w-mem rt_raw_ok contract) --------------------
//
// Parent 2026-08-04 (cross-lane): fixed ladder rungs AR-fit the majority library
// class 624x480 into 640x360 → delivered 468x360 (468%16=4). w-mem store requires
// coded_w%16==0 and even height; else rt_raw_ok=0 and geom falls back / rejects.
//
// PMS never upscales (measured). Requesting the source's own geometry (clamped to
// the product max box) avoids AR-fit that manufactures non-aligned widths.
// Request width is snapped DOWN to a multiple of 16; height even-floored.
//
// 426x240 class (4 items): native W not 16-aligned. Floor-snap → 416x240. Host
// must still verify delivery; if PMS keeps 426, store needs align-up pad (host).
//
// IMPORTANT (rd-duck): this helper only selects the **target bank / request**.
// Universal remains path_scale_class=arm_scale_fallback — delivery_verified=0,
// force-scale ON, vf frozen pre-banner. Parent ±2 tweak (624x352→626x352) means
// an aligned request can still yield unaligned delivery. Do NOT count source_snap
// as "ARM scaling removed" / fabric_native.

inline int alignWidthDown16(int w) {
    if (w < 16)
        return 16;
    return w - (w % 16);
}

inline int alignWidthUp16(int w) {
    if (w <= 0)
        return 16;
    return (w + 15) & ~15;
}

inline int evenFloorHeight(int h) {
    if (h < 2)
        return 2;
    return h & ~1;
}

// w-mem ddr_frame_store.sv: rt_raw_aligned = (coded_w[3:0]==0) && !coded_h[0] ...
inline bool isFabricStoreAligned(int coded_w, int coded_h) {
    return coded_w > 0 && coded_h > 0 && (coded_w % 16) == 0 && (coded_h % 2) == 0;
}

// Pad (never crop) a delivered/coded size so the fabric store accepts it.
inline void alignGeometryForFabricStore(int in_w, int in_h, int& out_w, int& out_h) {
    out_w = alignWidthUp16(in_w);
    out_h = evenFloorHeight(in_h);
    if (out_h < in_h)
        out_h = evenFloorHeight(in_h + 1); // even-ceil if odd source
    if ((out_h % 2) != 0)
        ++out_h;
}

struct SourceAwarePmsRequest {
    int request_w = 0;
    int request_h = 0;
    int store_w = 0; // bank / PLXG coded — always fabric-aligned
    int store_h = 0;
    std::string videoResolution; // "WxH" for universal URL
    bool host_may_need_pad = false; // source W was not 16-aligned
    const char* policy = "none";
};

// Direct Play Part: container samples ARE delivery (no PMS AR-fit). Bank =
// pad-only align-up of media WxH — NEVER floor-snap (that is the universal
// request path; floor 426→416 would mismatch Part 426×240 samples).
//   320×240 → store 320×240
//   426×240 → store 432×240  (pad; 426%16=10)
//   720×480 → store 720×480
// rd-duck 2026-08-03: DP early-return must set store_* or main keeps tier canvas.
inline SourceAwarePmsRequest selectDirectPartStoreGeometry(int media_w, int media_h) {
    SourceAwarePmsRequest o;
    if (media_w <= 0 || media_h <= 0) {
        o.policy = "direct_part_no_media";
        return o;
    }
    o.request_w = media_w;
    o.request_h = media_h;
    o.host_may_need_pad = !isFabricStoreAligned(media_w, media_h);
    if (!o.host_may_need_pad) {
        o.store_w = media_w;
        o.store_h = media_h;
        o.policy = "direct_part_native";
    } else {
        alignGeometryForFabricStore(media_w, media_h, o.store_w, o.store_h);
        o.policy = "direct_part_native_pad";
    }
    o.videoResolution = std::to_string(media_w) + "x" + std::to_string(media_h);
    return o;
}

// src_* = library Media/Stream size (0 = unknown).
// max_* = product ceiling from content tier (e.g. 960x540). 0 = no clamp.
inline SourceAwarePmsRequest selectSourceAwarePmsRequest(int src_w, int src_h, int max_w,
                                                         int max_h) {
    SourceAwarePmsRequest o;
    int w = src_w;
    int h = src_h;
    if (w <= 0 || h <= 0) {
        // No source meta — fall back to max box snapped (legacy ladder behaviour).
        w = max_w > 0 ? max_w : 960;
        h = max_h > 0 ? max_h : 540;
        o.policy = "max_box_fallback";
    } else {
        o.policy = "source_clamp_snap16";
        // Clamp into max box without upscaling (AR-preserving down only).
        if (max_w > 0 && max_h > 0 && (w > max_w || h > max_h)) {
            const double sw = static_cast<double>(max_w) / static_cast<double>(w);
            const double sh = static_cast<double>(max_h) / static_cast<double>(h);
            const double s = sw < sh ? sw : sh;
            w = static_cast<int>(std::floor(static_cast<double>(w) * s));
            h = static_cast<int>(std::floor(static_cast<double>(h) * s));
            o.policy = "source_clamp_to_max_snap16";
        }
    }
    if (w < 16)
        w = 16;
    if (h < 2)
        h = 2;

    // Measured 426x240 class (rk69, 2026-08-04 prove align-check):
    //   request 426 → deliv 426 (w%16=10) STORE REJECT
    //   request 432 → deliv 426 (no upscale) STORE REJECT
    //   request 416 → deliv 416x234 (aligned) — floor-snap + AR-fit height
    // rd-duck: store must track measured 416x234, not claim 416x240.
    o.host_may_need_pad = (src_w > 0) && ((src_w % 16) != 0);
    o.request_w = alignWidthDown16(w);
    o.request_h = evenFloorHeight(h);
    // When width floor-snap shrinks the box, PMS AR-fits into the new ceiling
    // (never upscales). Predict delivered height so store matches measurement.
    if (src_w > 0 && src_h > 0 && o.request_w < src_w) {
        const double ar = static_cast<double>(src_w) / static_cast<double>(src_h);
        if (ar > 0.0) {
            int h_fit = static_cast<int>(std::floor(static_cast<double>(o.request_w) / ar));
            h_fit = evenFloorHeight(h_fit);
            if (h_fit > 0 && h_fit <= o.request_h)
                o.request_h = h_fit;
        }
    }
    // Bank = request when already fabric-aligned; else pad (runtime caller of
    // alignGeometryForFabricStore — was previously dead code).
    if (isFabricStoreAligned(o.request_w, o.request_h)) {
        o.store_w = o.request_w;
        o.store_h = o.request_h;
    } else {
        alignGeometryForFabricStore(o.request_w, o.request_h, o.store_w, o.store_h);
        o.host_may_need_pad = true;
        o.policy = "source_snap_store_pad";
    }
    o.videoResolution =
        std::to_string(o.request_w) + "x" + std::to_string(o.request_h);
    return o;
}

// I420 byte payload for bank capacity checks (no stride pad).
inline std::uint32_t i420PayloadBytes(int w, int h) {
    if (w <= 0 || h <= 0)
        return 0;
    return static_cast<std::uint32_t>(w) * static_cast<std::uint32_t>(h) * 3u / 2u;
}

// w-mem LEG_BANK_USABLE_BYTES = 0x7F000 = 520192 (quoted ddr_frame_store.sv).
inline constexpr std::uint32_t kLegBankUsableBytes = 520192u;

inline bool i420FitsLegacyBank(int w, int h) {
    return i420PayloadBytes(w, h) <= kLegBankUsableBytes;
}

} // namespace misterplex
