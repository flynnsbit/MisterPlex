// GDM UDP payload ↔ HTTP /resources Player field parity + probe storm filter.
// No network. No lab IPs. Links Companion so production builders stay covered.

#include <cstdlib>
#include <iostream>
#include <string>

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

} // namespace

int main() {
    using namespace misterplex;

    // --- probe filter (merge-storm / self-reply CPU) ---
    require(gdmIsDiscoveryProbe("M-SEARCH * HTTP/1.1\r\n"), "M-SEARCH is a probe");
    require(gdmIsDiscoveryProbe("plex\r\n"), "bare plex probe still accepted");
    require(!gdmIsDiscoveryProbe("HTTP/1.0 200 OK\r\nProtocol: plex\r\n\r\n"),
            "HTTP reply must not be treated as probe");
    require(!gdmIsDiscoveryProbe("HTTP/1.0 200 OK\r\nContent-Type: plex/media-player\r\n\r\n"),
            "media-player Content-Type reply must not be probe");
    require(!gdmIsDiscoveryProbe(""), "empty is not a probe");
    require(!gdmIsDiscoveryProbe(nullptr), "null is not a probe");

    // --- listen port set (measured PMS M-SEARCH targets only) ---
    require(sizeof(kGdmListenPorts) / sizeof(kGdmListenPorts[0]) == 2, "two GDM listen ports");
    require(kGdmListenPorts[0] == 32412 && kGdmListenPorts[1] == 32414, "32412+32414 only");

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
