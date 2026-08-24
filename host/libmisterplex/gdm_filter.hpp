#pragma once

// Plex GDM discovery: classic clients probe UDP 32412; iOS / newer clients
// also probe 32414. Reply only to M-SEARCH. The old companion predicate
//   strstr(buf, "M-SEARCH") || strstr(buf, "plex")
// also matched our own HTTP/1.0 200 advertise (Content-Type: plex/...) and
// livelocked the GDM thread on its own broadcast.

#include <cctype>
#include <cstddef>
#include <cstdint>
#include <cstring>

namespace misterplex {

inline constexpr uint16_t kGdmListenPorts[] = {32412, 32414};

// True when the datagram is a GDM/SSDP M-SEARCH probe.
// First token only, case-insensitive — never scan the body for "plex".
inline bool gdmShouldReply(const char* buf, size_t len) {
    static constexpr char kMeth[] = "m-search";
    constexpr size_t kMethLen = sizeof(kMeth) - 1;
    if (!buf || len < kMethLen)
        return false;
    for (size_t i = 0; i < kMethLen; ++i) {
        const unsigned char c = static_cast<unsigned char>(buf[i]);
        if (static_cast<char>(std::tolower(c)) != kMeth[i])
            return false;
    }
    return true;
}

inline bool gdmShouldReplyCStr(const char* buf) {
    if (!buf)
        return false;
    return gdmShouldReply(buf, std::strlen(buf));
}

// Loose probe check: reject our own advertise (HTTP/ reply + media-player
// Content-Type) so a self-broadcast cannot re-match. Production gdmLoop uses
// the stricter gdmShouldReply (M-SEARCH method only).
inline bool gdmIsDiscoveryProbe(const char* buf) {
    if (!buf || !*buf)
        return false;
    if (std::strncmp(buf, "HTTP/", 5) == 0)
        return false;
    if (std::strstr(buf, "Content-Type: plex/media-player") != nullptr)
        return false;
    return std::strstr(buf, "M-SEARCH") != nullptr || std::strstr(buf, "plex") != nullptr;
}

inline constexpr const char* kGdmAdvertiseShape =
    "HTTP/1.0 200 OK\r\n"
    "Content-Type: plex/media-player\r\n"
    "Name: MiSTerPlex\r\n"
    "Port: 3005\r\n"
    "Product: MiSTerPlex\r\n"
    "Version: 0.2.0\r\n"
    "Protocol: plex\r\n"
    "Protocol-Version: 1\r\n"
    "Protocol-Capabilities: timeline,playback,navigation,mirror,playqueues\r\n"
    "Device-Class: stb\r\n"
    "Resource-Identifier: misterplex\r\n"
    "\r\n";

} // namespace misterplex
