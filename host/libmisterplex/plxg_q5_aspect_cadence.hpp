#pragma once
// PLXG q5 — display aspect + content cadence (parent ABI arbitration #2 + #2.1).
//
// Wire: doorbell + 0x828, little-endian qword:
//   [11:0]  dar_x
//   [23:12] dar_y
//   [31:24] content_fps   integer family fps (0 = unspecified)
//   [32]    dar_valid
//   [33]    fps_valid
//   [34]    fps_1001      when fps_valid: rate = content_fps * 1000/1001
//                         (24+1001 → 24000/1001; 30+1001 → 30000/1001)
//   [63:35] RESERVED — must be zero; pack/validate MUST reject non-zero
//
// rd-duck (2026-08-03): integer-only content_fps buckets 24000/1001→24 and
// discards the exact rational ARM pacing preserves. w-clock at ~24.000672 then
// outruns 23.976 by ~0.024648 fps → bank miss/extra ~every 40.57s. Bit 34 is
// the minimal wire flag; host also keeps fps_num/fps_den for logs (not on wire).
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
    uint8_t content_fps = 0;  // [31:24] integer family (24/25/30/…)
    bool dar_valid = false;   // [32]
    bool fps_valid = false;   // [33]
    bool fps_1001 = false;    // [34] NTSC/film *1000/1001 when fps_valid
    // Host-only exact rational (not packed into q5 beyond family+1001 flag).
    int fps_num = 0;
    int fps_den = 0;
};

// First reserved bit after defined cadence fields (ABI #2.1).
constexpr unsigned kPlxgQ5ReservedShift = 35u;
constexpr uint64_t kPlxgQ5Fps1001Bit = 1ull << 34;

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

// Pack q5. Returns false if reserved [63:35] would be non-zero or fields
// exceed their widths. On failure *out is left unchanged.
inline bool packPlxgQ5(const PlxgAspectCadence& in, uint64_t* out) {
    if (!out)
        return false;
    if (in.dar_x > kPlxgDarFieldMax || in.dar_y > kPlxgDarFieldMax)
        return false;
    // fps_1001 without fps_valid is illegal (would look like reserved noise).
    if (in.fps_1001 && !in.fps_valid)
        return false;
    uint64_t q = 0;
    q |= static_cast<uint64_t>(in.dar_x & kPlxgDarFieldMax);
    q |= static_cast<uint64_t>(in.dar_y & kPlxgDarFieldMax) << 12;
    q |= static_cast<uint64_t>(in.content_fps) << 24;
    if (in.dar_valid)
        q |= 1ull << 32;
    if (in.fps_valid)
        q |= 1ull << 33;
    if (in.fps_1001)
        q |= kPlxgQ5Fps1001Bit;
    // Bits 63:35 must stay zero.
    if ((q >> kPlxgQ5ReservedShift) != 0)
        return false;
    *out = q;
    return true;
}

// Validate a wire qword: reserved [63:35] must be zero (bit 34 = fps_1001).
inline bool plxgQ5ReservedOk(uint64_t q5) {
    return (q5 >> kPlxgQ5ReservedShift) == 0;
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
    c.fps_1001 = ((q5 >> 34) & 1ull) != 0;
    // Reconstruct exact NTSC/film rational when flag set (host convenience).
    if (c.fps_valid && c.fps_1001 && c.content_fps > 0) {
        c.fps_num = static_cast<int>(c.content_fps) * 1000;
        c.fps_den = 1001;
    } else if (c.fps_valid && c.content_fps > 0) {
        c.fps_num = static_cast<int>(c.content_fps);
        c.fps_den = 1;
    }
    *out = c;
    return true;
}

// Reject path used by host-side models of the fabric receiver.
inline bool plxgQ5ReceiverAccepts(uint64_t q5) {
    return plxgQ5ReservedOk(q5);
}

// --- Selection: PMS metadata + measured geometry only; never invent defaults. ---

// Exact content rate from q5 family + 1001 flag (for fabric consumers / tests).
inline bool plxgContentFpsRational(const PlxgAspectCadence& c, int* num, int* den) {
    if (!num || !den || !c.fps_valid || c.content_fps == 0)
        return false;
    if (c.fps_1001) {
        *num = static_cast<int>(c.content_fps) * 1000;
        *den = 1001;
        return true;
    }
    *num = static_cast<int>(c.content_fps);
    *den = 1;
    return true;
}

// Drift: when fabric runs at f_fab and content at f_c, unit phase slip period (s).
// Returns 0 if rates equal or invalid. rd-duck: 24.000672 vs 23.976 → ~40.57s.
inline double cadenceUnitSlipPeriodSec(double fabric_hz, double content_hz) {
    if (!(fabric_hz > 0.0) || !(content_hz > 0.0))
        return 0.0;
    const double d = fabric_hz - content_hz;
    if (d == 0.0)
        return 0.0;
    const double ad = d < 0.0 ? -d : d;
    return 1.0 / ad;
}

// Integer content_fps + optional 1001 flag for wire.
// Exact 24000/1001 → fps=24, fps_1001=1 (NOT silent bucket to integer 24 only).
// Does NOT default to 24 when unknown.
inline bool contentFpsForPlxg(int fps_num, int fps_den, uint8_t* out_fps, bool* out_1001) {
    if (!out_fps || fps_num <= 0 || fps_den <= 0)
        return false;
    if (out_1001)
        *out_1001 = false;

    // Exact integer 1..255 (den=1).
    if (fps_den == 1 && fps_num >= 1 && fps_num <= 255) {
        *out_fps = static_cast<uint8_t>(fps_num);
        return true;
    }

    // Exact NTSC/film rationals — preserve 1001 on the wire flag.
    if (fps_den == 1001) {
        if (fps_num == 24000) {
            *out_fps = 24;
            if (out_1001)
                *out_1001 = true;
            return true;
        }
        if (fps_num == 30000) {
            *out_fps = 30;
            if (out_1001)
                *out_1001 = true;
            return true;
        }
        if (fps_num == 60000) {
            *out_fps = 60;
            if (out_1001)
                *out_1001 = true;
            return true;
        }
        if (fps_num == 12000) {
            *out_fps = 12;
            if (out_1001)
                *out_1001 = true;
            return true;
        }
    }

    // Reduced forms already *1000/1001 (e.g. 24/1.001 not representable as int;
    // accept num/den that reduce to N*1000 / 1001).
    if (fps_den > 0 && (fps_den % 1001) == 0) {
        const int k = fps_den / 1001;
        if (k > 0 && (fps_num % k) == 0) {
            const int n1000 = fps_num / k;
            if (n1000 > 0 && (n1000 % 1000) == 0) {
                const int fam = n1000 / 1000;
                if (fam >= 1 && fam <= 255) {
                    *out_fps = static_cast<uint8_t>(fam);
                    if (out_1001)
                        *out_1001 = true;
                    return true;
                }
            }
        }
    }

    const double r = static_cast<double>(fps_num) / static_cast<double>(fps_den);
    if (!(r > 0.0) || r > 255.0)
        return false;

    // Near-NTSC floats from probes: set 1001 when clearly not integer 24/30/60.
    struct Bucket {
        double lo, hi;
        uint8_t v;
        bool is_1001_center; // center is N*1000/1001
    };
    static const Bucket kBuckets[] = {
        {23.5, 23.99, 24, true},  // 23.976
        {23.99, 24.5, 24, false}, // integer 24
        {24.5, 25.5, 25, false},
        {29.5, 29.99, 30, true}, // 29.97
        {29.99, 30.5, 30, false},
        {49.5, 50.5, 50, false},
        {59.0, 59.99, 60, true}, // 59.94
        {59.99, 61.0, 60, false},
    };
    for (const auto& b : kBuckets) {
        if (r > b.lo && r < b.hi) {
            *out_fps = b.v;
            if (out_1001)
                *out_1001 = b.is_1001_center;
            return true;
        }
    }
    return false;
}

// Back-compat: integer family only (drops 1001 distinction — prefer contentFpsForPlxg).
inline bool contentFpsIntegerForPlxg(int fps_num, int fps_den, uint8_t* out_fps) {
    bool dummy = false;
    return contentFpsForPlxg(fps_num, fps_den, out_fps, &dummy);
}

// Provenance for DAR (rd-duck adversarial audit):
//   DirectPlay  — coded samples are the source; apply Stream@pixelAspectRatio
//                 to coded WxH (source SAR is real).
//   Transcode   — PMS square-pixel fit already baked SAR into delivered dims.
//                 Applying *source* SAR to delivered 624×350 double-counts
//                 anamorphic (624×350×160:117 → 256:105 wrong; true DAR 16:9).
//                 Prefer Media@aspectRatio; else delivered stream SAR if 1:1 or
//                 present; else delivered storage aspect (square-pixel xcode).
enum class PlxgDarProvenance {
    DirectPlay = 0,
    Transcode = 1,
};

inline bool darFromCodedTimesSar(int coded_w, int coded_h, int sar_n, int sar_d, uint16_t* dar_x,
                                 uint16_t* dar_y) {
    if (!dar_x || !dar_y || coded_w <= 0 || coded_h <= 0 || sar_n <= 0 || sar_d <= 0)
        return false;
    uint64_t n = static_cast<uint64_t>(coded_w) * static_cast<uint64_t>(sar_n);
    uint64_t d = static_cast<uint64_t>(coded_h) * static_cast<uint64_t>(sar_d);
    const uint64_t g = std::gcd(n, d);
    n /= g;
    d /= g;
    if (n == 0 || d == 0 || n > 0xFFFFFFFFull || d > 0xFFFFFFFFull)
        return false;
    return fitDar12(static_cast<uint32_t>(n), static_cast<uint32_t>(d), *dar_x, *dar_y);
}

// DAR selection with explicit provenance. NEVER invents 16:9 defaults.
// pixelAspectRatio: for DirectPlay = source Stream SAR; for Transcode =
//   *delivered* stream SAR only (usually 1:1) — do not pass source SAR.
inline bool contentDarForPlxg(int coded_w, int coded_h, const std::string& pixelAspectRatio,
                              const std::string& mediaAspectRatio, uint16_t* dar_x,
                              uint16_t* dar_y,
                              PlxgDarProvenance prov = PlxgDarProvenance::DirectPlay) {
    if (!dar_x || !dar_y)
        return false;

    if (prov == PlxgDarProvenance::Transcode) {
        // 1) Media display aspect (title-level) — survives square-pixel xcode.
        RationalAspect mar;
        if (parseAspectRatioToken(mediaAspectRatio, mar) && mar.valid()) {
            return fitDar12(static_cast<uint32_t>(mar.num), static_cast<uint32_t>(mar.den),
                            *dar_x, *dar_y);
        }
        // 2) Delivered SAR (if caller passed delivered, not source).
        RationalAspect sar;
        if (parseAspectRatioToken(pixelAspectRatio, sar) && sar.valid() && coded_w > 0 &&
            coded_h > 0) {
            return darFromCodedTimesSar(coded_w, coded_h, sar.num, sar.den, dar_x, dar_y);
        }
        // 3) Square-pixel universal delivery: DAR = storage aspect of coded.
        if (coded_w > 0 && coded_h > 0)
            return fitDar12(static_cast<uint32_t>(coded_w), static_cast<uint32_t>(coded_h),
                            *dar_x, *dar_y);
        return false;
    }

    // DirectPlay: coded × source SAR first.
    RationalAspect sar;
    if (parseAspectRatioToken(pixelAspectRatio, sar) && sar.valid() && coded_w > 0 &&
        coded_h > 0) {
        return darFromCodedTimesSar(coded_w, coded_h, sar.num, sar.den, dar_x, dar_y);
    }
    RationalAspect mar;
    if (parseAspectRatioToken(mediaAspectRatio, mar) && mar.valid()) {
        return fitDar12(static_cast<uint32_t>(mar.num), static_cast<uint32_t>(mar.den), *dar_x,
                        *dar_y);
    }
    // Unknown — do not invent storage aspect for anamorphic DP without SAR.
    return false;
}

// Build the full aspect/cadence payload. Empty strings / non-positive rates →
// corresponding valid bit clear. Never sets a default 16:9 or 24 fps.
inline PlxgAspectCadence selectPlxgAspectCadence(int coded_w, int coded_h,
                                                 const std::string& pixelAspectRatio,
                                                 const std::string& mediaAspectRatio,
                                                 int fps_num, int fps_den,
                                                 PlxgDarProvenance prov =
                                                     PlxgDarProvenance::DirectPlay) {
    PlxgAspectCadence c{};
    uint16_t dx = 0, dy = 0;
    if (contentDarForPlxg(coded_w, coded_h, pixelAspectRatio, mediaAspectRatio, &dx, &dy,
                          prov)) {
        c.dar_x = dx;
        c.dar_y = dy;
        c.dar_valid = true;
    }
    uint8_t fps = 0;
    bool f1001 = false;
    if (contentFpsForPlxg(fps_num, fps_den, &fps, &f1001)) {
        c.content_fps = fps;
        c.fps_valid = true;
        c.fps_1001 = f1001;
        c.fps_num = fps_num;
        c.fps_den = fps_den;
    }
    return c;
}

// Human-readable one-line for daemon logs (no secrets).
inline std::string formatPlxgQ5LogLine(const PlxgAspectCadence& c, uint64_t q5_packed) {
    char buf[256];
    std::snprintf(buf, sizeof(buf),
                  "PLXG_Q5 dar=%u/%u dar_valid=%d fps=%u fps_1001=%d fps_valid=%d "
                  "fps_rational=%d/%d q5=0x%016llx off=0x828",
                  static_cast<unsigned>(c.dar_x), static_cast<unsigned>(c.dar_y),
                  c.dar_valid ? 1 : 0, static_cast<unsigned>(c.content_fps),
                  c.fps_1001 ? 1 : 0, c.fps_valid ? 1 : 0, c.fps_num, c.fps_den,
                  static_cast<unsigned long long>(q5_packed));
    return std::string(buf);
}

} // namespace misterplex
