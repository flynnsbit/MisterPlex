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

    // Trailing OWS on header value must still accept (HTTP field OWS both sides).
    // Audit probe: "X-Plex-Target-Client-Identifier: misterplex-dev   " was 409.
    {
        const std::string req =
            "GET /player/timeline/subscribe HTTP/1.1\r\n"
            "X-Plex-Target-Client-Identifier: misterplex-dev   \r\n"
            "\r\n";
        std::string got;
        CHECK(castTargetAccepted(req, self, &got));
        CHECK(got == "misterplex-dev");
    }
    // Leading + trailing OWS.
    {
        const std::string req =
            "GET /player/timeline/poll HTTP/1.1\r\n"
            "X-Plex-Target-Client-Identifier: \tmisterplex-dev \t\r\n"
            "\r\n";
        CHECK(castTargetAccepted(req, self));
    }

    // Percent-encoded query form must accept (misterplex%2Ddev == misterplex-dev).
    // Audit probe: raw substring compare rejected legal encoding with 409.
    {
        const std::string req =
            "GET /player/timeline/subscribe?X-Plex-Target-Client-Identifier="
            "misterplex%2Ddev&commandID=1 HTTP/1.1\r\n\r\n";
        std::string got;
        CHECK(castTargetAccepted(req, self, &got));
        CHECK(got == "misterplex-dev");
    }
    // Percent-encoded wrong id still rejects.
    {
        const std::string req =
            "GET /player/timeline/subscribe?X-Plex-Target-Client-Identifier="
            "misterplex%2D1 HTTP/1.1\r\n\r\n";
        CHECK(!castTargetAccepted(req, self));
    }

    // Header wins over query when both present (documented precedence).
    {
        const std::string req =
            "GET /player/timeline/poll?X-Plex-Target-Client-Identifier=misterplex-1 "
            "HTTP/1.1\r\n"
            "X-Plex-Target-Client-Identifier: misterplex-dev\r\n"
            "\r\n";
        CHECK(castTargetAccepted(req, self));
    }
    {
        const std::string req =
            "GET /player/timeline/poll?X-Plex-Target-Client-Identifier=misterplex-dev "
            "HTTP/1.1\r\n"
            "X-Plex-Target-Client-Identifier: misterplex-1\r\n"
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
