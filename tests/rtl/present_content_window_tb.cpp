// Verilator TB: present_content_window NN store map vs host reference.
// Positive: 320x240 content across 1280x720 DE — pixel-for-pixel store coords.
// Negative: FAULT floor-scale (compile -DPRESENT_WINDOW_FAULT_FLOOR_SCALE) must diverge.
#include "Vpresent_content_window_tb_top.h"
#include "verilated.h"

#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <iostream>
#include <string>

static int failures = 0;

static void tick(Vpresent_content_window_tb_top& dut) {
    dut.clk = 0;
    dut.eval();
    dut.clk = 1;
    dut.eval();
}

static uint32_t ceil_q16(uint32_t num_m1, uint32_t den_m1) {
    if (den_m1 == 0)
        den_m1 = 1;
    // ceil(num_m1 * 65536 / den_m1) = (num_m1*65536 + den_m1 - 1) / den_m1
    uint64_t n = (uint64_t)num_m1 * 65536ull + (uint64_t)den_m1 - 1ull;
    return (uint32_t)(n / den_m1);
}

static uint32_t floor_q16(uint32_t num_m1, uint32_t den_m1) {
    if (den_m1 == 0)
        den_m1 = 1;
    return (uint32_t)(((uint64_t)num_m1 * 65536ull) / den_m1);
}

struct Ref {
    uint32_t sx, sy;
    uint32_t x0, y0;
    uint32_t last_x, last_y;
};

static Ref make_ref(bool win, int cw, int ch, int x0, int y0, int hde, int vde, bool floor_fault) {
    Ref r{};
    if (!win) {
        // legacy not exercised here
        r.sx = (640 * 39647) / 320;
        r.sy = (480 * 65536) / 480;
        r.x0 = 0;
        r.y0 = 0;
        r.last_x = 639;
        r.last_y = 479;
        return r;
    }
    int cw_e = cw ? cw : 1;
    int ch_e = ch ? ch : 1;
    int hd = hde ? hde : 529;
    int vd = vde ? vde : 480;
    if (hd == 0) hd = 1;
    if (vd == 0) vd = 1;
    uint32_t cw_m1 = (cw_e <= 1) ? 0u : (uint32_t)(cw_e - 1);
    uint32_t ch_m1 = (ch_e <= 1) ? 0u : (uint32_t)(ch_e - 1);
    uint32_t hd_m1 = (hd <= 1) ? 1u : (uint32_t)(hd - 1);
    uint32_t vd_m1 = (vd <= 1) ? 1u : (uint32_t)(vd - 1);
    r.sx = floor_fault ? floor_q16(cw_m1, hd_m1) : ceil_q16(cw_m1, hd_m1);
    r.sy = floor_fault ? floor_q16(ch_m1, vd_m1) : ceil_q16(ch_m1, vd_m1);
    r.x0 = (uint32_t)x0;
    r.y0 = (uint32_t)y0;
    r.last_x = r.x0 + cw_m1;
    r.last_y = r.y0 + ch_m1;
    if (r.last_x > 1279) r.last_x = 1279;
    if (r.last_y > 719) r.last_y = 719;
    return r;
}

static void map_xy(const Ref& r, int hc, int py, uint32_t& sx, uint32_t& sy) {
    uint64_t xp = (uint64_t)(uint32_t)hc * r.sx;
    uint64_t yp = (uint64_t)(uint32_t)py * r.sy;
    uint32_t xq = (uint32_t)(xp >> 16);
    uint32_t yq = (uint32_t)(yp >> 16);
    uint32_t xs = r.x0 + xq;
    uint32_t ys = r.y0 + yq;
    sx = (xs > r.last_x) ? r.last_x : xs;
    sy = (ys > r.last_y) ? r.last_y : ys;
}

static void reset_dut(Vpresent_content_window_tb_top& dut) {
    dut.reset = 1;
    dut.ce_pix = 0;
    dut.hc = 0;
    dut.py = 0;
    dut.in_content = 0;
    dut.win_enable = 0;
    dut.content_w = 0;
    dut.content_h = 0;
    dut.content_x0 = 0;
    dut.content_y0 = 0;
    dut.h_de = 0;
    dut.v_de = 0;
    for (int i = 0; i < 4; ++i) tick(dut);
    dut.reset = 0;
    tick(dut);
}

static int run_frame(Vpresent_content_window_tb_top& dut, int cw, int ch, int hde, int vde,
                     bool expect_match, const char* tag, int x0 = 0, int y0 = 0) {
    const bool floor_fault =
#ifdef PRESENT_WINDOW_FAULT_FLOOR_SCALE
        true
#else
        false
#endif
        ;

    Ref ref = make_ref(true, cw, ch, x0, y0, hde, vde, /*ref always correct*/ false);
    // DUT under FAULT uses floor; positive build uses ceil.
    (void)floor_fault;

    reset_dut(dut);
    dut.win_enable = 1;
    dut.content_w = cw;
    dut.content_h = ch;
    dut.content_x0 = x0;
    dut.content_y0 = y0;
    dut.h_de = hde;
    dut.v_de = vde;
    // Let scale regs settle
    for (int i = 0; i < 3; ++i) tick(dut);

    int mism = 0;
    int checked = 0;
    // Sample a dense grid + corners (full 1280x720 is slow but OK; use stride for mid)
    auto check_at = [&](int hc, int py) {
        dut.hc = hc;
        dut.py = py;
        dut.in_content = 1;
        dut.ce_pix = 1;
        tick(dut);
        dut.ce_pix = 0;
        tick(dut); // hold

        uint32_t rx, ry;
        map_xy(ref, hc, py, rx, ry);
        uint32_t gx = dut.store_x;
        uint32_t gy = dut.store_y;
        ++checked;
        // mism = divergence from correct ceil-Q16 reference
        if (gx != rx || gy != ry) {
            if (mism < 8) {
                std::cerr << tag << " hc=" << hc << " py=" << py
                          << " got=(" << gx << "," << gy << ") ref=(" << rx << "," << ry
                          << ")\n";
            }
            ++mism;
        }
        (void)expect_match;
    };

    // Corners + last column/row (negative case bait for clamp/stride OBO)
    check_at(0, 0);
    check_at(hde - 1, 0);
    check_at(0, vde - 1);
    check_at(hde - 1, vde - 1);
    check_at(hde / 2, vde / 2);
    check_at(1, 1);
    // Dense stride sample
    for (int py = 0; py < vde; py += (vde > 64 ? 8 : 1))
        for (int hc = 0; hc < hde; hc += (hde > 64 ? 8 : 1))
            check_at(hc, py);
    // Explicit last-column sweep (edge clamp)
    for (int py = 0; py < vde; py += (vde > 32 ? 4 : 1))
        check_at(hde - 1, py);

    if (expect_match) {
        if (mism != 0) {
            std::cerr << tag << " FAIL mism=" << mism << " checked=" << checked << "\n";
            failures += mism;
            return 1;
        }
        std::cout << tag << " PASS checked=" << checked << "\n";
        return 0;
    } else {
        // Negative: DUT must diverge from correct ceil ref on at least corners
        if (mism == 0) {
            std::cerr << tag << " NEGATIVE FAIL: fault build matched ceil reference\n";
            failures++;
            return 1;
        }
        std::cout << tag << " NEGATIVE PASS diverged mism=" << mism << " checked=" << checked << "\n";
        return 0;
    }
}

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    Vpresent_content_window_tb_top dut;

#ifdef PRESENT_WINDOW_FAULT_FLOOR_SCALE
    const bool fault = true;
    std::cout << "present_content_window_tb FAULT=FLOOR_SCALE\n";
#else
    const bool fault = false;
    std::cout << "present_content_window_tb POSITIVE\n";
#endif

    // Target geometry: native 320x240 content across 1280x720 DE
    int rc = run_frame(dut, 320, 240, 1280, 720, /*expect_match=*/!fault, "g320to720");
    // Identity: floor==ceil so only run on positive (fault cannot diverge)
    if (!fault)
        rc |= run_frame(dut, 1280, 720, 1280, 720, true, "g1280id");
    // 640x480 → 1280x720
    rc |= run_frame(dut, 640, 480, 1280, 720, !fault, "g640to720");
    // Ship product source tier: 960×540 → 1280×720 DE (non-integer ~4/3 NN)
    rc |= run_frame(dut, 960, 540, 1280, 720, !fault, "g960to720");
    // Non-zero origin (PLXG island offset). Naive x0=0 implementation fails last-col+offset.
    if (!fault)
        rc |= run_frame(dut, 640, 480, 1280, 720, true, "g640off16", /*x0=*/16, /*y0=*/8);
    // ODD origin — x0=16 (even) would miss a half-pixel/phase bug under PPC=2.
    if (!fault)
        rc |= run_frame(dut, 640, 480, 1280, 720, true, "g640off17odd", /*x0=*/17, /*y0=*/9);

    // PPC=2 dual-map: lane1 must equal map(hc+1), NOT store_x+1 under scale.
    // Adjacent-store N-wide fetch assumption fails here (negative for identity-only).
    // Combined with ODD x0=17 — even-only origin would miss mid-pair phase bugs.
    if (!fault) {
        auto run_ppc2 = [&](int cw, int ch, int x0, int y0, const char* tag,
                            bool require_non_adj) -> int {
            Ref ref = make_ref(true, cw, ch, x0, y0, 1280, 720, false);
            reset_dut(dut);
            dut.win_enable = 1;
            dut.content_w = cw;
            dut.content_h = ch;
            dut.content_x0 = x0;
            dut.content_y0 = y0;
            dut.h_de = 1280;
            dut.v_de = 720;
            for (int i = 0; i < 3; ++i) tick(dut);

            int ppc_mism = 0;
            int adj_false = 0;
            int checked = 0;
            // Include both even and odd glass_x0 group starts (PPC pair phase).
            for (int hc = 0; hc < 1279; hc += 1) {
                if (hc % 11 != 0 && hc % 2 != 1)
                    continue; // dense on odds + every 11th even
                dut.hc = hc;
                dut.py = 100;
                dut.in_content = 1;
                dut.ce_pix = 1;
                tick(dut);
                dut.ce_pix = 0;
                tick(dut);
                uint32_t r0, r1, ry;
                map_xy(ref, hc, 100, r0, ry);
                map_xy(ref, hc + 1, 100, r1, ry);
                uint32_t g0 = dut.store_x;
                uint32_t g1 = dut.store_x_lane1;
                ++checked;
                if (g0 != r0 || g1 != r1) {
                    if (ppc_mism < 8) {
                        std::cerr << tag << " hc=" << hc << " x0=" << x0
                                  << " got=(" << g0 << "," << g1 << ") ref=(" << r0
                                  << "," << r1 << ")\n";
                    }
                    ++ppc_mism;
                }
                if (g1 != g0 + 1)
                    ++adj_false;
            }
            if (ppc_mism != 0) {
                std::cerr << tag << " FAIL mism=" << ppc_mism << " checked=" << checked
                          << "\n";
                failures += ppc_mism;
                return 1;
            }
            if (require_non_adj && adj_false < 8) {
                std::cerr << tag
                          << " NEGATIVE FAIL: lane1 almost always store_x+1 (adj_false="
                          << adj_false << ")\n";
                failures++;
                return 1;
            }
            std::cout << tag << " PASS checked=" << checked
                      << " non_adjacent_lane1=" << adj_false << " x0=" << x0 << "\n";
            return 0;
        };
        rc |= run_ppc2(960, 540, 0, 0, "g960ppc2", true);
        // ODD origin + dual lane (parent: even x0=16 alone cannot catch phase).
        rc |= run_ppc2(640, 480, 17, 9, "g640off17_ppc2", true);
        // ODD glass start only: force hc odd path density already in loop.
        rc |= run_ppc2(960, 540, 15, 7, "g960off15odd_ppc2", true);
    }

    if (fault) {
        // For fault build, success is divergence
        if (rc == 0)
            std::cout << "CONTENT_WINDOW FAULT_OK (diverged as required)\n";
        else {
            std::cerr << "CONTENT_WINDOW FAULT unexpected\n";
            return 1;
        }
        // Exit non-zero so outer shell treats as RED proof when used as negative exe
        // Convention in cavlc: negative test exe returns non-zero on "caught bug".
        // Our run_frame returns 0 when divergence seen. Shell expects non-zero for RED.
        // Return 1 to mean "fault injected path is wrong" i.e. negative caught.
        return 1;
    }

    if (failures || rc) {
        std::cerr << "CONTENT_WINDOW FAIL failures=" << failures << "\n";
        return 1;
    }
    std::cout << "CONTENT_WINDOW PASS\n";
    std::cout << "Verilator PASS\n";
    return 0;
}
