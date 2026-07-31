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

// Canonical product scale+pad strings — freeze tests pin these shapes.
// 480p crop path: scale into display geometry then pad once into coded stride,
// centering the scaled frame inside the display window (crop_left/top is the
// display origin inside the coded bank — NOT a left-align of the content).
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

    // Loud reason when numbers matched but delivery was not verified — the
    // silicon desync class (parent: wrap + magenta at force_scale=0).
    const bool numericMatchUnverified =
        req.scale_mode == FfmpegScaleMode::SkipIdentity && req.source_w > 0 &&
        req.source_h > 0 && req.source_w == req.coded_w && req.source_h == req.coded_h &&
        !req.delivery_geometry_verified && !req.assume_source_matches_coded;

    // Always, or SkipIdentity with mismatched/unknown/unverified source: scale+pad.
    const std::string flags = swsFlagsTokenOk(req.sws_flags) ? req.sws_flags : std::string();
    if (hasCrop) {
        append(buildScalePadCropped(dispW, dispH, req.coded_w, req.coded_h, req.crop_left,
                                    req.crop_top, flags));
        if (numericMatchUnverified)
            return finish(true, false,
                          flags.empty() ? "scale_pad_crop_unverified_delivery"
                                        : "scale_pad_crop_unverified_delivery_flags");
        return finish(true, false, flags.empty() ? "scale_pad_crop" : "scale_pad_crop_flags");
    }
    append(buildScalePadCentered(req.coded_w, req.coded_h, flags));
    if (numericMatchUnverified)
        return finish(true, false,
                      flags.empty() ? "scale_pad_center_unverified_delivery"
                                    : "scale_pad_center_unverified_delivery_flags");
    return finish(true, false, flags.empty() ? "scale_pad_center" : "scale_pad_center_flags");
}

} // namespace misterplex
