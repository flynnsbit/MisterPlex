#pragma once
// Single source of truth for player advertisement fields shared by:
//   - Companion GDM UDP payload (Name / Resource-Identifier / Port / …)
//   - Companion HTTP GET /resources Player XML
//   - plex.tv device identity headers (when PLEXTV_ANNOUNCE is on)
//
// Field drift across these three surfaces is a known cause of flaky Select
// Player / cast-picker behaviour. Unit tests pin GDM ↔ /resources parity.

#include <cstdint>
#include <cstring>
#include <string>

namespace misterplex {

inline constexpr const char kPlayerProduct[] = "MiSTerPlex";
inline constexpr const char kPlayerVersion[] = "0.2.0";
inline constexpr const char kPlayerProtocol[] = "plex";
inline constexpr const char kPlayerProtocolVersion[] = "1";
// Comma-separated, no spaces — matches historical GDM /resources /clients shape.
inline constexpr const char kPlayerProtocolCapabilities[] =
    "timeline,playback,navigation,mirror,playqueues";
inline constexpr const char kPlayerDeviceClass[] = "stb";
inline constexpr uint16_t kPlayerDefaultPort = 3005;
inline constexpr const char kPlayerDefaultName[] = "MiSTerPlex";
inline constexpr const char kPlayerDefaultMachineId[] = "misterplex-1";

// True when a UDP datagram is a discovery *probe* we should answer.
// GDM replies embed the substring "plex" (Protocol / Content-Type). We also
// broadcast those replies to 32412, and Linux delivers them back to this
// socket. Matching bare "plex" then re-emits a reply forever: creation-order 5
// (mplex-gdm) measured 98%onecpu at true idle, d_vol=0, always R/running.
// Replies are never probes; M-SEARCH and non-reply "plex" probes still match.
inline bool gdmIsDiscoveryProbe(const char* buf) {
    if (!buf || !*buf)
        return false;
    if (std::strncmp(buf, "HTTP/", 5) == 0)
        return false;
    if (std::strstr(buf, "Content-Type: plex/media-player") != nullptr)
        return false;
    return std::strstr(buf, "M-SEARCH") != nullptr || std::strstr(buf, "plex") != nullptr;
}

// PMS GDM discovery probes both 32412 and 32414 (broadcast M-SEARCH). Measured.
inline constexpr uint16_t kGdmListenPorts[] = {32412, 32414};

struct PlayerAdvertisement {
    std::string name = kPlayerDefaultName;
    std::string machineId = kPlayerDefaultMachineId;
    uint16_t port = kPlayerDefaultPort;
    std::string product = kPlayerProduct;
    std::string version = kPlayerVersion;
    std::string protocol = kPlayerProtocol;
    std::string protocolVersion = kPlayerProtocolVersion;
    std::string protocolCapabilities = kPlayerProtocolCapabilities;
    std::string deviceClass = kPlayerDeviceClass;
};

// GDM HTTP/1.0 200 reply body (headers only + blank line).
inline std::string buildGdmPayload(const PlayerAdvertisement& a) {
    std::string o;
    o.reserve(256);
    o += "HTTP/1.0 200 OK\r\n";
    o += "Content-Type: plex/media-player\r\n";
    o += "Name: ";
    o += a.name;
    o += "\r\n";
    o += "Port: ";
    o += std::to_string(a.port);
    o += "\r\n";
    o += "Product: ";
    o += a.product;
    o += "\r\n";
    o += "Version: ";
    o += a.version;
    o += "\r\n";
    o += "Protocol: ";
    o += a.protocol;
    o += "\r\n";
    o += "Protocol-Version: ";
    o += a.protocolVersion;
    o += "\r\n";
    o += "Protocol-Capabilities: ";
    o += a.protocolCapabilities;
    o += "\r\n";
    o += "Device-Class: ";
    o += a.deviceClass;
    o += "\r\n";
    o += "Resource-Identifier: ";
    o += a.machineId;
    o += "\r\n\r\n";
    return o;
}

// Minimal XML escape for attribute values (shared shape with Companion::xmlEsc).
inline std::string playerXmlEsc(const std::string& s) {
    std::string o;
    o.reserve(s.size());
    for (char c : s) {
        switch (c) {
        case '&':
            o += "&amp;";
            break;
        case '<':
            o += "&lt;";
            break;
        case '>':
            o += "&gt;";
            break;
        case '"':
            o += "&quot;";
            break;
        default:
            o += c;
        }
    }
    return o;
}

// GET /resources MediaContainer/Player XML — fields must match buildGdmPayload.
inline std::string buildResourcesXml(const PlayerAdvertisement& a) {
    std::string o;
    o.reserve(320);
    o += "<?xml version=\"1.0\" encoding=\"UTF-8\"?>";
    o += "<MediaContainer>";
    o += "<Player title=\"";
    o += playerXmlEsc(a.name);
    o += "\" product=\"";
    o += playerXmlEsc(a.product);
    o += "\" protocol=\"";
    o += playerXmlEsc(a.protocol);
    o += "\" protocolVersion=\"";
    o += playerXmlEsc(a.protocolVersion);
    o += "\" protocolCapabilities=\"";
    o += playerXmlEsc(a.protocolCapabilities);
    o += "\" deviceClass=\"";
    o += playerXmlEsc(a.deviceClass);
    o += "\" machineIdentifier=\"";
    o += playerXmlEsc(a.machineId);
    o += "\" version=\"";
    o += playerXmlEsc(a.version);
    o += "\" port=\"";
    o += std::to_string(a.port);
    o += "\"/>";
    o += "</MediaContainer>";
    return o;
}

// Extract "Key: value" from a GDM header block (case-sensitive keys as we emit).
inline std::string gdmHeaderValue(const std::string& payload, const char* key) {
    const std::string prefix = std::string(key) + ": ";
    auto pos = payload.find(prefix);
    if (pos == std::string::npos)
        return {};
    pos += prefix.size();
    auto end = payload.find("\r\n", pos);
    if (end == std::string::npos)
        return payload.substr(pos);
    return payload.substr(pos, end - pos);
}

// Extract attr="value" from the first <Player .../> element (not <?xml version=...>).
inline std::string xmlAttrValue(const std::string& xml, const char* attr) {
    auto player = xml.find("<Player ");
    if (player == std::string::npos)
        return {};
    auto tagEnd = xml.find("/>", player);
    if (tagEnd == std::string::npos)
        tagEnd = xml.find('>', player);
    if (tagEnd == std::string::npos)
        return {};
    const std::string key = std::string(attr) + "=\"";
    auto pos = xml.find(key, player);
    if (pos == std::string::npos || pos >= tagEnd)
        return {};
    pos += key.size();
    auto end = xml.find('"', pos);
    if (end == std::string::npos || end > tagEnd)
        return {};
    return xml.substr(pos, end - pos);
}

// Field-for-field map GDM header ↔ /resources Player attribute.
// Returns empty string on match; otherwise a short mismatch description.
inline std::string gdmResourcesFieldMismatch(const std::string& gdm, const std::string& resourcesXml) {
    struct Pair {
        const char* gdmKey;
        const char* xmlAttr;
    };
    static constexpr Pair kPairs[] = {
        {"Name", "title"},
        {"Port", "port"},
        {"Product", "product"},
        {"Version", "version"},
        {"Protocol", "protocol"},
        {"Protocol-Version", "protocolVersion"},
        {"Protocol-Capabilities", "protocolCapabilities"},
        {"Device-Class", "deviceClass"},
        {"Resource-Identifier", "machineIdentifier"},
    };
    for (const auto& p : kPairs) {
        const std::string gv = gdmHeaderValue(gdm, p.gdmKey);
        const std::string xv = xmlAttrValue(resourcesXml, p.xmlAttr);
        if (gv.empty())
            return std::string("missing GDM header ") + p.gdmKey;
        if (xv.empty())
            return std::string("missing /resources attr ") + p.xmlAttr;
        if (gv != xv)
            return std::string(p.gdmKey) + "='" + gv + "' != " + p.xmlAttr + "='" + xv + "'";
    }
    if (gdm.find("Content-Type: plex/media-player") == std::string::npos)
        return "missing GDM Content-Type: plex/media-player";
    if (resourcesXml.find("<Player ") == std::string::npos)
        return "missing /resources <Player";
    return {};
}

} // namespace misterplex
