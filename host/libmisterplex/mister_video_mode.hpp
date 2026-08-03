#pragma once
// Output chrome layout helpers (HDMI applied geometry).

#include <algorithm>

namespace misterplex {

struct OutputChromeLayout {
    int outW = 0;
    int outH = 0;
    int bodyScale = 2; // 2..8
    int glyphAdvance = 9;
    int advancePx = 18;
    bool useLargeFont = false;
};

inline OutputChromeLayout computeOutputChromeLayout(int outW, int outH) {
    OutputChromeLayout L;
    L.outW = outW;
    L.outH = outH;
    if (outH <= 0) {
        L.bodyScale = 2;
    } else {
        const int q = outH / 240;
        const int r = outH % 240;
        int raw = q;
        if (r > 120)
            raw = q + 1;
        else if (r == 120)
            raw = (q % 2 == 0) ? q : (q + 1);
        if (raw < 2)
            raw = 2;
        if (raw > 8)
            raw = 8;
        L.bodyScale = raw;
    }
    L.useLargeFont = outH >= 480;
    L.advancePx = L.glyphAdvance * L.bodyScale;
    return L;
}

} // namespace misterplex
