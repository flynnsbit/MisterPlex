// H.264 MC interpolation reference model — ITU-T H.264 clause 8.4.2.2
// Written independently from the specification, NOT from existing RTL.
// Purpose: provide a trusted oracle for bit-exact verification of h264_mc_interp.sv.
#pragma once

#include <algorithm>
#include <cassert>
#include <cstdint>
#include <cstdlib>
#include <vector>

namespace mc_ref {

// Clip to [0, 255] (clause 5-5, Clip1_Y)
static inline int clip1(int v) {
    if (v < 0) return 0;
    if (v > 255) return 255;
    return v;
}

// Edge clamp: reference samples outside the picture boundary are replaced
// with the nearest boundary sample (clause 8.4.2.2.1, NOTE).
static inline int clamp_coord(int v, int max_val) {
    if (v < 0) return 0;
    if (v >= max_val) return max_val - 1;
    return v;
}

// Fetch a reference sample with edge clamping.
static inline uint8_t fetch_ref(const uint8_t* ref, int stride,
                                int x, int y, int pic_w, int pic_h) {
    int cx = clamp_coord(x, pic_w);
    int cy = clamp_coord(y, pic_h);
    return ref[cy * stride + cx];
}

// ---------------------------------------------------------------------------
// Luma half-pel: 6-tap filter (1, -5, 20, 20, -5, 1)
// Clause 8.4.2.2.1
// ---------------------------------------------------------------------------

// Horizontal 6-tap at full precision (no rounding/clipping — used for 'j').
static inline int luma_h6_raw(const uint8_t* ref, int stride,
                              int x, int y, int pic_w, int pic_h) {
    int s0 = fetch_ref(ref, stride, x - 2, y, pic_w, pic_h);
    int s1 = fetch_ref(ref, stride, x - 1, y, pic_w, pic_h);
    int s2 = fetch_ref(ref, stride, x,     y, pic_w, pic_h);
    int s3 = fetch_ref(ref, stride, x + 1, y, pic_w, pic_h);
    int s4 = fetch_ref(ref, stride, x + 2, y, pic_w, pic_h);
    int s5 = fetch_ref(ref, stride, x + 3, y, pic_w, pic_h);
    return s0 - 5 * s1 + 20 * s2 + 20 * s3 - 5 * s4 + s5;
}

// Horizontal half-pel 'b': (h6_raw + 16) >> 5, clipped.
static inline int luma_half_h(const uint8_t* ref, int stride,
                              int x, int y, int pic_w, int pic_h) {
    return clip1((luma_h6_raw(ref, stride, x, y, pic_w, pic_h) + 16) >> 5);
}

// Vertical 6-tap at full precision.
static inline int luma_v6_raw(const uint8_t* ref, int stride,
                              int x, int y, int pic_w, int pic_h) {
    int s0 = fetch_ref(ref, stride, x, y - 2, pic_w, pic_h);
    int s1 = fetch_ref(ref, stride, x, y - 1, pic_w, pic_h);
    int s2 = fetch_ref(ref, stride, x, y,     pic_w, pic_h);
    int s3 = fetch_ref(ref, stride, x, y + 1, pic_w, pic_h);
    int s4 = fetch_ref(ref, stride, x, y + 2, pic_w, pic_h);
    int s5 = fetch_ref(ref, stride, x, y + 3, pic_w, pic_h);
    return s0 - 5 * s1 + 20 * s2 + 20 * s3 - 5 * s4 + s5;
}

// Vertical half-pel 'h': (v6_raw + 16) >> 5, clipped.
static inline int luma_half_v(const uint8_t* ref, int stride,
                              int x, int y, int pic_w, int pic_h) {
    return clip1((luma_v6_raw(ref, stride, x, y, pic_w, pic_h) + 16) >> 5);
}

// Centre half-pel 'j': vertical 6-tap applied to horizontal 6-tap intermediates.
// The horizontal intermediates are NOT rounded before the vertical filter.
// Final rounding: (sum + 512) >> 10, clipped.
static inline int luma_half_j(const uint8_t* ref, int stride,
                              int x, int y, int pic_w, int pic_h) {
    // First compute 6 horizontal raw intermediates at rows y-2..y+3.
    int h0 = luma_h6_raw(ref, stride, x, y - 2, pic_w, pic_h);
    int h1 = luma_h6_raw(ref, stride, x, y - 1, pic_w, pic_h);
    int h2 = luma_h6_raw(ref, stride, x, y,     pic_w, pic_h);
    int h3 = luma_h6_raw(ref, stride, x, y + 1, pic_w, pic_h);
    int h4 = luma_h6_raw(ref, stride, x, y + 2, pic_w, pic_h);
    int h5 = luma_h6_raw(ref, stride, x, y + 3, pic_w, pic_h);
    // Vertical 6-tap on intermediates.
    int sum = h0 - 5 * h1 + 20 * h2 + 20 * h3 - 5 * h4 + h5;
    return clip1((sum + 512) >> 10);
}

// Bilinear average for quarter-pel: (a + b + 1) >> 1.
static inline int avg2(int a, int b) {
    return (a + b + 1) >> 1;
}

// ---------------------------------------------------------------------------
// Luma quarter-pel interpolation: all 16 sub-positions
// Clause 8.4.2.2.1, Table 8-12 (figure 8-4)
//
// Input: integer-pel position (int_x, int_y) and quarter-pel fraction
//        (frac_x in 0..3, frac_y in 0..3).
// The actual referenced integer position in the frame is (int_x, int_y).
// ---------------------------------------------------------------------------

static inline uint8_t luma_interp(const uint8_t* ref, int stride,
                                  int int_x, int int_y,
                                  int frac_x, int frac_y,
                                  int pic_w, int pic_h) {
    // Integer sample at (int_x, int_y) = G
    // Integer sample at (int_x+1, int_y) = H  (to the right of G)
    // Integer sample at (int_x, int_y+1) = M  (below G)
    // Half-pel positions:
    //   b = half_h at (int_x, int_y)     — between G and H horizontally
    //   h = half_v at (int_x, int_y)     — between G and M vertically
    //   j = half_j at (int_x, int_y)     — centre
    //   s = half_h at (int_x, int_y+1)   — below b
    //   k = half_v at (int_x+1, int_y)   — right of h

    int G = fetch_ref(ref, stride, int_x, int_y, pic_w, pic_h);
    int result;

    switch (frac_y * 4 + frac_x) {
    case 0:  // (0,0) — G
        result = G;
        break;
    case 1:  // (0,1) — avg(G, b)
        result = avg2(G, luma_half_h(ref, stride, int_x, int_y, pic_w, pic_h));
        break;
    case 2:  // (0,2) — b
        result = luma_half_h(ref, stride, int_x, int_y, pic_w, pic_h);
        break;
    case 3: { // (0,3) — avg(b, H)
        int H = fetch_ref(ref, stride, int_x + 1, int_y, pic_w, pic_h);
        result = avg2(luma_half_h(ref, stride, int_x, int_y, pic_w, pic_h), H);
        break;
    }
    case 4:  // (1,0) — avg(G, h)
        result = avg2(G, luma_half_v(ref, stride, int_x, int_y, pic_w, pic_h));
        break;
    case 5:  // (1,1) — avg(b, h) — "e"
        result = avg2(luma_half_h(ref, stride, int_x, int_y, pic_w, pic_h),
                      luma_half_v(ref, stride, int_x, int_y, pic_w, pic_h));
        break;
    case 6:  // (1,2) — avg(b, j) — "f"
        result = avg2(luma_half_h(ref, stride, int_x, int_y, pic_w, pic_h),
                      luma_half_j(ref, stride, int_x, int_y, pic_w, pic_h));
        break;
    case 7:  // (1,3) — avg(b, k) where k = half_v at (int_x+1, int_y)
        result = avg2(luma_half_h(ref, stride, int_x, int_y, pic_w, pic_h),
                      luma_half_v(ref, stride, int_x + 1, int_y, pic_w, pic_h));
        break;
    case 8:  // (2,0) — h
        result = luma_half_v(ref, stride, int_x, int_y, pic_w, pic_h);
        break;
    case 9:  // (2,1) — avg(h, j)
        result = avg2(luma_half_v(ref, stride, int_x, int_y, pic_w, pic_h),
                      luma_half_j(ref, stride, int_x, int_y, pic_w, pic_h));
        break;
    case 10: // (2,2) — j
        result = luma_half_j(ref, stride, int_x, int_y, pic_w, pic_h);
        break;
    case 11: // (2,3) — avg(j, k)
        result = avg2(luma_half_j(ref, stride, int_x, int_y, pic_w, pic_h),
                      luma_half_v(ref, stride, int_x + 1, int_y, pic_w, pic_h));
        break;
    case 12: { // (3,0) — avg(h, M)
        int M = fetch_ref(ref, stride, int_x, int_y + 1, pic_w, pic_h);
        result = avg2(luma_half_v(ref, stride, int_x, int_y, pic_w, pic_h), M);
        break;
    }
    case 13: // (3,1) — avg(s, h) where s = half_h at (int_x, int_y+1)
        result = avg2(luma_half_h(ref, stride, int_x, int_y + 1, pic_w, pic_h),
                      luma_half_v(ref, stride, int_x, int_y, pic_w, pic_h));
        break;
    case 14: // (3,2) — avg(j, s)
        result = avg2(luma_half_j(ref, stride, int_x, int_y, pic_w, pic_h),
                      luma_half_h(ref, stride, int_x, int_y + 1, pic_w, pic_h));
        break;
    case 15: // (3,3) — avg(s, k)
        result = avg2(luma_half_h(ref, stride, int_x, int_y + 1, pic_w, pic_h),
                      luma_half_v(ref, stride, int_x + 1, int_y, pic_w, pic_h));
        break;
    default:
        result = 0;
        break;
    }
    return static_cast<uint8_t>(result);
}

// ---------------------------------------------------------------------------
// Chroma MC interpolation: eighth-pel bilinear
// Clause 8.4.2.2.2
//
// Weights: (8-xFrac)(8-yFrac), xFrac(8-yFrac), (8-xFrac)yFrac, xFrac*yFrac
// Rounding: (sum + 32) >> 6
// ---------------------------------------------------------------------------

static inline uint8_t chroma_interp(const uint8_t* ref, int stride,
                                    int int_x, int int_y,
                                    int frac_x, int frac_y,
                                    int pic_w, int pic_h) {
    int p00 = fetch_ref(ref, stride, int_x,     int_y,     pic_w, pic_h);
    int p10 = fetch_ref(ref, stride, int_x + 1, int_y,     pic_w, pic_h);
    int p01 = fetch_ref(ref, stride, int_x,     int_y + 1, pic_w, pic_h);
    int p11 = fetch_ref(ref, stride, int_x + 1, int_y + 1, pic_w, pic_h);

    int wx0 = 8 - frac_x;
    int wy0 = 8 - frac_y;
    int wx1 = frac_x;
    int wy1 = frac_y;

    int sum = wx0 * wy0 * p00 + wx1 * wy0 * p10 +
              wx0 * wy1 * p01 + wx1 * wy1 * p11;
    return static_cast<uint8_t>((sum + 32) >> 6);
}

// ---------------------------------------------------------------------------
// Block-level MC: compute prediction for an entire block.
// ---------------------------------------------------------------------------

// Luma block prediction.
// mv_x, mv_y are in quarter-pel units.
// blk_x, blk_y are the top-left of the block in integer-pel coordinates.
static inline void luma_mc_block(const uint8_t* ref, int ref_stride,
                                 int blk_x, int blk_y,
                                 int mv_x, int mv_y,
                                 int blk_w, int blk_h,
                                 int pic_w, int pic_h,
                                 uint8_t* out, int out_stride) {
    int frac_x = mv_x & 3;
    int frac_y = mv_y & 3;
    int int_x = blk_x + (mv_x >> 2);
    int int_y = blk_y + (mv_y >> 2);

    for (int r = 0; r < blk_h; r++) {
        for (int c = 0; c < blk_w; c++) {
            out[r * out_stride + c] = luma_interp(
                ref, ref_stride,
                int_x + c, int_y + r,
                frac_x, frac_y,
                pic_w, pic_h);
        }
    }
}

// Chroma block prediction.
// mv_x, mv_y are in eighth-pel units.
static inline void chroma_mc_block(const uint8_t* ref, int ref_stride,
                                   int blk_x, int blk_y,
                                   int mv_x, int mv_y,
                                   int blk_w, int blk_h,
                                   int pic_w, int pic_h,
                                   uint8_t* out, int out_stride) {
    int frac_x = mv_x & 7;
    int frac_y = mv_y & 7;
    int int_x = blk_x + (mv_x >> 3);
    int int_y = blk_y + (mv_y >> 3);

    for (int r = 0; r < blk_h; r++) {
        for (int c = 0; c < blk_w; c++) {
            out[r * out_stride + c] = chroma_interp(
                ref, ref_stride,
                int_x + c, int_y + r,
                frac_x, frac_y,
                pic_w, pic_h);
        }
    }
}

} // namespace mc_ref
