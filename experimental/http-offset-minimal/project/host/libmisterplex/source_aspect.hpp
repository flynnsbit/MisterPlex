#pragma once

#include <array>
#include <cctype>
#include <cerrno>
#include <cmath>
#include <cstdint>
#include <cstdlib>
#include <numeric>
#include <string>

#include "mailbox_abi_spec.hpp"

namespace misterplex {

constexpr uint8_t kSourceAspectIoctlIndex = 4;
constexpr uint32_t kSourceAspectPacketMagic = 0x41584C50u; // "PLXA" little-endian
constexpr uint16_t kSourceAspectMax = 4095;
constexpr double kSourceAspectMinRatio = 0.25;
constexpr double kSourceAspectMaxRatio = 4.0;

struct SourceAspect {
    uint16_t x = 4;
    uint16_t y = 3;
    bool valid = false;
};

// 720p HDMI product is 16:9 (1280×720 leftover and 960×540 Track B).
// 240p/480p stay 4:3 until a stream publishes another DAR.
inline bool bankIsHdmi720pClass(int w, int h) {
    return (w >= 1280 && h >= 720) || (w == 960 && h == 540);
}

inline SourceAspect defaultSourceAspectForBank(int w, int h) {
    if (bankIsHdmi720pClass(w, h))
        return {16, 9, true};
    return {4, 3, true};
}

struct SourceAspectAck {
    SourceAspect aspect{};
    uint8_t token = 0;
};

inline SourceAspect reduceSourceAspect(int64_t x, int64_t y) {
    if (x <= 0 || y <= 0)
        return {};
    const int64_t divisor = std::gcd(x, y);
    x /= divisor;
    y /= divisor;
    if (x > kSourceAspectMax || y > kSourceAspectMax)
        return {};
    return {static_cast<uint16_t>(x), static_cast<uint16_t>(y), true};
}

inline SourceAspect sourceAspectFromDouble(double ratio) {
    if (!std::isfinite(ratio) || ratio < kSourceAspectMinRatio ||
        ratio > kSourceAspectMaxRatio)
        return {};

    static constexpr SourceAspect common[] = {
        {4, 3, true}, {16, 9, true}, {3, 2, true}, {5, 4, true},
        {21, 9, true}, {47, 20, true}, {37, 20, true}, {239, 100, true},
    };
    for (const auto& aspect : common) {
        const double candidate =
            static_cast<double>(aspect.x) / static_cast<double>(aspect.y);
        if (std::abs(ratio - candidate) < 0.005)
            return aspect;
    }

    uint16_t bestX = 0;
    uint16_t bestY = 0;
    double bestError = 1e9;
    // PMS and FFmpeg describe DAR with short decimal strings. Keeping the
    // denominator bounded avoids turning arbitrary malformed decimals into
    // huge, apparently authoritative scaler ratios.
    constexpr uint16_t kMaxMetadataDenominator = 100;
    for (uint16_t y = 1; y <= kMaxMetadataDenominator; ++y) {
        const long rounded = std::lround(ratio * static_cast<double>(y));
        if (rounded <= 0 || rounded > kSourceAspectMax)
            continue;
        const double error =
            std::abs(ratio - static_cast<double>(rounded) / static_cast<double>(y));
        if (error < bestError) {
            bestError = error;
            bestX = static_cast<uint16_t>(rounded);
            bestY = y;
        }
    }
    if (bestError > 0.001)
        return {};
    return reduceSourceAspect(bestX, bestY);
}

inline SourceAspect sourceAspectFromText(const std::string& ratioText) {
    if (ratioText.empty())
        return {};

    const auto separator = ratioText.find_first_of(":/");
    if (separator != std::string::npos) {
        const std::string xText = ratioText.substr(0, separator);
        const std::string yText = ratioText.substr(separator + 1);
        char* xEnd = nullptr;
        char* yEnd = nullptr;
        errno = 0;
        const long long x = std::strtoll(xText.c_str(), &xEnd, 10);
        const long long y = std::strtoll(yText.c_str(), &yEnd, 10);
        if (errno == 0 && xEnd != xText.c_str() && *xEnd == '\0' &&
            yEnd != yText.c_str() && *yEnd == '\0') {
            const auto parsed = reduceSourceAspect(x, y);
            if (parsed.valid) {
                const double ratio =
                    static_cast<double>(parsed.x) / static_cast<double>(parsed.y);
                if (ratio >= kSourceAspectMinRatio && ratio <= kSourceAspectMaxRatio)
                    return parsed;
            }
        }
        return {};
    }

    {
        char* end = nullptr;
        errno = 0;
        const double ratio = std::strtod(ratioText.c_str(), &end);
        if (errno == 0 && end != ratioText.c_str() && *end == '\0') {
            const auto parsed = sourceAspectFromDouble(ratio);
            if (parsed.valid)
                return parsed;
        }
    }
    return {};
}

inline SourceAspect sourceAspectFromMetadata(const std::string& displayAspectText,
                                             const std::string& sampleAspectText,
                                             int codedWidth,
                                             int codedHeight,
                                             bool squarePixelsKnown) {
    const auto display = sourceAspectFromText(displayAspectText);
    if (display.valid)
        return display;

    const auto sample = sourceAspectFromText(sampleAspectText);
    if (sample.valid && codedWidth > 0 && codedHeight > 0) {
        return reduceSourceAspect(static_cast<int64_t>(codedWidth) * sample.x,
                                  static_cast<int64_t>(codedHeight) * sample.y);
    }
    if (squarePixelsKnown)
        return reduceSourceAspect(codedWidth, codedHeight);
    return {};
}

inline SourceAspect sourceAspectFromFfmpegProbeText(const std::string& text) {
    size_t pos = 0;
    while ((pos = text.find("DAR ", pos)) != std::string::npos) {
        pos += 4;
        const size_t end = text.find_first_of(" \t\r\n],", pos);
        const auto parsed = sourceAspectFromText(text.substr(pos, end - pos));
        if (parsed.valid)
            return parsed;
    }
    return {};
}

// First Video: WxH (skips fourcc 0x........). P5: file==bank for identity skip.
// First "N fps" or "N/M fps" on the Video: line (tbr is fallback).
inline bool fpsTokenFromFfmpegProbeText(const std::string& text, std::string& token) {
    token.clear();
    const size_t video = text.find("Video:");
    const std::string body =
        video == std::string::npos ? text : text.substr(video);
    const char* keys[] = {" fps", " tbr"};
    for (const char* key : keys) {
        size_t pos = 0;
        while ((pos = body.find(key, pos)) != std::string::npos) {
            size_t b = pos;
            while (b > 0 && (std::isdigit(static_cast<unsigned char>(body[b - 1])) ||
                             body[b - 1] == '.' || body[b - 1] == '/'))
                --b;
            if (b < pos) {
                token = body.substr(b, pos - b);
                return !token.empty();
            }
            pos += 4;
        }
    }
    return false;
}

inline bool codedSizeFromFfmpegProbeText(const std::string& text, int& w, int& h) {
    w = 0;
    h = 0;
    const size_t video = text.find("Video:");
    const char* s = text.c_str() + (video == std::string::npos ? 0 : video);
    const char* end = text.c_str() + text.size();
    for (const char* p = s; p + 3 < end; ++p) {
        if (!std::isdigit(static_cast<unsigned char>(*p)))
            continue;
        char* endx = nullptr;
        const long ww = std::strtol(p, &endx, 10);
        if (!endx || endx == p || *endx != 'x' || ww < 16 || ww > 4096)
            continue;
        char* endy = nullptr;
        const long hh = std::strtol(endx + 1, &endy, 10);
        if (!endy || endy == endx + 1 || hh < 16 || hh > 4096)
            continue;
        w = static_cast<int>(ww);
        h = static_cast<int>(hh);
        return true;
    }
    return false;
}

inline std::array<uint8_t, 9> encodeSourceAspectPacket(const SourceAspect& aspect,
                                                       uint8_t token) {
    return {
        static_cast<uint8_t>(kSourceAspectPacketMagic & 0xFFu),
        static_cast<uint8_t>((kSourceAspectPacketMagic >> 8) & 0xFFu),
        static_cast<uint8_t>((kSourceAspectPacketMagic >> 16) & 0xFFu),
        static_cast<uint8_t>((kSourceAspectPacketMagic >> 24) & 0xFFu),
        static_cast<uint8_t>(aspect.x & 0xFFu),
        static_cast<uint8_t>(aspect.x >> 8),
        static_cast<uint8_t>(aspect.y & 0xFFu),
        static_cast<uint8_t>(aspect.y >> 8),
        token,
    };
}

inline bool decodeSourceAspectAckWord(uint64_t word, SourceAspectAck& out) {
    if (static_cast<uint32_t>(word) != mailbox_abi::kPlxjMagic)
        return false;
    const uint16_t x = static_cast<uint16_t>((word >> 32) & 0x0fffu);
    const uint16_t y = static_cast<uint16_t>((word >> 44) & 0x0fffu);
    const auto aspect = reduceSourceAspect(x, y);
    if (!aspect.valid)
        return false;
    out.aspect = {x, y, true};
    out.token = static_cast<uint8_t>(word >> 56);
    return true;
}

inline bool decodeStableSourceAspectAck(uint32_t lo, uint32_t hi,
                                        uint32_t verifyLo, uint32_t verifyHi,
                                        SourceAspectAck& out) {
    if (lo != verifyLo || hi != verifyHi)
        return false;
    return decodeSourceAspectAckWord(static_cast<uint64_t>(lo) |
                                     (static_cast<uint64_t>(hi) << 32), out);
}

} // namespace misterplex
