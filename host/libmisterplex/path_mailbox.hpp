#pragma once
// PLXP — FPGA→ARM path-play mailbox (OSD F1 .mpx stubs).
// Addresses/magics: mailbox_abi_spec.hpp (doorbell-relative on product maps).

#include "mailbox_abi_spec.hpp"

#include <cstdint>
#include <string>

namespace misterplex {

constexpr uint32_t kPathMailboxPhys     = mailbox_abi::kPlxpAddr;
constexpr uint32_t kPathMailboxMagic    = mailbox_abi::kPlxpMagic;
constexpr uint32_t kPathBufferPhys      = mailbox_abi::kPlxpPathAddr;
constexpr unsigned kPathMailboxMaxLen   = mailbox_abi::kPlxpPathMax;
constexpr unsigned kPathMailboxCtrlOff  = mailbox_abi::kPlxpCtrlOff;
constexpr unsigned kPathMailboxPathOff  = mailbox_abi::kPlxpPathOff;

struct PathPlaySample {
    uint16_t seq = 0;
    uint8_t len = 0;
    std::string path;
};

inline bool decodePathMailboxWord(uint64_t word, uint16_t& seq, uint8_t& len) {
    if (static_cast<uint32_t>(word) != kPathMailboxMagic)
        return false;
    len = static_cast<uint8_t>((word >> 32) & 0xFFu);
    seq = static_cast<uint16_t>((word >> 48) & 0xFFFFu);
    if (len == 0 || len > kPathMailboxMaxLen)
        return false;
    return true;
}

// Trim trailing CR/LF/NUL/space from a path buffer of length len.
inline std::string pathFromBuffer(const uint8_t* buf, size_t len) {
    while (len > 0) {
        const uint8_t b = buf[len - 1];
        if (b == 0 || b == '\n' || b == '\r' || b == ' ' || b == '\t')
            --len;
        else
            break;
    }
    if (len == 0)
        return {};
    // Reject embedded NULs in the middle.
    for (size_t i = 0; i < len; ++i) {
        if (buf[i] == 0)
            return {};
    }
    return std::string(reinterpret_cast<const char*>(buf), len);
}

// Edge detector: fire once per new seq with a non-empty path.
// First valid sample after attach is latched only (stale DDR after core load).
class PathMailboxEdgeDetector {
public:
    void reset() {
        seen_ = false;
        seq_ = 0;
    }

    bool accept(uint16_t seq, const std::string& path, std::string& outPath) {
        outPath.clear();
        if (path.empty())
            return false;
        if (!seen_) {
            seen_ = true;
            seq_ = seq;
            return false;
        }
        if (seq == seq_)
            return false;
        seq_ = seq;
        outPath = path;
        return true;
    }

private:
    bool seen_ = false;
    uint16_t seq_ = 0;
};

} // namespace misterplex
