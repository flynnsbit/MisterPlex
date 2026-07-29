// Executes the transform / dequant RTL and compares it against the
// multiply-and-shift expressions the area work replaced.
//
// The reference here is deliberately NOT an independent H.264 model.  The
// question this bench answers is narrower and more useful: does the
// multiplier-free RTL compute bit-for-bit what the multiplying RTL computed?
// mul_norm claims c*normAdjust is a sum of at most three shifted copies,
// shl_qdiv claims a nine-way mux equals a variable shift, the DC paths claim
// LevelScale's factor of 16 cancels against the rounding shift, and the
// chroma bilinear claims (8-f)*a + f*b == (a<<3) + f*(b-a).  Each of those is
// an asserted identity, and an asserted identity that nobody executed is a
// guess.

#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <random>
#include <vector>

#include "Vh264_transform_dequant_tb_top.h"
#include "verilated.h"

namespace {

// normAdjust4x4 as the RTL indexes it: class 0 = row and col both even,
// class 1 = exactly one odd, class 2 = both odd.  Note this is NOT the
// column order the spec tables are printed in (the spec lists both-odd
// second); getting it backwards silently swaps 13 for 16.
const int kNormAdjust[6][3] = {
    {10, 13, 16}, {11, 14, 18}, {13, 16, 20},
    {14, 18, 23}, {16, 20, 25}, {18, 23, 29},
};

// Inverse zig-zag: scan position holding raster index r.
const int kScanOfRaster[16] = {0, 1, 5, 6, 2, 4, 7, 12, 3, 8, 11, 13, 9, 10, 14, 15};

int MiOfRaster(int r) { return ((r % 2) != 0 ? 1 : 0) + (((r / 4) % 2) != 0 ? 1 : 0); }

int64_t Sat29(int64_t v) {
  if (v > 268435455LL) return 268435455LL;
  if (v < -268435456LL) return -268435456LL;
  return v;
}

// Verilator returns the 29-bit outputs zero-extended inside a wider word.
int64_t SignExtend29(uint64_t raw) {
  int64_t v = static_cast<int64_t>(raw & 0x1FFFFFFFULL);
  if (v & 0x10000000LL) v -= 0x20000000LL;
  return v;
}

// Read element `i` of a W-bit little-endian packed field out of a Verilator
// WData array.
uint64_t MaskOf(int width) {
  return width >= 64 ? ~0ULL : ((1ULL << width) - 1ULL);
}

uint64_t GetField(uint64_t field, int bit_off, int width) {
  return (field >> bit_off) & MaskOf(width);
}

void SetField(uint64_t& field, int bit_off, int width, uint64_t value) {
  field &= ~(MaskOf(width) << bit_off);
  field |= (value & MaskOf(width)) << bit_off;
}

template <typename T>
uint64_t GetField(const T& field, int bit_off, int width) {
  const uint32_t* words = field.data();
  uint64_t out = 0;
  for (int b = 0; b < width; ++b) {
    int bit = bit_off + b;
    uint64_t v = (words[bit / 32] >> (bit % 32)) & 1u;
    out |= v << b;
  }
  return out;
}

template <typename T>
void SetField(T& field, int bit_off, int width, uint64_t value) {
  uint32_t* words = field.data();
  for (int b = 0; b < width; ++b) {
    int bit = bit_off + b;
    uint32_t mask = 1u << (bit % 32);
    if ((value >> b) & 1ULL)
      words[bit / 32] |= mask;
    else
      words[bit / 32] &= ~mask;
  }
}

struct Failure {
  const char* what;
  int index;
  int qp;
  int64_t got;
  int64_t want;
};

}  // namespace

int main(int argc, char** argv) {
  Verilated::commandArgs(argc, argv);
  auto* dut = new Vh264_transform_dequant_tb_top;

  std::mt19937 rng(0xC0FFEE);
  std::vector<Failure> failures;
  long checks = 0;

  // Coefficient magnitudes: ordinary CAVLC levels are bounded to +/-2047, but
  // I_16x16 DC levels flow through the same path and reach ~26,000 measured,
  // so the sweep has to cover the full signed 16-bit input the port declares.
  const int kMags[] = {1, 2, 3, 7, 15, 255, 2047, 8191, 26000, 32767};

  for (int qp = 0; qp <= 51; ++qp) {
    const int qmod = qp % 6;
    const int qdiv = qp / 6;

    for (int trial = 0; trial < 40; ++trial) {
      int16_t coeff[16];
      int16_t c4[4];
      for (int i = 0; i < 16; ++i) {
        int mag = kMags[rng() % (sizeof(kMags) / sizeof(kMags[0]))];
        int v = static_cast<int>(rng() % (2u * mag + 1)) - mag;
        if (v < -32768) v = -32768;
        if (v > 32767) v = 32767;
        coeff[i] = static_cast<int16_t>(v);
      }
      for (int i = 0; i < 4; ++i) c4[i] = coeff[i];

      const int max_coeff = 1 + static_cast<int>(rng() % 16);
      const int skip_dc = static_cast<int>(rng() & 1u);
      const int dc_override = static_cast<int>(rng() & 1u);
      const int64_t dc_value = static_cast<int64_t>(rng() % 1000u) - 500;

      for (int i = 0; i < 16; ++i)
        SetField(dut->coeff16_flat, 16 * i, 16, static_cast<uint16_t>(coeff[i]));
      for (int i = 0; i < 4; ++i)
        SetField(dut->coeff4_flat, 16 * i, 16, static_cast<uint16_t>(c4[i]));
      dut->qp = qp;
      dut->max_coeff = max_coeff;
      dut->skip_dc = skip_dc;
      dut->dc_override = dc_override;
      dut->dc_value = static_cast<uint32_t>(dc_value & 0x1FFFFFFF);

      // Chroma bilinear window and fractions.
      uint8_t win[81];
      for (int i = 0; i < 81; ++i) win[i] = static_cast<uint8_t>(rng() & 0xFF);
      for (int i = 0; i < 81; ++i) SetField(dut->refwin_flat, 8 * i, 8, win[i]);
      const int fx = static_cast<int>(rng() % 8u);
      const int fy = static_cast<int>(rng() % 8u);
      dut->frac_x = fx;
      dut->frac_y = fy;

      dut->eval();

      // ---- h264_dequant4x4_flex --------------------------------------
      // 8.5.12.1 with the flat weight matrix: (c * normAdjust) << (qP/6).
      for (int r = 0; r < 16; ++r) {
        const int scan_idx = kScanOfRaster[r];
        const int arr_idx = skip_dc ? scan_idx - 1 : scan_idx;
        bool in_range = skip_dc ? (scan_idx != 0 && (scan_idx - 1) < max_coeff)
                                : (scan_idx < max_coeff);
        const int64_t c = in_range ? coeff[arr_idx & 15] : 0;
        const int64_t na = kNormAdjust[qmod][MiOfRaster(r)];
        const int64_t want_scaled = Sat29((c * na) << qdiv);
        int64_t want = want_scaled;
        if (r == 0) want = dc_override ? dc_value : (skip_dc ? 0 : want_scaled);
        const int64_t got = SignExtend29(GetField(dut->flex_flat, 29 * r, 29));
        ++checks;
        if (got != want && failures.size() < 12)
          failures.push_back({"dequant4x4_flex", r, qp, got, want});
      }

      // ---- h264_dequant4x4 -------------------------------------------
      for (int r = 0; r < 16; ++r) {
        const int sk = kScanOfRaster[r];
        const int64_t c = (max_coeff > sk) ? coeff[sk] : 0;
        const int64_t na = kNormAdjust[qmod][MiOfRaster(r)];
        const int64_t full = (c * na) << qdiv;
        const int64_t want = SignExtend29(static_cast<uint64_t>(full));
        const int64_t got = SignExtend29(GetField(dut->deq_flat, 29 * r, 29));
        ++checks;
        if (got != want && failures.size() < 12)
          failures.push_back({"dequant4x4", r, qp, got, want});
      }

      // ---- h264_luma_dc_hadamard_inv (8.5.10) ------------------------
      {
        int64_t c[16];
        for (int z = 0; z < 16; ++z) c[z] = coeff[kScanOfRaster[z]];
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
        const int64_t ls = 16 * kNormAdjust[qmod][0];
        for (int i = 0; i < 16; ++i) {
          // Original form, before the >>6 was collapsed against LevelScale.
          const int64_t want = Sat29((((f[i] * ls) << qdiv) + 32) >> 6);
          const int64_t got = SignExtend29(GetField(dut->ldc_flat, 29 * i, 29));
          ++checks;
          if (got != want && failures.size() < 12)
            failures.push_back({"luma_dc_hadamard_inv", i, qp, got, want});
        }
      }

      // ---- h264_chroma_dc_hadamard_inv (8.5.11) ----------------------
      {
        const int64_t a = c4[0], b = c4[1], cc = c4[2], d = c4[3];
        const int64_t f[4] = {a + b + cc + d, a - b + cc - d, a + b - cc - d,
                              a - b - cc + d};
        const int64_t ls = 16 * kNormAdjust[qmod][0];
        for (int i = 0; i < 4; ++i) {
          const int64_t want = Sat29(((f[i] * ls) << qdiv) >> 5);
          const int64_t got = SignExtend29(GetField(dut->cdc_flat, 29 * i, 29));
          ++checks;
          if (got != want && failures.size() < 12)
            failures.push_back({"chroma_dc_hadamard_inv", i, qp, got, want});
        }
      }

      // ---- h264_chroma_epel_block_8x8 (8.4.2.2.2) --------------------
      // Reference is the four-triple-product form the separable rewrite
      // replaced.  Any difference is a rounding change, not an optimisation.
      for (int oy = 0; oy < 8; ++oy) {
        for (int ox = 0; ox < 8; ++ox) {
          const int p00 = win[oy * 9 + ox];
          const int p10 = win[oy * 9 + ox + 1];
          const int p01 = win[(oy + 1) * 9 + ox];
          const int p11 = win[(oy + 1) * 9 + ox + 1];
          const int sum = (8 - fx) * (8 - fy) * p00 + fx * (8 - fy) * p10 +
                          (8 - fx) * fy * p01 + fx * fy * p11 + 32;
          const int64_t want = (sum >> 6) & 0xFF;
          const int64_t got =
              static_cast<int64_t>(GetField(dut->cpred_flat, 8 * (oy * 8 + ox), 8));
          ++checks;
          if (got != want && failures.size() < 12)
            failures.push_back({"chroma_epel_block_8x8", oy * 8 + ox, qp, got, want});
        }
      }
    }
  }

  dut->final();
  delete dut;

  if (!failures.empty()) {
    for (const auto& f : failures)
      std::printf("FAIL %-24s idx=%2d qp=%2d got=%lld want=%lld\n", f.what, f.index,
                  f.qp, static_cast<long long>(f.got), static_cast<long long>(f.want));
    std::printf("TRANSFORM_DEQUANT_RTL_SIM FAIL: %zu mismatch(es) of %ld checks\n",
                failures.size(), checks);
    return 1;
  }

  std::printf("TRANSFORM_DEQUANT_RTL_SIM PASS: %ld checks executed on real RTL\n",
              checks);
  return 0;
}
