// Product present_core store sampling math — T7 ceiling lock (w-fit + w-geom Part1).
//
// Legacy (c5382bee class): V_STORE=240 + py=vc>>1 + STORE_Y_SCALE=2.0 → even rows only.
// Product fix (scandouble): V_STORE_SD=480 + py=vc + STORE_Y_SCALE=1.0 → all 480 rows.
//
// Locks Plex.qsf FRAME_W=640 FRAME_H=480 (not ifndef 320/240, not CODED_W=624).
// true rc direct. Soft-skip never. Red twin proves old even-row cull still enumerable.

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

int store_x_scale(int frame_w) { return (frame_w * 39647) / 320; }
int store_y_scale_sd(int frame_h) { return (frame_h * 65536) / 480; }
int store_y_scale_prog(int frame_h) { return (frame_h * 65536) / 240; }

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
    EXPECT(file_contains("fpga/Plex_MiSTer/Plex.qsf", "FRAME_W=640"),
           "Plex.qsf product FRAME_W=640");
    EXPECT(file_contains("fpga/Plex_MiSTer/Plex.qsf", "FRAME_H=480"),
           "Plex.qsf product FRAME_H=480");
    EXPECT(file_contains("fpga/Plex_MiSTer/rtl/ddr_frame_layout_params.svh",
                         "DDR_FRAME_CODED_WIDTH = 624"),
           "CODED_W=624 separate from FRAME_W");
    EXPECT(file_contains("fpga/Plex_MiSTer/rtl/present_core.sv", "localparam H_DE    = 10'd529"),
           "H_DE hardcoded 529 (Template; H ceiling deferred)");
    EXPECT(file_contains("fpga/Plex_MiSTer/rtl/present_core.sv", "wire [9:0] read_hc = hc"),
           "read_hc is hc (identity)");
    EXPECT(file_contains("fpga/Plex_MiSTer/rtl/present_core.sv", "V_STORE_SD   = 480"),
           "T7 V_STORE_SD=480");
    EXPECT(file_contains("fpga/Plex_MiSTer/rtl/present_core.sv", "V_STORE_PROG = 240"),
           "progressive window still 240");
    EXPECT(file_contains("fpga/Plex_MiSTer/rtl/present_core.sv", "STORE_Y_SCALE_SD ="),
           "STORE_Y_SCALE_SD present");
    EXPECT(file_contains("fpga/Plex_MiSTer/rtl/present_core.sv",
                         "(FRAME_H * 65536) / V_STORE_SD"),
           "sd scale formula 1:1 at FRAME_H=480");
    EXPECT(!file_contains("fpga/Plex_MiSTer/rtl/present_core.sv",
                          "wire [9:0] py = scandouble ? (vc >> 1) : vc"),
           "legacy py=vc>>1 must be gone");
    EXPECT(file_contains("fpga/Plex_MiSTer/rtl/present_core.sv",
                         ".CODED_W(DDR_FRAME_CODED_WIDTH)"),
           "ddr_frame_store CODED_W from layout params");

    constexpr int FRAME_W = 640;
    constexpr int FRAME_H = 480;
    constexpr int H_DE = 529;
    constexpr int V_STORE_SD = 480;
    constexpr int V_STORE_PROG = 240;

    const int sx_scale = store_x_scale(FRAME_W);
    const int sy_sd = store_y_scale_sd(FRAME_H);
    const int sy_prog = store_y_scale_prog(FRAME_H);
    std::printf("PRODUCT FRAME_W=%d FRAME_H=%d\n", FRAME_W, FRAME_H);
    std::printf("STORE_X_SCALE=%d STORE_Y_SCALE_SD=%d STORE_Y_SCALE_PROG=%d\n", sx_scale, sy_sd,
                sy_prog);
    EXPECT(sx_scale == 79294, "STORE_X_SCALE product = 640*39647/320 = 79294");
    EXPECT(sy_sd == 65536, "STORE_Y_SCALE_SD = 480*65536/480 = 65536 (=1.0 Q16)");
    EXPECT(sy_prog == 131072, "STORE_Y_SCALE_PROG legacy 2.0 Q16");

    std::set<int> ys_sd;
    for (int py = 0; py < V_STORE_SD; ++py)
        ys_sd.insert(store_y_at(py, sy_sd, V_STORE_SD, FRAME_H - 1));
    std::printf("scandouble unique store_y count=%zu min=%d max=%d\n", ys_sd.size(),
                *ys_sd.begin(), *ys_sd.rbegin());
    EXPECT(ys_sd.size() == 480, "scandouble: 480 unique store_y");
    EXPECT(*ys_sd.begin() == 0 && *ys_sd.rbegin() == 479, "scandouble spans 0..479");
    int odd_hit = 0;
    for (int y : ys_sd)
        if (y & 1)
            ++odd_hit;
    EXPECT(odd_hit == 240, "scandouble: odd store rows ARE fetched (240 odds)");

    std::set<int> ys_legacy;
    for (int py = 0; py < V_STORE_PROG; ++py)
        ys_legacy.insert(store_y_at(py, sy_prog, V_STORE_PROG, FRAME_H - 1));
    EXPECT(ys_legacy.size() == 240, "legacy unique count 240");
    bool legacy_all_even = true;
    for (int y : ys_legacy)
        if (y & 1)
            legacy_all_even = false;
    EXPECT(legacy_all_even, "RED twin: legacy scale hits only EVEN rows");
    EXPECT(*ys_legacy.rbegin() == 478, "legacy max store_y 478");
    std::printf("RED_TWIN legacy even-only OK (count=%zu max=%d)\n", ys_legacy.size(),
                *ys_legacy.rbegin());

    std::set<int> xs;
    for (int hc = 0; hc < H_DE; ++hc)
        xs.insert(store_x_at(hc, sx_scale, FRAME_W - 1));
    std::printf("unique store_x count=%zu min=%d max=%d\n", xs.size(), *xs.begin(),
                *xs.rbegin());
    EXPECT(xs.size() == 529, "529 unique store_x from H_DE (H ceiling deferred)");
    EXPECT(*xs.rbegin() == 638, "store_x max 638 under FRAME_W=640");

    std::printf("VERDICT_T7: scandouble product fetches all 480 store rows 1:1; "
                "H_DE=529 deferred; frames_done pack is separate (PLXD).\n");

    if (g_fails) {
        std::fprintf(stderr, "%d present_store_scale fail(s)\n", g_fails);
        return 1;
    }
    std::printf("OK test_present_store_scale_math\n");
    return 0;
}
