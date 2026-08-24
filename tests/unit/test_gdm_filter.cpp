#include "libmisterplex/gdm_filter.hpp"

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

static bool legacyContainsPlex(const char* buf) {
    if (!buf)
        return false;
    return std::strstr(buf, "M-SEARCH") != nullptr || std::strstr(buf, "plex") != nullptr;
}

int main() {
    using namespace misterplex;

    CHECK(sizeof(kGdmListenPorts) / sizeof(kGdmListenPorts[0]) == 2);
    CHECK(kGdmListenPorts[0] == 32412);
    CHECK(kGdmListenPorts[1] == 32414);

    const char* msearch = "M-SEARCH * HTTP/1.1\r\nHost: 239.255.255.250\r\n\r\n";
    const char* msearchLower = "m-search * http/1.1\r\n\r\n";
    const char* plexOnly = "Content-Type: plex/media-player\r\nProtocol: plex\r\n";

    CHECK(gdmShouldReplyCStr(msearch));
    CHECK(gdmShouldReplyCStr(msearchLower));
    CHECK(gdmShouldReply(msearch, std::strlen(msearch)));

    CHECK(!gdmShouldReplyCStr(kGdmAdvertiseShape));
    CHECK(!gdmShouldReplyCStr(plexOnly));
    CHECK(!gdmShouldReplyCStr("hello world"));
    CHECK(!gdmShouldReplyCStr(""));
    CHECK(!gdmShouldReply(nullptr, 0));
    CHECK(!gdmShouldReplyCStr(nullptr));
    CHECK(!gdmShouldReplyCStr("plex"));
    CHECK(!gdmShouldReplyCStr("I love plex media server"));
    // Method must be the first token, not buried in a body.
    CHECK(!gdmShouldReplyCStr("GET / HTTP/1.1\r\nX: M-SEARCH\r\n"));

    CHECK(legacyContainsPlex(kGdmAdvertiseShape));
    CHECK(legacyContainsPlex(plexOnly));
    CHECK(legacyContainsPlex(msearch));
    CHECK(legacyContainsPlex(kGdmAdvertiseShape) != gdmShouldReplyCStr(kGdmAdvertiseShape));
    CHECK(legacyContainsPlex(plexOnly) != gdmShouldReplyCStr(plexOnly));
    CHECK(std::strstr(kGdmAdvertiseShape, "plex") != nullptr);

    CHECK(gdmIsDiscoveryProbe(msearch));
    CHECK(!gdmIsDiscoveryProbe(kGdmAdvertiseShape));
    CHECK(!gdmIsDiscoveryProbe("HTTP/1.0 200 OK\r\nName: MiSTerPlex\r\n"));
    CHECK(!gdmIsDiscoveryProbe(plexOnly));
    CHECK(!gdmIsDiscoveryProbe(""));
    CHECK(!gdmIsDiscoveryProbe(nullptr));

    if (fails) {
        std::fprintf(stderr, "test_gdm_filter: %d failure(s)\n", fails);
        return 1;
    }
    std::printf("test_gdm_filter: OK\n");
    return 0;
}
