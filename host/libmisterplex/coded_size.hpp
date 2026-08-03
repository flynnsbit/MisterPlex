#pragma once

// Coded-size ingestion boundary for conf/argv/OSD-adjacent text.
//
// DECODE conf and --decode are untyped strings. Before this header they were
// sscanf'd into bare ints and fed to setDecodeSize, so a stale DECODE=624x480
// (or a presented 640x480 typo) adopted silently. The type system from
// geometry_units.hpp stops PresentedWidth↔CodedWidth swaps inside C++, but
// cannot see a text file. This header is the single place a string becomes a
// CodedSize claim.
//
// Boundary map (draw explicitly):
//   STRUCTURALLY IMPOSSIBLE (compile-time):
//     - setDecodeSize(bare int, bare int)          — no overload
//     - setDecodeSize(PresentedWidth, ...)        — tag mismatch
//     - CodedSize from untagged brace of two ints without CodedWidth/Height
//   RUNTIME-VALIDATED (text can hold anything):
//     - parse shape "WxH"
//     - reject presented-scanout mistake 640x480 as a *decode* size
//     - reject non-even / non-positive / frame-store-rejected sizes
//     - reject lab 480p coded (624x480) from conf/argv unless allowLab480p
//   OUT OF SCOPE HERE (device-side, w-gate3):
//     - resident core geometry vs adopted decode (needs live probe)

#include "libmisterplex/ddr_frame_layout.hpp"
#include "libmisterplex/geometry_units.hpp"

#include <cstdio>
#include <cstring>
#include <string>

namespace misterplex {

struct CodedSize {
    CodedWidth width{320};
    CodedHeight height{240};

    constexpr CodedSize() = default;
    constexpr CodedSize(CodedWidth w, CodedHeight h) noexcept : width(w), height(h) {}

    constexpr bool operator==(CodedSize o) const noexcept {
        return width == o.width && height == o.height;
    }
    constexpr bool operator!=(CodedSize o) const noexcept { return !(*this == o); }

    std::string wxh() const {
        return std::to_string(width.get()) + "x" + std::to_string(height.get());
    }
};

// Product-safe shipping default (v0.3.0 stable path).
constexpr CodedSize kDefaultCodedDecodeSize{CodedWidth{320}, CodedHeight{240}};
// Lab 480p coded payload — valid DDR geometry, not the shipping default.
inline CodedSize plex480pCodedDecodeSize() {
    return CodedSize{kPlex480pCodedWidth, kPlex480pCodedHeight};
}

enum class CodedSizeParseStatus {
    Ok = 0,
    Empty,
    Malformed,
    NotPositive,
    NotEven,
    PresentedMistake, // e.g. 640x480 presented scanout used as DECODE
    NotFrameStoreAccepted,
    Lab480pBlocked, // 624x480 without explicit lab allow
};

struct CodedSizeParseResult {
    CodedSizeParseStatus status = CodedSizeParseStatus::Empty;
    CodedSize size = kDefaultCodedDecodeSize;
    const char* reason = "empty";

    bool ok() const noexcept { return status == CodedSizeParseStatus::Ok; }
};

inline const char* codedSizeParseStatusName(CodedSizeParseStatus s) {
    switch (s) {
    case CodedSizeParseStatus::Ok:
        return "ok";
    case CodedSizeParseStatus::Empty:
        return "empty";
    case CodedSizeParseStatus::Malformed:
        return "malformed";
    case CodedSizeParseStatus::NotPositive:
        return "not_positive";
    case CodedSizeParseStatus::NotEven:
        return "not_even";
    case CodedSizeParseStatus::PresentedMistake:
        return "presented_mistake";
    case CodedSizeParseStatus::NotFrameStoreAccepted:
        return "not_frame_store_accepted";
    case CodedSizeParseStatus::Lab480pBlocked:
        return "lab_480p_blocked";
    }
    return "unknown";
}

// Shape-level parse: text -> candidate coded size. No lab policy.
// Rejects the classic presented-as-decode footgun (640x480) here so every
// caller shares one diagnosis.
inline CodedSizeParseResult parseCodedSizeString(const std::string& text) {
    CodedSizeParseResult r;
    if (text.empty()) {
        r.status = CodedSizeParseStatus::Empty;
        r.reason = "empty string";
        return r;
    }
    int w = 0, h = 0;
    // Require exact WxH — trailing junk means malformed (stale/concat conf).
    if (std::sscanf(text.c_str(), "%dx%d", &w, &h) != 2) {
        r.status = CodedSizeParseStatus::Malformed;
        r.reason = "expected WxH";
        return r;
    }
    // Ensure no trailing garbage: reconstruct and compare loosely after trim.
    char probe[64];
    std::snprintf(probe, sizeof(probe), "%dx%d", w, h);
    // Allow optional whitespace-only suffix by checking prefix match of digits form.
    const char* p = text.c_str();
    while (*p == ' ' || *p == '\t')
        ++p;
    if (std::strncmp(p, probe, std::strlen(probe)) != 0) {
        r.status = CodedSizeParseStatus::Malformed;
        r.reason = "expected WxH";
        return r;
    }
    p += std::strlen(probe);
    while (*p == ' ' || *p == '\t' || *p == '\r' || *p == '\n')
        ++p;
    if (*p != '\0') {
        r.status = CodedSizeParseStatus::Malformed;
        r.reason = "trailing junk after WxH";
        return r;
    }
    if (w <= 0 || h <= 0) {
        r.status = CodedSizeParseStatus::NotPositive;
        r.reason = "width/height must be positive";
        return r;
    }
    if ((w & 1) || (h & 1)) {
        r.status = CodedSizeParseStatus::NotEven;
        r.reason = "width/height must be even (YUV)";
        return r;
    }
    // Presented scanout is not a coded decode size. 640x480 here is the fault
    // class that tiered bitrate and OSD on the wrong width.
    if (w == kPlex480pPresentedWidth.get() && h == kPlex480pPresentedHeight.get()) {
        r.status = CodedSizeParseStatus::PresentedMistake;
        r.reason = "640x480 is presented scanout, not coded decode (use 624x480 lab coded "
                   "with allow, or 320x240 product default)";
        return r;
    }
    if (!ddrFrameStoreAcceptsResolution(CodedWidth{w}, CodedHeight{h})) {
        r.status = CodedSizeParseStatus::NotFrameStoreAccepted;
        r.reason = "size not accepted by DDR frame-store contract";
        return r;
    }
    r.status = CodedSizeParseStatus::Ok;
    r.size = CodedSize{CodedWidth{w}, CodedHeight{h}};
    r.reason = "ok";
    return r;
}

// Conf/argv adoption policy on top of parseCodedSizeString.
// Lab 480p coded (624x480) is a valid geometry but not the shipping default;
// adopting it from a stale conf is exactly the corruption that shipped to the
// user. Require an explicit allow bit from conf/CLI — still not a device probe.
inline CodedSizeParseResult adoptExternalCodedSize(const std::string& text, bool allowLab480p) {
    CodedSizeParseResult r = parseCodedSizeString(text);
    if (!r.ok())
        return r;
    const bool isLab480p = r.size.width == kPlex480pCodedWidth &&
                           r.size.height == kPlex480pCodedHeight;
    if (isLab480p && !allowLab480p) {
        r.status = CodedSizeParseStatus::Lab480pBlocked;
        r.reason = "624x480 lab coded decode blocked without DECODE_ALLOW_LAB_480P=1 "
                   "(stale conf guard; OSD O[4] still selects 480p at play time)";
        r.size = kDefaultCodedDecodeSize;
        return r;
    }
    return r;
}

} // namespace misterplex
