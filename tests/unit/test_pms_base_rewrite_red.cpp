// L8 RED twin: frozen compose-era isUnreachableHost (docker-bridge 172.17/18/20/21
// only). Must keep failing the 127 / *.plex.direct rewrite CHECKs.
// If this binary returns 0, the frozen copy was weakened — not a product PASS.
#include <cstdio>
#include <string>

static int fails = 0;

static constexpr const char* kLabPms = "http://192.168.2.1:32400";

static std::string hostOnly(const std::string& hostOrUrl) {
    std::string h = hostOrUrl;
    if (auto p = h.find("://"); p != std::string::npos)
        h = h.substr(p + 3);
    if (auto p = h.find('/'); p != std::string::npos)
        h = h.substr(0, p);
    if (auto p = h.find(':'); p != std::string::npos)
        h = h.substr(0, p);
    return h;
}

// Frozen copy of compose isUnreachableHost — docker-bridge only.
static bool isUnreachableHost(const std::string& hostOrUrl) {
    const std::string h = hostOnly(hostOrUrl);
    if (h.rfind("172.17.", 0) == 0 || h.rfind("172.18.", 0) == 0 ||
        h.rfind("172.20.", 0) == 0 || h.rfind("172.21.", 0) == 0)
        return true;
    if (h.find("172-17-") != std::string::npos || h.find("172-18-") != std::string::npos ||
        h.find("172-20-") != std::string::npos || h.find("172-21-") != std::string::npos)
        return true;
    return false;
}

static std::string buildPlexBase(const std::string& protocol, const std::string& address,
                                const std::string& port, const std::string& lanFallback) {
    std::string addr = address;
    std::string proto = protocol.empty() ? "http" : protocol;
    std::string p = port.empty() ? "32400" : port;
    if (addr.empty() || isUnreachableHost(addr)) {
        if (!lanFallback.empty() && !isUnreachableHost(lanFallback)) {
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

static void expect_lab(const std::string& got, const char* tag) {
    if (got != kLabPms) {
        std::fprintf(stderr, "FAIL %s: old isUnreachableHost left base='%s' want '%s'\n", tag,
                     got.c_str(), kLabPms);
        ++fails;
    }
}

int main() {
    std::printf("old isUnreachableHost(127.0.0.1)=%d (0 = leaves 127 as the base)\n",
                isUnreachableHost("127.0.0.1") ? 1 : 0);
    std::printf("old isUnreachableHost(abc.plex.direct)=%d\n",
                isUnreachableHost("abc.plex.direct") ? 1 : 0);

    expect_lab(buildPlexBase("http", "127.0.0.1", "32400", kLabPms), "127.0.0.1:32400");
    expect_lab(buildPlexBase("http", "http://127.0.0.1:32400", "32400", kLabPms),
               "http://127.0.0.1:32400");
    expect_lab(buildPlexBase("http", "127.0.0.1", "9324", kLabPms), "127.0.0.1:9324");
    expect_lab(buildPlexBase("http", "localhost", "32400", kLabPms), "localhost");
    expect_lab(buildPlexBase("http", "abc.plex.direct", "32400", kLabPms), "abc.plex.direct");
    expect_lab(buildPlexBase("https", "1-2-3-4.foo.plex.direct", "32400", kLabPms),
               "dashed plex.direct");

    if (fails) {
        std::fprintf(stderr, "test_pms_base_rewrite_red: %d failure(s) (expected RED)\n", fails);
        return 1;
    }
    std::printf("test_pms_base_rewrite_red: unexpectedly OK\n");
    return 0;
}
