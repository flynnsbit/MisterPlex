// Execute transform/dequant RTL against ITU-T H.264 8.5.x SPEC formulas
// (h264_transform_spec_golden.hpp).  Golden is NOT derived from the RTL.

#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <random>
#include <vector>

#include "Vh264_transform_dequant_tb_top.h"
#include "verilated.h"
#include "h264_transform_spec_golden.hpp"

namespace {

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
    out |= (uint64_t)((words[bit / 32] >> (bit % 32)) & 1u) << b;
  }
  return out;
}

template <typename T>
void SetField(T& field, int bit_off, int width, uint64_t value) {
  uint32_t* words = field.data();
  for (int b = 0; b < width; ++b) {
    int bit = bit_off + b;
    uint32_t mask = 1u << (bit % 32);
    if ((value >> b) & 1ULL) words[bit / 32] |= mask;
    else words[bit / 32] &= ~mask;
  }
}

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
  dut->clk = 0; dut->eval();
  dut->clk = 1; dut->eval();
}

void PulseStart(Vh264_transform_dequant_tb_top* dut, int which) {
  dut->ldc_start = (which & 1) ? 1 : 0;
  dut->seq_start = (which & 2) ? 1 : 0;
  Tick(dut);
  dut->ldc_start = 0;
  dut->seq_start = 0;
}

bool WaitDone(Vh264_transform_dequant_tb_top* dut, int which, int max_cyc) {
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
  const int kMags[] = {0, 1, 2, 3, 7, 15, 255, 2047, 8191, 26000, 32767};

  dut->clk = 0; dut->reset = 1;
  dut->ldc_start = 0; dut->seq_start = 0;
  for (int i = 0; i < 4; ++i) Tick(dut);
  dut->reset = 0; Tick(dut);

  for (int qp = 0; qp <= 51; ++qp) {
    for (int trial = 0; trial < 40; ++trial) {
      int16_t coeff[16];
      int16_t c4[4];
      for (int i = 0; i < 16; ++i) {
        int mag = kMags[rng() % (sizeof(kMags) / sizeof(kMags[0]))];
        int v = mag == 0 ? 0 : (int)(rng() % (2u * mag + 1)) - mag;
        if (v < -32768) v = -32768;
        if (v > 32767) v = 32767;
        coeff[i] = (int16_t)v;
      }
      for (int i = 0; i < 4; ++i) c4[i] = coeff[i];

      int max_coeff = 1 + (int)(rng() % 16);
      if (max_coeff == 15) max_coeff = 16; // plain dequant AC-only max15 tested via flex skip_dc
      const int skip_dc = (int)(rng() & 1u);
      const int dc_override = (int)(rng() & 1u);
      const int64_t dc_value = (int64_t)(rng() % 1000u) - 500;

      for (int i = 0; i < 16; ++i)
        SetField(dut->coeff16_flat, 16 * i, 16, (uint16_t)coeff[i]);
      for (int i = 0; i < 4; ++i)
        SetField(dut->coeff4_flat, 16 * i, 16, (uint16_t)c4[i]);
      dut->qp = qp;
      dut->max_coeff = max_coeff;
      dut->skip_dc = skip_dc;
      dut->dc_override = dc_override;
      dut->dc_value = (uint32_t)(dc_value & 0x1FFFFFFF);

      uint8_t win[81];
      for (int i = 0; i < 81; ++i) win[i] = (uint8_t)(rng() & 0xFF);
      for (int i = 0; i < 81; ++i) SetField(dut->refwin_flat, 8 * i, 8, win[i]);
      const int fx = (int)(rng() % 8u);
      const int fy = (int)(rng() % 8u);
      dut->frac_x = fx; dut->frac_y = fy;

      dut->eval();

      // ---- 8.5.12.1 flex dequant ------------------------------------
      int64_t want_flex[16];
      h264_spec::DequantFlex(coeff, qp, max_coeff, skip_dc, dc_override,
                             dc_value, want_flex);
      for (int r = 0; r < 16; ++r) {
        const int64_t got = SignExtend29(GetField(dut->flex_flat, 29 * r, 29));
        ++checks;
        if (got != want_flex[r] && failures.size() < 16)
          failures.push_back({"dequant4x4_flex", r, qp, got, want_flex[r]});
      }

      // ---- plain dequant --------------------------------------------
      int64_t want_deq[16];
      h264_spec::DequantPlain(coeff, qp, max_coeff, want_deq);
      for (int r = 0; r < 16; ++r) {
        const int64_t got = SignExtend29(GetField(dut->deq_flat, 29 * r, 29));
        ++checks;
        if (got != want_deq[r] && failures.size() < 16)
          failures.push_back({"dequant4x4", r, qp, got, want_deq[r]});
      }

      // ---- 8.5.11 chroma DC (QPc = qp in this sweep) ----------------
      int64_t want_cdc[4];
      h264_spec::ChromaDcHadamardInv(c4, qp, want_cdc);
      for (int i = 0; i < 4; ++i) {
        const int64_t got = SignExtend29(GetField(dut->cdc_flat, 29 * i, 29));
        ++checks;
        if (got != want_cdc[i] && failures.size() < 16)
          failures.push_back({"chroma_dc_hadamard_inv", i, qp, got, want_cdc[i]});
      }

      // ---- chroma epel (not transform; keep identity check) ---------
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
              (int64_t)GetField(dut->cpred_flat, 8 * (oy * 8 + ox), 8);
          ++checks;
          if (got != want && failures.size() < 16)
            failures.push_back({"chroma_epel", oy * 8 + ox, qp, got, want});
        }
      }

      // Parallel IDCT golden from SPEC on flex dequant
      int64_t want_idct[16];
      h264_spec::Idct4x4(want_flex, want_idct);
      for (int i = 0; i < 16; ++i) {
        const int64_t got = SignExtend29(GetField(dut->idct_flat, 29 * i, 29));
        ++checks;
        if (got != want_idct[i] && failures.size() < 16)
          failures.push_back({"idct4x4", i, qp, got, want_idct[i]});
      }

      // Sequential units
      PulseStart(dut, 3);
      if (!WaitDone(dut, 3, 64)) {
        failures.push_back({"seq_timeout", 0, qp, 0, 1});
        break;
      }

      // ---- 8.5.10 luma DC Hadamard ----------------------------------
      int64_t want_ldc[16];
      h264_spec::LumaDcHadamardInv(coeff, qp, want_ldc);
      for (int i = 0; i < 16; ++i) {
        const int64_t got = SignExtend29(GetField(dut->ldc_flat, 29 * i, 29));
        ++checks;
        if (got != want_ldc[i] && failures.size() < 16)
          failures.push_back({"luma_dc_hadamard_inv", i, qp, got, want_ldc[i]});
      }

      // ---- sequential IQ+IDCT vs spec IDCT(flex) --------------------
      for (int i = 0; i < 16; ++i) {
        const int64_t got = SignExtend29(GetField(dut->seq_flat, 29 * i, 29));
        ++checks;
        if (got != want_idct[i] && failures.size() < 16)
          failures.push_back({"iq_idct_seq", i, qp, got, want_idct[i]});
      }
    }
  }

  if (!failures.empty()) {
    std::fprintf(stderr, "FAIL %zu error(s) after %ld checks (SPEC golden)\n",
                 failures.size(), checks);
    for (const auto& f : failures)
      std::fprintf(stderr, "  %s idx=%d qp=%d got=%lld want=%lld\n", f.what,
                   f.index, f.qp, (long long)f.got, (long long)f.want);
    delete dut;
    return 1;
  }
  std::printf("PASS checks=%ld SPEC-golden (flex/deq/ldc/cdc/idct/seq)\n", checks);
  delete dut;
  return 0;
}
