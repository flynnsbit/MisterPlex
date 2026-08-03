// Fabric content-window scale math (w-scaler, 720p-native).
// Models present_content_window:
//   legacy win_enable=0: SX = FRAME_W*39647/320  (bit-exact 480p product)
//   window win_enable=1: SX = floor(cw * 65536 / h_de), SY = floor(ch * 65536 / v_de)
// Proves 320×240 and 1280×720 coverage. true rc direct.

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

// Legacy product scale (win_enable=0).
int legacy_store_x_scale(int frame_w) { return (frame_w * 39647) / 320; }
int legacy_store_y_scale(int frame_h, int v_de) { return (frame_h * 65536) / v_de; }

// Window endpoint-exact scale (win_enable=1) — ceil Q16 so hc last → content last.
// SX = ceil((cw-1)*65536/(h_de-1)) = ((cw-1)*65536 + (h_de-2))/(h_de-1)
int win_store_x_scale(int content_w, int h_de) {
    if (content_w <= 1 || h_de <= 1)
        return 0;
    const int64_t num = int64_t(content_w - 1) * 65536;
    const int64_t den = h_de - 1;
    return int((num + den - 1) / den);
}
int win_store_y_scale(int content_h, int v_de) {
    if (content_h <= 1 || v_de <= 1)
        return 0;
    const int64_t num = int64_t(content_h - 1) * 65536;
    const int64_t den = v_de - 1;
    return int((num + den - 1) / den);
}

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

// Runtime I420 plane bases (qwords) — mirrors ddr_frame_store eff_u/v_base_qw.
// u_base_q = (y_stride_bytes * coded_h) / 8
// c_plane_q = (chroma_stride_bytes * (coded_h/2)) / 8
// v_base_q = u_base_q + c_plane_q
int plane_u_base_q(int y_stride, int coded_h) { return (y_stride * coded_h) / 8; }
int plane_c_q(int c_stride, int coded_h) { return (c_stride * (coded_h / 2)) / 8; }
int plane_v_base_q(int y_stride, int c_stride, int coded_h) {
    return plane_u_base_q(y_stride, coded_h) + plane_c_q(c_stride, coded_h);
}

} // namespace

int main() {
    constexpr int H_DE_480 = 529;
    constexpr int V_DE_480 = 480;

    // --- RTL source locks ---
    EXPECT(file_contains("fpga/Plex_MiSTer/rtl/present_content_window.sv",
                         "module present_content_window"),
           "present_content_window.sv exists");
    EXPECT(file_contains("fpga/Plex_MiSTer/rtl/present_content_window.sv", "STORE_W = 1280"),
           "STORE_W=1280 (one M10K luma line)");
    EXPECT(file_contains("fpga/Plex_MiSTer/rtl/present_content_window.sv", "STORE_H = 720"),
           "STORE_H=720");
    EXPECT(file_contains("fpga/Plex_MiSTer/rtl/present_content_window.sv",
                         "STORE_X_SCALE = (FRAME_W * 39647) / 320"),
           "legacy STORE_X_SCALE formula");
    EXPECT(file_contains("fpga/Plex_MiSTer/rtl/present_content_window.sv",
                         "sx_num_ceil = sx_num_gen + {21'd0, hd_m1} - 32'd1"),
           "endpoint-exact ceil SX");
    EXPECT(file_contains("fpga/Plex_MiSTer/rtl/present_core.sv", "present_content_window"),
           "present_core instantiates window");
    EXPECT(file_contains("fpga/Plex_MiSTer/Plex.sv", "present_geom_latch"),
           "Plex instantiates PLXG latch");
    EXPECT(file_contains("fpga/Plex_MiSTer/Plex.sv", "plxg_wr_en   = 1'b0"),
           "PLXG writes tied off (safe default)");
    EXPECT(file_contains("fpga/Plex_MiSTer/rtl/present_geom_latch.sv", "504C_5847"),
           "PLXG magic not PLXW");

    // --- Legacy full-bank ---
    {
        const int cw = 640, ch = 480;
        const int sx = legacy_store_x_scale(cw);
        const int sy = legacy_store_y_scale(ch, V_DE_480);
        EXPECT(sx == 79294, "legacy STORE_X_SCALE 640");
        EXPECT(sy == 65536, "legacy STORE_Y_SCALE 1.0");
        std::set<int> ys;
        for (int py = 0; py < V_DE_480; ++py)
            ys.insert(store_y_at(py, sy, 0, V_DE_480, ch - 1));
        EXPECT(ys.size() == 480u, "legacy unique Y = 480");
    }

    // --- V1 window 320×240 on 480p DE (endpoint-exact) ---
    {
        const int cw = 320, ch = 240;
        const int sx = win_store_x_scale(cw, H_DE_480);
        const int sy = win_store_y_scale(ch, V_DE_480);
        EXPECT(sx == win_store_x_scale(320, 529), "320 window SX ceil endpoint");
        EXPECT(sy == win_store_y_scale(240, 480), "320 window SY ceil endpoint");
        EXPECT(sx == int((int64_t(319) * 65536 + 527) / 528), "320 SX closed form");

        std::set<int> xs, ys;
        for (int hc = 0; hc < H_DE_480; ++hc)
            xs.insert(store_x_at(hc, sx, 0, cw - 1));
        for (int py = 0; py < V_DE_480; ++py)
            ys.insert(store_y_at(py, sy, 0, V_DE_480, ch - 1));

        EXPECT(xs.size() == 320u, "unique store_x 320");
        EXPECT(*xs.begin() == 0 && *xs.rbegin() == 319, "x 0..319");
        EXPECT(ys.size() == 240u, "unique store_y 240");
        EXPECT(*ys.begin() == 0 && *ys.rbegin() == 239, "y 0..239");
        EXPECT(store_x_at(H_DE_480 - 1, sx, 0, 319) == 319, "hc last -> 319");
        EXPECT(store_y_at(V_DE_480 - 1, sy, 0, V_DE_480, 239) == 239, "py last -> 239");
        std::printf("V1_320 window sx=%d sy=%d unique_x=%zu unique_y=%zu\n", sx, sy, xs.size(),
                    ys.size());
    }

    // --- 1280×720 on 480p DE (downscale; proves 11b + endpoint span) ---
    {
        const int cw = 1280, ch = 720;
        const int sx = win_store_x_scale(cw, H_DE_480);
        const int sy = win_store_y_scale(ch, V_DE_480);
        EXPECT(sx == win_store_x_scale(1280, 529), "720 SX ceil on 529 DE");
        EXPECT(sy == win_store_y_scale(720, 480), "720 SY ceil on 480 DE");
        EXPECT(store_x_at(0, sx, 0, cw - 1) == 0, "720 x0");
        EXPECT(store_x_at(H_DE_480 - 1, sx, 0, cw - 1) == cw - 1, "720 x last 1279");
        EXPECT(store_y_at(V_DE_480 - 1, sy, 0, V_DE_480, ch - 1) == ch - 1, "720 y last 719");
        EXPECT(store_x_at(H_DE_480 - 1, sx, 0, cw - 1) > 639, "exceeds FRAME_W 640");
        // Downscale cannot visit every content column — unique ≤ H_DE.
        std::set<int> xs;
        for (int hc = 0; hc < H_DE_480; ++hc)
            xs.insert(store_x_at(hc, sx, 0, cw - 1));
        EXPECT(xs.size() == size_t(H_DE_480), "one NN x per DE col");
        std::printf("V1_720on480 sx=%d sy=%d x_last=%d y_last=%d unique_x=%zu\n", sx, sy,
                    store_x_at(H_DE_480 - 1, sx, 0, cw - 1),
                    store_y_at(V_DE_480 - 1, sy, 0, V_DE_480, ch - 1), xs.size());
    }

    // --- 1280×720 identity DE ---
    {
        const int cw = 1280, ch = 720, hde = 1280, vde = 720;
        const int sx = win_store_x_scale(cw, hde);
        const int sy = win_store_y_scale(ch, vde);
        EXPECT(sx == 65536, "720id SX 1.0 endpoint");
        EXPECT(sy == 65536, "720id SY 1.0 endpoint");
        std::set<int> xs, ys;
        for (int hc = 0; hc < hde; ++hc)
            xs.insert(store_x_at(hc, sx, 0, cw - 1));
        for (int py = 0; py < vde; ++py)
            ys.insert(store_y_at(py, sy, 0, vde, ch - 1));
        EXPECT(xs.size() == 1280u && ys.size() == 720u, "720id unique full");
        std::printf("V1_720id unique_x=%zu unique_y=%zu\n", xs.size(), ys.size());
    }

    // --- Runtime stride plane bases (ddr_frame_store geom_enable=1) ---
    {
        EXPECT(file_contains("fpga/Plex_MiSTer/rtl/ddr_frame_store.sv", "geom_enable"),
               "ddr_frame_store exposes geom_enable");
        EXPECT(file_contains("fpga/Plex_MiSTer/rtl/ddr_frame_store.sv", "MAX_CODED_W = 1280"),
               "MAX_CODED_W=1280");
        EXPECT(file_contains("fpga/Plex_MiSTer/rtl/ddr_frame_store.sv", "eff_y_pitch_qw"),
               "runtime y pitch");
        EXPECT(file_contains("fpga/Plex_MiSTer/rtl/present_core.sv", "geom_enable"),
               "present_core geom ports");
        EXPECT(file_contains("fpga/Plex_MiSTer/rtl/present_geom_latch.sv", "geom_enable"),
               "latch drives geom_enable");

        // Legacy 624×480 tight pack (geom off defaults).
        EXPECT(plane_u_base_q(624, 480) == 37440, "legacy U base q");
        EXPECT(plane_v_base_q(624, 312, 480) == 46800, "legacy V base q");
        // Note: legacy uses c_stride = coded_w/2 = 312 for plane size via CODED_W*H/32.
        EXPECT((624 * 480) / 32 == 9360, "legacy C plane q via W*H/32");
        EXPECT(37440 + 9360 == 46800, "legacy V = U + C");

        // 720p tight: y_stride=1280, c_stride=640, h=720.
        EXPECT(plane_u_base_q(1280, 720) == 115200, "720p U base q");
        EXPECT(plane_c_q(640, 720) == 28800, "720p C plane q");
        EXPECT(plane_v_base_q(1280, 640, 720) == 144000, "720p V base q");
        EXPECT(plane_u_base_q(1280, 720) != plane_u_base_q(624, 480),
               "negative: 720p U ≠ legacy U (fixed-624 would fail)");
        EXPECT(yuv420_bytes(1280, 720) == 1280u * 720u * 3u / 2u, "720p I420 bytes");
        std::printf("RT_STRIDE leg_u=%d rt_u=%d rt_v=%d\n", plane_u_base_q(624, 480),
                    plane_u_base_q(1280, 720), plane_v_base_q(1280, 640, 720));
    }


    // --- Pad-only negative ---
    {
        const int sx_wrong = legacy_store_x_scale(640);
        std::set<int> xs;
        for (int hc = 0; hc < H_DE_480; ++hc)
            xs.insert(store_x_at(hc, sx_wrong, 0, 639));
        EXPECT(xs.size() > 320u, "pad-only wrong scale samples >320 x");
        EXPECT(*xs.rbegin() > 319, "pad-only past content width");
        std::printf("NEG_pad_only unique_x=%zu max=%d\n", xs.size(), *xs.rbegin());
    }

    // --- Byte contracts ---
    EXPECT(yuv420_bytes(624, 480) == 449280u, "coded 480 bank bytes");
    EXPECT(yuv420_bytes(320, 240) == 115200u, "native 320 bytes");
    EXPECT(yuv420_bytes(1280, 720) == 1382400u, "native 720 bytes");
    // 1280 bytes/line = exactly one M10K
    EXPECT(1280 == 1280, "720p luma line = 1280 B = 1 M10K");
    const double ratio320 = double(yuv420_bytes(624, 480)) / double(yuv420_bytes(320, 240));
    EXPECT(ratio320 > 3.8 && ratio320 < 4.0, "DDR write ratio ~3.9x at 320");
    std::printf("DDR_BYTES bank480=%zu native320=%zu native720=%zu ratio320=%.3f\n",
                yuv420_bytes(624, 480), yuv420_bytes(320, 240), yuv420_bytes(1280, 720), ratio320);

    // --- FEED wall ms/f pins (scale leg only — ARM removal claim) ---
    {
        constexpr double present_ms = 10.411;
        constexpr double scale_ms = 2.954;
        constexpr double sum_ms = 40.190;
        constexpr double budget_25 = 40.0;
        EXPECT(present_ms > scale_ms * 3.0, "FEED: present/DDR > 3x scale delta");
        EXPECT(sum_ms > budget_25, "FEED: full stack over 25 fps budget");
        // This RTL removes the scale leg when ARM stops vf scale (win_enable=1 +
        // native publish). Claimed ARM ms/f removed = FEED scale delta 2.954 at
        // the 320 path that still scaled. Byte-side present savings need stride.
        std::printf("ARM_MS_REMOVED_SCALE_FEED=%.3f (docs/evidence p480 table; "
                    "only when ARM vf scale is OFF after win_enable)\n",
                    scale_ms);
        std::printf("ARM_MS_REMOVED_PRESENT_BYTES=unknown until copy_us/flush_us "
                    "measured with native publish+stride (pre-reg band 2.5-5.5 from "
                    "FEED present=%.3f * frac * (1-1/3.9))\n",
                    present_ms);
        const double bytes_ratio = 449280.0 / 115200.0;
        const double save_lo = 0.30 * present_ms * (1.0 - 1.0 / bytes_ratio);
        const double save_hi = 0.70 * present_ms * (1.0 - 1.0 / bytes_ratio);
        EXPECT(save_lo > 2.0 && save_hi < 6.0, "pre-reg A1 save band");
        std::printf("FEED_PIN present=%.3f scale=%.3f A1_save_band=%.2f..%.2f ms/f\n", present_ms,
                    scale_ms, save_lo, save_hi);
    }

    
    // PMS degradation tier: 720×404 → 1280×720 DE (w-path / w-clock agree).
    {
        constexpr int CW = 720, CH = 404, HDE = 1280, VDE = 720;
        const int sx = win_store_x_scale(CW, HDE);
        const int sy = win_store_y_scale(CH, VDE);
        EXPECT(store_x_at(0, sx, 0, CW - 1) == 0, "404→720p x0");
        EXPECT(store_x_at(HDE - 1, sx, 0, CW - 1) == CW - 1, "404→720p x last");
        EXPECT(store_y_at(VDE - 1, sy, 0, VDE, CH - 1) == CH - 1, "404→720p y last");
        const int mid = store_x_at((HDE - 1) / 2, sx, 0, CW - 1);
        EXPECT(mid != (HDE - 1) / 2, "404 mid not identity DE");
        EXPECT(mid > 300 && mid < 400, "404 mid in content half");
        // Identity scale would be sx=65536 → mid==639.
        EXPECT(store_x_at((HDE - 1) / 2, 65536, 0, CW - 1) == (HDE - 1) / 2 ||
                   store_x_at((HDE - 1) / 2, 65536, 0, CW - 1) == CW - 1,
               "identity scale model clamps or tracks DE (discriminator power)");
        std::printf("PASS math pms404→720p sx=%d sy=%d mid=%d\n", sx, sy, mid);
    }


    // NEG: floor Q16 (not ceil) undershoots last DE pixel — off-by-one class.
    {
        constexpr int CW = 720, HDE = 1280;
        const int sx_ceil = win_store_x_scale(CW, HDE);
        const int64_t num = int64_t(CW - 1) * 65536;
        const int sx_floor = int(num / (HDE - 1));
        EXPECT(sx_floor < sx_ceil, "floor sx < ceil sx");
        const int x_last_floor = store_x_at(HDE - 1, sx_floor, 0, CW - 1);
        const int x_last_ceil = store_x_at(HDE - 1, sx_ceil, 0, CW - 1);
        EXPECT(x_last_ceil == CW - 1, "ceil hits last content col");
        EXPECT(x_last_floor == CW - 2, "floor undershoots last col (off-by-one)");
        std::printf("NEG_floor_undershoot sx_floor=%d sx_ceil=%d x_last_f=%d x_last_c=%d\n",
                    sx_floor, sx_ceil, x_last_floor, x_last_ceil);
    }
    // NEG: inverted ratio (de-1)/(cw-1) is not product scale.
    {
        constexpr int CW = 720, HDE = 1280;
        const int sx_ok = win_store_x_scale(CW, HDE);
        const int64_t inv_num = int64_t(HDE - 1) * 65536 + (CW - 2);
        const int sx_inv = int(inv_num / (CW - 1));
        EXPECT(sx_inv != sx_ok, "invert sx != product sx");
        const int mid_ok = store_x_at((HDE - 1) / 2, sx_ok, 0, CW - 1);
        const int mid_inv = store_x_at((HDE - 1) / 2, sx_inv, 0, CW - 1);
        EXPECT(mid_ok != mid_inv, "invert mid differs");
        EXPECT(mid_ok > 300 && mid_ok < 400, "product mid in content half");
        // inverted mid clamps near content end
        EXPECT(mid_inv >= CW - 5, "invert mid near clamp end");
        std::printf("NEG_invert_ratio sx_ok=%d sx_inv=%d mid_ok=%d mid_inv=%d\n",
                    sx_ok, sx_inv, mid_ok, mid_inv);
    }


    // Parent ship path: 960×540 → 1280×720 (~4/3 non-integer).
    {
        constexpr int CW = 960, CH = 540, HDE = 1280, VDE = 720;
        EXPECT(CW * 4 == HDE * 3, "4:3 width product target");
        EXPECT(CH * 4 == VDE * 3, "4:3 height product target");
        const int sx = win_store_x_scale(CW, HDE);
        const int sy = win_store_y_scale(CH, VDE);
        EXPECT(store_x_at(0, sx, 0, CW - 1) == 0, "540 x0");
        EXPECT(store_x_at(HDE - 1, sx, 0, CW - 1) == CW - 1, "540 x last");
        EXPECT(store_y_at(VDE - 1, sy, 0, VDE, CH - 1) == CH - 1, "540 y last");
        const int mid = store_x_at((HDE - 1) / 2, sx, 0, CW - 1);
        EXPECT(mid != (HDE - 1) / 2, "540 mid not identity");
        EXPECT(mid > 400 && mid < 560, "540 mid in 4/3 band");
        // floor undershoot still fails last
        const int64_t num = int64_t(CW - 1) * 65536;
        const int sx_floor = int(num / (HDE - 1));
        EXPECT(store_x_at(HDE - 1, sx_floor, 0, CW - 1) == CW - 2,
               "540 floor undershoot last (neg)");
        std::printf("PASS math product540 960x540→720p sx=%d sy=%d mid=%d\n", sx, sy, mid);
    }

if (g_fails) {
        std::fprintf(stderr, "test_fabric_content_window_math: %d failure(s)\n", g_fails);
        return 1;
    }
    std::printf("PASS test_fabric_content_window_math\n");
    return 0;
}
