// OSD_CONTROL policy: detect core generation from live CONF_STR, not filenames.
//
// Safety property (fail closed):
//   Auto enables Idle/A/V bit decode ONLY when UIO_GET_STRING returns a CONF_STR
//   that contains the product Idle-screen menu marker:
//       "O[15:14],Idle screen"
//   (see fpga/Plex_MiSTer/Plex.sv CONF_STR and docs/release.md).
//
//   Pre-v3 cores use those same status bits for Pattern / Content FPS. Applying
//   the v3 decoder on them corrupts settings. Filenames and CORENAME are useless
//   (every build reports CORENAME=Plex).
//
// PLXS DDR mailbox (magic 0x504C5853 at 0x3007F100) is TRANSPORT only — it
// carries status[15:0] without SPI. It is NOT a generation proof by itself:
// a mismatched or hand-rolled bitstream could publish PLXS while still using
// pre-v3 bit meanings. Auto therefore never enables apply from mailbox liveness
// alone. Once CONF_STR proves V3 Idle semantics, mailbox is preferred and SPI
// status is an allowed fallback (bits are known Idle/A/V).
//
// Pure header — unit-tested without FPGA.
#pragma once

#include <cstdint>
#include <string>

namespace misterplex {

// Conf / operator override. Default product mode is Auto.
enum class OsdControlMode : uint8_t {
    Auto = 0,      // probe live CONF_STR; apply only when V3 Idle proven
    ForcedOn = 1,  // always apply (operator accepts pre-v3 risk)
    ForcedOff = 2, // never poll / never apply
};

// Settled core generation / capability for apply decisions.
// Named for logs: greppable capability=v3_idle|pre_v3|absent|unknown
enum class OsdCapability : uint8_t {
    Unknown = 0, // confstr not yet classified
    PreV3 = 1,   // confstr readable and lacks Idle-screen marker (or has Pattern)
    V3Idle = 2,  // confstr contains O[15:14],Idle screen — safe Idle/A/V decode
    Absent = 3,  // probe window elapsed without a readable confstr
};

// Exact product marker from Plex.sv CONF_STR (Idle screen menu, v3+).
// Do not loosen to a bare "Idle" substring — keep the bit field + label.
inline constexpr const char kOsdIdleScreenConfMarker[] = "O[15:14],Idle screen";

// Positive pre-v3 markers from the CONF_STR replaced by commit 363183d8
// (A/V lipsync fix, OSD menu v3 + idle screen). Presence of either without the
// Idle-screen marker is definitive pre-v3 bit layout.
inline constexpr const char kOsdPreV3PatternMarker[] = "O[7:6],Pattern";
inline constexpr const char kOsdPreV3ContentFpsMarker[] = "O[5:4],Content FPS";

inline const char* osdControlModeName(OsdControlMode m) {
    switch (m) {
    case OsdControlMode::Auto:
        return "auto";
    case OsdControlMode::ForcedOn:
        return "on";
    case OsdControlMode::ForcedOff:
        return "off";
    }
    return "auto";
}

inline const char* osdCapabilityName(OsdCapability c) {
    switch (c) {
    case OsdCapability::Unknown:
        return "unknown";
    case OsdCapability::PreV3:
        return "pre_v3";
    case OsdCapability::V3Idle:
        return "v3_idle";
    case OsdCapability::Absent:
        return "absent";
    }
    return "unknown";
}

// Classify a live CONF_STR blob from FpgaSpi::getConfigString / UIO_GET_STRING.
// Empty → Unknown (caller keeps probing). Never guesses from RBF path.
inline OsdCapability classifyOsdConfStr(const std::string& confstr) {
    if (confstr.empty())
        return OsdCapability::Unknown;
    if (confstr.find(kOsdIdleScreenConfMarker) != std::string::npos)
        return OsdCapability::V3Idle;
    // Readable string without Idle-screen menu → pre-v3 bit layout (fail closed).
    return OsdCapability::PreV3;
}

// True when confstr text itself is positive pre-v3 evidence (for log detail).
inline bool confStrHasPreV3Markers(const std::string& confstr) {
    return confstr.find(kOsdPreV3PatternMarker) != std::string::npos ||
           confstr.find(kOsdPreV3ContentFpsMarker) != std::string::npos;
}

// Parse conf token. Empty / "auto" → Auto (smart default).
// 1/true/yes/on → ForcedOn. 0/false/no/off → ForcedOff.
// Unknown non-empty tokens → ForcedOff (fail closed; never silently enable).
inline OsdControlMode parseOsdControlMode(std::string raw) {
    while (!raw.empty() &&
           (raw.back() == ' ' || raw.back() == '\t' || raw.back() == '\r' || raw.back() == '\n'))
        raw.pop_back();
    size_t i = 0;
    while (i < raw.size() &&
           (raw[i] == ' ' || raw[i] == '\t' || raw[i] == '\r' || raw[i] == '\n'))
        ++i;
    if (i)
        raw.erase(0, i);
    if (raw.empty() || raw == "auto")
        return OsdControlMode::Auto;
    if (raw == "1" || raw == "true" || raw == "yes" || raw == "on")
        return OsdControlMode::ForcedOn;
    if (raw == "0" || raw == "false" || raw == "no" || raw == "off")
        return OsdControlMode::ForcedOff;
    return OsdControlMode::ForcedOff;
}

// Run the poll/probe thread?
inline bool osdPollWanted(OsdControlMode mode) {
    return mode != OsdControlMode::ForcedOff;
}

// May apply decoded status[15:0] to idle / A/V / content tier?
// Auto requires V3Idle from CONF_STR — never from mailbox alone.
inline bool osdApplyWanted(OsdControlMode mode, OsdCapability cap) {
    if (mode == OsdControlMode::ForcedOff)
        return false;
    if (mode == OsdControlMode::ForcedOn)
        return true;
    return cap == OsdCapability::V3Idle;
}

// SPI UIO_GET_STATUS for the OSD word: allowed once bit semantics are proven
// V3Idle (Auto) or when the operator ForcedOn. Never under ForcedOff / Auto+pre_v3.
inline bool osdSpiStatusWanted(OsdControlMode mode, OsdCapability cap) {
    if (mode == OsdControlMode::ForcedOff)
        return false;
    if (mode == OsdControlMode::ForcedOn)
        return true;
    return cap == OsdCapability::V3Idle;
}

// Back-compat name: SPI without confstr proof is ForcedOn-only (pre-v3 footgun).
inline bool osdSpiFallbackWanted(OsdControlMode mode) {
    return mode == OsdControlMode::ForcedOn;
}

// Mirror of FpgaSpi::readOsdMailbox liveness (seq must advance; stale freezes → dead).
// Transport health only — does not authorize apply under Auto.
struct OsdMailboxLiveness {
    bool seen = false;
    uint16_t last_seq = 0;
    double last_change_ms = 0.0;
    bool alive = false;

    bool observe(bool magic_ok, uint16_t seq, double now_ms, double stale_ms = 2000.0) {
        if (!magic_ok) {
            alive = false;
            return false;
        }
        if (!seen) {
            // First sight proves nothing — may be leftover DDR from a prior core.
            seen = true;
            last_seq = seq;
            last_change_ms = now_ms;
            alive = false;
            return false;
        }
        if (seq != last_seq) {
            last_seq = seq;
            last_change_ms = now_ms;
            alive = true;
        } else if (now_ms - last_change_ms > stale_ms) {
            alive = false;
        }
        return alive;
    }
};

// Auto probe window for UIO_GET_STRING. SPI may skip while Main is busy; retry
// until this budget elapses, then settle Absent (fail closed).
constexpr double kOsdAutoProbeMs = 2500.0;

// After start_ms, still-Unknown capability → Absent. PreV3/V3Idle stick.
inline OsdCapability osdAutoSettle(OsdCapability current, double start_ms, double now_ms,
                                   double probe_ms = kOsdAutoProbeMs) {
    if (current == OsdCapability::V3Idle || current == OsdCapability::PreV3 ||
        current == OsdCapability::Absent)
        return current;
    if (now_ms - start_ms >= probe_ms)
        return OsdCapability::Absent;
    return OsdCapability::Unknown;
}

// Optional HDMI banner when F12 Idle cannot drive the daemon.
// Product default: LOG ONLY (no HDMI paint) so IDLE_SCREEN=logo stays a clean
// chevron. Opt-in conf OSD_INERT_NOTICE=1 flashes this string via PlaybackOverlay.
// Keep ASCII + short if ever enabled on glass.
inline const char* osdInertUserNotice() {
    return "F12 Idle: use conf";
}

} // namespace misterplex
