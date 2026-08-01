#pragma once
// Resolve MiSTer HDMI/output geometry from MiSTer.ini [Plex] video_mode.
//
// Product overlay today authors into the DDR bank (624x480) and is stretched by
// ascal to this output raster. Option (c) chrome plane needs the OUTPUT size for
// layout; this helper fills the ARM-side gap documented in docs/osd-hires.md §A.
//
// Index table matches common MiSTer.ini comments / docs/display-resolution.md.
// Custom CVT strings (e.g. "1920,1440,60,cvtrb") are parsed when present.
// Missing/unparsed → ok=false (caller keeps bank chrome; never invents 1080p).

#include <algorithm>
#include <cctype>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <fstream>
#include <sstream>
#include <string>
#include <utility>
#include <vector>

namespace misterplex {

struct MisterVideoMode {
    bool ok = false;
    int index = -1; // preset index when value was a bare integer; -1 if custom
    int width = 0;
    int height = 0;
    int refresh = 0; // 0 if unknown
    std::string raw; // exact value string
    std::string source; // path or "builtin"
};

// Standard MiSTer preset indices used in docs and lab (not exhaustive).
inline bool misterVideoModePreset(int index, int* w, int* h, int* hz) {
    // Sourced from docs/display-resolution.md + lab notes (video_mode=12 = 1920x1440).
    struct Row {
        int i, w, h, hz;
    };
    static constexpr Row kRows[] = {
        {0, 640, 480, 60},   {1, 720, 480, 60},   {2, 720, 576, 50},
        {3, 800, 600, 60},   {4, 1024, 768, 60},  {5, 800, 600, 60},
        {6, 640, 480, 60},   {7, 1280, 720, 60},  {8, 1920, 1080, 60},
        {9, 1920, 1080, 50}, {10, 1366, 768, 60}, {11, 1024, 600, 60},
        {12, 1920, 1440, 60}, {13, 2048, 1536, 60},
    };
    for (const auto& r : kRows) {
        if (r.i == index) {
            if (w)
                *w = r.w;
            if (h)
                *h = r.h;
            if (hz)
                *hz = r.hz;
            return true;
        }
    }
    return false;
}

namespace detail {

inline std::string trimCopy(std::string s) {
    while (!s.empty() && std::isspace(static_cast<unsigned char>(s.front())))
        s.erase(s.begin());
    while (!s.empty() && std::isspace(static_cast<unsigned char>(s.back())))
        s.pop_back();
    return s;
}

inline bool parseIntStrict(const std::string& s, int* out) {
    if (s.empty() || out == nullptr)
        return false;
    char* end = nullptr;
    const long v = std::strtol(s.c_str(), &end, 10);
    if (end == s.c_str() || (end && *end != '\0'))
        return false;
    if (v < 0 || v > 100000)
        return false;
    *out = static_cast<int>(v);
    return true;
}

// "1920,1440,60,..." or "1920x1440" / "1920x1440@60"
inline bool parseCustomMode(const std::string& raw, int* w, int* h, int* hz) {
    if (raw.find(',') != std::string::npos) {
        std::vector<int> parts;
        std::stringstream ss(raw);
        std::string tok;
        while (std::getline(ss, tok, ',')) {
            tok = trimCopy(tok);
            if (tok.empty())
                break;
            // stop at non-numeric tokens (cvtrb, p13, …)
            int v = 0;
            if (!parseIntStrict(tok, &v))
                break;
            parts.push_back(v);
        }
        if (parts.size() >= 2) {
            *w = parts[0];
            *h = parts[1];
            *hz = parts.size() >= 3 ? parts[2] : 0;
            // MiSTer CVT form is hact,hfp,hs,hbp,vact,... — if 8+ ints, h/v act are [0] and [4]
            if (parts.size() >= 8 && parts[0] > 0 && parts[4] > 0) {
                *w = parts[0];
                *h = parts[4];
                // Fpix is last; refresh unknown here
                *hz = 0;
            }
            return *w >= 160 && *h >= 120;
        }
        return false;
    }
    // 1920x1440 or 1920x1440@60
    std::string s = raw;
    for (char& c : s) {
        if (c == 'X')
            c = 'x';
    }
    const auto xp = s.find('x');
    if (xp == std::string::npos)
        return false;
    int ww = 0, hh = 0, rr = 0;
    if (!parseIntStrict(s.substr(0, xp), &ww))
        return false;
    std::string rest = s.substr(xp + 1);
    const auto at = rest.find('@');
    if (at == std::string::npos) {
        if (!parseIntStrict(rest, &hh))
            return false;
    } else {
        if (!parseIntStrict(rest.substr(0, at), &hh))
            return false;
        (void)parseIntStrict(rest.substr(at + 1), &rr);
    }
    if (ww < 160 || hh < 120)
        return false;
    *w = ww;
    *h = hh;
    *hz = rr;
    return true;
}

} // namespace detail

// Parse a single video_mode value token (integer preset or custom string).
inline MisterVideoMode parseMisterVideoModeValue(const std::string& rawIn) {
    MisterVideoMode m;
    m.raw = detail::trimCopy(rawIn);
    if (m.raw.empty())
        return m;
    // strip inline comments
    const auto semi = m.raw.find(';');
    if (semi != std::string::npos)
        m.raw = detail::trimCopy(m.raw.substr(0, semi));
    const auto hash = m.raw.find('#');
    if (hash != std::string::npos)
        m.raw = detail::trimCopy(m.raw.substr(0, hash));

    int idx = 0;
    if (detail::parseIntStrict(m.raw, &idx)) {
        int w = 0, h = 0, hz = 0;
        if (!misterVideoModePreset(idx, &w, &h, &hz))
            return m;
        m.ok = true;
        m.index = idx;
        m.width = w;
        m.height = h;
        m.refresh = hz;
        m.source = "preset";
        return m;
    }
    int w = 0, h = 0, hz = 0;
    if (detail::parseCustomMode(m.raw, &w, &h, &hz)) {
        m.ok = true;
        m.index = -1;
        m.width = w;
        m.height = h;
        m.refresh = hz;
        m.source = "custom";
        return m;
    }
    return m;
}

// Read video_mode= from MiSTer.ini.
// Provenance (honest labels — never call ini "measured"):
//   1) [Plex] video_mode  → source "ini:plex"  (core-local override)
//   2) else [MiSTer] video_mode → source "ini:mister" (device global; parent lab)
//   3) else empty → ok=false (caller logs DEFAULT_ASSUMED source=none)
// Prefers bare video_mode over _ntsc/_pal within a section. Not applied HDMI
// (no userspace read API — r-misterfin); fabric plane uses HDMI_WIDTH/HEIGHT wires.
inline MisterVideoMode loadMisterVideoModeFromIni(const std::string& path) {
    MisterVideoMode out;
    std::ifstream in(path);
    if (!in)
        return out;
    enum class Sec { Other, Plex, Mister };
    Sec sec = Sec::Other;
    std::string plexRaw;
    std::string misterRaw;
    std::string plexAlt;
    std::string misterAlt;
    std::string line;
    while (std::getline(in, line)) {
        std::string t = detail::trimCopy(line);
        if (t.empty() || t[0] == ';' || t[0] == '#')
            continue;
        if (t.front() == '[') {
            std::string s = t;
            if (!s.empty() && s.back() == ']')
                s.pop_back();
            if (!s.empty() && s.front() == '[')
                s.erase(s.begin());
            std::string low = s;
            for (char& c : low)
                c = static_cast<char>(std::tolower(static_cast<unsigned char>(c)));
            if (low == "plex")
                sec = Sec::Plex;
            else if (low == "mister")
                sec = Sec::Mister;
            else
                sec = Sec::Other;
            continue;
        }
        if (sec != Sec::Plex && sec != Sec::Mister)
            continue;
        const auto eq = t.find('=');
        if (eq == std::string::npos)
            continue;
        std::string key = detail::trimCopy(t.substr(0, eq));
        std::string val = detail::trimCopy(t.substr(eq + 1));
        for (char& c : key)
            c = static_cast<char>(std::tolower(static_cast<unsigned char>(c)));
        auto take = [&](std::string& primary, std::string& alt) {
            if (key == "video_mode")
                primary = val;
            else if (key == "video_mode_ntsc" || key == "video_mode_pal") {
                if (alt.empty())
                    alt = val;
            }
        };
        if (sec == Sec::Plex)
            take(plexRaw, plexAlt);
        else
            take(misterRaw, misterAlt);
    }
    const std::string* best = nullptr;
    const char* tag = nullptr;
    if (!plexRaw.empty()) {
        best = &plexRaw;
        tag = "ini:plex";
    } else if (!plexAlt.empty()) {
        best = &plexAlt;
        tag = "ini:plex";
    } else if (!misterRaw.empty()) {
        best = &misterRaw;
        tag = "ini:mister";
    } else if (!misterAlt.empty()) {
        best = &misterAlt;
        tag = "ini:mister";
    }
    if (!best)
        return out;
    out = parseMisterVideoModeValue(*best);
    if (out.ok) {
        // tag is authoritative provenance; path is secondary detail in raw logs
        out.source = tag ? tag : "ini";
    }
    return out;
}

// Default on-device path (daemon runs as root on MiSTer).
inline constexpr const char* kMisterIniDefaultPath = "/media/fat/MiSTer.ini";

inline MisterVideoMode loadMisterVideoMode() {
    return loadMisterVideoModeFromIni(kMisterIniDefaultPath);
}

// Output-raster layout scale — docs/osd-chrome-plane-design.md §4.
// Independent of bank PlaybackOverlay::compute (which is content-canvas).
struct OutputChromeLayout {
    int outW = 0;
    int outH = 0;
    int bodyScale = 2; // 2..8
    int margin = 8;
    int panelH = 64;
    int glyphAdvance = 13; // 12x16 cell advance before scale
    int advancePx = 26; // glyphAdvance * bodyScale (OUTPUT pixels)
    bool useLargeFont = true;
};

inline OutputChromeLayout computeOutputChromeLayout(int outW, int outH) {
    OutputChromeLayout L;
    L.outW = outW;
    L.outH = outH;
    if (outW <= 0 || outH <= 0)
        return L;
    L.margin = std::max(6, outW / 40);
    // bodyScale = clamp(2..8, round(H/240)) with half-to-even — must match
    // tests/unit/test_chrome_output_layout_static.py (Python 3 round).
    // 600→2, 1080→4, 1440→6. Do not use lround (half away from zero).
    {
        const int q = outH / 240;
        const int r = outH % 240;
        int raw = q;
        if (r > 120)
            raw = q + 1;
        else if (r == 120)
            raw = (q % 2 == 0) ? q : (q + 1); // half toward even
        if (raw < 2)
            raw = 2;
        if (raw > 8)
            raw = 8;
        L.bodyScale = raw;
    }
    L.useLargeFont = (outH >= 480);
    L.glyphAdvance = L.useLargeFont ? 13 : 9;
    L.advancePx = L.glyphAdvance * L.bodyScale;
    const int glyphH = L.useLargeFont ? 16 : 13;
    const int textH = glyphH * L.bodyScale;
    const int need = 8 + textH + 4 + textH + 12 + 6;
    L.panelH = std::max(need, std::min(outH / 3, std::max(64, outH / 4)));
    if (L.panelH > outH - 2 * L.margin)
        L.panelH = std::max(need, outH - 2 * L.margin);
    L.panelH &= ~1;
    return L;
}

} // namespace misterplex
