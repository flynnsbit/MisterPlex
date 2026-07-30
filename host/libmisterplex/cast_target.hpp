#pragma once
// Cast target identity: Plex controllers name the selected player via
// X-Plex-Target-Client-Identifier (header or query). If that id disagrees with
// our machineId, GDM still lists us (picker shows the player) but the session
// will not stick — classic "appears then vanishes" with no phone-side error.
//
// Pure helpers so unit tests pin the match rule without HTTP.

#include <cctype>
#include <string>

namespace misterplex {

namespace cast_target_detail {

inline std::string asciiLower(std::string s) {
    for (char& c : s)
        c = static_cast<char>(std::tolower(static_cast<unsigned char>(c)));
    return s;
}

inline std::string headerValueCI(const std::string& req, const char* name) {
    const std::string want = asciiLower(name);
    size_t line = 0;
    while (line < req.size()) {
        auto eol = req.find("\r\n", line);
        if (eol == std::string::npos)
            eol = req.size();
        if (eol == line)
            break;
        std::string h = req.substr(line, eol - line);
        auto colon = h.find(':');
        if (colon != std::string::npos) {
            if (asciiLower(h.substr(0, colon)) == want) {
                size_t v = colon + 1;
                while (v < h.size() && (h[v] == ' ' || h[v] == '\t'))
                    ++v;
                return h.substr(v);
            }
        }
        if (eol >= req.size())
            break;
        line = eol + 2;
    }
    return {};
}

inline std::string queryParam(const std::string& req, const char* key) {
    const std::string k = std::string(key) + "=";
    auto pos = req.find(k);
    if (pos == std::string::npos)
        return {};
    pos += k.size();
    auto end = req.find_first_of(" &\r\n", pos);
    return req.substr(pos, end == std::string::npos ? std::string::npos : end - pos);
}

} // namespace cast_target_detail

// Target client id from a raw HTTP request. Empty if the controller did not
// name one (local lab curls, /resources probes).
inline std::string castTargetClientId(const std::string& req) {
    using namespace cast_target_detail;
    std::string t = headerValueCI(req, "X-Plex-Target-Client-Identifier");
    if (!t.empty())
        return t;
    t = queryParam(req, "X-Plex-Target-Client-Identifier");
    if (!t.empty())
        return t;
    return queryParam(req, "targetClientIdentifier");
}

// true = handle; false = reject (target named a different player).
inline bool castTargetAccepted(const std::string& req, const std::string& selfId,
                               std::string* gotOut = nullptr) {
    const std::string got = castTargetClientId(req);
    if (gotOut)
        *gotOut = got;
#ifdef CAST_TARGET_FAULT_ACCEPT_ALL
    // Fault mutant: pre-fix behaviour — ignore target header entirely.
    (void)selfId;
    return true;
#else
    if (got.empty())
        return true;
    return got == selfId;
#endif
}

} // namespace misterplex
