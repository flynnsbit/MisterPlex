#pragma once
// Central log redaction for misterplexd.
//
// Secrets must never reach misterplexd.log. Call redactSensitive() on every
// string before it is written to a log sink (stderr / setLog callbacks).
// Do NOT apply this to live playback argv/URLs — only to the logged copy.

#include <string>

namespace misterplex {

// Replace secret VALUES, keep keys visible for debugging:
//   X-Plex-Token=SECRET     -> X-Plex-Token=REDACTED
//   X-Plex-Token: SECRET    -> X-Plex-Token: REDACTED
//   token=... / accessToken=... / PLEX_TOKEN=... likewise.
//
// Byte-identical when no known secret key is present.
inline std::string redactSensitive(std::string s) {
#ifdef LOG_REDACT_FAULT_IDENTITY
    // Intentional fault for EXPECTED_RED mutation tests only.
    return s;
#else
    // Longer / more specific keys first so a future case-fold cannot let
    // bare "token" collide with "X-Plex-Token".
    static const char* kKeys[] = {
        "X-Plex-Token",
        "accessToken",
        "PLEX_TOKEN",
        "token",
    };
    static constexpr const char kRedacted[] = "REDACTED";

    auto isKeyBoundary = [](const std::string& str, size_t pos) -> bool {
        if (pos == 0)
            return true;
        const char prev = str[pos - 1];
        return prev == '&' || prev == '?' || prev == ' ' || prev == '\t' || prev == '\n' ||
               prev == '\r' || prev == ';' || prev == '"' || prev == '\'';
    };

    for (const char* key : kKeys) {
        const std::string k(key);

        // Query / conf form: Key=VALUE
        {
            const std::string pfx = k + "=";
            size_t pos = 0;
            while ((pos = s.find(pfx, pos)) != std::string::npos) {
                if (!isKeyBoundary(s, pos)) {
                    pos += pfx.size();
                    continue;
                }
                const size_t val = pos + pfx.size();
                const auto end = s.find_first_of("& \t\r\n\"'", val);
                const size_t len =
                    (end == std::string::npos) ? std::string::npos : (end - val);
                s.replace(val, len, kRedacted);
                pos = val + (sizeof(kRedacted) - 1);
            }
        }

        // HTTP header form (FFmpeg -headers block): Key: VALUE
        {
            const std::string pfx = k + ":";
            size_t pos = 0;
            while ((pos = s.find(pfx, pos)) != std::string::npos) {
                if (!isKeyBoundary(s, pos)) {
                    pos += pfx.size();
                    continue;
                }
                size_t val = pos + pfx.size();
                while (val < s.size() && (s[val] == ' ' || s[val] == '\t'))
                    ++val;
                const auto end = s.find_first_of("\r\n", val);
                const size_t len =
                    (end == std::string::npos) ? std::string::npos : (end - val);
                s.replace(val, len, kRedacted);
                pos = val + (sizeof(kRedacted) - 1);
            }
        }
    }
    return s;
#endif
}

} // namespace misterplex
