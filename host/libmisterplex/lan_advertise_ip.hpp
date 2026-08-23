// GDM / companion advertise address picker.
//
// Companion::lanIp() used connect(1.1.1.1)+getsockname and fell back to
// 127.0.0.1 when that route was missing. GDM then advertised loopback and
// Plex Web could pin 127.0.0.1 / the 720p-only :9324 proxy — Web scrubber
// stuck at 0:00. Never prefer 127/169.254 when a 192.168.2.x (or any
// usable) iface exists.
#pragma once

#include <string>
#include <vector>

namespace misterplex {

inline bool lanAdvertiseIpUnusable(const std::string& ip) {
    if (ip.empty() || ip == "0.0.0.0" || ip == "::" || ip == "::1" || ip == "localhost")
        return true;
    if (ip.rfind("127.", 0) == 0)
        return true;
    if (ip.rfind("169.254.", 0) == 0)
        return true;
    return false;
}

inline std::string pickLanAdvertiseIp(const std::string& routeHint,
                                      const std::vector<std::string>& ifaceIpv4) {
    if (!lanAdvertiseIpUnusable(routeHint))
        return routeHint;
    for (const auto& ip : ifaceIpv4) {
        if (ip.rfind("192.168.2.", 0) == 0)
            return ip;
    }
    for (const auto& ip : ifaceIpv4) {
        if (!lanAdvertiseIpUnusable(ip))
            return ip;
    }
    return routeHint.empty() ? std::string("127.0.0.1") : routeHint;
}

} // namespace misterplex
