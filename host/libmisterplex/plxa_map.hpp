#pragma once
// PLXA — self-describing mailbox map (FPGA→ARM bootstrap).
//
// Fixed absolute phys 0x3007F0F0 so the host can find the map without already
// knowing the product doorbell. The word names abi_version + flags + PLXD
// offset; a version mismatch must FAIL LOUDLY (this class of bug burned a week
// of zero-reads on a core with no writer).
//
// Does not edit mailbox_abi_spec.hpp (w-mem). Coordinate any ABI table merge
// through the parent.

#include <cstdint>

namespace misterplex {
namespace plxa {

// Absolute bootstrap (outside 720p phys window starting at 0x3018_0000).
inline constexpr uint32_t kPlxaPhys = 0x3007F0F0u;
// In-window mirror on every product doorbell page (RTL MAP_ON_DOORBELL).
// Prefer this when the frame mmap already covers the doorbell.
inline constexpr uint32_t kPlxaDoorbellOffset = 0x0F0u;
inline constexpr uint32_t kPlxaMagic = 0x504C5841u; // "PLXA"
// Bump when layout/flags semantics break. Host refuses unknown versions.
inline constexpr uint8_t kPlxaAbiVersion = 1;

inline uint32_t plxaPhysOnDoorbell(uint32_t doorbell_phys) {
    return doorbell_phys + kPlxaDoorbellOffset;
}

// flags
inline constexpr uint8_t kFlagDoorbellRelative = 1u << 0; // mailboxes at doorbell+off
inline constexpr uint8_t kFlagHasPlxd = 1u << 1;          // PLXD writer present

struct MapWord {
    uint8_t version = 0;
    uint8_t flags = 0;
    uint16_t plxd_offset = 0; // byte offset from doorbell if relative; else ignored
    bool ok_magic = false;
};

inline bool decodePlxaWord(uint64_t word, MapWord& out) {
    out = MapWord{};
    if (static_cast<uint32_t>(word) != kPlxaMagic)
        return false;
    const uint32_t hi = static_cast<uint32_t>(word >> 32);
    out.ok_magic = true;
    out.version = static_cast<uint8_t>(hi & 0xFFu);
    out.flags = static_cast<uint8_t>((hi >> 8) & 0xFFu);
    out.plxd_offset = static_cast<uint16_t>((hi >> 16) & 0xFFFFu);
    return true;
}

enum class AcceptStatus {
    Ok = 0,
    BadMagic,
    VersionMismatch,
    MissingPlxdCapability,
};

// expected_version defaults to the host's compiled kPlxaAbiVersion.
inline AcceptStatus acceptPlxa(const MapWord& m, uint8_t expected_version = kPlxaAbiVersion) {
    if (!m.ok_magic)
        return AcceptStatus::BadMagic;
    if (m.version != expected_version)
        return AcceptStatus::VersionMismatch;
    if ((m.flags & kFlagHasPlxd) == 0)
        return AcceptStatus::MissingPlxdCapability;
    return AcceptStatus::Ok;
}

inline const char* acceptStatusName(AcceptStatus s) {
    switch (s) {
    case AcceptStatus::Ok:
        return "ok";
    case AcceptStatus::BadMagic:
        return "bad_magic";
    case AcceptStatus::VersionMismatch:
        return "version_mismatch";
    case AcceptStatus::MissingPlxdCapability:
        return "missing_plxd";
    }
    return "unknown";
}

inline uint64_t packPlxaWord(uint8_t version, uint8_t flags, uint16_t plxd_offset) {
    const uint32_t hi = static_cast<uint32_t>(version) |
                        (static_cast<uint32_t>(flags) << 8) |
                        (static_cast<uint32_t>(plxd_offset) << 16);
    return static_cast<uint64_t>(kPlxaMagic) | (static_cast<uint64_t>(hi) << 32);
}

// Resolve PLXD phys from an accepted PLXA map.
// relative: doorbell_phys + plxd_offset; absolute: fallback_abs (registry).
// Caller must have acceptPlxa(...) == Ok.
inline uint32_t resolvePlxdPhys(const MapWord& m, uint32_t doorbell_phys,
                                uint32_t fallback_abs) {
    if ((m.flags & kFlagDoorbellRelative) != 0)
        return doorbell_phys + static_cast<uint32_t>(m.plxd_offset);
    return fallback_abs;
}

} // namespace plxa
} // namespace misterplex
