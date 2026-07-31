// OSD_CONTROL policy: auto-detect capability from the core mailbox, not filenames.
//
// Safety: on Auto, apply decoded OSD bits ONLY when the PLXS DDR mailbox is LIVE
// (magic + advancing seq). Pre-v3 / pre-mailbox cores never publish a live PLXS
// heartbeat, so Auto fails closed and never reinterprets Pattern/Content-FPS bits
// as A/V offset / Idle screen. Filenames and CORENAME are not used (all say "Plex").
//
// Pure header — unit-tested without FPGA.
#pragma once

#include <cstdint>
#include <string>

namespace misterplex {

// Conf / operator override. Default product mode is Auto.
enum class OsdControlMode : uint8_t {
    Auto = 0,      // probe PLXS; apply only when LIVE
    ForcedOn = 1,  // always apply (mailbox preferred; SPI fallback) — operator risk
    ForcedOff = 2, // never poll / never apply
};

// Observed core capability (never guessed from RBF path or CORENAME).
enum class OsdCapability : uint8_t {
    Unknown = 0,     // not yet proven
    LiveMailbox = 1, // PLXS magic + advancing seq (v3+ mailbox path)
    Absent = 2,      // probe window elapsed without LIVE mailbox
};

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
    case OsdCapability::LiveMailbox:
        return "live_mailbox";
    case OsdCapability::Absent:
        return "absent";
    }
    return "unknown";
}

// Parse conf token. Empty / "auto" → Auto (smart default).
// 1/true/yes/on → ForcedOn. 0/false/no/off → ForcedOff.
// Unknown non-empty tokens → ForcedOff (fail closed; never silently enable).
inline OsdControlMode parseOsdControlMode(std::string raw) {
    // trim CR/space (conf files may be CRLF)
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
// Auto requires LiveMailbox — SPI-only words are never applied under Auto.
inline bool osdApplyWanted(OsdControlMode mode, OsdCapability cap) {
    if (mode == OsdControlMode::ForcedOff)
        return false;
    if (mode == OsdControlMode::ForcedOn)
        return true;
    return cap == OsdCapability::LiveMailbox;
}

// SPI fallback (pre-mailbox getCoreStatus) is only for ForcedOn.
// Auto must not use SPI status bits — that is the pre-v3 footgun.
inline bool osdSpiFallbackWanted(OsdControlMode mode) {
    return mode == OsdControlMode::ForcedOn;
}

// Mirror of FpgaSpi::readOsdMailbox liveness (seq must advance; stale freezes → dead).
// Unit tests pin the contract so host and SPI code cannot drift silently.
struct OsdMailboxLiveness {
    bool seen = false;
    uint16_t last_seq = 0;
    double last_change_ms = 0.0;
    bool alive = false;

    // magic_ok: lo word == "PLXS". seq: hi[31:16]. now_ms: monotonic ms.
    // stale_ms: no seq change → declare not alive (default 2000 matches fpga_spi.cpp).
    // Returns true only when the sample is trusted LIVE for apply.
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

// Auto probe window: if no LIVE mailbox within this many ms after poll start,
// capability → Absent (fail closed). Matches "heartbeat is ms; two seconds frozen
// means nothing is publishing" class of timeout used by the mailbox reader.
constexpr double kOsdAutoProbeMs = 2500.0;

// After start_ms, with still-Unknown capability and no LIVE sample, settle Absent.
inline OsdCapability osdAutoSettle(OsdCapability current, double start_ms, double now_ms,
                                   double probe_ms = kOsdAutoProbeMs) {
    if (current == OsdCapability::LiveMailbox)
        return current;
    if (current == OsdCapability::Absent)
        return current;
    if (now_ms - start_ms >= probe_ms)
        return OsdCapability::Absent;
    return OsdCapability::Unknown;
}

// User-facing short notice when F12 Idle cannot drive the daemon.
// Keep ASCII + short: drawn with the 5x7 overlay font on idle HDMI.
inline const char* osdInertUserNotice() {
    return "F12 Idle: use conf";
}

} // namespace misterplex
