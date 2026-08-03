#pragma once
// PLXG q5 — display aspect + content cadence (parent ABI arbitration #2).
//
// Wire: doorbell + 0x828, little-endian qword:
//   [11:0]  dar_x
//   [23:12] dar_y
//   [31:24] content_fps   integer fps (0 = unspecified)
//   [32]    dar_valid
//   [33]    fps_valid
//   [63:34] RESERVED — must be zero; pack/validate MUST reject non-zero
//
// w-path owns publishing values from PMS metadata + measured FFmpeg only.
// Never invent defaults: *_valid=0 when unknown. Fabric (w-scaler/w-clock)
// consumes; w-mem owns RTL/atomic latch (B16) and mailbox header ownership.

#include "libmisterplex/pms_delivery_geom.hpp"

#include <cstdint>
#include <cstdio>
#include <numeric>
#include <string>

namespace misterplex {

// Parent freeze: q5 sits immediately after q0..q4 (0x800 + 5*8).
constexpr uint32_t kPlxgQ5ByteOffset = 0x828u;
constexpr uint32_t kPlxgQ5Index = 5u;
constexpr uint32_t kPlxgRecordQwordsAspectCadence = 6u;
constexpr uint32_t kPlxgRecordBytesAspectCadence = kPlxgRecordQwordsAspectCadence * 8u; // 48

static_assert(kPlxgQ5ByteOffset == 0x800u + 5u * 8u, "q5 must be sixth qword at +0x828");
static_assert(kPlxgRecordBytesAspectCadence == 48u, "PLXG grows to 6 qwords / 48 bytes");

// 12-bit field maxima for dar_x / dar_y.
constexpr uint32_t kPlxgDarFieldMax = 0xFFFu;

struct PlxgAspectCadence {
    uint16_t dar_x = 0;       // [11:0]
    uint16_t dar_y = 0;       // [23:12]
    uint8_t content_fps = 0;  // [31:24]
    bool dar_valid = false;   // [32]
    bool fps_valid = false;   // [33]
};

// Reduce positive fraction; fail if either side collapses to 0.
inline bool reducePositiveFraction(uint32_t& n, uint32_t& d) {
    if (n == 0 || d == 0)
        return false;
    const uint32_t g = std::gcd(n, d);
    n /= g;
    d /= g;
    return n > 0 && d > 0;
}

// Fit a reduced positive fraction into 12-bit fields without inventing 16:9.
// Scales both sides down together when needed; fails if either becomes 0.
inline bool fitDar12(uint32_t n, uint32_t d, uint16_t& ox, uint16_t& oy) {
    if (!reducePositiveFraction(n, d))
        return false;
    while (n > kPlxgDarFieldMax || d > kPlxgDarFieldMax) {
        n >>= 1;
        d >>= 1;
        if (n == 0 || d == 0)
            return false;
    }
    if (!reducePositiveFraction(n, d))
        return false;
    if (n > kPlxgDarFieldMax || d > kPlxgDarFieldMax)
        return false;
    ox = static_cast<uint16_t>(n);
    oy = static_cast<uint16_t>(d);
    return ox > 0 && oy > 0;
}

// Pack q5. Returns false if reserved would be non-zero (caller bug) or fields
// exceed their widths. On failure *out is left unchanged.
inline bool packPlxgQ5(const PlxgAspectCadence& in, uint64_t* out) {
    if (!out)
        return false;
    if (in.dar_x > kPlxgDarFieldMax || in.dar_y > kPlxgDarFieldMax)
        return false;
    // content_fps is uint8_t — always in range.
    uint64_t q = 0;
    q |= static_cast<uint64_t>(in.dar_x & kPlxgDarFieldMax);
    q |= static_cast<uint64_t>(in.dar_y & kPlxgDarFieldMax) << 12;
    q |= static_cast<uint64_t>(in.content_fps) << 24;
    if (in.dar_valid)
        q |= 1ull << 32;
    if (in.fps_valid)
        q |= 1ull << 33;
    // Bits 63:34 must stay zero — enforced by construction above.
    if ((q >> 34) != 0)
        return false;
    *out = q;
    return true;
}

// Validate a wire qword: reserved [63:34] must be zero.
// Does not invent values — only structural legality.
inline bool plxgQ5ReservedOk(uint64_t q5) {
    return (q5 >> 34) == 0;
}

inline bool unpackPlxgQ5(uint64_t q5, PlxgAspectCadence* out) {
    if (!out)
        return false;
    if (!plxgQ5ReservedOk(q5))
        return false;
    PlxgAspectCadence c{};
    c.dar_x = static_cast<uint16_t>(q5 & kPlxgDarFieldMax);
    c.dar_y = static_cast<uint16_t>((q5 >> 12) & kPlxgDarFieldMax);
    c.content_fps = static_cast<uint8_t>((q5 >> 24) & 0xFFu);
    c.dar_valid = ((q5 >> 32) & 1ull) != 0;
    c.fps_valid = ((q5 >> 33) & 1ull) != 0;
    *out = c;
    return true;
}

// Reject path used by host-side models of the fabric receiver.
inline bool plxgQ5ReceiverAccepts(uint64_t q5) {
    return plxgQ5ReservedOk(q5);
}

// --- Selection: PMS metadata + measured geometry only; never invent defaults. ---

// Integer content_fps for fabric V_TOTAL family selection.
// Maps measured rational rates onto the integer field only when they fall in a
// known broadcast family (or are already integer). Returns false → fps_valid=0.
// Does NOT default to 24 when unknown.
inline bool contentFpsIntegerForPlxg(int fps_num, int fps_den, uint8_t* out_fps) {
    if (!out_fps || fps_num <= 0 || fps_den <= 0)
        return false;
    const double r = static_cast<double>(fps_num) / static_cast<double>(fps_den);
    if (!(r > 0.0) || r > 255.0)
        return false;
    // Exact integer 1..255.
    if (fps_den == 1 && fps_num >= 1 && fps_num <= 255) {
        *out_fps = static_cast<uint8_t>(fps_num);
        return true;
    }
    // NTSC/film families measured from PMS/FFmpeg (not guessed defaults).
    struct Bucket {
        double lo, hi;
        uint8_t v;
    };
    static const Bucket kBuckets[] = {
        {23.5, 24.5, 24},
        {24.5, 25.5, 25},
        {29.5, 30.5, 30},
        {49.5, 50.5, 50},
        {59.0, 61.0, 60},
    };
    for (const auto& b : kBuckets) {
        if (r > b.lo && r < b.hi) {
            *out_fps = b.v;
            return true;
        }
    }
    return false;
}

// DAR from explicit SAR (preferred) or Media@aspectRatio. NEVER falls back to
// coded_w/coded_h storage aspect — 720×480 proves storage AR is unsound.
// coded dims are only used with SAR to form display aspect.
inline bool contentDarForPlxg(int coded_w, int coded_h, const std::string& pixelAspectRatio,
                              const std::string& mediaAspectRatio, uint16_t* dar_x,
                              uint16_t* dar_y) {
    if (!dar_x || !dar_y)
        return false;
    RationalAspect sar;
    if (parseAspectRatioToken(pixelAspectRatio, sar) && sar.valid() && coded_w > 0 &&
        coded_h > 0) {
        // DAR = (w*sar_n) : (h*sar_d)
        uint64_t n = static_cast<uint64_t>(coded_w) * static_cast<uint64_t>(sar.num);
        uint64_t d = static_cast<uint64_t>(coded_h) * static_cast<uint64_t>(sar.den);
        // Reduce 64-bit before fitDar12.
        const uint64_t g = std::gcd(n, d);
        n /= g;
        d /= g;
        if (n == 0 || d == 0 || n > 0xFFFFFFFFull || d > 0xFFFFFFFFull)
            return false;
        return fitDar12(static_cast<uint32_t>(n), static_cast<uint32_t>(d), *dar_x, *dar_y);
    }
    RationalAspect mar;
    if (parseAspectRatioToken(mediaAspectRatio, mar) && mar.valid()) {
        return fitDar12(static_cast<uint32_t>(mar.num), static_cast<uint32_t>(mar.den), *dar_x,
                        *dar_y);
    }
    // Unknown — do not invent storage aspect.
    return false;
}

// Build the full aspect/cadence payload. Empty strings / non-positive rates →
// corresponding valid bit clear. Never sets a default 16:9 or 24 fps.
inline PlxgAspectCadence selectPlxgAspectCadence(int coded_w, int coded_h,
                                                 const std::string& pixelAspectRatio,
                                                 const std::string& mediaAspectRatio,
                                                 int fps_num, int fps_den) {
    PlxgAspectCadence c{};
    uint16_t dx = 0, dy = 0;
    if (contentDarForPlxg(coded_w, coded_h, pixelAspectRatio, mediaAspectRatio, &dx, &dy)) {
        c.dar_x = dx;
        c.dar_y = dy;
        c.dar_valid = true;
    }
    uint8_t fps = 0;
    if (contentFpsIntegerForPlxg(fps_num, fps_den, &fps)) {
        c.content_fps = fps;
        c.fps_valid = true;
    }
    return c;
}

// Human-readable one-line for daemon logs (no secrets).
inline std::string formatPlxgQ5LogLine(const PlxgAspectCadence& c, uint64_t q5_packed) {
    char buf[192];
    std::snprintf(buf, sizeof(buf),
                  "PLXG_Q5 dar=%u/%u dar_valid=%d fps=%u fps_valid=%d q5=0x%016llx off=0x828",
                  static_cast<unsigned>(c.dar_x), static_cast<unsigned>(c.dar_y),
                  c.dar_valid ? 1 : 0, static_cast<unsigned>(c.content_fps),
                  c.fps_valid ? 1 : 0, static_cast<unsigned long long>(q5_packed));
    return std::string(buf);
}

} // namespace misterplex
