// Unit tests for arm/misterplexd/log_redact.hpp
// Green path: tokens scrubbed; clean strings byte-identical.
// Build with -DLOG_REDACT_FAULT_IDENTITY for the EXPECTED_RED mutation path.
#include "log_redact.hpp"

#include <cstdio>
#include <cstring>
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
    using misterplex::redactSensitive;

    // Obviously fake — never a real Plex credential (see test_no_private_data.sh).
    constexpr const char* kFake = "FAKE-TOKEN-0000";

    // --- Direction A: secrets must be scrubbed, keys kept ---
    {
        const std::string in =
            std::string("misterplexd: PLAY http://pms.example:32400/video/:/transcode/"
                        "universal/start.mp4?path=%2Flibrary&X-Plex-Token=") +
            kFake + " off=0 dur=30021";
        const std::string out = redactSensitive(in);
        CHECK(out.find(kFake) == std::string::npos);
        CHECK(out.find("X-Plex-Token=REDACTED") != std::string::npos);
        // Vacuous-pass guard: input really contained the secret.
        CHECK(in.find(kFake) != std::string::npos);
        CHECK(in.find("X-Plex-Token=REDACTED") == std::string::npos);
    }

    {
        const std::string in =
            std::string("media: spawn single-process /media/fat/misterplex/bin/ffmpeg -i "
                        "http://pms.example:32400/x?token=") +
            kFake + " pipe:1";
        const std::string out = redactSensitive(in);
        CHECK(out.find(kFake) == std::string::npos);
        CHECK(out.find("token=REDACTED") != std::string::npos);
    }

    {
        const std::string in =
            std::string("X-Plex-Session-Identifier: sess\r\nX-Plex-Token: ") + kFake + "\r\n";
        const std::string out = redactSensitive(in);
        CHECK(out.find(kFake) == std::string::npos);
        CHECK(out.find("X-Plex-Token: REDACTED") != std::string::npos);
    }

    {
        const std::string in = std::string("accessToken=") + kFake + "&foo=1";
        const std::string out = redactSensitive(in);
        CHECK(out.find(kFake) == std::string::npos);
        CHECK(out.find("accessToken=REDACTED") != std::string::npos);
    }

    {
        const std::string in = std::string("PLEX_TOKEN=") + kFake;
        const std::string out = redactSensitive(in);
        CHECK(out.find(kFake) == std::string::npos);
        CHECK(out.find("PLEX_TOKEN=REDACTED") != std::string::npos);
    }

    // Multiple secrets in one line.
    {
        const std::string in = std::string("a?X-Plex-Token=") + kFake + "&token=" + kFake;
        const std::string out = redactSensitive(in);
        CHECK(out.find(kFake) == std::string::npos);
        CHECK(out.find("X-Plex-Token=REDACTED") != std::string::npos);
        CHECK(out.find("token=REDACTED") != std::string::npos);
    }

    // --- Direction B: no secret => byte-identical ---
    {
        const std::string clean =
            "misterplexd: PLAY http://pms.example:32400/library/metadata/1 off=0 dur=1000";
        const std::string out = redactSensitive(clean);
        CHECK(out == clean);
        // Vacuous-pass guard: sizes match and pointer-inequality is irrelevant;
        // equality must hold character-for-character.
        CHECK(out.size() == clean.size());
        CHECK(std::memcmp(out.data(), clean.data(), clean.size()) == 0);
    }

    {
        const std::string clean = "media: frames=710 vfps=23.0 presented=710";
        CHECK(redactSensitive(clean) == clean);
    }

    {
        // "token" as a substring of an unrelated word must not be mutilated.
        const std::string clean = "status=ok mytokenbucket=12 path=/tokens/list";
        CHECK(redactSensitive(clean) == clean);
    }

    if (fails) {
        std::fprintf(stderr, "test_log_redact: %d FAIL(s)\n", fails);
        return 1;
    }
    std::printf("test_log_redact: OK\n");
    return 0;
}
