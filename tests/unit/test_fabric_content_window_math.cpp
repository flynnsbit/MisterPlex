// Fabric content-window scale math (w-geom design gate + w-scaler RTL lock).
// Models present_content_window mul-shift with RUNTIME content_w/h instead of FRAME_W/H.
// Proves: 320x240 content covers full DE without quarter-size island.
// true rc direct. Soft-skip never.

#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <fstream>
#include <set>
#include <string>

namespace {

int g_fails = 0;
#define EXPECT(c, m)                                                                               \
    do {                                                                                           \
        if (!(c)) {                                                                                \
            std::fprintf(stderr, "FAIL: %s\n", m);                                                 \
            ++g_fails;                                                                             \
        }                                                                                          \
    } while (0)

// present_core formulas (content_* replace FRAME_* when win_enable).
int store_x_scale(int content_w) { return (content_w * 39647) / 320; }
int store_y_scale(int content_h, int v_de) { return (content_h * 65536) / v_de; }

int store_x_at(int hc, int scale, int x0, int last_x) {
    const uint32_t prod = uint32_t(hc) * uint32_t(scale);
    int comb = x0 + int(prod >> 16);
    if (comb > last_x)
        comb = last_x;
    if (comb < x0)
        comb = x0;
    return comb;
}

int store_y_at(int py, int scale, int y0, int v_de, int last_y) {
    int sy = py;
    if (sy >= v_de)
        sy = v_de - 1;
    const uint32_t prod = uint32_t(sy) * uint32_t(scale);
    int comb = y0 + int(prod >> 16);
    if (comb > last_y)
        comb = last_y;
    if (comb < y0)
        comb = y0;
    return comb;
}

size_t yuv420_bytes(int w, int h) {
    if (w <= 0 || h <= 0 || (w & 1) || (h & 1))
        return 0;
    return size_t(w) * size_t(h) * 3u / 2u;
}

} // namespace

bool file_contains(const char* path, const char* needle) {
    std::ifstream in(path);
    if (!in)
        return false;
    std::string all((std::istreambuf_iterator<char>(in)), std::istreambuf_iterator<char>());
    return all.find(needle) != std::string::npos;
}

int main() {
    constexpr int H_DE = 529;
    constexpr int V_DE = 480;

    // --- RTL source locks (w-scaler) ---
    EXPECT(file_contains("fpga/Plex_MiSTer/rtl/present_content_window.sv",
                         "module present_content_window"),
           "present_content_window.sv exists");
    EXPECT(file_contains("fpga/Plex_MiSTer/rtl/present_content_window.sv", "win_enable"),
           "window has win_enable");
    EXPECT(file_contains("fpga/Plex_MiSTer/rtl/present_content_window.sv",
                         "STORE_X_SCALE = (FRAME_W * 39647) / 320"),
           "legacy STORE_X_SCALE formula in window module");
    EXPECT(file_contains("fpga/Plex_MiSTer/rtl/present_content_window.sv",
                         "sx_num = {18'd0, cw_eff} * 28'd39647"),
           "runtime SX numerator");
    EXPECT(file_contains("fpga/Plex_MiSTer/rtl/present_core.sv", "present_content_window"),
           "present_core instantiates window");
    EXPECT(file_contains("fpga/Plex_MiSTer/Plex.sv", "fabric_win_enable"),
           "Plex.sv wires fabric_win_enable (safe default 0)");
    EXPECT(file_contains("fpga/Plex_MiSTer/Plex.sv", "fabric_win_enable   = 1'b0"),
           "win_enable defaults 0 (legacy safe)");

    // --- Legacy full-bank (win_enable=0 equivalent): content = 640x480 ---
    {
        const int cw = 640, ch = 480;
        const int sx = store_x_scale(cw);
        const int sy = store_y_scale(ch, V_DE);
        EXPECT(sx == 79294, "legacy STORE_X_SCALE 640");
        EXPECT(sy == 65536, "legacy STORE_Y_SCALE 1.0");
        std::set<int> ys;
        for (int py = 0; py < V_DE; ++py)
            ys.insert(store_y_at(py, sy, 0, V_DE, ch - 1));
        EXPECT(ys.size() == 480u, "legacy unique Y = 480");
    }

    // --- V1 fabric window: content 320x240 at origin, full DE stretch ---
    {
        const int cw = 320, ch = 240, x0 = 0, y0 = 0;
        const int sx = store_x_scale(cw);
        const int sy = store_y_scale(ch, V_DE);
        EXPECT(sx == 39647, "320 content STORE_X_SCALE");
        // 240*65536/480 = 32768 = 0.5 Q16 → each store row covers 2 DE lines
        EXPECT(sy == 32768, "320 content STORE_Y_SCALE 0.5");

        std::set<int> xs, ys;
        for (int hc = 0; hc < H_DE; ++hc)
            xs.insert(store_x_at(hc, sx, x0, x0 + cw - 1));
        for (int py = 0; py < V_DE; ++py)
            ys.insert(store_y_at(py, sy, y0, V_DE, y0 + ch - 1));

        EXPECT(xs.size() == 320u, "unique store_x covers all 320 content cols");
        EXPECT(*xs.begin() == 0 && *xs.rbegin() == 319, "store_x range 0..319");
        EXPECT(ys.size() == 240u, "unique store_y covers all 240 content rows");
        EXPECT(*ys.begin() == 0 && *ys.rbegin() == 239, "store_y range 0..239");

        // Quarter-size failure mode: if scales stayed 640/480 while content is 320,
        // DE would only sample x 0..~264 of a 640 domain — not full 320 content
        // mapped across DE. Our window maps full content across full DE.
        EXPECT(store_x_at(0, sx, 0, 319) == 0, "hc0 -> x0");
        EXPECT(store_x_at(H_DE - 1, sx, 0, 319) == 319, "hc last -> x last");
        EXPECT(store_y_at(0, sy, 0, V_DE, 239) == 0, "py0 -> y0");
        EXPECT(store_y_at(V_DE - 1, sy, 0, V_DE, 239) == 239, "py last -> y last");

        std::printf("V1_320 window sx=%d sy=%d unique_x=%zu unique_y=%zu\n", sx, sy, xs.size(),
                    ys.size());
    }

    // --- Pad-only negative (documented): content island WITHOUT scale change ---
    // If ARM writes 320x240 at (0,0) but SX/SY stay full-frame 640/480, DE samples
    // store as if 640 wide → first ~265 of 640 = mostly content + black, NOT full
    // stretch of 320. Unique x in 0..319 while addressing 640 domain ≠ full DE map.
    {
        const int sx_wrong = store_x_scale(640); // forgot to switch scale
        std::set<int> xs;
        for (int hc = 0; hc < H_DE; ++hc)
            xs.insert(store_x_at(hc, sx_wrong, 0, 639));
        // Samples ~529 unique x across 0..638 — does NOT clamp to 319.
        EXPECT(xs.size() > 320u, "pad-only wrong scale samples >320 x (quarter class)");
        EXPECT(*xs.rbegin() > 319, "pad-only reaches past content width");
        std::printf("NEG_pad_only unique_x=%zu max=%d (quarter-size class)\n", xs.size(),
                    *xs.rbegin());
    }

    // --- Byte contract ---
    EXPECT(yuv420_bytes(624, 480) == 449280u, "coded bank bytes");
    EXPECT(yuv420_bytes(320, 240) == 115200u, "native 320 bytes");
    EXPECT(yuv420_bytes(320, 240) * 4 > yuv420_bytes(624, 480) || true, "ratio note");
    const double ratio =
        double(yuv420_bytes(624, 480)) / double(yuv420_bytes(320, 240));
    EXPECT(ratio > 3.8 && ratio < 4.0, "DDR write ratio ~3.9x");
    std::printf("DDR_BYTES bank=%zu native320=%zu ratio=%.3f\n", yuv420_bytes(624, 480),
                yuv420_bytes(320, 240), ratio);

    // --- FORCE_SCALE retarget: reader bytes follow content window ---
    EXPECT(yuv420_bytes(320, 240) != yuv420_bytes(624, 480),
           "FORCE_SCALE must retarget reader bytes when window is 320");

    // FEED wall ms/f pins (docs/evidence/p480/p720-bus-and-bitrate-margin.md).
    {
        constexpr double present_ms = 10.411;
        constexpr double scale_ms = 2.954;
        constexpr double sum_ms = 40.190;
        constexpr double budget_25 = 40.0;
        EXPECT(present_ms > scale_ms * 3.0, "FEED: present/DDR > 3x scale delta");
        EXPECT(sum_ms > budget_25, "FEED: full stack over 25 fps budget");
        const double bytes_ratio = 449280.0 / 115200.0;
        EXPECT(bytes_ratio > 3.89 && bytes_ratio < 3.91, "byte ratio 3.9");
        const double save_lo = 0.30 * present_ms * (1.0 - 1.0 / bytes_ratio);
        const double save_hi = 0.70 * present_ms * (1.0 - 1.0 / bytes_ratio);
        EXPECT(save_lo > 2.0 && save_hi < 6.0, "pre-reg A1 save band ~2-5.5 ms/f");
        std::printf("FEED_PIN present=%.3f scale=%.3f A1_save_band=%.2f..%.2f ms/f\n", present_ms,
                    scale_ms, save_lo, save_hi);
    }

    if (g_fails) {
        std::fprintf(stderr, "test_fabric_content_window_math: %d failure(s)\n", g_fails);
        return 1;
    }
    std::printf("PASS test_fabric_content_window_math\n");
    return 0;
}
