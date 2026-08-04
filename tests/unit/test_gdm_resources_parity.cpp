// GDM UDP payload ↔ HTTP /resources Player field parity + probe storm filter
// + real bind of kGdmListenPorts (32412 and 32414).
// No lab IPs. Links Companion so production builders stay covered.
//
// Scope note: GDM listen/reply is correctness/robustness (PMS probes both
// ports). It is NOT the cast-picker population path (companionServer
// friendlyName). Do not over-claim in logs if this test fails.

#include <arpa/inet.h>
#include <cstdlib>
#include <cstring>
#include <iostream>
#include <netinet/in.h>
#include <string>
#include <sys/socket.h>
#include <unistd.h>
#include <vector>

#define private public
#include "companion.hpp"
#undef private
#include "player_identity.hpp"
#include "plextv_device.hpp"

namespace {

void require(bool ok, const std::string& msg) {
    if (!ok) {
        std::cerr << "FAIL: " << msg << "\n";
        std::exit(1);
    }
}

// Pre-fix shape: bare substring — accepts own GDM replies (storm).
bool bareStrstrPlexProbe(const char* buf) {
    return buf && std::strstr(buf, "plex") != nullptr;
}

uint16_t boundPort(int fd) {
    sockaddr_in a{};
    socklen_t len = sizeof(a);
    if (getsockname(fd, reinterpret_cast<sockaddr*>(&a), &len) != 0)
        return 0;
    return ntohs(a.sin_port);
}

} // namespace

int main() {
    using namespace misterplex;

    // --- probe filter (Sweep 114 self-loop / merge-storm CPU) ---
    // Contract: M-SEARCH only. Bare "plex" is the defect class (advertise body).
    require(gdmIsDiscoveryProbe("M-SEARCH * HTTP/1.1\r\n"), "M-SEARCH is a probe");
    require(gdmIsDiscoveryProbe("m-search * HTTP/1.1\r\n"), "M-SEARCH is case-insensitive");
    require(!gdmIsDiscoveryProbe("plex\r\n"), "bare plex must NOT be a probe (Sweep 114)");
    const char* selfReply = "HTTP/1.0 200 OK\r\n"
                            "Content-Type: plex/media-player\r\n"
                            "Protocol: plex\r\n"
                            "Name: MiSTerPlex\r\n\r\n";
    require(bareStrstrPlexProbe(selfReply),
            "red fixture: bare strstr MUST match self-reply (else red-check is dead)");
    require(!gdmIsDiscoveryProbe(selfReply),
            "gate must reject self-reply that bare strstr accepts (storm regression)");
    require(!gdmIsDiscoveryProbe("HTTP/1.0 200 OK\r\nProtocol: plex\r\n\r\n"),
            "HTTP reply must not be treated as probe");
    require(!gdmIsDiscoveryProbe("HTTP/1.0 200 OK\r\nContent-Type: plex/media-player\r\n\r\n"),
            "media-player Content-Type reply must not be probe");
    require(!gdmIsDiscoveryProbe(""), "empty is not a probe");
    require(!gdmIsDiscoveryProbe(nullptr), "null is not a probe");

    // --- listen port set (measured PMS M-SEARCH targets only) ---
    constexpr size_t nPorts = sizeof(kGdmListenPorts) / sizeof(kGdmListenPorts[0]);
    require(nPorts == 2, "two GDM listen ports");
    require(kGdmListenPorts[0] == 32412 && kGdmListenPorts[1] == 32414, "32412+32414 only");

    // --- real bind: both ports must open (SO_REUSEADDR); prove via getsockname ---
    {
        std::vector<int> fds;
        fds.reserve(nPorts);
        for (size_t i = 0; i < nPorts; ++i) {
            const uint16_t want = kGdmListenPorts[i];
            std::string err;
            const int fd = Companion::openGdmListenFd(want, &err);
            require(fd >= 0, "bind UDP " + std::to_string(want) + " failed: " + err);
            const uint16_t got = boundPort(fd);
            require(got == want, "getsockname port " + std::to_string(got) + " != " +
                                     std::to_string(want));
            fds.push_back(fd);
        }
        require(fds.size() == 2, "must hold both 32412 and 32414 simultaneously");
        for (int fd : fds)
            close(fd);
    }

    // --- pure builders: defaults ---
    {
        PlayerAdvertisement a;
        const std::string gdm = buildGdmPayload(a);
        const std::string xml = buildResourcesXml(a);
        const std::string miss = gdmResourcesFieldMismatch(gdm, xml);
        require(miss.empty(), "default builder mismatch: " + miss);
        require(gdmHeaderValue(gdm, "Product") == kPlayerProduct, "default product");
        require(gdmHeaderValue(gdm, "Version") == kPlayerVersion, "default version");
        require(gdmHeaderValue(gdm, "Port") == std::to_string(kPlayerDefaultPort), "default port");
    }

    // --- pure builders: lab-shaped identity (no IPs) ---
    {
        PlayerAdvertisement a;
        a.name = "MiSTerPlex";
        a.machineId = "misterplex-dev";
        a.port = 3005;
        const std::string gdm = buildGdmPayload(a);
        const std::string xml = buildResourcesXml(a);
        const std::string miss = gdmResourcesFieldMismatch(gdm, xml);
        require(miss.empty(), "misterplex-dev mismatch: " + miss);
        require(gdmHeaderValue(gdm, "Name") == "MiSTerPlex", "Name");
        require(gdmHeaderValue(gdm, "Resource-Identifier") == "misterplex-dev", "Resource-Identifier");
        require(xmlAttrValue(xml, "title") == "MiSTerPlex", "title");
        require(xmlAttrValue(xml, "machineIdentifier") == "misterplex-dev", "machineIdentifier");
        require(xmlAttrValue(xml, "port") == "3005", "resources port attr");
    }

    // --- Companion production path uses the same builders ---
    {
        Companion comp;
        comp.setName("MiSTerPlex");
        comp.setMachineId("misterplex-dev");
        comp.setPort(3005);
        const std::string gdm = comp.gdmPayload();
        const std::string xml = comp.resourcesXml();
        const std::string miss = gdmResourcesFieldMismatch(gdm, xml);
        require(miss.empty(), "Companion gdm/resources mismatch: " + miss);
        PlayerAdvertisement expect;
        expect.name = "MiSTerPlex";
        expect.machineId = "misterplex-dev";
        expect.port = 3005;
        require(gdm == buildGdmPayload(expect),
                "Companion gdmPayload must equal buildGdmPayload");
        require(xml == buildResourcesXml(expect),
                "Companion resourcesXml must equal buildResourcesXml");
    }

    // --- plex.tv identity defaults match player constants ---
    {
        PlexTvDeviceIdentity id;
        require(id.product == kPlayerProduct, "plex.tv product default");
        require(id.version == kPlayerVersion, "plex.tv version default");
        require(id.port == kPlayerDefaultPort, "plex.tv port default");
        require(id.deviceName == kPlayerDefaultName, "plex.tv deviceName default");
    }

    // --- XML escape keeps parity after escaping ---
    {
        PlayerAdvertisement a;
        a.name = "A&B\"C";
        a.machineId = "id<x>";
        const std::string gdm = buildGdmPayload(a);
        const std::string xml = buildResourcesXml(a);
        // GDM is not XML-escaped (header values); resources is. Compare unescaped
        // sides only for fields that do not need escape in the GDM path.
        require(gdmHeaderValue(gdm, "Product") == xmlAttrValue(xml, "product"),
                "product still matches with special name");
        require(xmlAttrValue(xml, "title") == "A&amp;B&quot;C", "title escaped");
        require(xmlAttrValue(xml, "machineIdentifier") == "id&lt;x&gt;", "machineId escaped");
    }

    std::cout << "test_gdm_resources_parity: OK\n";
    return 0;
}
