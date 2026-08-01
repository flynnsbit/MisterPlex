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

#include <cctype>
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
    std::string reason;      // short machine token for logs
};

// Build scale=WxH with optional :flags= after the geometry token and before
// force_original_aspect_ratio (ffmpeg accepts both orders; keep flags early).
inline std::string scaleFilterGeom(const std::string& wh, const std::string& sws_flags) {
    std::string s = "scale=" + wh;
    if (!sws_flags.empty() && swsFlagsTokenOk(sws_flags))
        s += ":flags=" + sws_flags;
    return s;
}

// Integer model of ffmpeg scale=box_w:box_h:force_original_aspect_ratio=decrease
// output height (no even-align). Width-limited fit:
//   out_h = floor(src_h * box_w / src_w) when box_w/src_w <= box_h/src_h.
// Product defect class: src 624x480 into box 618x480 → out_h = 480*618/624 = 475.
inline int scaleDecreaseOutHeight(int src_w, int src_h, int box_w, int box_h) {
    if (src_w <= 0 || src_h <= 0 || box_w <= 0 || box_h <= 0)
        return 0;
    // width-limited when box_w * src_h <= box_h * src_w  (box narrower or equal AR)
    if (static_cast<long long>(box_w) * static_cast<long long>(src_h) <=
        static_cast<long long>(box_h) * static_cast<long long>(src_w)) {
        return static_cast<int>((static_cast<long long>(src_h) * box_w) / src_w);
    }
    // height-limited: out_h = min(box_h, src_h) under decrease with s<=1 on h
    return box_h < src_h ? box_h : src_h;
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
// 480p crop path (upscale / non-bank source): scale into display geometry then
// pad once into coded stride, centering inside the display window (crop_left/top
// is the display origin inside the coded bank — NOT a left-align of content).
//
// 480p exact-coded source (source WxH == coded WxH): MUST NOT scale into the
// narrower display box with force_original_aspect_ratio=decrease — that applies
// min(display_w/src_w, display_h/src_h) to BOTH axes and turns a pure 6-px
// horizontal crop into a ~1% vertical resample (624x480 → ~618x475 → pad).
// Under Always/FORCE_SCALE: unverified exact → crop+pad pin (product hot path);
// verified exact → true identity. SkipIdentity+unverified → crop+pad. Non-exact
// bank-height (e.g. 640x480) uses buildCropPadNoScale (hfit).
//
// Square path: scale into coded geometry with centred pad.
//
// Prior pad=<coded>:<crop_left>:<crop_top> left/top-aligned the scaled picture
// at the crop origin. For any source that does not fill the display box that
// put the entire pillar/letter box on the right/bottom and shoved content into
// the top-left — wrong vs force_original_aspect_ratio=decrease + pad intent,
// and it disagreed with packYuv420pCenteredIntoCodedBank (constant center).
// FFmpeg expressions keep the margin constant per frame (iw/ih are filter-graph
// constants for a given frame, not recomputed per scanline).
inline std::string buildScalePadCropped(int display_w, int display_h, int coded_w, int coded_h,
                                        int crop_left, int crop_top,
                                        const std::string& sws_flags) {
    const std::string displayScale =
        std::to_string(display_w) + ":" + std::to_string(display_h);
    const std::string scale = std::to_string(coded_w) + ":" + std::to_string(coded_h);
    // pad x = crop_left + (display_w - iw)/2 ; y = crop_top + (display_h - ih)/2
    // so a full-bleed decrease into display_w lands at x=crop_left (product
    // crop_left=0 → x=0), and a narrower frame is pillarboxed inside display.
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

    auto finish = [&](bool scaled, bool skipped, const char* reason) {
        plan.vf = std::move(vf);
        plan.scale_applied = scaled;
        plan.identity_skip = skipped;
        plan.reason = reason;
        return plan;
    };

    if (req.coded_w <= 0 || req.coded_h <= 0)
        return finish(false, false, "invalid_coded");

    // Off: no scale/pad regardless of source (lab).
    if (req.scale_mode == FfmpegScaleMode::Off)
        return finish(false, false, "scale_off");

    // SkipIdentity: omit scale+pad only when verified delivery equals coded.
    // Even when display crop is non-zero (624 coded / 618 display), a *verified*
    // identity skip is intentional — clearYuv420pCropPadding blackens pad cols.
    if (req.scale_mode == FfmpegScaleMode::SkipIdentity && sourceMatchesCoded(req))
        return finish(false, true, hasCrop ? "identity_skip_crop_pad_clear" : "identity_skip");

    const bool exactCodedSource = req.source_w > 0 && req.source_h > 0 &&
                                  req.source_w == req.coded_w && req.source_h == req.coded_h;
    const bool exactUnverified =
        exactCodedSource && !req.delivery_geometry_verified && !req.assume_source_matches_coded;

    // FORCE_SCALE product path maps conf SkipIdentity → Always.
    //
    // Exact coded *claim* at plan time is almost always UNVERIFIED: source WxH
    // is PMS transcode_request / library_media (main.cpp setFfmpegScaleSourceSize),
    // and delivery_geometry_verified stays 0 until the ffmpeg banner arrives —
    // after the vf plan is frozen for the session. Unverified is the product
    // hot path, not an edge case.
    //
    // Unverified + Always: crop+pad (NO swscale, NO FOAR decrease). Pins OUTPUT
    // geometry to coded bank the way old Always-scale did, without the ~1%
    // vertical resample (624→618 FOAR → 475). identity_skip=false so a wrong
    // claim cannot silent-phase-walk the raw reader (MILESTONE 4 class).
    //
    // Verified + Always (lab / measured-before-plan): true identity no-op;
    // display crop cols cleared by clearYuv420pCropPadding on present.
    //
    // Non-exact / unknown under Always: still scale+pad below (byte pin).
    if (req.scale_mode == FfmpegScaleMode::Always && exactCodedSource) {
        if (!exactUnverified) {
            return finish(false, true, hasCrop ? "force_exact_identity_crop_clear"
                                               : "force_exact_identity");
        }
        // Unverified claim of exact coded — pin via crop+pad, never identity_skip.
        append(buildCropPadNoScale(dispW, dispH, req.coded_w, req.coded_h, req.crop_left,
                                   req.crop_top, req.source_w));
        return finish(false, false,
                      hasCrop ? "force_exact_crop_pad_unverified"
                              : "force_exact_pad_unverified");
    }

    // Always (non-exact), or SkipIdentity with mismatched/unknown/unverified: scale+pad.
    const std::string flags = swsFlagsTokenOk(req.sws_flags) ? req.sws_flags : std::string();

    // Height already equals bank/display height and width is wide enough to
    // cover the display window: crop+pad ONLY (no FOAR decrease V-resample).
    // Covers: SkipIdentity unverified exact 624; Always/Skip 640x480 hfit; etc.
    // 240p / shorter sources still take buildScalePadCropped (need V upscale).
    const bool heightAlreadyBank = req.source_h > 0 && req.source_h == req.coded_h &&
                                   req.source_h == dispH;
    const bool wideEnoughForDisplayCrop =
        req.source_w > 0 && req.source_w >= dispW;
    if (hasCrop && heightAlreadyBank && wideEnoughForDisplayCrop) {
        append(buildCropPadNoScale(dispW, dispH, req.coded_w, req.coded_h, req.crop_left,
                                   req.crop_top, req.source_w));
        if (exactUnverified && req.scale_mode == FfmpegScaleMode::SkipIdentity)
            return finish(false, false, "crop_pad_no_v_scale_unverified_delivery");
        if (exactCodedSource)
            return finish(false, false, "crop_pad_no_v_scale");
        return finish(false, false, "crop_pad_no_v_scale_hfit");
    }

    if (hasCrop) {
        append(buildScalePadCropped(dispW, dispH, req.coded_w, req.coded_h, req.crop_left,
                                    req.crop_top, flags));
        return finish(true, false, flags.empty() ? "scale_pad_crop" : "scale_pad_crop_flags");
    }
    append(buildScalePadCentered(req.coded_w, req.coded_h, flags));
    return finish(true, false, flags.empty() ? "scale_pad_center" : "scale_pad_center_flags");
}

} // namespace misterplex
