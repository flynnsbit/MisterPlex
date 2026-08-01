// Product present_core store sampling math (w-geom T7).
//
// Pre-T7 defect (LOCKED AS HISTORY): V_STORE=240 + STORE_Y_SCALE=FRAME_H*65536/240
// at FRAME_H=480 → only even store rows → half vertical detail discarded.
//
// T7 product path (Plex.qsf FRAME_W=640 FRAME_H=480):
//   NATIVE_V_1TO1 → V_STORE=FRAME_H=480, STORE_Y_SCALE=1.0, py=vc
//   → all 480 store rows addressed under scandouble active vc=0..479.
//
// Horizontal: H_DE=529 still samples 529 of 640 (clk_sys=20 MHz forbids H_DE=640
// at 60 Hz / 524 lines). Documented, not papered over.
//
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

bool file_contains(const char* path, const char* needle) {
    std::ifstream in(path);
    if (!in)
        return false;
    std::string all((std::istreambuf_iterator<char>(in)), std::istreambuf_iterator<char>());
    return all.find(needle) != std::string::npos;
}

// Mirror present_core T7 integer math.
int store_x_scale(int frame_w) { return (frame_w * 39647) / 320; }
int store_y_scale(int frame_h, int v_store) { return (frame_h * 65536) / v_store; }

int store_x_at(int hc, int scale, int last_x) {
    const uint32_t prod = uint32_t(hc) * uint32_t(scale);
    int comb = int(prod >> 16);
    if (comb > last_x)
        comb = last_x;
    return comb;
}

int store_y_at(int py, int scale, int v_store, int last_y) {
    int sy = py;
    if (sy >= v_store)
        sy = v_store - 1;
    const uint32_t prod = uint32_t(sy) * uint32_t(scale);
    int comb = int(prod >> 16);
    if (comb > last_y)
        comb = last_y;
    return comb;
}

} // namespace

int main() {
    // --- Source locks (product build config + T7 RTL) ---
    EXPECT(file_contains("fpga/Plex_MiSTer/Plex.qsf", "FRAME_W=640"),
           "Plex.qsf product FRAME_W=640");
    EXPECT(file_contains("fpga/Plex_MiSTer/Plex.qsf", "FRAME_H=480"),
           "Plex.qsf product FRAME_H=480");
    EXPECT(file_contains("fpga/Plex_MiSTer/rtl/ddr_frame_layout_params.svh",
                         "DDR_FRAME_CODED_WIDTH = 624"),
           "CODED_W=624 separate from FRAME_W");
    EXPECT(file_contains("fpga/Plex_MiSTer/rtl/present_core.sv", "NATIVE_V_1TO1"),
           "T7 NATIVE_V_1TO1 present");
    EXPECT(file_contains("fpga/Plex_MiSTer/rtl/present_core.sv",
                         "localparam int V_STORE_I = NATIVE_V_1TO1 ? FRAME_H : 240"),
           "V_STORE_I from FRAME_H when native");
    EXPECT(file_contains("fpga/Plex_MiSTer/rtl/present_core.sv", "localparam H_DE = 10'd529"),
           "H_DE hardcoded 529");
    EXPECT(file_contains("fpga/Plex_MiSTer/rtl/present_core.sv", "wire [9:0] read_hc = hc"),
           "read_hc is hc (identity)");
    EXPECT(file_contains("fpga/Plex_MiSTer/rtl/present_core.sv",
                         "STORE_Y_SCALE = (FRAME_H * 65536) / V_STORE_I"),
           "STORE_Y_SCALE uses V_STORE_I");
    EXPECT(file_contains("fpga/Plex_MiSTer/rtl/present_core.sv",
                         "STORE_X_SCALE = (FRAME_W * 39647) / 320"),
           "STORE_X_SCALE formula");
    EXPECT(file_contains("fpga/Plex_MiSTer/rtl/present_core.sv",
                         "wire [9:0] py = NATIVE_V_1TO1 ? vc : (scandouble ? (vc >> 1) : vc)"),
           "py=vc on native 480 path");
    EXPECT(file_contains("fpga/Plex_MiSTer/rtl/present_core.sv",
                         "past_last_row = (py >= V_STORE)"),
           "past_last_row vs V_STORE");
    EXPECT(file_contains("fpga/Plex_MiSTer/rtl/present_core.sv",
                         ".CODED_W(DDR_FRAME_CODED_WIDTH)"),
           "ddr_frame_store CODED_W from layout params");
    // Honest swap pack must ship with this RBF for skip instrumentation.
    EXPECT(file_contains("fpga/Plex_MiSTer/rtl/ddr_frame_store.sv",
                         "DDRAM_DIN <= {frames_done_d2"),
           "tip packs frames_done_d2 for w-fit-1");
    EXPECT(!file_contains("fpga/Plex_MiSTer/rtl/ddr_frame_store.sv",
                          "DDRAM_DIN <= {bank_vsync_count"),
           "tip must NOT pack bank_vsync_count into PLXD");

    // Product values
    constexpr int FRAME_W = 640;
    constexpr int FRAME_H = 480;
    constexpr int H_DE = 529;
    constexpr int V_STORE = FRAME_H; // T7 native
    constexpr int CLK_SYS_HZ = 20'000'000;
    constexpr int REFRESH_HZ = 60;
    constexpr int V_TOTAL_SD = 524; // colorbars NTSC scandouble wrap vc==523

    const int sx_scale = store_x_scale(FRAME_W);
    const int sy_scale = store_y_scale(FRAME_H, V_STORE);
    std::printf("PRODUCT FRAME_W=%d FRAME_H=%d (from Plex.qsf macros)\n", FRAME_W, FRAME_H);
    std::printf("T7 V_STORE=%d STORE_X_SCALE=%d STORE_Y_SCALE=%d ratio_y=%.6f\n", V_STORE,
                sx_scale, sy_scale, double(sy_scale) / 65536.0);
    EXPECT(sx_scale == 79294, "STORE_X_SCALE product = 640*39647/320 = 79294");
    EXPECT(sy_scale == 65536, "STORE_Y_SCALE product = 480*65536/480 = 65536 (=1.0<<16)");
    EXPECT(sy_scale == 1 * 65536, "STORE_Y_SCALE exactly 1.0 in Q16");

    // Vertical T7: all rows 0..479 under py=vc for scandouble active range
    std::set<int> ys;
    for (int py = 0; py < V_STORE; ++py)
        ys.insert(store_y_at(py, sy_scale, V_STORE, FRAME_H - 1));
    std::printf("unique store_y count=%zu min=%d max=%d\n", ys.size(), *ys.begin(),
                *ys.rbegin());
    EXPECT(ys.size() == 480, "exactly 480 unique store_y from 480 py");
    EXPECT(*ys.begin() == 0 && *ys.rbegin() == 479, "store_y spans 0..479");
    for (int y = 0; y < FRAME_H; ++y)
        EXPECT(ys.count(y) == 1, "every store row addressed exactly once in set");

    // Pre-T7 defect must NOT hold on product math anymore
    std::set<int> odd;
    for (int y : ys)
        if (y & 1)
            odd.insert(y);
    EXPECT(odd.size() == 240, "odd rows ARE fetched after T7 (was 0 pre-T7)");

    // Horizontal: still 529 unique of 640
    std::set<int> xs;
    for (int hc = 0; hc < H_DE; ++hc)
        xs.insert(store_x_at(hc, sx_scale, FRAME_W - 1));
    std::printf("unique store_x count=%zu min=%d max=%d (of FRAME_W=%d)\n", xs.size(),
                *xs.begin(), *xs.rbegin(), FRAME_W);
    EXPECT(xs.size() == 529, "529 unique store_x from H_DE");
    EXPECT(*xs.begin() == 0, "store_x starts 0");
    EXPECT(*xs.rbegin() == 638, "store_x max 638 under FRAME_W=640 scale");

    // Clock budget: full H_DE=640 @ 60 Hz / 524 lines needs H_total>=640 and
    // H_total*524*60 <= CLK_SYS. Max H_total = floor(CLK/60/524)=636 < 640.
    const int max_h_total = CLK_SYS_HZ / REFRESH_HZ / V_TOTAL_SD;
    std::printf("CLK_SYS=%d REFRESH=%d V_TOTAL_SD=%d max_H_total=%d\n", CLK_SYS_HZ, REFRESH_HZ,
                V_TOTAL_SD, max_h_total);
    EXPECT(max_h_total == 636, "20e6/60/524 = 636 clocks/line max");
    EXPECT(max_h_total < 640, "H_DE=640 impossible at 20 MHz/60 Hz/524 lines");
    std::printf("FACT: full-width 640 DE blocked by clk_sys; vertical 480 is the T7 win\n");

    // Bandwidth: full-frame YUV420p read @ 60 Hz vs 90 MHz DDRAM 25% budget
    constexpr double frame_bytes = 624.0 * 480.0 * 1.5; // CODED I420
    constexpr double read_MBps = frame_bytes * 60.0 / 1e6;
    constexpr double ddr_clk_mhz = 90.0;
    constexpr double peak_MBps = ddr_clk_mhz * 8.0; // 64-bit
    constexpr double safe_read_MBps = peak_MBps * 0.25;
    std::printf("BW full-frame read=%.3f MB/s safe_budget_25pct=%.1f MB/s peak=%.1f\n", read_MBps,
                safe_read_MBps, peak_MBps);
    EXPECT(read_MBps < safe_read_MBps, "full 480-row frame read within 25% of 90 MHz peak");
    // 2× vs pre-T7 even-only: still well under line budget parent measured (10us→~20us vs 63.8us)
    constexpr double pre_t7_unique_y = 240.0;
    constexpr double t7_unique_y = 480.0;
    EXPECT(t7_unique_y / pre_t7_unique_y == 2.0, "T7 doubles unique Y line fetches");
    std::printf("FACT: unique Y lines 240→480 (2×); parent line fill 10us*2=20us << 63.8us ESTIMATE\n");

    // Legacy FRAME_H=240 path still 1:1 on 240 window
    {
        constexpr int LH = 240;
        constexpr int VS = 240;
        const int sy = store_y_scale(LH, VS);
        EXPECT(sy == 65536, "legacy FRAME_H=240 STORE_Y_SCALE=1.0");
        std::set<int> lys;
        for (int py = 0; py < VS; ++py)
            lys.insert(store_y_at(py, sy, VS, LH - 1));
        EXPECT(lys.size() == 240, "legacy 240 unique rows");
    }

    std::printf("FACT: present_core store_x/y index FRAME_W x FRAME_H domain (%dx%d)\n", FRAME_W,
                FRAME_H);
    std::printf("FACT: ddr_frame_store planes use CODED_W=624 CODED_H=480\n");
    std::printf("FACT: O[4] content_res wires exist in Plex.sv but FRAME_W/H are synthesis "
                "macros — O[4] does not retarget the DDR store\n");
    std::printf("VERDICT_T7: vertical FULL 480 rows addressed (scale 1.0); "
                "horizontal still 529/640 until clk_sys or timing class changes.\n");
    std::printf("VERDICT_PACK: frames_done_d2 pack present for next RBF (w-fit-1).\n");

    if (g_fails) {
        std::fprintf(stderr, "%d present_store_scale fail(s)\n", g_fails);
        return 1;
    }
    std::printf("OK test_present_store_scale_math\n");
    return 0;
}
