// RED-before-GREEN TB for fabric BT.601 YUV420→RGB (yuv_bt601_npx, PPC=2).
// Reference: host/libmisterplex/pixel_format.hpp yuvToRgb (full-range Y, U/V-128).
//
// Negative cases a naive wrong impl must fail:
//   1) swapped U/V (R/B channels inverted on pure chroma)
//   2) studio/limited-range (Y-16)*298 style when DUT is full-range product math

#include "Vyuv_bt601_npx_tb_top.h"
#include "verilated.h"

#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>

namespace {

uint8_t clamp8(int v) {
    if (v < 0) return 0;
    if (v > 255) return 255;
    return static_cast<uint8_t>(v);
}

// Product reference (matches pixel_format.hpp / ddr_frame_store / yuv_bt601_npx).
void yuvToRgbFull(uint8_t y, uint8_t u, uint8_t v, uint8_t& r, uint8_t& g, uint8_t& b) {
    const int uu = static_cast<int>(u) - 128;
    const int vv = static_cast<int>(v) - 128;
    r = clamp8((static_cast<int>(y) * 256 + 359 * vv) >> 8);
    g = clamp8((static_cast<int>(y) * 256 - 88 * uu - 183 * vv) >> 8);
    b = clamp8((static_cast<int>(y) * 256 + 454 * uu) >> 8);
}

// Wrong limited-range math (ITU studio) — must NOT match DUT on Y=16 black.
void yuvToRgbLimitedWrong(uint8_t y, uint8_t u, uint8_t v, uint8_t& r, uint8_t& g, uint8_t& b) {
    const int yy = static_cast<int>(y) - 16;
    const int uu = static_cast<int>(u) - 128;
    const int vv = static_cast<int>(v) - 128;
    r = clamp8((298 * yy + 409 * vv + 128) >> 8);
    g = clamp8((298 * yy - 100 * uu - 208 * vv + 128) >> 8);
    b = clamp8((298 * yy + 516 * uu + 128) >> 8);
}

void tick(Vyuv_bt601_npx_tb_top* dut) {
    dut->clk = 0;
    dut->eval();
    dut->clk = 1;
    dut->eval();
}

uint8_t pick8(uint64_t q, int idx) {
    return static_cast<uint8_t>((q >> (8 * (idx & 7))) & 0xff);
}

void pack_line_y(uint64_t& yq, const uint8_t y[8]) {
    yq = 0;
    for (int i = 0; i < 8; ++i)
        yq |= (static_cast<uint64_t>(y[i]) << (8 * i));
}

void pack_line_c(uint64_t& cq, const uint8_t c[8]) {
    cq = 0;
    for (int i = 0; i < 8; ++i)
        cq |= (static_cast<uint64_t>(c[i]) << (8 * i));
}

struct Rgb {
    uint8_t r, g, b;
};

int g_fails = 0;

void expect(bool cond, const char* msg) {
    if (!cond) {
        std::fprintf(stderr, "FAIL: %s\n", msg);
        ++g_fails;
    }
}

void drive_pair(Vyuv_bt601_npx_tb_top* dut, int src_x0, uint64_t yq, uint64_t uq, uint64_t vq,
                Rgb out[2]) {
    dut->in_valid = 1;
    dut->src_x0 = src_x0;
    dut->y_qword = yq;
    dut->u_qword = uq;
    dut->v_qword = vq;
    dut->y_qword_hi = 0;
    dut->y_hi_valid = 0;
    tick(dut);
    // 1-cycle registered output
    tick(dut);
    out[0] = {static_cast<uint8_t>(dut->out_r & 0xff), static_cast<uint8_t>(dut->out_g & 0xff),
              static_cast<uint8_t>(dut->out_b & 0xff)};
    out[1] = {static_cast<uint8_t>((dut->out_r >> 8) & 0xff),
              static_cast<uint8_t>((dut->out_g >> 8) & 0xff),
              static_cast<uint8_t>((dut->out_b >> 8) & 0xff)};
    expect(dut->out_valid == 1, "out_valid after in_valid");
    expect((dut->out_lane_valid & 0x3) == 0x3, "both lanes valid");
    dut->in_valid = 0;
}

}  // namespace

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    const bool negative_uv_swap = (std::getenv("YUV_NEG_UV_SWAP") != nullptr);
    const bool negative_limited = (std::getenv("YUV_NEG_LIMITED") != nullptr);

    auto* dut = new Vyuv_bt601_npx_tb_top;
    dut->reset = 1;
    dut->in_valid = 0;
    dut->src_x0 = 0;
    dut->y_qword = 0;
    dut->u_qword = 0;
    dut->v_qword = 0;
    dut->y_qword_hi = 0;
    dut->y_hi_valid = 0;
    for (int i = 0; i < 4; ++i) tick(dut);
    dut->reset = 0;
    tick(dut);

    // Known vectors: neutral gray, pure red-ish (high V), pure blue-ish (high U), black, white.
    struct Vec {
        uint8_t y0, y1, u, v;
        const char* name;
    };
    const Vec vecs[] = {
        {128, 130, 128, 128, "near_gray"},
        {180, 200, 128, 200, "high_v"},
        {180, 160, 200, 128, "high_u"},
        {16, 16, 128, 128, "y16_blackish"},
        {235, 235, 128, 128, "y235_whiteish"},
        {0, 255, 0, 255, "extremes"},
    };

    int checked = 0;
    for (const auto& vc : vecs) {
        uint8_t yb[8] = {};
        uint8_t ub[8] = {};
        uint8_t vb[8] = {};
        // Place pair at x0=0 → y bytes 0,1; chroma index x[3:1]=0
        yb[0] = vc.y0;
        yb[1] = vc.y1;
        ub[0] = vc.u;
        vb[0] = vc.v;
        if (negative_uv_swap) {
            // Feed swapped chroma into DUT inputs while reference stays correct U/V.
            ub[0] = vc.v;
            vb[0] = vc.u;
        }
        uint64_t yq, uq, vq;
        pack_line_y(yq, yb);
        pack_line_c(uq, ub);
        pack_line_c(vq, vb);

        Rgb got[2];
        drive_pair(dut, 0, yq, uq, vq, got);

        for (int lane = 0; lane < 2; ++lane) {
            const uint8_t y = (lane == 0) ? vc.y0 : vc.y1;
            uint8_t er, eg, eb;
            if (negative_limited) {
                yuvToRgbLimitedWrong(y, vc.u, vc.v, er, eg, eb);
            } else {
                yuvToRgbFull(y, vc.u, vc.v, er, eg, eb);
            }
            char buf[160];
            std::snprintf(buf, sizeof(buf), "%s lane%d R got=%u exp=%u", vc.name, lane, got[lane].r,
                          er);
            expect(got[lane].r == er, buf);
            std::snprintf(buf, sizeof(buf), "%s lane%d G got=%u exp=%u", vc.name, lane, got[lane].g,
                          eg);
            expect(got[lane].g == eg, buf);
            std::snprintf(buf, sizeof(buf), "%s lane%d B got=%u exp=%u", vc.name, lane, got[lane].b,
                          eb);
            expect(got[lane].b == eb, buf);
            ++checked;
        }
    }

    // Straddle case: src_x0=6 uses y bytes 6,7 in primary qword (even-aligned PPC=2).
    {
        uint8_t yb[8] = {10, 20, 30, 40, 50, 60, 70, 80};
        uint8_t ub[8] = {128, 128, 128, 140, 128, 128, 128, 128};
        uint8_t vb[8] = {128, 128, 128, 110, 128, 128, 128, 128};
        uint64_t yq, uq, vq;
        pack_line_y(yq, yb);
        pack_line_c(uq, ub);
        pack_line_c(vq, vb);
        Rgb got[2];
        drive_pair(dut, 6, yq, uq, vq, got);
        // x=6,7 → cidx = x[3:1] = 3
        uint8_t er, eg, eb;
        yuvToRgbFull(70, 140, 110, er, eg, eb);
        expect(got[0].r == er && got[0].g == eg && got[0].b == eb, "x6 RGB");
        yuvToRgbFull(80, 140, 110, er, eg, eb);
        expect(got[1].r == er && got[1].g == eg && got[1].b == eb, "x7 RGB");
        checked += 2;
    }

    // Prove limited-range oracle differs on Y=16 so NEG_LIMITED is a real negative.
    {
        uint8_t rf, gf, bf, rl, gl, bl;
        yuvToRgbFull(16, 128, 128, rf, gf, bf);
        yuvToRgbLimitedWrong(16, 128, 128, rl, gl, bl);
        expect(!(rf == rl && gf == gl && bf == bl),
               "oracle: full vs limited must differ at Y=16 (negative case fuel)");
    }

    delete dut;

    if (negative_uv_swap || negative_limited) {
        // Negative mode: we EXPECT mismatches → exit 1 if zero fails (proof weak).
        if (g_fails == 0) {
            std::fprintf(stderr, "NEG_FAIL: expected mismatches but got 0 fails\n");
            return 1;
        }
        std::printf("YUV_BT601_NPX NEG_OK mode=%s fails=%d (expected)\n",
                    negative_uv_swap ? "UV_SWAP" : "LIMITED", g_fails);
        return 1;  // shell expects non-zero for RED proof
    }

    if (g_fails != 0) {
        std::printf("YUV_BT601_NPX FAIL fails=%d checked=%d\n", g_fails, checked);
        return 1;
    }
    std::printf("YUV_BT601_NPX PASS checked=%d ppc=2 full_range_bt601\n", checked);
    return 0;
}
