// Tiny conf value helpers shared by misterplexd and unit tests.
// Key lookup is whole-file scan (order of keys in the conf text does not matter).
#pragma once

#include "libmisterplex/coded_size.hpp"

#include <string>

namespace misterplex {

// Strip leading/trailing ASCII space and CR/LF/TAB. Conf files edited on Windows
// or transferred with CRLF leave a trailing '\r' after getline; without this,
// confTruthy("1\r") is false and DECODE_ALLOW_LAB_480P silently fails closed.
inline std::string trimConfValue(std::string v) {
    while (!v.empty() &&
           (v.back() == ' ' || v.back() == '\t' || v.back() == '\r' || v.back() == '\n'))
        v.pop_back();
    size_t i = 0;
    while (i < v.size() &&
           (v[i] == ' ' || v[i] == '\t' || v[i] == '\r' || v[i] == '\n'))
        ++i;
    if (i)
        v.erase(0, i);
    return v;
}

inline bool confTruthy(const std::string& raw) {
    const std::string v = trimConfValue(raw);
    return v == "1" || v == "true" || v == "yes" || v == "on";
}

// First KEY= value in a multi-line conf blob (comments and blanks skipped).
// Returns trimmed value or empty if absent. Scan is whole-file — key order
// relative to other keys is irrelevant.
inline std::string confLookup(const std::string& text, const char* key) {
    if (!key || !*key)
        return {};
    const std::string prefix = std::string(key) + "=";
    size_t pos = 0;
    while (pos < text.size()) {
        size_t eol = text.find('\n', pos);
        if (eol == std::string::npos)
            eol = text.size();
        std::string line = text.substr(pos, eol - pos);
        pos = eol + 1;
        if (!line.empty() && line.back() == '\r')
            line.pop_back();
        if (line.empty() || line[0] == '#')
            continue;
        if (line.rfind(prefix, 0) == 0)
            return trimConfValue(line.substr(prefix.size()));
    }
    return {};
}

struct DecodeConfAdoption {
    bool allow_lab_480p = false;
    bool decode_key_present = false;
    CodedSizeParseResult result{};
};

// Order-independent DECODE + DECODE_ALLOW_LAB_480P adoption from conf text.
// Mirrors misterplexd main: resolve allow first (from text), then adopt DECODE.
// Unit tests pin both key orders and CRLF allow values.
inline DecodeConfAdoption adoptDecodeFromConfText(const std::string& text) {
    DecodeConfAdoption out;
    const std::string allowRaw = confLookup(text, "DECODE_ALLOW_LAB_480P");
    out.allow_lab_480p = confTruthy(allowRaw);
    const std::string decodeRaw = confLookup(text, "DECODE");
    out.decode_key_present = !decodeRaw.empty();
    if (!out.decode_key_present) {
        out.result.status = CodedSizeParseStatus::Empty;
        out.result.reason = "DECODE key absent";
        out.result.size = kDefaultCodedDecodeSize;
        return out;
    }
    out.result = adoptExternalCodedSize(decodeRaw, out.allow_lab_480p);
    return out;
}

} // namespace misterplex
