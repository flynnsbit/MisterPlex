// Spec-derived H.264 Baseline inverse transform golden (ITU-T H.264 8.5.x).
// Written from the standard + bit-exact FFmpeg/JM decoder forms — NOT from RTL.
// Flat 4x4 weight matrix (Baseline default) weightScale = 16 everywhere.
//
// Algebra notes (LevelScale = 16 * normAdjust):
//   AC 8.5.12.1 unsimplified collapses to (c * na) << (qp/6) for integer results.
//   Luma DC 8.5.10: FFmpeg ff_h264_luma_dc_dequant_idct uses
//     qmul = (na*16) << (qp/6 + 2);  dc = (f * qmul + 128) >> 8
//     ≡ (((f * LevelScale) << (qp/6)) + 32) >> 6
//     ≡ (((f * na) << (qp/6)) + 2) >> 2
//   Chroma DC 8.5.11: FFmpeg ff_h264_chroma_dc_dequant_idct uses
//     (f * qmul) >> 7 with the same qmul construction
//     ≡ (((f * LevelScale) << (qp/6))) >> 5
//     ≡ (((f * na) << (qp/6))) >> 1
// A misremembered unsimplified DC form using <<(qdiv-2) with LevelScale=16*na
// is 16× too large vs every production decoder — do not use it.
#pragma once
#include <cstdint>
#include <algorithm>

namespace h264_spec {

// Table 8-13 normAdjust4x4[m][class]: both-even, one-odd, both-odd.
inline int NormAdjust(int qmod, int mi_class) {
  static const int t[6][3] = {
    {10, 13, 16}, {11, 14, 18}, {13, 16, 20},
    {14, 18, 23}, {16, 20, 25}, {18, 23, 29},
  };
  return t[qmod][mi_class];
}

// Inverse zig-zag: scan index holding raster position r (Table 8-13 / 6-10).
inline int ScanOfRaster(int r) {
  static const int s[16] = {0, 1, 5, 6, 2, 4, 7, 12, 3, 8, 11, 13, 9, 10, 14, 15};
  return s[r];
}

inline int MiClass(int r) {
  int col_odd = (r % 2) != 0;
  int row_odd = ((r / 4) % 2) != 0;
  return col_odd + row_odd; // 0,1,2
}

inline int64_t Sat29(int64_t v) {
  if (v > 268435455LL) return 268435455LL;
  if (v < -268435456LL) return -268435456LL;
  return v;
}

// 8.5.12.1 Scaling process for residual transform coefficients.
// weightScale flat = 16.  LevelScale(m,i,j) = weightScale * normAdjust.
// Unsimplified form from the standard:
//   if (qP >= 24)
//     c_ij = (c_ij * LevelScale) << (qP/6 - 4)
//   else
//     c_ij = (c_ij * LevelScale + (1 << (3 - qP/6))) >> (4 - qP/6)
// Integer-equivalent collapsed form used by FFmpeg/JM: (c * na) << (qp/6).
inline int64_t LevelScaleDequant(int64_t c, int qp, int raster) {
  const int qmod = qp % 6;
  const int qdiv = qp / 6;
  const int na = NormAdjust(qmod, MiClass(raster));
  const int64_t level_scale = 16LL * na;
  int64_t out;
  if (qp >= 24) {
    out = (c * level_scale) << (qdiv - 4);
  } else {
    const int64_t rnd = 1LL << (3 - qdiv);
    out = (c * level_scale + rnd) >> (4 - qdiv);
  }
  return Sat29(out);
}

// Flex dequant: inverse zig-zag placement + optional AC-only / DC override.
inline void DequantFlex(const int16_t coeff[16], int qp, int max_coeff,
                        int skip_dc, int dc_override, int64_t dc_value,
                        int64_t deq[16]) {
  for (int r = 0; r < 16; ++r) {
    const int scan = ScanOfRaster(r);
    const int arr = skip_dc ? scan - 1 : scan;
    bool in_range = skip_dc ? (scan != 0 && (scan - 1) < max_coeff)
                            : (scan < max_coeff);
    const int64_t c = in_range ? coeff[arr & 15] : 0;
    int64_t s = LevelScaleDequant(c, qp, r);
    if (r == 0) s = dc_override ? dc_value : (skip_dc ? 0 : s);
    deq[r] = s;
  }
}

// Plain dequant (scan-order coeffs, full 16).
inline void DequantPlain(const int16_t coeff[16], int qp, int max_coeff,
                         int64_t deq[16]) {
  for (int r = 0; r < 16; ++r) {
    const int sk = ScanOfRaster(r);
    const int64_t c = (max_coeff > sk) ? coeff[sk] : 0;
    deq[r] = LevelScaleDequant(c, qp, r);
  }
}

// 8.5.12.2 Transformation process (integer inverse transform).
// Butterfly + final (e_ij + 32) >> 6.  Rounding via d[0][0] += 32 pre-transform
// (FFmpeg ff_h264_idct_add / standard equivalent).
inline void Idct4x4(const int64_t d_in[16], int64_t r[16]) {
  int64_t b[16];
  for (int i = 0; i < 16; ++i) b[i] = d_in[i];
  b[0] += 32;

  auto row = [](int64_t x0, int64_t x1, int64_t x2, int64_t x3,
                int64_t& y0, int64_t& y1, int64_t& y2, int64_t& y3) {
    int64_t z0 = x0 + x2;
    int64_t z1 = x0 - x2;
    int64_t z2 = (x1 >> 1) - x3;
    int64_t z3 = x1 + (x3 >> 1);
    y0 = z0 + z3; y1 = z1 + z2; y2 = z1 - z2; y3 = z0 - z3;
  };

  int64_t t[16];
  for (int row_i = 0; row_i < 4; ++row_i)
    row(b[4 * row_i + 0], b[4 * row_i + 1], b[4 * row_i + 2], b[4 * row_i + 3],
        t[4 * row_i + 0], t[4 * row_i + 1], t[4 * row_i + 2], t[4 * row_i + 3]);

  int64_t e[16];
  for (int col = 0; col < 4; ++col)
    row(t[0 + col], t[4 + col], t[8 + col], t[12 + col],
        e[0 + col], e[4 + col], e[8 + col], e[12 + col]);

  for (int i = 0; i < 16; ++i) r[i] = Sat29(e[i] >> 6);
}

// 8.5.10 Scaling + transform for luma DC (Intra_16x16).
// Input: Intra16x16DCLevel in zig-zag scan order.
// 1) inverse zig-zag into 4x4 raster
// 2) inverse Hadamard f = H * c * H
// 3) scale bit-exact to FFmpeg ff_h264_luma_dc_dequant_idct / LevelScale form
//    dc = (((f * LevelScale(m,0,0)) << (qp/6)) + 32) >> 6
inline void LumaDcHadamardInv(const int16_t coeff_scan[16], int qp, int64_t dc[16]) {
  int64_t c[16];
  for (int r = 0; r < 16; ++r) c[r] = coeff_scan[ScanOfRaster(r)];

  int64_t g[16];
  for (int row = 0; row < 4; ++row) {
    const int64_t* p = &c[4 * row];
    g[4 * row + 0] = p[0] + p[1] + p[2] + p[3];
    g[4 * row + 1] = p[0] + p[1] - p[2] - p[3];
    g[4 * row + 2] = p[0] - p[1] - p[2] + p[3];
    g[4 * row + 3] = p[0] - p[1] + p[2] - p[3];
  }
  int64_t f[16];
  for (int col = 0; col < 4; ++col) {
    f[col + 0] = g[col] + g[col + 4] + g[col + 8] + g[col + 12];
    f[col + 4] = g[col] + g[col + 4] - g[col + 8] - g[col + 12];
    f[col + 8] = g[col] - g[col + 4] - g[col + 8] + g[col + 12];
    f[col + 12] = g[col] - g[col + 4] + g[col + 8] - g[col + 12];
  }

  const int qmod = qp % 6;
  const int qdiv = qp / 6;
  const int64_t ls = 16LL * NormAdjust(qmod, 0); // LevelScale(m,0,0)
  for (int i = 0; i < 16; ++i) {
    // FFmpeg: qmul = ls << (qdiv+2); (f*qmul + 128) >> 8
    const int64_t qmul = ls << (qdiv + 2);
    dc[i] = Sat29((f[i] * qmul + 128) >> 8);
  }
}

// 8.5.11 Chroma DC 4:2:0 2x2 Hadamard + scale (QPc).
// f = [[1,1],[1,-1]] * c * [[1,1],[1,-1]]
// FFmpeg ff_h264_chroma_dc_dequant_idct: (f * qmul) >> 7
// with qmul = LevelScale << (qp/6 + 2)  →  (((f*ls)<<qdiv)>>5)
inline void ChromaDcHadamardInv(const int16_t c4[4], int qp_c, int64_t dc[4]) {
  const int64_t a = c4[0], b = c4[1], cc = c4[2], d = c4[3];
  // Match RTL/FFmpeg butterfly order: f0=a+b+c+d, f1=a-b+c-d, f2=a+b-c-d, f3=a-b-c+d
  const int64_t f[4] = {a + b + cc + d, a - b + cc - d, a + b - cc - d, a - b - cc + d};
  const int qmod = qp_c % 6;
  const int qdiv = qp_c / 6;
  const int64_t ls = 16LL * NormAdjust(qmod, 0);
  const int64_t qmul = ls << (qdiv + 2);
  for (int i = 0; i < 4; ++i)
    dc[i] = Sat29((f[i] * qmul) >> 7);
}

// Table 8-15 qPi -> QPc (TB usually feeds QPc directly).
inline int QpCFromY(int qpy, int chroma_qp_index_offset = 0) {
  int qpi = qpy + chroma_qp_index_offset;
  if (qpi < 0) qpi = 0;
  if (qpi > 51) qpi = 51;
  static const int map[22] = {
    29, 30, 31, 32, 32, 33, 34, 34, 35, 35, 36, 36, 37, 37, 37, 38, 38, 38, 39, 39, 39, 39
  };
  if (qpi < 30) return qpi;
  return map[qpi - 30];
}

}  // namespace h264_spec
