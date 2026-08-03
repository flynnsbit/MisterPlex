// Fabric content-window scale math — models present_content_window.sv ceil-Q16 NN.
// Positive: endpoint-exact last pixel. Negative: floor Q16 undershoots last col.
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

bool file_contains(const char* path, const char* needle) {
    std::ifstream in(path);
    if (!in)
        return false;
    std::string all((std::istreambuf_iterator<char>(in)), std::istreambuf_iterator<char>());
    return all.find(needle) != std::string::npos;
}

int win_store_x_scale(int content_w, int h_de) {
    if (content_w <= 1 || h_de <= 1)
        return 65536;
    const int cw_m1 = content_w - 1;
    const int hd_m1 = h_de - 1;
    // ceil((cw-1)*65536/(h_de-1))
    return int(((int64_t)cw_m1 * 65536 + hd_m1 - 1) / hd_m1);
}
int win_store_y_scale(int content_h, int v_de) {
    if (content_h <= 1 || v_de <= 1)
        return 65536;
    const int ch_m1 = content_h - 1;
    const int vd_m1 = v_de - 1;
    return int(((int64_t)ch_m1 * 65536 + vd_m1 - 1) / vd_m1);
}

int store_x_at(int hc, int sx, int x0, int last_x) {
    int64_t prod = (int64_t)hc * sx;
    int x = x0 + int(prod >> 16);
    if (x > last_x)
        x = last_x;
    return x;
}
int store_y_at(int py, int sy, int y0, int /*v_de*/, int last_y) {
    int64_t prod = (int64_t)py * sy;
    int y = y0 + int(prod >> 16);
    if (y > last_y)
        y = last_y;
    return y;
}

} // namespace

int main() {
    EXPECT(file_contains("fpga/Plex_MiSTer/rtl/present_content_window.sv", "sx_num_ceil"),
           "RTL uses endpoint-exact ceil SX");
    EXPECT(file_contains("fpga/Plex_MiSTer/rtl/present_content_window.sv", "present_content_window"),
           "module present");
    EXPECT(file_contains("fpga/Plex_MiSTer/rtl/present_nn_linebuf_scaler.sv", "present_nn_linebuf_scaler"),
           "linebuf scaler module present");
    EXPECT(file_contains("fpga/Plex_MiSTer/rtl/present_nn_linebuf_scaler.sv", "10240"),
           "M10K 10240-bit rationale in scaler header");

    // 320x240 → 1280x720
    {
        const int cw = 320, ch = 240, hde = 1280, vde = 720;
        const int sx = win_store_x_scale(cw, hde);
        const int sy = win_store_y_scale(ch, vde);
        EXPECT(store_x_at(0, sx, 0, cw - 1) == 0, "320→720 x0");
        EXPECT(store_x_at(hde - 1, sx, 0, cw - 1) == cw - 1, "320→720 x last");
        EXPECT(store_y_at(0, sy, 0, vde, ch - 1) == 0, "320→720 y0");
        EXPECT(store_y_at(vde - 1, sy, 0, vde, ch - 1) == ch - 1, "320→720 y last");
        std::set<int> ux, uy;
        for (int hc = 0; hc < hde; ++hc)
            ux.insert(store_x_at(hc, sx, 0, cw - 1));
        for (int py = 0; py < vde; ++py)
            uy.insert(store_y_at(py, sy, 0, vde, ch - 1));
        EXPECT((int)ux.size() == cw, "320 unique x");
        EXPECT((int)uy.size() == ch, "240 unique y");
        std::printf("V1_320to720 sx=%d sy=%d unique_x=%zu unique_y=%zu\n", sx, sy, ux.size(),
                    uy.size());
    }

    // Identity 1280x720
    {
        const int sx = win_store_x_scale(1280, 1280);
        const int sy = win_store_y_scale(720, 720);
        EXPECT(sx == 65536, "id sx");
        EXPECT(sy == 65536, "id sy");
        EXPECT(store_x_at(1279, sx, 0, 1279) == 1279, "id x last");
        EXPECT(store_y_at(719, sy, 0, 720, 719) == 719, "id y last");
        std::printf("V1_1280id sx=%d sy=%d\n", sx, sy);
    }

    // NEG: floor undershoots last column
    {
        const int CW = 320, HDE = 1280;
        const int sx_ceil = win_store_x_scale(CW, HDE);
        const int sx_floor = int(((int64_t)(CW - 1) * 65536) / (HDE - 1));
        EXPECT(sx_floor < sx_ceil, "floor sx < ceil sx");
        EXPECT(store_x_at(HDE - 1, sx_ceil, 0, CW - 1) == CW - 1, "ceil hits last");
        EXPECT(store_x_at(HDE - 1, sx_floor, 0, CW - 1) == CW - 2, "floor undershoots last");
        std::printf("NEG_floor_undershoot sx_floor=%d sx_ceil=%d\n", sx_floor, sx_ceil);
    }

    // Pad-only dead end: unique_x stays at content width if DE maps 1:1 into padded bank
    {
        // DE 529 maps into 624 bank without scale → never reaches full content stretch
        // (historical negative; document unique count for 320 content in 529 DE with scale)
        const int sx = win_store_x_scale(320, 529);
        std::set<int> ux;
        for (int hc = 0; hc < 529; ++hc)
            ux.insert(store_x_at(hc, sx, 0, 319));
        EXPECT((int)ux.size() == 320, "scaled 320 covers all cols on 529 DE");
        std::printf("V1_320on529 unique_x=%zu\n", ux.size());
    }

    // Budget arithmetic (echo; not a timed sim)
    {
        const double budget = 20000000.0 / 24.0;
        const double stream_cost = 320.0 * 240.0 + 3.0 * 1280.0 * 720.0; // linebuf model ~3cy/out
        EXPECT(stream_cost > budget, "stream linebuf 320→720p FAILS 20MHz/24fps budget");
        const double present_nn = 1280.0 * 720.0; // 1 cy/ce_pix present-path
        EXPECT(present_nn > budget, "even 1cy/px present 720p@24 FAILS clk_sys 20MHz alone");
        std::printf("BUDGET=%.0f STREAM_LINEBUF=%.0f ratio=%.3f FAIL\n", budget, stream_cost,
                    stream_cost / budget);
        std::printf("PRESENT_NN_1CY=%.0f ratio=%.3f FAIL_without_faster_pixclk_or_PPC\n", present_nn,
                    present_nn / budget);
    }

    if (g_fails) {
        std::fprintf(stderr, "test_fabric_content_window_math: %d failure(s)\n", g_fails);
        return 1;
    }
    std::printf("PASS test_fabric_content_window_math\n");
    return 0;
}
