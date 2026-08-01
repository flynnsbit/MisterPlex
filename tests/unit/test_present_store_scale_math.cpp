// Product present_core store sampling math (w-geom Part 1).
//
// Parent claim: V_STORE=240 + STORE_Y_SCALE=FRAME_H*65536/240 at FRAME_H=480
// yields only even store rows → half vertical detail discarded before ascal.
//
// This gate locks the PRODUCT macros from Plex.qsf (FRAME_W=640 FRAME_H=480),
// not the ifndef defaults (320/240) and not CODED_W=624.
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

// Mirror present_core.sv:163-164 integer math.
int store_x_scale(int frame_w) { return (frame_w * 39647) / 320; }
int store_y_scale(int frame_h) { return (frame_h * 65536) / 240; }

int store_x_at(int hc, int scale, int last_x) {
    const uint32_t prod = uint32_t(hc) * uint32_t(scale);
    int comb = int(prod >> 16);
    if (comb > last_x)
        comb = last_x;
    return comb;
}

int store_y_at(int py, int scale, int last_y) {
    // present_core: past_last_row clamps py>=240 to 239 before scale
    int sy = py;
    if (sy >= 240)
        sy = 239;
    const uint32_t prod = uint32_t(sy) * uint32_t(scale);
    int comb = int(prod >> 16);
    if (comb > last_y)
        comb = last_y;
    return comb;
}

} // namespace

int main() {
    // --- Source locks (product build config) ---
    EXPECT(file_contains("fpga/Plex_MiSTer/Plex.qsf", "FRAME_W=640"),
           "Plex.qsf product FRAME_W=640");
    EXPECT(file_contains("fpga/Plex_MiSTer/Plex.qsf", "FRAME_H=480"),
           "Plex.qsf product FRAME_H=480");
    EXPECT(file_contains("fpga/Plex_MiSTer/rtl/ddr_frame_layout_params.svh",
                         "DDR_FRAME_CODED_WIDTH = 624"),
           "CODED_W=624 separate from FRAME_W");
    EXPECT(file_contains("fpga/Plex_MiSTer/rtl/present_core.sv", "localparam V_STORE = 10'd240"),
           "V_STORE hardcoded 240");
    EXPECT(file_contains("fpga/Plex_MiSTer/rtl/present_core.sv", "localparam H_DE    = 10'd529"),
           "H_DE hardcoded 529");
    EXPECT(file_contains("fpga/Plex_MiSTer/rtl/present_core.sv", "wire [9:0] read_hc = hc"),
           "read_hc is hc (identity)");
    EXPECT(file_contains("fpga/Plex_MiSTer/rtl/present_core.sv",
                         "STORE_Y_SCALE = (FRAME_H * 65536) / 240"),
           "STORE_Y_SCALE formula");
    EXPECT(file_contains("fpga/Plex_MiSTer/rtl/present_core.sv",
                         "STORE_X_SCALE = (FRAME_W * 39647) / 320"),
           "STORE_X_SCALE formula");
    EXPECT(file_contains("fpga/Plex_MiSTer/rtl/present_core.sv",
                         ".CODED_W(DDR_FRAME_CODED_WIDTH)"),
           "ddr_frame_store CODED_W from layout params");

    // Product values
    constexpr int FRAME_W = 640;
    constexpr int FRAME_H = 480;
    constexpr int H_DE = 529;
    constexpr int V_STORE = 240;

    const int sx_scale = store_x_scale(FRAME_W);
    const int sy_scale = store_y_scale(FRAME_H);
    std::printf("PRODUCT FRAME_W=%d FRAME_H=%d (from Plex.qsf macros)\n", FRAME_W, FRAME_H);
    std::printf("STORE_X_SCALE=%d STORE_Y_SCALE=%d ratio_y=%.6f\n", sx_scale, sy_scale,
                double(sy_scale) / 65536.0);
    EXPECT(sx_scale == 79294, "STORE_X_SCALE product = 640*39647/320 = 79294");
    EXPECT(sy_scale == 131072, "STORE_Y_SCALE product = 480*65536/240 = 131072 (=2.0<<16)");
    EXPECT(sy_scale == 2 * 65536, "STORE_Y_SCALE exactly 2.0 in Q16");

    // Vertical: only even rows 0,2,...,478
    std::set<int> ys;
    for (int py = 0; py < V_STORE; ++py)
        ys.insert(store_y_at(py, sy_scale, FRAME_H - 1));
    std::printf("unique store_y count=%zu min=%d max=%d\n", ys.size(), *ys.begin(),
                *ys.rbegin());
    EXPECT(ys.size() == 240, "exactly 240 unique store_y from 240 py");
    EXPECT(*ys.begin() == 0 && *ys.rbegin() == 478, "store_y spans 0..478");
    bool all_even = true;
    for (int y : ys)
        if (y & 1)
            all_even = false;
    EXPECT(all_even, "all addressed store_y are EVEN — odd rows never fetched");
    // Odd rows 1,3,...,479 never appear
    for (int odd = 1; odd < FRAME_H; odd += 2)
        EXPECT(ys.count(odd) == 0, "odd store row never addressed");

    // Horizontal: 529 DE columns → sample of FRAME_W=640
    std::set<int> xs;
    for (int hc = 0; hc < H_DE; ++hc)
        xs.insert(store_x_at(hc, sx_scale, FRAME_W - 1));
    std::printf("unique store_x count=%zu min=%d max=%d (of FRAME_W=%d)\n", xs.size(),
                *xs.begin(), *xs.rbegin(), FRAME_W);
    EXPECT(xs.size() == 529, "529 unique store_x from H_DE");
    EXPECT(*xs.begin() == 0, "store_x starts 0");
    EXPECT(*xs.rbegin() == 638, "store_x max 638 under FRAME_W=640 scale");
    // Parent used FRAME_W=624 → different scale; product is 640.
    const int scale_if_624 = store_x_scale(624);
    std::printf("NOTE parent 624-path STORE_X_SCALE would be %d; product is %d\n", scale_if_624,
                sx_scale);
    EXPECT(scale_if_624 != sx_scale, "624 vs 640 scales differ — do not mix CODED_W into scale");

    // CODED vs presented: store address is FRAME_W/H domain; plane fetch uses CODED_W
    std::printf("FACT: present_core store_x/y index FRAME_W x FRAME_H domain (%dx%d)\n", FRAME_W,
                FRAME_H);
    std::printf("FACT: ddr_frame_store planes use CODED_W=624 CODED_H=480\n");
    std::printf("FACT: Y_STRIDE_BYTES=624; PRESENTED=640 with pillar 11+11; DISPLAY crop 618\n");
    std::printf("FACT: DECODE=624x480 is the coded bank contract, NOT a FRAME_W mismatch bug\n");
    std::printf("FACT: FRAME_STRIDE defaults to FRAME_W=640 but YUV plane addr uses CODED_W\n");
    std::printf("FACT: V_STORE=240 hardcodes content window; scandouble only halves vc→py\n");
    std::printf("VERDICT_PART1: only 240 of 480 store rows addressed (even); "
                "529 of 640 store cols sampled (17.3%% never unique). Native 480-line "
                "detail does NOT reach ascal without RBF changing V_STORE/scale.\n");

    if (g_fails) {
        std::fprintf(stderr, "%d present_store_scale fail(s)\n", g_fails);
        return 1;
    }
    std::printf("OK test_present_store_scale_math\n");
    return 0;
}
