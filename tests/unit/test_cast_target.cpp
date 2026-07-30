// Unit: cast target id match (X-Plex-Target-Client-Identifier).
#include "libmisterplex/cast_target.hpp"

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

int main() {
    using namespace misterplex;
    const std::string self = "misterplex-dev";

    // No target header → accept (lab curls, discovery).
    CHECK(castTargetAccepted("GET /player/timeline/poll HTTP/1.1\r\n\r\n", self));

    // Matching header → accept.
    {
        const std::string req =
            "GET /player/timeline/subscribe HTTP/1.1\r\n"
            "X-Plex-Target-Client-Identifier: misterplex-dev\r\n"
            "\r\n";
        std::string got;
        CHECK(castTargetAccepted(req, self, &got));
        CHECK(got == "misterplex-dev");
    }

    // Mismatched header → REJECT (pre-fix accepted silently — vanish path).
    {
        const std::string req =
            "GET /player/timeline/subscribe HTTP/1.1\r\n"
            "X-Plex-Target-Client-Identifier: misterplex-1\r\n"
            "\r\n";
        std::string got;
        CHECK(!castTargetAccepted(req, self, &got));
        CHECK(got == "misterplex-1");
    }

    // Query form + case-insensitive header name.
    {
        const std::string req =
            "GET /player/playback/playMedia?X-Plex-Target-Client-Identifier=misterplex-dev "
            "HTTP/1.1\r\n\r\n";
        CHECK(castTargetAccepted(req, self));
    }
    {
        const std::string req =
            "GET /player/timeline/poll HTTP/1.1\r\n"
            "x-plex-target-client-identifier: misterplex-wrong\r\n"
            "\r\n";
        CHECK(!castTargetAccepted(req, self));
    }

    // Prefix must not match (misterplex-dev-old ≠ misterplex-dev).
    {
        const std::string req =
            "GET /player/timeline/poll HTTP/1.1\r\n"
            "X-Plex-Target-Client-Identifier: misterplex-dev-old\r\n"
            "\r\n";
        CHECK(!castTargetAccepted(req, self));
    }

    if (fails) {
        std::fprintf(stderr, "test_cast_target: %d failure(s)\n", fails);
        return 1;
    }
    std::printf("test_cast_target: OK\n");
    return 0;
}
