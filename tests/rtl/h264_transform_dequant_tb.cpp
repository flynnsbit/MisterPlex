// Executes the transform / dequant RTL against multiply-and-shift identities.
// Luma DC Hadamard and iq_idct_seq are sequential — clock start/done.

#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <random>
#include <vector>

#include "Vh264_transform_dequant_tb_top.h"
#include "verilated.h"

namespace {

const int kNormAdjust[6][3] = {
    {10, 13, 16}, {11, 14, 18}, {13, 16, 20},
    {14, 18, 23}, {16, 20, 25}, {18, 23, 29},
};
const int kScanOfRaster[16] = {0, 1, 5, 6, 2, 4, 7, 12, 3, 8, 11, 13, 9, 10, 14, 15};

int MiOfRaster(int r) {
  return ((r % 2) != 0 ? 1 : 0) + (((r / 4) % 2) != 0 ? 1 : 0);
}

int64_t Sat29(int64_t v) {
  if (v > 268435455LL) return 268435455LL;
  if (v < -268435456LL) return -268435456LL;
  return v;
}

int64_t SignExtend29(uint64_t raw) {
  int64_t v = static_cast<int64_t>(raw & 0x1FFFFFFFULL);
  if (v & 0x10000000LL) v -= 0x20000000LL;
  return v;
}

uint64_t MaskOf(int width) {
  return width >= 64 ? ~0ULL : ((1ULL << width) - 1ULL);
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

// Specializations for plain uint64_t ports if any.
uint64_t GetField(uint64_t field, int bit_off, int width) {
  return (field >> bit_off) & MaskOf(width);
}
void SetField(uint64_t& field, int bit_off, int width, uint64_t value) {
  field &= ~(MaskOf(width) << bit_off);
  field |= (value & MaskOf(width)) << bit_off;
}

struct Failure {
  const char* what;
  int index;
  int qp;
  int64_t got;
  int64_t want;
};

void Tick(Vh264_transform_dequant_tb_top* dut) {
  dut->clk = 0;
  dut->eval();
  dut->clk = 1;
  dut->eval();
}

void PulseStart(Vh264_transform_dequant_tb_top* dut, int which) {
  // which: 1=ldc, 2=seq, 3=both
  dut->ldc_start = (which & 1) ? 1 : 0;
  dut->seq_start = (which & 2) ? 1 : 0;
  Tick(dut);
  dut->ldc_start = 0;
  dut->seq_start = 0;
}

bool WaitDone(Vh264_transform_dequant_tb_top* dut, int which, int max_cyc) {
  // done is a 1-cycle pulse; ldc (~18 cyc) and seq (~21 cyc) finish on
  // different cycles, so latch each independently.
  bool saw_ldc = !(which & 1);
  bool saw_seq = !(which & 2);
  for (int i = 0; i < max_cyc; ++i) {
    Tick(dut);
    if (dut->ldc_done) saw_ldc = true;
    if (dut->seq_done) saw_seq = true;
    if (saw_ldc && saw_seq) return true;
  }
  return false;
}

}  // namespace

int main(int argc, char** argv) {
  Verilated::commandArgs(argc, argv);
  auto* dut = new Vh264_transform_dequant_tb_top;

  std::mt19937 rng(0xC0FFEE);
  std::vector<Failure> failures;
  long checks = 0;

  const int kMags[] = {1, 2, 3, 7, 15, 255, 2047, 8191, 26000, 32767};

  dut->clk = 0;
  dut->reset = 1;
  dut->ldc_start = 0;
  dut->seq_start = 0;
  for (int i = 0; i < 4; ++i) Tick(dut);
  dut->reset = 0;
  Tick(dut);

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

      uint8_t win[81];
      for (int i = 0; i < 81; ++i) win[i] = static_cast<uint8_t>(rng() & 0xFF);
      for (int i = 0; i < 81; ++i) SetField(dut->refwin_flat, 8 * i, 8, win[i]);
      const int fx = static_cast<int>(rng() % 8u);
      const int fy = static_cast<int>(rng() % 8u);
      dut->frac_x = fx;
      dut->frac_y = fy;

      // Combo paths settle immediately.
      dut->eval();

      // ---- h264_dequant4x4_flex --------------------------------------
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

      // ---- h264_chroma_epel_block_8x8 --------------------------------
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

      // Parallel idct residual golden (from idct_flat combo on flex).
      int64_t idct_want[16];
      for (int i = 0; i < 16; ++i)
        idct_want[i] = SignExtend29(GetField(dut->idct_flat, 29 * i, 29));

      // ---- sequential units: start both, wait both ------------------
      PulseStart(dut, 3);
      if (!WaitDone(dut, 3, 64)) {
        failures.push_back({"seq_timeout", 0, qp, 0, 1});
        break;
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
          const int64_t want = Sat29((((f[i] * ls) << qdiv) + 32) >> 6);
          const int64_t got = SignExtend29(GetField(dut->ldc_flat, 29 * i, 29));
          ++checks;
          if (got != want && failures.size() < 12)
            failures.push_back({"luma_dc_hadamard_inv", i, qp, got, want});
        }
      }

      // ---- h264_iq_idct_seq vs parallel flex+idct --------------------
      for (int i = 0; i < 16; ++i) {
        const int64_t got = SignExtend29(GetField(dut->seq_flat, 29 * i, 29));
        const int64_t want = idct_want[i];
        ++checks;
        if (got != want && failures.size() < 12)
          failures.push_back({"iq_idct_seq", i, qp, got, want});
      }
    }
  }

  if (!failures.empty()) {
    std::fprintf(stderr, "FAIL %zu error(s) after %ld checks\n", failures.size(), checks);
    for (const auto& f : failures)
      std::fprintf(stderr, "  %s idx=%d qp=%d got=%lld want=%lld\n", f.what, f.index,
                   f.qp, static_cast<long long>(f.got), static_cast<long long>(f.want));
    delete dut;
    return 1;
  }

  std::printf("PASS checks=%ld (flex/deq/ldc/cdc/epel/seq)\n", checks);
  delete dut;
  return 0;
}
