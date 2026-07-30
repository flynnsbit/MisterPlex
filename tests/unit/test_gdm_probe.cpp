// Regression: GDM self-reply must not be treated as a discovery probe (90a82208).
#include "companion.hpp"

#include <cstdio>
#include <cstring>

static int fails = 0;
#define CHECK(cond)                                                                              \
    do {                                                                                         \
        if (!(cond)) {                                                                           \
            std::fprintf(stderr, "FAIL %s:%d: %s\n", __FILE__, __LINE__, #cond);                 \
            ++fails;                                                                             \
        }                                                                                        \
    } while (0)

int main() {
    using misterplex::gdmIsDiscoveryProbe;

    CHECK(!gdmIsDiscoveryProbe(nullptr));
    CHECK(!gdmIsDiscoveryProbe(""));

    // Real SSDP-style probe — must answer.
    CHECK(gdmIsDiscoveryProbe("M-SEARCH * HTTP/1.1\r\nHOST: 239.255.255.250:1900\r\n"));
    CHECK(gdmIsDiscoveryProbe("M-SEARCH * HTTP/1.1\r\n"));

    // Some clients send a short "plex" hello without M-SEARCH — still a probe.
    CHECK(gdmIsDiscoveryProbe("plex\r\n"));

    // Own GDM advertise / reply looped back to 32412 — NEVER a probe.
    const char* reply =
        "HTTP/1.0 200 OK\r\n"
        "Content-Type: plex/media-player\r\n"
        "Name: MiSTerPlex\r\n"
        "Port: 3005\r\n"
        "Product: Plex Media Player\r\n"
        "Protocol: plex\r\n"
        "Protocol-Version: 1\r\n"
        "Resource-Identifier: misterplex-1\r\n"
        "Updated-At: 0\r\n"
        "Version: 1.0\r\n"
        "\r\n";
    CHECK(!gdmIsDiscoveryProbe(reply));
    CHECK(!gdmIsDiscoveryProbe("HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\n\r\n"));
    // Content-Type alone (even without HTTP/ prefix) must not trigger a reply storm.
    CHECK(!gdmIsDiscoveryProbe("Content-Type: plex/media-player\r\nProtocol: plex\r\n"));

    // M-SEARCH without reply Content-Type is a probe (User-Agent may contain "plex").
    CHECK(gdmIsDiscoveryProbe("M-SEARCH * HTTP/1.1\r\nUser-Agent: plex\r\n"));
    // 90a82208 order: Content-Type plex/media-player rejects before M-SEARCH check.
    CHECK(!gdmIsDiscoveryProbe(
        "M-SEARCH * HTTP/1.1\r\nContent-Type: plex/media-player\r\n"));

    if (fails) {
        std::fprintf(stderr, "test_gdm_probe: %d failures\n", fails);
        return 1;
    }
    std::printf("test_gdm_probe: OK\n");
    return 0;
}
