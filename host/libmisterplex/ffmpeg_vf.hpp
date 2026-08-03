// FFmpeg -vf construction for misterplexd STREAM=0 rawvideo path.
// Pure header (no I/O): unit-tested so filter policy cannot drift silently.
//
// SkipIdentity may omit scale+pad ONLY when delivery geometry is VERIFIED equal
// to the coded bank (or lab ASSUME_MATCH). A bare PMS videoResolution *request*
// is NOT verification — PMS upperBound limits are ceilings, not exact sizes.
// Silicon (c5382bee): identity_skip at DECODE=624x480 with delivery_basis=
// transcode_request desynced the raw pipe (wrap + magenta + defect B). Force
// scale fixed both colour and throughput. parseFfmpegScaleMode empty/unknown →
// Always (safe for callers that omit conf).
#pragma once

#include <algorithm>
#include <cctype>
#include <cstdint>
#include <cstdio>
#include <string>

namespace misterplex {

// How the scale/pad stage is chosen.
//   Always        — always emit scale+pad.
//   SkipIdentity  — omit scale+pad only when source WxH equals coded WxH AND
//                   delivery_geometry_verified (or assume_source_matches_coded).
//                   Display-crop geometry is then handled by clearYuv420pCropPadding
//                   on the present path, not by a 624→618→624 swscale round-trip.
//   Off           — never emit scale+pad (lab only; wrong if sizes mismatch).
enum class FfmpegScaleMode { Always, SkipIdentity, Off };

inline const char* ffmpegScaleModeName(FfmpegScaleMode m) {
    switch (m) {
    case FfmpegScaleMode::Always:
        return "always";
    case FfmpegScaleMode::SkipIdentity:
        return "skip_identity";
    case FfmpegScaleMode::Off:
        return "off";
    }
    return "always";
}

// Parse conf token. Empty/unknown → Always (conservative for bare callers).
// misterplexd itself defaults conf to skip_identity before calling this.
inline FfmpegScaleMode parseFfmpegScaleMode(const std::string& raw) {
    if (raw.empty())
        return FfmpegScaleMode::Always;
    if (raw == "always" || raw == "on" || raw == "1" || raw == "true" || raw == "yes")
        return FfmpegScaleMode::Always;
    if (raw == "skip_identity" || raw == "skip-identity" || raw == "auto" || raw == "skip")
        return FfmpegScaleMode::SkipIdentity;
    if (raw == "off" || raw == "never" || raw == "none" || raw == "0" || raw == "false" ||
        raw == "no")
        return FfmpegScaleMode::Off;
    return FfmpegScaleMode::Always;
}

// Allow-list for -vf scale flags=. Empty string = omit :flags= (ffmpeg default algo).
// Reject anything that is not a simple ffmpeg sws flag token / flag+flag combo.
inline bool swsFlagsTokenOk(const std::string& flags) {
    if (flags.empty())
        return true;
    // ffmpeg accepts names like fast_bilinear, bilinear, bicubic, neighbor, area,
    // bicublin, gauss, sinc, lanczos, spline, and + combinations. Keep charset tight.
    for (char c : flags) {
        const bool ok = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
                        (c >= '0' && c <= '9') || c == '_' || c == '+' || c == '-';
        if (!ok)
            return false;
    }
    return flags.size() <= 64;
}

struct FfmpegVfRequest {
    int coded_w = 0;
    int coded_h = 0;
    int display_w = 0; // visible width before coded pad; 0 → coded_w
    int display_h = 0;
    int crop_left = 0;
    int crop_top = 0;
    // Optional leading fps= filter fragment without trailing comma (e.g. "fps=24000/1001").
    std::string fps_filter;
    FfmpegScaleMode scale_mode = FfmpegScaleMode::Always;
    // Empty = do not append :flags= (today's behaviour). Example: "fast_bilinear".
    std::string sws_flags;
    // Decoded bitstream size if known (0 = unknown). Used by SkipIdentity.
    int source_w = 0;
    int source_h = 0;
    // When source is unknown, SkipIdentity may still omit scale if this is true
    // (lab: trust PMS ladder delivered the coded tier). Default false = safe.
    bool assume_source_matches_coded = false;
    // True only when source_w/h are VERIFIED delivered geometry (library Media
    // WxH on direct play, or a measured probe). False for PMS transcode_request
    // (what we asked for) — numeric equality alone must not identity-skip.
    bool delivery_geometry_verified = false;
};

struct FfmpegVfPlan {
    std::string vf;          // full -vf argument (may be empty)
    bool scale_applied = false;
    bool identity_skip = false;
    // When true, vf pins every output frame to coded WxH (scale=cw:ch). Safe if
    // the input geometry changes mid-stream: ffmpeg emits whole frames at fixed
    // size — raw reader cannot assemble a mixed old/new raster. stderr abort is
    // then diagnostic only, not the correctness interlock (rd-duck 2026-08-03).
    // identity_skip (empty vf / raw unprotected) must stay false when this is set.
    bool fixed_output_barrier = false;
    std::string reason;      // short machine token for logs
};

// Fixed-size pin for "content identity" paths. neighbor keeps cost low when
// input already matches; if input shrinks/grows, output bytes stay coded WxH.
inline std::string fixedOutputBarrierFilter(int coded_w, int coded_h) {
    return "scale=" + std::to_string(coded_w) + ":" + std::to_string(coded_h) +
           ":flags=neighbor";
}

// Build scale=WxH with optional :flags= after the geometry token and before
// force_original_aspect_ratio (ffmpeg accepts both orders; keep flags early).
inline std::string scaleFilterGeom(const std::string& wh, const std::string& sws_flags) {
    std::string s = "scale=" + wh;
    if (!sws_flags.empty() && swsFlagsTokenOk(sws_flags))
        s += ":flags=" + sws_flags;
    return s;
}

// Integer model of ffmpeg scale=box_w:box_h:force_original_aspect_ratio=decrease
// (fits inside box; may upscale). s = min(box_w/src_w, box_h/src_h).
// Width-limited: out_w=box_w, out_h=floor(src_h*box_w/src_w).
// Height-limited: out_h=box_h, out_w=floor(src_w*box_h/src_h).
// Product defect class: src 624x480 into box 618x480 → out_h = 480*618/624 = 475.
inline int scaleDecreaseOutHeight(int src_w, int src_h, int box_w, int box_h) {
    if (src_w <= 0 || src_h <= 0 || box_w <= 0 || box_h <= 0)
        return 0;
    // width-limited when box_w/src_w <= box_h/src_h
    if (static_cast<long long>(box_w) * static_cast<long long>(src_h) <=
        static_cast<long long>(box_h) * static_cast<long long>(src_w)) {
        return static_cast<int>((static_cast<long long>(src_h) * box_w) / src_w);
    }
    return box_h;
}

inline int scaleDecreaseOutWidth(int src_w, int src_h, int box_w, int box_h) {
    if (src_w <= 0 || src_h <= 0 || box_w <= 0 || box_h <= 0)
        return 0;
    if (static_cast<long long>(box_w) * static_cast<long long>(src_h) <=
        static_cast<long long>(box_h) * static_cast<long long>(src_w)) {
        return box_w;
    }
    return static_cast<int>((static_cast<long long>(src_w) * box_h) / src_h);
}

// Delivered samples as fraction of coded bank (Loss 2: PMS half-res 312x240 → 0.5 V).
inline double deliveredVerticalDetailFrac(int delivered_h, int bank_h) {
    if (bank_h <= 0 || delivered_h <= 0)
        return 0.0;
    return static_cast<double>(delivered_h) / static_cast<double>(bank_h);
}

inline double deliveredAreaFrac(int delivered_w, int delivered_h, int bank_w, int bank_h) {
    if (bank_w <= 0 || bank_h <= 0 || delivered_w <= 0 || delivered_h <= 0)
        return 0.0;
    const double d = static_cast<double>(delivered_w) * static_cast<double>(delivered_h);
    const double b = static_cast<double>(bank_w) * static_cast<double>(bank_h);
    return d / b;
}

// Compound: real source rows retained after delivery *and* FOAR letterbox.
// e.g. 312x240 FOAR-fills bank → delivered_v=0.5, filter_v≈1 → compound=0.5
//      624x480 FOAR-into-618 16:9 → delivered_v=1, filter_v≈0.725 → compound≈0.725
inline double compoundVerticalDetailFrac(double delivered_v_frac, double filter_v_frac) {
    if (delivered_v_frac <= 0.0 || filter_v_frac <= 0.0)
        return 0.0;
    return delivered_v_frac * filter_v_frac;
}

// True when decrease-into-box would change vertical sample count (any axis shrink
// that is width-limited with s<1, or height-limited with box_h < src_h).
inline bool scaleDecreaseResamplesHeight(int src_w, int src_h, int box_w, int box_h) {
    if (src_h <= 0)
        return false;
    return scaleDecreaseOutHeight(src_w, src_h, box_w, box_h) != src_h;
}

// Gate predicate: a vf string for a source already at bank height must not run
// force_original_aspect_ratio=decrease (both axes share min(sx,sy)) and must not
// scale= at all — crop+pad (or empty/fps-only) only. Used by unit gate so the
// 624→618→475 class cannot regress silently.
inline bool vfPreservesBankHeightSource(const std::string& vf) {
    if (vf.find("force_original_aspect_ratio=decrease") != std::string::npos)
        return false;
    if (vf.find("scale=") != std::string::npos)
        return false;
    return true;
}

// Canonical product scale+pad strings — freeze tests pin these shapes.
// LEGACY: FOAR-decrease into the *display* box (product 618x480) then pad to
// coded 624x480. Kept for unit mutation/red tests and historical string pins.
//
// PRODUCT MUST NOT use this for the non-exact Always path anymore (see
// buildFfmpegVideoFilter): FOAR into 618 applies min(sx,sy) and destroys rows —
// parent 2026-08-02: PMS delivers 624x480 for rk6 AND rk36; our vf
// scale=618:480:FOAR=decrease is what produces ~350 real rows for 16:9 DAR
// (and ~464 for 4:3). Display crop_right=6 belongs at present/RTL
// (clearYuv420pCropPadding), not as a swscale target.
//
// LEGACY string builder only. Product Always+unverified exact claim uses
// buildScalePadCoded (FOAR into coded). crop+pad is for verified exact or hfit.
inline std::string buildScalePadCropped(int display_w, int display_h, int coded_w, int coded_h,
                                        int crop_left, int crop_top,
                                        const std::string& sws_flags) {
    const std::string displayScale =
        std::to_string(display_w) + ":" + std::to_string(display_h);
    const std::string scale = std::to_string(coded_w) + ":" + std::to_string(coded_h);
    // pad x = crop_left + (display_w - iw)/2 ; y = crop_top + (display_h - ih)/2
    const std::string padX = std::to_string(crop_left) + "+(" + std::to_string(display_w) +
                             "-iw)/2";
    const std::string padY = std::to_string(crop_top) + "+(" + std::to_string(display_h) +
                             "-ih)/2";
    return scaleFilterGeom(displayScale, sws_flags) +
           ":force_original_aspect_ratio=decrease,pad=" + scale + ":" + padX + ":" + padY +
           ":color=black";
}

// Horizontal display crop + pad back to coded bank — zero vertical resample.
// Caller enforces source_h == display_h == coded_h and source_w >= display_w.
//
// crop_x:
//   - exact coded width (source_w == coded_w): fixed crop_left (product 0 →
//     leftmost display_w; right strip = crop_right).
//   - wider than coded (e.g. 640x480): center-crop with ffmpeg expr so the
//     visible window is taken from the source middle without any scale.
// After crop, iw=display_w so pad x collapses to crop_left.
inline std::string buildCropPadNoScale(int display_w, int display_h, int coded_w, int coded_h,
                                       int crop_left, int crop_top,
                                       int source_w = 0) {
    const bool centerInSource = source_w > coded_w;
    const std::string cropX =
        centerInSource ? ("(iw-" + std::to_string(display_w) + ")/2")
                       : std::to_string(crop_left);
    const std::string crop = "crop=" + std::to_string(display_w) + ":" +
                             std::to_string(display_h) + ":" + cropX + ":" +
                             std::to_string(crop_top);
    const std::string padX = std::to_string(crop_left) + "+(" + std::to_string(display_w) +
                             "-iw)/2";
    const std::string padY = std::to_string(crop_top) + "+(" + std::to_string(display_h) +
                             "-ih)/2";
    return crop + ",pad=" + std::to_string(coded_w) + ":" + std::to_string(coded_h) + ":" +
           padX + ":" + padY + ":color=black";
}

inline std::string buildScalePadCentered(int coded_w, int coded_h,
                                         const std::string& sws_flags) {
    const std::string scale = std::to_string(coded_w) + ":" + std::to_string(coded_h);
    // Historical product string omits :color=black on the centred pad path
    // (crop path keeps color=black). Do not "fix" that here — default must match.
    return scaleFilterGeom(scale, sws_flags) +
           ":force_original_aspect_ratio=decrease,pad=" + scale + ":(ow-iw)/2:(oh-ih)/2";
}

// Floor to even (FFmpeg yuv420p pad x/y chroma alignment).
inline int padInsetChromaEven(int ideal_inset) {
    if (ideal_inset < 0)
        return 0;
    return ideal_inset & ~1;
}

// Integer model of FFmpeg pad placement for even YUV420 dims.
// Ideal center = (coded-src)/2, then chroma-floor-even (matches measured
// pad=W:H:(ow-iw)/2 on yuv420p: 426→432 → pad_x=2, not 3).
// rd-duck 2026-08-03: naive /2 oracle (x=3) fails real FFmpeg raw output.
inline bool padOnlyInsets(int src_w, int src_h, int coded_w, int coded_h, int* pad_x,
                          int* pad_y) {
    if (!pad_x || !pad_y)
        return false;
    if (src_w <= 0 || src_h <= 0 || coded_w <= 0 || coded_h <= 0)
        return false;
    if ((src_w & 1) || (src_h & 1) || (coded_w & 1) || (coded_h & 1))
        return false;
    if (src_w > coded_w || src_h > coded_h)
        return false;
    *pad_x = padInsetChromaEven((coded_w - src_w) / 2);
    *pad_y = padInsetChromaEven((coded_h - src_h) / 2);
    return true;
}

// Right/bottom residual pad (may be larger than left when chroma-snapped).
inline bool padOnlyResiduals(int src_w, int src_h, int coded_w, int coded_h, int* right,
                             int* bottom) {
    int px = 0, py = 0;
    if (!padOnlyInsets(src_w, src_h, coded_w, coded_h, &px, &py) || !right || !bottom)
        return false;
    *right = coded_w - src_w - px;
    *bottom = coded_h - src_h - py;
    return *right >= 0 && *bottom >= 0;
}

// Pure horizontal/vertical pad into the coded bank — NO scale= (no swscale).
// Direct Part store align-up (426×240 → 432×240) must use this; FOAR scale would
// resample every sample even when H already matches (rd-duck 2026-08-03).
// Emit **explicit even insets** so PLXG/present crop math matches raw output.
inline std::string buildPadOnlyNoScale(int coded_w, int coded_h, int pad_x, int pad_y) {
    return "pad=" + std::to_string(coded_w) + ":" + std::to_string(coded_h) + ":" +
           std::to_string(pad_x) + ":" + std::to_string(pad_y) + ":color=black";
}

inline std::string buildPadOnlyNoScaleForSource(int src_w, int src_h, int coded_w,
                                                int coded_h) {
    int px = 0, py = 0;
    if (!padOnlyInsets(src_w, src_h, coded_w, coded_h, &px, &py))
        return buildPadOnlyNoScale(coded_w, coded_h, 0, 0);
    return buildPadOnlyNoScale(coded_w, coded_h, px, py);
}

// Y-plane pad model: source columns copied unchanged at chroma-aligned inset.
// Used by unit tests; must match buildPadOnlyNoScale explicit x/y.
inline bool padYPlaneCopyUnchanged(const uint8_t* src, int src_w, int src_h, uint8_t* dst,
                                   int coded_w, int coded_h) {
    if (!src || !dst)
        return false;
    int pad_x = 0, pad_y = 0;
    if (!padOnlyInsets(src_w, src_h, coded_w, coded_h, &pad_x, &pad_y))
        return false;
    const size_t dst_bytes = static_cast<size_t>(coded_w) * static_cast<size_t>(coded_h);
    std::fill(dst, dst + dst_bytes, static_cast<uint8_t>(0));
    for (int y = 0; y < src_h; ++y) {
        const uint8_t* srow = src + static_cast<size_t>(y) * static_cast<size_t>(src_w);
        uint8_t* drow =
            dst + static_cast<size_t>(y + pad_y) * static_cast<size_t>(coded_w) +
            static_cast<size_t>(pad_x);
        std::copy(srow, srow + src_w, drow);
    }
    return true;
}

// Numeric WxH match is necessary but not sufficient for identity_skip.
// Unverified "we requested 624x480" must NOT skip — PMS may deliver 640x480
// (or any ≤ upperBound), and the raw reader then desyncs at coded frameBytes.
inline bool sourceMatchesCoded(const FfmpegVfRequest& req) {
    if (req.coded_w <= 0 || req.coded_h <= 0)
        return false;
    if (req.assume_source_matches_coded && !(req.source_w > 0 && req.source_h > 0))
        return true; // lab: unknown dims + explicit assume
    if (req.source_w <= 0 || req.source_h <= 0)
        return false;
    if (req.source_w != req.coded_w || req.source_h != req.coded_h)
        return false;
    // Exact numbers only count when delivery was verified (or lab assume).
    return req.delivery_geometry_verified || req.assume_source_matches_coded;
}

// Byte-phase model for a fixed-size rawvideo reader against a producer whose
// per-frame size differs. After frame_index completed reads of reader_bytes from
// a stream of producer_bytes frames, returns the byte offset into the current
// producer frame (0 = still aligned). Used by the desync gate.
inline size_t rawPipePhaseOffset(size_t producer_frame_bytes, size_t reader_frame_bytes,
                                 size_t frame_index) {
    if (producer_frame_bytes == 0)
        return 0;
    const size_t consumed = frame_index * reader_frame_bytes;
    return consumed % producer_frame_bytes;
}

inline bool rawPipeDesynced(size_t producer_frame_bytes, size_t reader_frame_bytes,
                            size_t frame_index) {
    if (producer_frame_bytes == reader_frame_bytes)
        return false;
    return rawPipePhaseOffset(producer_frame_bytes, reader_frame_bytes, frame_index) != 0 ||
           frame_index > 0;
}

// Capture discriminator (B1): N legible frame-counter copies in one *reader*
// raster ⇒ producer frame size ≈ reader_bytes / N.
// Example: N=2 TREK24 copies in a 449280-byte bank ⇒ S≈224640 = 624x240 I420.
// 640x480=460800 > reader cannot place two full producer frames in one raster
// (wrong sign for the historical N=2 silicon story).
inline size_t producerBytesFromCounterCopies(size_t reader_frame_bytes, int n_copies) {
    if (n_copies <= 0 || reader_frame_bytes == 0)
        return 0;
    return reader_frame_bytes / static_cast<size_t>(n_copies);
}

// Runtime risk: identity_skip (or any path that reads fixed reader_bytes) while the
// producer frame size differs. The STREAM=0 loop always reads exactly reader_bytes
// per frame, so totalBytes % reader_bytes stays 0 even while the pipe desyncs —
// remainder checks alone cannot see this class. Compare measured producer size.
inline bool pipeDesyncRisk(size_t producer_frame_bytes, size_t reader_frame_bytes,
                           bool identity_skip) {
    if (producer_frame_bytes == 0 || reader_frame_bytes == 0)
        return false;
    if (producer_frame_bytes == reader_frame_bytes)
        return false;
    return identity_skip;
}

// --- Identity/native mid-stream geometry fail-closed (rd-duck 2026-08-03) ---
// Play-time vf cannot rebuild after measurement changes. Under *raw*
// identity_skip (empty vf) the reader still chunks fixed frameBytes — a
// producer size change shears the pipe and can publish mixed frames.
// stderr observation races the stdout reader and CANNOT be the interlock.
//
// Correctness barrier (product default): buildFfmpegVideoFilter emits a
// fixed-output pin (fixed_output_barrier=1, identity_skip=0) on former
// identity paths so every raw frame is coded WxH. Fail-closed below only
// applies to residual raw identity_skip (scale_mode=off / lab).
// Policy: on measured mismatch OR mid-stream change while identity_skip →
// abort session and publish NO further frames until FFmpeg restart with a new
// measured geometry. fixed_output_barrier / force-scale → Continue.
enum class IdentityGeomFailClosedAction : uint8_t {
    Continue = 0,
    AbortNoPublish = 1,
};

struct IdentityGeomFailClosed {
    IdentityGeomFailClosedAction action = IdentityGeomFailClosedAction::Continue;
    bool allow_publish = true;
    const char* reason = "ok";
};

// fixed_output_barrier makes mid-stream size change safe (ffmpeg re-scales each
// whole frame). Pass barrier=true for product identity-class plans.
inline IdentityGeomFailClosed identitySkipGeomFailClosed(bool identity_skip, int reader_w,
                                                         int reader_h, int measured_w,
                                                         int measured_h,
                                                         bool mid_stream_change,
                                                         bool fixed_output_barrier = false) {
    IdentityGeomFailClosed d;
    if (fixed_output_barrier || !identity_skip) {
        d.reason = fixed_output_barrier ? "fixed_output_barrier_safe" : "arm_scale_fallback_safe";
        return d;
    }
    if (measured_w <= 0 || measured_h <= 0) {
        d.reason = "awaiting_measurement";
        return d;
    }
    // Mid-stream change is always fatal under identity — even before byte compare
    // (banner race / SPS change class). Mutation: 624x480 → 320x240.
    if (mid_stream_change) {
        d.action = IdentityGeomFailClosedAction::AbortNoPublish;
        d.allow_publish = false;
        d.reason = "identity_mid_stream_geom_change";
        return d;
    }
    if (measured_w != reader_w || measured_h != reader_h) {
        d.action = IdentityGeomFailClosedAction::AbortNoPublish;
        d.allow_publish = false;
        d.reason = "identity_measured_ne_reader";
        return d;
    }
    d.reason = "identity_geom_match";
    return d;
}

// Sticky publish gate: once aborted, zero post-change publishes until restart.
inline bool identitySkipMayPublish(bool already_aborted, const IdentityGeomFailClosed& d) {
    if (already_aborted)
        return false;
    return d.allow_publish;
}

// Convenience: byte-level identity desync ⇒ fail-closed (same as WxH mismatch).
inline IdentityGeomFailClosed identitySkipGeomFailClosedBytes(bool identity_skip,
                                                              size_t reader_frame_bytes,
                                                              size_t producer_frame_bytes,
                                                              bool mid_stream_change,
                                                              bool fixed_output_barrier = false) {
    if (fixed_output_barrier || !identity_skip) {
        IdentityGeomFailClosed d;
        d.reason = fixed_output_barrier ? "fixed_output_barrier_safe" : "arm_scale_fallback_safe";
        return d;
    }
    if (mid_stream_change) {
        IdentityGeomFailClosed d;
        d.action = IdentityGeomFailClosedAction::AbortNoPublish;
        d.allow_publish = false;
        d.reason = "identity_mid_stream_geom_change";
        return d;
    }
    if (producer_frame_bytes == 0 || reader_frame_bytes == 0) {
        IdentityGeomFailClosed d;
        d.reason = "awaiting_measurement";
        return d;
    }
    if (producer_frame_bytes != reader_frame_bytes) {
        IdentityGeomFailClosed d;
        d.action = IdentityGeomFailClosedAction::AbortNoPublish;
        d.allow_publish = false;
        d.reason = "identity_measured_ne_reader";
        return d;
    }
    IdentityGeomFailClosed d;
    d.reason = "identity_geom_match";
    return d;
}

// Model the stdout/stderr race rd-duck named: N frames may already be fully
// read before stderr sets abort. A pure atomic check at present entry cannot
// un-mix those bytes. Returns how many frames a barrier-less reader could still
// publish after the producer size changed at frame `change_at` while abort is
// only observed at `abort_observed_at` (abort_observed_at >= change_at).
inline int identityRawRacePublishWindow(int change_at, int abort_observed_at) {
    if (abort_observed_at < change_at)
        return 0;
    return abort_observed_at - change_at + 1; // inclusive frames that may be mixed/wrong
}

// I420 packed size (same as ddr_frame_layout yuv420pFrameBytes but local for
// ffmpeg_vf tests that do not include ddr headers).
inline size_t yuv420pFrameBytesWH(int w, int h) {
    if (w <= 0 || h <= 0 || (w & 1) || (h & 1))
        return 0;
    return static_cast<size_t>(w) * static_cast<size_t>(h) * 3u / 2u;
}

// Parse one ffmpeg stderr/info line for a video WxH.
// Matches Input/Output "Stream #... Video: ... 640x480" style banners.
// Returns true and sets out_w/out_h on the first WxH after "Video:".
struct FfmpegGeometryLine {
    bool ok = false;
    int w = 0;
    int h = 0;
    bool is_input = false;
    bool is_output = false;
    bool is_video = false;
};

inline FfmpegGeometryLine parseFfmpegGeometryLine(const std::string& line) {
    FfmpegGeometryLine g;
    if (line.find("Video:") == std::string::npos && line.find("video:") == std::string::npos)
        return g;
    g.is_video = true;
    if (line.find("Input #") != std::string::npos || line.find("Stream #0:") != std::string::npos)
        g.is_input = (line.find("Output") == std::string::npos);
    if (line.find("Output #") != std::string::npos)
        g.is_output = true;
    // Prefer the first NNNNxNNNN token (coded dimensions). Ignore SAR like 1:1.
    for (size_t i = 0; i + 3 < line.size(); ++i) {
        if (!std::isdigit(static_cast<unsigned char>(line[i])))
            continue;
        int w = 0, h = 0, n = 0;
        if (std::sscanf(line.c_str() + i, "%dx%d%n", &w, &h, &n) == 2 && w >= 16 && h >= 16 &&
            w <= 7680 && h <= 4320) {
            // Reject obvious fps-like 24x1 or bitrates; require even YUV dims.
            if ((w & 1) == 0 && (h & 1) == 0) {
                g.ok = true;
                g.w = w;
                g.h = h;
                // Input vs output: Output section lines often contain "Output #0"
                // earlier in the buffer; per-line, " -> " maps are not geometry.
                if (line.find("Output") != std::string::npos)
                    g.is_output = true;
                return g;
            }
            i += static_cast<size_t>(n > 0 ? n : 1);
        }
    }
    return g;
}

// Session-end align check. Complete frames always yield remainder 0 by construction
// of the read loop; a non-zero remainder means EOF mid-frame (shortRead) OR a bug
// that counted bytes outside the frame loop. Still useful as a hard assert.
inline bool rawPipeByteAligned(size_t total_bytes, size_t reader_frame_bytes) {
    if (reader_frame_bytes == 0)
        return true;
    return (total_bytes % reader_frame_bytes) == 0;
}

// Pixel-format conversion is NOT expressed here — misterplexd uses -pix_fmt on the
// rawvideo output. That keeps format conversion out of the scale/resample path.
inline FfmpegVfPlan buildFfmpegVideoFilter(const FfmpegVfRequest& req) {
    FfmpegVfPlan plan;
    std::string vf = req.fps_filter;
    const int dispW = req.display_w > 0 ? req.display_w : req.coded_w;
    const int dispH = req.display_h > 0 ? req.display_h : req.coded_h;
    const bool hasCrop = (dispW != req.coded_w || dispH != req.coded_h);

    const auto append = [&](const std::string& piece) {
        if (piece.empty())
            return;
        if (!vf.empty())
            vf.push_back(',');
        vf += piece;
    };

    auto finish = [&](bool scaled, bool skipped, const char* reason, bool barrier = false) {
        plan.vf = std::move(vf);
        plan.scale_applied = scaled;
        plan.identity_skip = skipped;
        plan.fixed_output_barrier = barrier;
        plan.reason = reason;
        return plan;
    };

    // Content-identity class with fixed-output pin (rd-duck): never empty-vf raw
    // identity_skip — that races stderr geom and can publish mixed frames.
    auto finishExactFixedOut = [&](const char* reason) {
        append(fixedOutputBarrierFilter(req.coded_w, req.coded_h));
        // scale_applied=false: not product ARM resample class; barrier only.
        // identity_skip=false: raw pipe is protected. FabricNative via !scale.
        return finish(false, false, reason, /*barrier=*/true);
    };

    if (req.coded_w <= 0 || req.coded_h <= 0)
        return finish(false, false, "invalid_coded");

    // Off: no scale/pad regardless of source (lab). RAW unprotected — only path
    // that may still set identity_skip semantics via empty vf (caller beware).
    if (req.scale_mode == FfmpegScaleMode::Off)
        return finish(false, false, "scale_off");

    // SkipIdentity + verified exact: fixed-out pin (not raw identity_skip).
    // Display crop still cleared on present (clearYuv420pCropPadding).
    if (req.scale_mode == FfmpegScaleMode::SkipIdentity && sourceMatchesCoded(req))
        return finishExactFixedOut(hasCrop ? "identity_fixed_out_crop_clear"
                                           : "identity_fixed_out_barrier");

    const bool exactCodedSource = req.source_w > 0 && req.source_h > 0 &&
                                  req.source_w == req.coded_w && req.source_h == req.coded_h;
    const bool exactUnverified =
        exactCodedSource && !req.delivery_geometry_verified && !req.assume_source_matches_coded;

    // FORCE_SCALE product path maps conf SkipIdentity → Always.
    //
    // Exact coded *claim* at plan time is almost always UNVERIFIED: source WxH
    // is PMS transcode_request / library_media (main.cpp setFfmpegScaleSourceSize),
    // and delivery_geometry_verified stays 0 until the ffmpeg banner arrives —
    // after the vf plan is frozen for the session.
    //
    // Fleet log mode (parent 2026-08-02): measured=624x350 is the MOST COMMON
    // delivery while request still claims 624x480. crop=618:480 on a 624x350
    // input fails hard (host ffmpeg: "Invalid too big ... height '480'", rc=234,
    // 0 output bytes). FOAR into *coded* 624 pins OUTPUT 449280 for BOTH:
    //   - true 624x480: scaleDecreaseOutHeight→480 (no letterbox)
    //   - 624x350: upscale/letterbox then pad (bytes safe; detail loss is Loss2)
    // Never identity_skip on unverified claims (MILESTONE 4 pipe desync).
    //
    // Verified + Always: fixed-out barrier (not raw identity); crop pad clear.
    // FOAR into display 618 remains forbidden (row destroyer) — coded only.
    if (req.scale_mode == FfmpegScaleMode::Always && exactCodedSource) {
        if (!exactUnverified) {
            return finishExactFixedOut(hasCrop ? "force_exact_fixed_out_crop_clear"
                                               : "force_exact_fixed_out_barrier");
        }
        const std::string flagsExact =
            swsFlagsTokenOk(req.sws_flags) ? req.sws_flags : std::string();
        append(buildScalePadCentered(req.coded_w, req.coded_h, flagsExact));
        return finish(true, false,
                      flagsExact.empty() ? "force_unverified_claim_scale_pad_coded"
                                         : "force_unverified_claim_scale_pad_coded_flags");
    }

    // Always (non-exact), or SkipIdentity with mismatched/unknown/unverified: scale+pad.
    const std::string flags = swsFlagsTokenOk(req.sws_flags) ? req.sws_flags : std::string();

    // Pad-up FIRST (Direct Part 426 content → 432 store) — before hasCrop crop_pad.
    //
    // rd-duck FIX-COLLISION: corrected metadata is coded=432 display=426 crop_left=2.
    // If pad-up is gated only on verified, the later branch
    //   hasCrop && source_h==coded_h && source_w>=dispW
    // calls buildCropPadNoScale → crop=426:240:2:0 on a 426-wide input (OOB).
    // Rule: when source == display < coded, there is NO source crop — only
    // destination pad at inset; crop_left/right travel to PLXG, not FFmpeg crop=.
    //
    // Two equivalent geometry claims (both pad-up, no scale):
    //   A) product: source==display=426, coded=432, crop_left=2
    //   B) legacy:  display==coded=432, source=426 (pre-DE split)
    {
        const bool yuvEvenOk = (req.source_w % 2) == 0 && (req.source_h % 2) == 0 &&
                               (req.coded_w % 2) == 0 && (req.coded_h % 2) == 0 &&
                               (dispW % 2) == 0 && (dispH % 2) == 0;
        const bool srcOk = req.source_w > 0 && req.source_h > 0;
        // A: content fills visible DE; store larger — NEVER crop from source.
        const bool contentFillsDisplay =
            srcOk && req.source_w == dispW && req.source_h == dispH &&
            req.source_w <= req.coded_w && req.source_h <= req.coded_h &&
            (req.source_w < req.coded_w || req.source_h < req.coded_h);
        // B: same-height into bank when display was set equal to coded.
        const bool legacySameHeightPad =
            srcOk && req.source_h == req.coded_h && req.source_h == dispH &&
            req.source_w <= req.coded_w && req.source_w <= dispW &&
            req.source_w < req.coded_w;
        // Product pad-up (source==display < coded): STRUCTURAL — never crop from
        // source. Do not require verified (unverified product geom must not hit
        // crop_pad OOB). Legacy display==coded pad still needs verified so an
        // unverified 426-into-432-bank claim keeps FOAR (universal ceiling trap).
        const bool productPadUp = yuvEvenOk && contentFillsDisplay;
        const bool legacyVerifiedPad =
            yuvEvenOk && legacySameHeightPad && req.delivery_geometry_verified;
        if (productPadUp || legacyVerifiedPad) {
            // Explicit chroma-even x/y (426→432 → pad=432:240:2:0, not (ow-iw)/2).
            // Prefer crop_left when geometry already computed it (must match pad).
            int px = 0, py = 0;
            if (req.crop_left > 0 || req.crop_top > 0) {
                px = req.crop_left;
                py = req.crop_top;
            } else {
                padOnlyInsets(req.source_w, req.source_h, req.coded_w, req.coded_h, &px, &py);
            }
            append(buildPadOnlyNoScale(req.coded_w, req.coded_h, px, py));
            const char* why = "verified_same_height_pad_only";
            if (productPadUp && !req.delivery_geometry_verified)
                why = "pad_up_no_source_crop";
            else if (productPadUp && req.delivery_geometry_verified)
                why = "verified_same_height_pad_only";
            return finish(false, false, why);
        }
    }

    // Height already equals bank/display height and width is STRICTLY wide enough
    // to crop a display window FROM the source, then pad to coded.
    // 240p / shorter sources FOAR into coded bank (need V upscale).
    // NOT pad-up (source==display < coded) — returned above.
    const bool heightAlreadyBank = req.source_h > 0 && req.source_h == req.coded_h &&
                                   req.source_h == dispH;
    // Must be able to take crop_left + display_w samples from source (or center
    // crop when source_w > coded). source_w == dispW with crop_left>0 is OOB.
    const bool canCropDisplayFromSource =
        req.source_w > 0 &&
        ((req.source_w > req.coded_w && req.source_w > dispW) ||
         (req.source_w >= dispW + std::max(0, req.crop_left) && req.source_w > dispW));
    if (hasCrop && heightAlreadyBank && canCropDisplayFromSource && !exactUnverified) {
        append(buildCropPadNoScale(dispW, dispH, req.coded_w, req.coded_h, req.crop_left,
                                   req.crop_top, req.source_w));
        if (exactCodedSource)
            return finish(false, false, "crop_pad_no_v_scale");
        return finish(false, false, "crop_pad_no_v_scale_hfit");
    }
    // SkipIdentity + unverified exact claim (force escape): same FOAR pin as Always.
    if (exactUnverified) {
        append(buildScalePadCentered(req.coded_w, req.coded_h, flags));
        return finish(true, false,
                      flags.empty() ? "unverified_claim_scale_pad_coded"
                                    : "unverified_claim_scale_pad_coded_flags");
    }

    // Non-exact / unknown source that needs resample: FOAR into the CODED bank
    // (624x480), never into display 618. Parent miss correction: PMS rk6/rk36
    // both emit scale=w=624:h=480; the 350-row loss was OUR
    // scale=618:480:FOAR=decrease. 618 is kPlex480pDisplayWidth (crop_right=6)
    // — deliberate for RTL/present crop, not an FOAR target.
    //
    // 16:9 DAR still letterboxes inside 624x480 (~350 rows) when FOAR runs —
    // that is the honest aspect tradeoff when source is not bank-exact. Bank-
    // exact 624x480 takes crop_pad above and keeps all 480 rows (anamorphic
    // SAR is a present/display concern, not a reason to destroy samples here).
    if (hasCrop) {
        append(buildScalePadCentered(req.coded_w, req.coded_h, flags));
        return finish(true, false,
                      flags.empty() ? "scale_pad_center_coded" : "scale_pad_center_coded_flags");
    }
    append(buildScalePadCentered(req.coded_w, req.coded_h, flags));
    return finish(true, false, flags.empty() ? "scale_pad_center" : "scale_pad_center_flags");
}

// Predict FOAR-decrease output height into a box (storage aspect, SAR=1).
// For 16:9 content into 624x480 → 350; into 618x480 → 348. Used for
// FILTER_CHAIN_LOSS telemetry (not a desync model).
inline int predictFoarDecreaseHeight(int src_w, int src_h, int box_w, int box_h) {
    return scaleDecreaseOutHeight(src_w, src_h, box_w, box_h);
}

// Vertical detail retained if FOAR-decrease fits src into box then pad to bank_h.
inline double foarVerticalDetailFrac(int src_w, int src_h, int box_w, int box_h, int bank_h) {
    if (bank_h <= 0)
        return 0.0;
    const int out_h = predictFoarDecreaseHeight(src_w, src_h, box_w, box_h);
    if (out_h <= 0)
        return 0.0;
    return static_cast<double>(out_h) / static_cast<double>(bank_h);
}

} // namespace misterplex
