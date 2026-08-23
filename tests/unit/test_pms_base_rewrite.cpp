// L8: Plex Web 127.0.0.1 / *.plex.direct must not stay as the PMS base.
// Timeline from loopback stuck the scrubber at 0:00; 9324 proxy must not win.
// Rewrite to the lab docker PMS http://192.168.2.1:32400.
#include "plex_resolve.hpp"

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

static constexpr const char* kLabPms = "http://192.168.2.1:32400";

static void expect_lab(const std::string& got, const char* tag) {
    if (got != kLabPms) {
        std::fprintf(stderr, "FAIL %s: got '%s' want '%s'\n", tag, got.c_str(), kLabPms);
        ++fails;
    }
}

int main() {
    using namespace misterplex;

    // LAN docker PMS is kept.
    expect_lab(buildPlexBase("http", "192.168.2.1", "32400", ""), "LAN 192.168.2.1");
    expect_lab(buildPlexBase("http", "192.168.2.1", "32400", kLabPms), "LAN with fallback");

    // 127.0.0.1 is the host Plex Web / timeline, not MiSTer loopback.
    expect_lab(buildPlexBase("http", "127.0.0.1", "32400", kLabPms), "127.0.0.1:32400");
    expect_lab(buildPlexBase("http", "http://127.0.0.1:32400", "32400", kLabPms),
               "http://127.0.0.1:32400");
    expect_lab(buildPlexBase("http", "127.0.0.1", "9324", kLabPms),
               "127.0.0.1:9324 proxy must not win");
    expect_lab(buildPlexBase("http", "localhost", "32400", kLabPms), "localhost");

    // Cast / plex.direct transients must not beat the LAN docker PMS.
    expect_lab(buildPlexBase("http", "abc.plex.direct", "32400", kLabPms), "abc.plex.direct");
    expect_lab(buildPlexBase("https", "1-2-3-4.foo.plex.direct", "32400", kLabPms),
               "dashed plex.direct");
    expect_lab(buildPlexBase("http", "https://xyz.plex.direct:32400", "", kLabPms),
               "https plex.direct URL");

    // Empty fallback must not leave 127 as the base (9324 cannot win).
    {
        const auto nofb = buildPlexBase("http", "127.0.0.1", "32400", "");
        CHECK(nofb != "http://127.0.0.1:32400");
        CHECK(nofb != "http://127.0.0.1:9324");
        if (nofb != kLabPms && !nofb.empty()) {
            std::fprintf(stderr, "FAIL 127 no-fallback: got '%s' (want lab PMS or empty)\n",
                         nofb.c_str());
            ++fails;
        }
    }

    // Docker-bridge plex.direct still falls back (already-green landmine).
    {
        const auto br = buildPlexBase("http", "172-17-0-1.abc.plex.direct", "32400", kLabPms);
        expect_lab(br, "docker-bridge plex.direct");
    }

    if (fails) {
        std::fprintf(stderr, "test_pms_base_rewrite: %d failure(s)\n", fails);
        return 1;
    }
    std::printf("test_pms_base_rewrite: OK\n");
    return 0;
}
