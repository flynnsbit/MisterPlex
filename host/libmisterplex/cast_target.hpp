#pragma once
// Cast target identity: Plex controllers name the selected player via
// X-Plex-Target-Client-Identifier (header or query). If that id disagrees with
// our machineId, GDM still lists us (picker shows the player) but the session
// will not stick — classic "appears then vanishes" with no phone-side error.
//
// Pure helpers so unit tests pin the match rule without HTTP.
//
// Match rules (keep in sync with tests/unit/test_cast_target.*):
//  - Header name is case-insensitive (HTTP).
//  - Optional whitespace (OWS) is trimmed on BOTH ends of the value.
//  - Query values are percent-decoded before compare (e.g. misterplex%2Ddev).
//  - Precedence: header wins over query when both are present (deterministic;
//    do not "fix" this without updating callers and the unit probes).
//  - Empty / absent target → accept (lab curls, discovery probes).

#include <cctype>
#include <string>

namespace misterplex {

namespace cast_target_detail {

inline std::string asciiLower(std::string s) {
    for (char& c : s)
        c = static_cast<char>(std::tolower(static_cast<unsigned char>(c)));
    return s;
}

// HTTP optional whitespace: SP / HTAB on either side of a field value.
inline std::string trimOws(std::string s) {
    size_t b = 0;
    while (b < s.size() && (s[b] == ' ' || s[b] == '\t'))
        ++b;
    size_t e = s.size();
    while (e > b && (s[e - 1] == ' ' || s[e - 1] == '\t'))
        --e;
    return s.substr(b, e - b);
}

inline int hexNibble(char c) {
    if (c >= '0' && c <= '9')
        return c - '0';
    if (c >= 'a' && c <= 'f')
        return c - 'a' + 10;
    if (c >= 'A' && c <= 'F')
        return c - 'A' + 10;
    return -1;
}

// Percent-decode (and '+' → space). Invalid % sequences are left intact.
inline std::string percentDecode(const std::string& in) {
    std::string out;
    out.reserve(in.size());
    for (size_t i = 0; i < in.size(); ++i) {
        if (in[i] == '%' && i + 2 < in.size()) {
            const int hi = hexNibble(in[i + 1]);
            const int lo = hexNibble(in[i + 2]);
            if (hi >= 0 && lo >= 0) {
                out.push_back(static_cast<char>((hi << 4) | lo));
                i += 2;
                continue;
            }
        }
        if (in[i] == '+') {
            out.push_back(' ');
            continue;
        }
        out.push_back(in[i]);
    }
    return out;
}

inline std::string normalizeTargetId(std::string raw) {
    // Trim first so trailing OWS is not part of the token; then decode so
    // misterplex%2Ddev matches misterplex-dev.
    return percentDecode(trimOws(std::move(raw)));
}

inline std::string headerValueCI(const std::string& req, const char* name) {
    const std::string want = asciiLower(name);
    size_t line = 0;
    while (line < req.size()) {
        // Incomplete trailing line (no CRLF yet) must not be treated as a
        // finished header — TCP can split mid-value ("misterplex-" | "dev").
        auto eol = req.find("\r\n", line);
        if (eol == std::string::npos)
            break;
        if (eol == line)
            break; // empty line → end of headers
        std::string h = req.substr(line, eol - line);
        auto colon = h.find(':');
        if (colon != std::string::npos) {
            if (asciiLower(h.substr(0, colon)) == want) {
                // Full field-value; normalizeTargetId trims OWS both sides.
                return h.substr(colon + 1);
            }
        }
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
//
// Precedence (documented, intentional): header over query. When a controller
// sends both, the header is the authoritative selection; query is a fallback
// for clients that only put the id on the URL.
inline std::string castTargetClientId(const std::string& req) {
    using namespace cast_target_detail;
    std::string t = headerValueCI(req, "X-Plex-Target-Client-Identifier");
    if (!t.empty())
        return normalizeTargetId(std::move(t));
    t = queryParam(req, "X-Plex-Target-Client-Identifier");
    if (!t.empty())
        return normalizeTargetId(std::move(t));
    t = queryParam(req, "targetClientIdentifier");
    if (!t.empty())
        return normalizeTargetId(std::move(t));
    return {};
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
