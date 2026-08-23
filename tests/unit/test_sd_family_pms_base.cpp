// SD-family PMS base: loopback / link-local / *.plex.direct must rewrite
// to conf PLEX_BASE (LAN 192.168.2.1:32400). Mixing plex.direct + the wrong
// token freezes Plex Web at 0:00; 127.0.0.1:9324 is the parked 720p proxy.
#include "plex_resolve.hpp"
#include "libmisterplex/lan_advertise_ip.hpp"

#include <cstdio>
#include <string>

static int fails = 0;
#define CHECK(cond)                                                                              \
    do {                                                                                         \
        if (!(cond)) {                                                                           \
            std::fprintf(stderr, "FAIL %s:%d: %s\n", __FILE__, __LINE__, #cond);                 \
            ++fails;                                                                             \
        }                                                                                        \
    } while (0)

#define CHECK_EQ(got, want)                                                                      \
    do {                                                                                         \
        const std::string _got = (got);                                                          \
        const std::string _want = (want);                                                        \
        if (_got != _want) {                                                                     \
            std::fprintf(stderr, "FAIL %s:%d:\n  got  [%s]\n  want [%s]\n  expr %s\n",           \
                         __FILE__, __LINE__, _got.c_str(), _want.c_str(), #got);                 \
            ++fails;                                                                             \
        }                                                                                        \
    } while (0)

namespace {

// Byte-faithful pre-SD-family host check (docker-bridge only). RED twin.
bool legacyIsUnreachableHost(const std::string& hostOrUrl) {
    std::string h = hostOrUrl;
    if (auto p = h.find("://"); p != std::string::npos)
        h = h.substr(p + 3);
    if (auto p = h.find('/'); p != std::string::npos)
        h = h.substr(0, p);
    if (auto p = h.find(':'); p != std::string::npos)
        h = h.substr(0, p);
    if (h.rfind("172.17.", 0) == 0 || h.rfind("172.18.", 0) == 0 ||
        h.rfind("172.20.", 0) == 0 || h.rfind("172.21.", 0) == 0)
        return true;
    if (h.find("172-17-") != std::string::npos || h.find("172-18-") != std::string::npos ||
        h.find("172-20-") != std::string::npos || h.find("172-21-") != std::string::npos)
        return true;
    return false;
}

// Same shape as pre-fix buildPlexBase, wired to the legacy host check.
std::string legacyBuildPlexBase(const std::string& protocol, const std::string& address,
                                const std::string& port, const std::string& lanFallback) {
    std::string addr = misterplex::urlDecode(address);
    std::string proto = protocol.empty() ? "http" : protocol;
    std::string p = port.empty() ? "32400" : port;
    if (addr.empty() || legacyIsUnreachableHost(addr)) {
        if (!lanFallback.empty() && !legacyIsUnreachableHost(lanFallback)) {
            addr = lanFallback;
            if (addr.find("://") == std::string::npos)
                return "http://" + addr + ":" + p;
            return addr;
        }
        return {};
    }
    if (addr.find("://") != std::string::npos)
        return addr;
    if (addr.find(':') != std::string::npos)
        return proto + "://" + addr;
    return proto + "://" + addr + ":" + p;
}

} // namespace

int main() {
    using namespace misterplex;
    const std::string lan = "http://192.168.2.1:32400";

    // --- GREEN: SD-family rewrite to conf PLEX_BASE ---------------------------
    CHECK_EQ(buildPlexBase("https", "192-168-2-1.abc.plex.direct", "32400", lan), lan);
    CHECK_EQ(buildPlexBase("http", "127.0.0.1", "32400", lan), lan);
    CHECK_EQ(buildPlexBase("http", "127.0.0.1", "9324", lan), lan); // 720p proxy must not win

    CHECK_EQ(buildPlexBase("http", "localhost", "32400", lan), lan);
    CHECK_EQ(buildPlexBase("http", "::1", "32400", lan), lan);
    CHECK_EQ(buildPlexBase("http", "169.254.1.20", "32400", lan), lan);
    CHECK_EQ(buildPlexBase("https",
                           "192-168-2-1.f29ec2ab5a084cad97407d2004a85125.plex.direct", "32400",
                           lan),
             lan);

    CHECK(isUnreachableHost("127.0.0.1"));
    CHECK(isUnreachableHost("localhost"));
    CHECK(isUnreachableHost("LOCALHOST"));
    CHECK(isUnreachableHost("::1"));
    CHECK(isUnreachableHost("[::1]:32400"));
    CHECK(isUnreachableHost("169.254.1.20"));
    CHECK(isUnreachableHost("https://192-168-2-1.abc.plex.direct:32400"));
    CHECK(isUnreachableHost("172.17.0.1"));
    CHECK(!isUnreachableHost("192.168.2.1"));
    CHECK(!isUnreachableHost("http://192.168.2.1:32400"));
    CHECK(!isUnreachableHost("pms.lan"));

    // Reachable LAN host keeps its own base (not forced through fallback).
    CHECK_EQ(buildPlexBase("http", "192.168.2.1", "32400", lan), "http://192.168.2.1:32400");

    // Docker-bridge still rewrites (existing contract).
    CHECK_EQ(buildPlexBase("http", "172.17.0.1", "32400", lan), lan);

    // Loopback fallback is itself unreachable → empty (caller uses conf later).
    CHECK(buildPlexBase("http", "127.0.0.1", "32400", "http://127.0.0.1:9324").empty());

    // --- RED twin: old docker-bridge-only check must NOT rewrite 127/LAN plex.direct
    // If these ever go false, the defect class is gone from the oracle — fail loud.
    CHECK(!legacyIsUnreachableHost("127.0.0.1"));
    CHECK(!legacyIsUnreachableHost("localhost"));
    CHECK(!legacyIsUnreachableHost("::1"));
    CHECK(!legacyIsUnreachableHost("169.254.1.20"));
    CHECK(!legacyIsUnreachableHost("192-168-2-1.abc.plex.direct"));
    CHECK(legacyIsUnreachableHost("172.17.0.1"));
    {
        const auto old127 = legacyBuildPlexBase("http", "127.0.0.1", "32400", lan);
        CHECK(old127 != lan);
        CHECK(old127 == "http://127.0.0.1:32400");
        const auto old9324 = legacyBuildPlexBase("http", "127.0.0.1", "9324", lan);
        CHECK(old9324 != lan);
        CHECK(old9324 == "http://127.0.0.1:9324");
        const auto oldPd =
            legacyBuildPlexBase("https", "192-168-2-1.abc.plex.direct", "32400", lan);
        CHECK(oldPd != lan);
        CHECK(oldPd.find("plex.direct") != std::string::npos);
        CHECK(legacyIsUnreachableHost("127.0.0.1") != isUnreachableHost("127.0.0.1"));
        CHECK(legacyIsUnreachableHost("192-168-2-1.abc.plex.direct") !=
              isUnreachableHost("192-168-2-1.abc.plex.direct"));
    }

    // --- lanIp picker (no root; synthetic ifaces) -----------------------------
    CHECK(lanAdvertiseIpUnusable("127.0.0.1"));
    CHECK(lanAdvertiseIpUnusable("169.254.12.34"));
    CHECK(lanAdvertiseIpUnusable("localhost"));
    CHECK(!lanAdvertiseIpUnusable("192.168.2.10"));
    CHECK(!lanAdvertiseIpUnusable("192.168.1.183"));
    CHECK_EQ(pickLanAdvertiseIp("127.0.0.1", {"192.168.2.10", "127.0.0.1"}), "192.168.2.10");
    CHECK_EQ(pickLanAdvertiseIp("169.254.1.1", {"192.168.2.1"}), "192.168.2.1");
    CHECK_EQ(pickLanAdvertiseIp("192.168.1.183", {"192.168.2.1"}), "192.168.1.183");
    CHECK_EQ(pickLanAdvertiseIp("127.0.0.1", {"169.254.1.1", "192.168.1.183"}),
             "192.168.1.183");
    CHECK_EQ(pickLanAdvertiseIp("", {"127.0.0.1"}), "127.0.0.1"); // last resort

    if (fails) {
        std::fprintf(stderr, "test_sd_family_pms_base: %d failure(s)\n", fails);
        return 1;
    }
    std::printf("test_sd_family_pms_base: OK\n");
    return 0;
}
