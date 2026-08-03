// Named stream target profiles: one row binds DECODE geometry, PMS universal
// transcode parameters, and the present transport budget so they cannot drift.
//
// Parent hardware (2026-08-03): PRESENT=fpga frame push is SPI/F1. Measured
// ceiling ~5.5 MiB/s — 320x240@24 I420 fits (~2.64 MiB/s); 624x480@24 (~10.3)
// and 1280x720@24 (~31.6) do not (pfps=0.00 on glass). Profiles that need more
// than the active transport budget must refuse at selection/startup — never
// silently request 480p over SPI.
//
// PMS evidence (lab docker, decision→start, subjects ≠ rk=7 pilot):
//   videoResolution = CEILING (aspect-preserving square-pixel fit)
//   maxVideoBitrate, videoQuality, protocol=http, directPlay=0, directStream=0
//   videoCodec=h264, audioCodec=aac, videoProfile=baseline, videoLevel=30
// See docs/evidence/p720-path-20260803/pms_profile_contract/REPORT.md
#pragma once

#include "libmisterplex/osd_menu.hpp"

#include <cmath>
#include <cstdio>
#include <cstring>
#include <string>

namespace misterplex {

// How decoded frames reach the core scanout path.
enum class PresentTransport : uint8_t {
    // Product path today: ARM → SPI/F1 → core frame store (PRESENT=fpga).
    SpiF1 = 0,
    // Higher-bandwidth DDR bulk present (required for 480p/720p content rates).
    DdrBulk = 1,
};

inline constexpr const char* presentTransportName(PresentTransport t) {
    switch (t) {
    case PresentTransport::SpiF1:
        return "spi_f1";
    case PresentTransport::DdrBulk:
        return "ddr_bulk";
    }
    return "unknown";
}

// Parent-measured SPI present ceiling (MiB/s of raw frame payload).
inline constexpr double kPresentSpiF1BudgetMiBs = 5.5;
// Conservative DDR bulk budget once w-mem stride/path is live (MiB/s).
inline constexpr double kPresentDdrBulkBudgetMiBs = 80.0;

inline constexpr double presentTransportBudgetMiBs(PresentTransport t) {
    switch (t) {
    case PresentTransport::SpiF1:
        return kPresentSpiF1BudgetMiBs;
    case PresentTransport::DdrBulk:
        return kPresentDdrBulkBudgetMiBs;
    }
    return 0.0;
}

// I420 payload rate used for present-path fit (not compressed ES bitrate).
inline constexpr double i420PayloadMiBs(int w, int h, double fps) {
    if (w <= 0 || h <= 0 || fps <= 0.0)
        return 0.0;
    const double bytes_per_frame = static_cast<double>(w) * static_cast<double>(h) * 1.5;
    return (bytes_per_frame * fps) / (1024.0 * 1024.0);
}

// One product row: name → DECODE WxH + PMS universal params + required transport.
struct StreamTargetProfile {
    const char* id = ""; // "240p-spi" | "480p-ddr" | "720p-ddr"
    int decode_w = 0;
    int decode_h = 0;
    // PMS videoResolution= (ceiling). May match decode bank (480p uses 624x480).
    const char* pms_video_resolution = "";
    int max_video_bitrate_kbps = 0;
    int video_quality = 0;
    int h264_level = 30;
    const char* h264_profile = "baseline"; // request pin
    const char* video_codec = "h264";
    const char* audio_codec = "aac";
    const char* protocol = "http";
    int direct_play = 0;   // universal path suppresses DP
    int direct_stream = 0; // universal path suppresses DS
    PresentTransport required_transport = PresentTransport::SpiF1;
    double budget_fps = 24.0;
    // Ladder name for applyPlexTranscodeProfile (240p/480p/720p).
    const char* ladder_name = "";
};

// Compile-time table — extend by adding a row, not by sprinkling ifs.
inline constexpr StreamTargetProfile kStreamTargetProfiles[] = {
    // SPI-safe product default. Parent glass: pfps≈23.3 @ 320x240.
    {"240p-spi", 320, 240, "320x240", kPlex240pWeakBitrateKbps, 40, 30, "baseline", "h264",
     "aac", "http", 0, 0, PresentTransport::SpiF1, 24.0, "240p"},
    // 480p content requires DDR bulk present (SPI cannot carry ~10.3 MiB/s).
    {"480p-ddr", 624, 480, "624x480", kPlex480pWeakBitrateKbps, 60, 30, "baseline", "h264",
     "aac", "http", 0, 0, PresentTransport::DdrBulk, 24.0, "480p"},
    // 720p content requires DDR bulk + bank stride (w-mem). PMS ceiling 1280x720.
    {"720p-ddr", 1280, 720, "1280x720", kPlex720pWeakBitrateKbps, 70, kPlex720pH264Level,
     "baseline", "h264", "aac", "http", 0, 0, PresentTransport::DdrBulk, 24.0, "720p"},
};

inline constexpr std::size_t kStreamTargetProfileCount =
    sizeof(kStreamTargetProfiles) / sizeof(kStreamTargetProfiles[0]);

// Static fit checks: SPI profile must fit SPI; DDR profiles must exceed SPI
// (otherwise they would be mis-labeled and hide the transport requirement).
static_assert(i420PayloadMiBs(320, 240, 24.0) < kPresentSpiF1BudgetMiBs,
              "240p-spi must fit measured SPI budget");
static_assert(i420PayloadMiBs(624, 480, 24.0) > kPresentSpiF1BudgetMiBs,
              "480p must NOT fit SPI — profile must require DdrBulk");
static_assert(i420PayloadMiBs(1280, 720, 24.0) > kPresentSpiF1BudgetMiBs,
              "720p must NOT fit SPI — profile must require DdrBulk");
static_assert(i420PayloadMiBs(624, 480, 24.0) < kPresentDdrBulkBudgetMiBs,
              "480p-ddr must fit DDR bulk budget");
static_assert(i420PayloadMiBs(1280, 720, 24.0) < kPresentDdrBulkBudgetMiBs,
              "720p-ddr must fit DDR bulk budget");

enum class StreamTargetProfileError : uint8_t {
    Ok = 0,
    UnknownName,
    GeometryPresentDisagree,
    ExceedsPresentBudget,
    UnsupportedOversized,
    LadderMissing,
};

inline constexpr const char* streamTargetProfileErrorName(StreamTargetProfileError e) {
    switch (e) {
    case StreamTargetProfileError::Ok:
        return "ok";
    case StreamTargetProfileError::UnknownName:
        return "unknown_name";
    case StreamTargetProfileError::GeometryPresentDisagree:
        return "geometry_present_disagree";
    case StreamTargetProfileError::ExceedsPresentBudget:
        return "exceeds_present_budget";
    case StreamTargetProfileError::UnsupportedOversized:
        return "unsupported_oversized";
    case StreamTargetProfileError::LadderMissing:
        return "ladder_missing";
    }
    return "unknown";
}

struct StreamTargetProfileResult {
    bool ok = false;
    StreamTargetProfileError error = StreamTargetProfileError::UnknownName;
    const char* reason = "unset";
    StreamTargetProfile profile{};
    double payload_mib_s = 0.0;
    double budget_mib_s = 0.0;
    bool fits_budget = false;
};

inline bool streamTargetProfileIdEquals(const char* a, const char* b) {
    if (!a || !b)
        return false;
    return std::strcmp(a, b) == 0;
}

// Case-sensitive product ids (conf values). Also accept legacy ladder aliases
// only when transport can be inferred safely (240p → spi; 480p/720p → ddr).
inline StreamTargetProfileResult lookupStreamTargetProfile(const char* id) {
    StreamTargetProfileResult r;
    if (!id || !*id) {
        r.error = StreamTargetProfileError::UnknownName;
        r.reason = "empty profile id";
        return r;
    }
    // Explicit table ids.
    for (std::size_t i = 0; i < kStreamTargetProfileCount; ++i) {
        if (streamTargetProfileIdEquals(kStreamTargetProfiles[i].id, id)) {
            r.ok = true;
            r.error = StreamTargetProfileError::Ok;
            r.reason = "ok";
            r.profile = kStreamTargetProfiles[i];
            r.payload_mib_s =
                i420PayloadMiBs(r.profile.decode_w, r.profile.decode_h, r.profile.budget_fps);
            r.budget_mib_s = presentTransportBudgetMiBs(r.profile.required_transport);
            r.fits_budget = r.payload_mib_s <= r.budget_mib_s + 1e-9;
            return r;
        }
    }
    // Aliases → full ids (data, not open-coded geometry).
    if (streamTargetProfileIdEquals(id, "240p") || streamTargetProfileIdEquals(id, "320x240"))
        return lookupStreamTargetProfile("240p-spi");
    if (streamTargetProfileIdEquals(id, "480p") || streamTargetProfileIdEquals(id, "624x480"))
        return lookupStreamTargetProfile("480p-ddr");
    if (streamTargetProfileIdEquals(id, "720p") || streamTargetProfileIdEquals(id, "1280x720"))
        return lookupStreamTargetProfile("720p-ddr");

    // Known oversized names must be typed refusals, not unknown.
    if (streamTargetProfileIdEquals(id, "1080p") || streamTargetProfileIdEquals(id, "1920x1080") ||
        streamTargetProfileIdEquals(id, "480p-spi") || // illegal: 480p cannot be SPI
        streamTargetProfileIdEquals(id, "720p-spi")) {
        r.error = StreamTargetProfileError::UnsupportedOversized;
        r.reason = "profile exceeds product present/decode ceiling or illegal transport pairing";
        return r;
    }
    r.error = StreamTargetProfileError::UnknownName;
    r.reason = "unknown STREAM_TARGET_PROFILE id";
    return r;
}

// Map active DECODE WxH + available transport → profile (or typed refuse).
inline StreamTargetProfileResult selectStreamTargetProfile(int decode_w, int decode_h,
                                                           PresentTransport available) {
    StreamTargetProfileResult r;
    // Find the unique table row whose decode matches.
    const StreamTargetProfile* match = nullptr;
    for (std::size_t i = 0; i < kStreamTargetProfileCount; ++i) {
        const auto& p = kStreamTargetProfiles[i];
        if (p.decode_w == decode_w && p.decode_h == decode_h) {
            match = &p;
            break;
        }
    }
    if (!match) {
        // Any geometry above 720 is oversized; others unknown.
        if (decode_w > 1280 || decode_h > 720 || decode_w * decode_h > 1280 * 720) {
            r.error = StreamTargetProfileError::UnsupportedOversized;
            r.reason = "decode geometry above 1280x720 product ceiling";
        } else {
            r.error = StreamTargetProfileError::UnknownName;
            r.reason = "no stream target profile for decode geometry";
        }
        return r;
    }
    r.profile = *match;
    r.payload_mib_s = i420PayloadMiBs(match->decode_w, match->decode_h, match->budget_fps);
    r.budget_mib_s = presentTransportBudgetMiBs(available);
    r.fits_budget = r.payload_mib_s <= r.budget_mib_s + 1e-9;

    // Transport must satisfy the row's requirement.
    if (match->required_transport == PresentTransport::DdrBulk &&
        available == PresentTransport::SpiF1) {
        r.ok = false;
        r.error = StreamTargetProfileError::GeometryPresentDisagree;
        r.reason = "decode geometry requires ddr_bulk present; active transport is spi_f1";
        return r;
    }
    if (!r.fits_budget) {
        r.ok = false;
        r.error = StreamTargetProfileError::ExceedsPresentBudget;
        r.reason = "I420 payload MiB/s exceeds active present transport budget";
        return r;
    }
    r.ok = true;
    r.error = StreamTargetProfileError::Ok;
    r.reason = "ok";
    return r;
}

// Infer transport from PRESENT= conf (product: fpga ⇒ SPI F1 push today).
// PRESENT_PATH=ddr_bulk overrides when bulk path is actually fitted.
inline PresentTransport presentTransportFromConf(const std::string& present_mode,
                                                 const std::string& present_path_override) {
    if (present_path_override == "ddr_bulk" || present_path_override == "ddr" ||
        present_path_override == "DDR_BULK")
        return PresentTransport::DdrBulk;
    if (present_path_override == "spi_f1" || present_path_override == "spi" ||
        present_path_override == "SPI_F1")
        return PresentTransport::SpiF1;
    // Default product: fpga/both push frames over SPI into the core store.
    (void)present_mode;
    return PresentTransport::SpiF1;
}

// Greppable startup / play log line (no secrets, no tokens).
inline std::string formatStreamTargetProfileLogLine(const StreamTargetProfileResult& r,
                                                    PresentTransport available,
                                                    const char* where) {
    char buf[512];
    const StreamTargetProfile& p = r.profile;
    std::snprintf(
        buf, sizeof(buf),
        "misterplexd: STREAM_TARGET where=%s ok=%d err=%s profile=%s "
        "decode=%dx%d pms_videoResolution=%s maxVideoBitrate=%d videoQuality=%d "
        "protocol=%s directPlay=%d directStream=%d "
        "present_required=%s present_available=%s "
        "payload_MiB_s=%.3f budget_MiB_s=%.3f fits=%d reason=%s",
        where ? where : "?", r.ok ? 1 : 0, streamTargetProfileErrorName(r.error),
        (p.id && *p.id) ? p.id : "?", p.decode_w, p.decode_h,
        (p.pms_video_resolution && *p.pms_video_resolution) ? p.pms_video_resolution : "?",
        p.max_video_bitrate_kbps, p.video_quality, p.protocol ? p.protocol : "http",
        p.direct_play, p.direct_stream, presentTransportName(p.required_transport),
        presentTransportName(available), r.payload_mib_s, r.budget_mib_s, r.fits_budget ? 1 : 0,
        r.reason ? r.reason : "");
    return std::string(buf);
}

} // namespace misterplex
