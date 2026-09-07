#pragma once
// On-glass PMS library overlay. No FPGA exec — daemon paints + playMedia.

#include <algorithm>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <string>
#include <vector>

namespace misterplex {

struct LibraryRow {
    std::string title;
    std::string key;
    std::string ratingKey;
    std::string type;
    bool directory = false;
};

inline std::string xmlAttr(const std::string& tag, const char* name) {
    const std::string pre = std::string(name) + "=\"";
    const auto p = tag.find(pre);
    if (p == std::string::npos)
        return {};
    const auto s = p + pre.size();
    const auto e = tag.find('"', s);
    if (e == std::string::npos)
        return {};
    return tag.substr(s, e - s);
}

inline void appendTags(const std::string& xml, const char* open, bool directory,
                       std::vector<LibraryRow>& out) {
    size_t i = 0;
    while (i < xml.size()) {
        const auto p = xml.find(open, i);
        if (p == std::string::npos)
            break;
        const auto e = xml.find('>', p);
        if (e == std::string::npos)
            break;
        const std::string tag = xml.substr(p, e - p + 1);
        LibraryRow r;
        r.title = xmlAttr(tag, "title");
        r.key = xmlAttr(tag, "key");
        r.ratingKey = xmlAttr(tag, "ratingKey");
        r.type = xmlAttr(tag, "type");
        r.directory = directory;
        if (!r.title.empty() || !r.key.empty() || !r.ratingKey.empty())
            out.push_back(std::move(r));
        i = e + 1;
    }
}

inline std::vector<LibraryRow> parseLibraryXml(const std::string& xml) {
    std::vector<LibraryRow> rows;
    appendTags(xml, "<Directory", true, rows);
    appendTags(xml, "<Video", false, rows);
    appendTags(xml, "<Track", false, rows);
    return rows;
}

inline std::string libraryListPath(const LibraryRow& row) {
    if (row.key.empty())
        return {};
    if (row.key[0] == '/')
        return row.key;
    return "/library/sections/" + row.key + "/all";
}

struct LibraryBrowser {
    bool visible = false;
    std::vector<std::vector<LibraryRow>> stack;
    std::vector<int> cursors;
    std::string status;

    void reset() {
        visible = false;
        stack.clear();
        cursors.clear();
        status.clear();
    }

    void show(std::vector<LibraryRow> root, std::string why = {}) {
        stack.clear();
        cursors.clear();
        stack.push_back(std::move(root));
        cursors.push_back(0);
        visible = true;
        status = std::move(why);
        clamp();
    }

    void hide() { visible = false; }

    bool empty() const { return stack.empty() || stack.back().empty(); }

    int cursor() const { return cursors.empty() ? 0 : cursors.back(); }

    const LibraryRow* current() const {
        if (stack.empty() || cursors.empty())
            return nullptr;
        const auto& rows = stack.back();
        const int c = cursors.back();
        if (c < 0 || c >= static_cast<int>(rows.size()))
            return nullptr;
        return &rows[static_cast<size_t>(c)];
    }

    void clamp() {
        if (stack.empty())
            return;
        if (cursors.size() != stack.size())
            cursors.resize(stack.size(), 0);
        auto& c = cursors.back();
        const int n = static_cast<int>(stack.back().size());
        if (n <= 0)
            c = 0;
        else if (c < 0)
            c = 0;
        else if (c >= n)
            c = n - 1;
    }

    void move(int delta) {
        if (!visible || stack.empty())
            return;
        clamp();
        const int n = static_cast<int>(stack.back().size());
        if (n <= 0)
            return;
        cursors.back() = (cursors.back() + delta % n + n) % n;
    }

    void push(std::vector<LibraryRow> child) {
        stack.push_back(std::move(child));
        cursors.push_back(0);
        clamp();
    }

    bool pop() {
        if (stack.size() <= 1) {
            hide();
            return false;
        }
        stack.pop_back();
        cursors.pop_back();
        return true;
    }
};

// 5×7 caps, same pitch as playback_overlay glyphs.
inline const uint8_t* libraryGlyph(char ch) {
    static constexpr uint8_t sp[7] = {0, 0, 0, 0, 0, 0, 0};
    static constexpr uint8_t g[27][7] = {
        {0x0e, 0x11, 0x11, 0x1f, 0x11, 0x11, 0x11}, // A
        {0x1e, 0x11, 0x11, 0x1e, 0x11, 0x11, 0x1e}, // B
        {0x0e, 0x11, 0x10, 0x10, 0x10, 0x11, 0x0e}, // C
        {0x1e, 0x11, 0x11, 0x11, 0x11, 0x11, 0x1e}, // D
        {0x1f, 0x10, 0x10, 0x1e, 0x10, 0x10, 0x1f}, // E
        {0x1f, 0x10, 0x10, 0x1e, 0x10, 0x10, 0x10}, // F
        {0x0e, 0x11, 0x10, 0x17, 0x11, 0x11, 0x0f}, // G
        {0x11, 0x11, 0x11, 0x1f, 0x11, 0x11, 0x11}, // H
        {0x0e, 0x04, 0x04, 0x04, 0x04, 0x04, 0x0e}, // I
        {0x01, 0x01, 0x01, 0x01, 0x11, 0x11, 0x0e}, // J
        {0x11, 0x12, 0x14, 0x18, 0x14, 0x12, 0x11}, // K
        {0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x1f}, // L
        {0x11, 0x1b, 0x15, 0x11, 0x11, 0x11, 0x11}, // M
        {0x11, 0x19, 0x15, 0x13, 0x11, 0x11, 0x11}, // N
        {0x0e, 0x11, 0x11, 0x11, 0x11, 0x11, 0x0e}, // O
        {0x1e, 0x11, 0x11, 0x1e, 0x10, 0x10, 0x10}, // P
        {0x0e, 0x11, 0x11, 0x11, 0x15, 0x12, 0x0d}, // Q
        {0x1e, 0x11, 0x11, 0x1e, 0x14, 0x12, 0x11}, // R
        {0x0f, 0x10, 0x10, 0x0e, 0x01, 0x01, 0x1e}, // S
        {0x1f, 0x04, 0x04, 0x04, 0x04, 0x04, 0x04}, // T
        {0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x0e}, // U
        {0x11, 0x11, 0x11, 0x11, 0x0a, 0x0a, 0x04}, // V
        {0x11, 0x11, 0x11, 0x15, 0x15, 0x1b, 0x11}, // W
        {0x11, 0x11, 0x0a, 0x04, 0x0a, 0x11, 0x11}, // X
        {0x11, 0x11, 0x0a, 0x04, 0x04, 0x04, 0x04}, // Y
        {0x1f, 0x01, 0x02, 0x04, 0x08, 0x10, 0x1f}, // Z
    };
    static constexpr uint8_t d[10][7] = {
        {0x0e, 0x11, 0x13, 0x15, 0x19, 0x11, 0x0e}, {0x04, 0x0c, 0x04, 0x04, 0x04, 0x04, 0x0e},
        {0x0e, 0x11, 0x01, 0x02, 0x04, 0x08, 0x1f}, {0x1e, 0x01, 0x01, 0x0e, 0x01, 0x01, 0x1e},
        {0x02, 0x06, 0x0a, 0x12, 0x1f, 0x02, 0x02}, {0x1f, 0x10, 0x1e, 0x01, 0x01, 0x11, 0x0e},
        {0x06, 0x08, 0x10, 0x1e, 0x11, 0x11, 0x0e}, {0x1f, 0x01, 0x02, 0x04, 0x08, 0x08, 0x08},
        {0x0e, 0x11, 0x11, 0x0e, 0x11, 0x11, 0x0e}, {0x0e, 0x11, 0x11, 0x0f, 0x01, 0x02, 0x0c},
    };
    static constexpr uint8_t gt[7] = {0x04, 0x08, 0x10, 0x08, 0x04, 0x00, 0x00}; // >
    static constexpr uint8_t dash[7] = {0x00, 0x00, 0x00, 0x1f, 0x00, 0x00, 0x00};
    static constexpr uint8_t dot[7] = {0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x04};
    static constexpr uint8_t qmark[7] = {0x0e, 0x11, 0x01, 0x02, 0x04, 0x00, 0x04};
    static constexpr uint8_t slash[7] = {0x01, 0x02, 0x04, 0x04, 0x08, 0x10, 0x10};
    static constexpr uint8_t colon[7] = {0x00, 0x04, 0x00, 0x00, 0x00, 0x04, 0x00};
    static constexpr uint8_t apos[7] = {0x04, 0x04, 0x00, 0x00, 0x00, 0x00, 0x00};
    if (ch >= 'a' && ch <= 'z')
        ch = static_cast<char>(ch - 'a' + 'A');
    if (ch >= 'A' && ch <= 'Z')
        return g[ch - 'A'];
    if (ch >= '0' && ch <= '9')
        return d[ch - '0'];
    if (ch == '>')
        return gt;
    if (ch == '-' || ch == '_')
        return dash;
    if (ch == '.' || ch == ',')
        return dot;
    if (ch == '?')
        return qmark;
    if (ch == '/')
        return slash;
    if (ch == ':' || ch == ';')
        return colon;
    if (ch == '\'' || ch == '`')
        return apos;
    return sp;
}

inline void libraryPutY(uint8_t* y, int w, int h, int x, int y0, uint8_t v) {
    if (x < 0 || y0 < 0 || x >= w || y0 >= h)
        return;
    y[static_cast<size_t>(y0) * static_cast<size_t>(w) + static_cast<size_t>(x)] = v;
}

inline void libraryDrawText(uint8_t* y, int w, int h, int x, int y0, const char* text,
                            int scale, uint8_t ink) {
    if (!y || !text || scale < 1)
        return;
    for (const char* p = text; *p; ++p) {
        const uint8_t* g = libraryGlyph(*p);
        for (int row = 0; row < 7; ++row)
            for (int col = 0; col < 5; ++col)
                if (g[row] & (1u << (4 - col)))
                    for (int dy = 0; dy < scale; ++dy)
                        for (int dx = 0; dx < scale; ++dx)
                            libraryPutY(y, w, h, x + col * scale + dx, y0 + row * scale + dy,
                                        ink);
        x += 6 * scale;
    }
}

inline void renderLibraryI420(uint8_t* i420, int w, int h, const LibraryBrowser& br) {
    if (!i420 || w < 64 || h < 64 || (w & 1) || (h & 1) || !br.visible)
        return;
    const size_t ysz = static_cast<size_t>(w) * static_cast<size_t>(h);
    uint8_t* y = i420;
    uint8_t* u = i420 + ysz;
    uint8_t* v = u + ysz / 4;
    std::memset(y, 0x1a, ysz);
    std::memset(u, 128, ysz / 4);
    std::memset(v, 128, ysz / 4);

    const int scale = (w >= 1280) ? 3 : ((w >= 640) ? 2 : 1);
    libraryDrawText(y, w, h, 8, 8, "PLEX LIBRARY", scale, 0xE0);
    if (!br.status.empty())
        libraryDrawText(y, w, h, 8, 8 + 10 * scale, br.status.c_str(), scale, 0x90);

    const int rowH = 9 * scale;
    const int yList = 8 + 22 * scale;
    const int maxRows = std::max(1, (h - yList - 8) / rowH);
    if (br.stack.empty())
        return;
    const auto& rows = br.stack.back();
    const int cur = br.cursor();
    int start = 0;
    if (cur >= maxRows)
        start = cur - maxRows + 1;
    for (int i = 0; i < maxRows; ++i) {
        const int idx = start + i;
        if (idx >= static_cast<int>(rows.size()))
            break;
        const int yy = yList + i * rowH;
        const bool hi = (idx == cur);
        if (hi) {
            for (int r = 0; r < rowH - scale; ++r)
                for (int x = 4; x < w - 4; ++x)
                    libraryPutY(y, w, h, x, yy + r, 0x40);
        }
        char line[96];
        const auto& row = rows[static_cast<size_t>(idx)];
        const char mark = row.directory ? '>' : ' ';
        std::snprintf(line, sizeof(line), "%c %s", mark, row.title.empty() ? "?" : row.title.c_str());
        libraryDrawText(y, w, h, 8, yy + scale, line, scale, hi ? 0xF0 : 0xC8);
    }
}

} // namespace misterplex
