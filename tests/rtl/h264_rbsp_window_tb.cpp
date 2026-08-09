#include "Vh264_rbsp_window_tb.h"
#include "verilated.h"
#include <cstdio>
#include <cstdint>

static void tick(Vh264_rbsp_window_tb& t) {
  t.clk = 0; t.eval();
  t.clk = 1; t.eval();
}

static int check_base(Vh264_rbsp_window_tb& t, uint16_t base, const char* label) {
  t.req_valid = 1; t.req_offset = base; tick(t); t.req_valid = 0;
  int wait = 0;
  while (!(t.window_valid && t.window_base == base) && wait < 50) { tick(t); wait++; }
  int errs = 0;
  if (!(t.window_valid && t.window_base == base)) {
    printf("FAIL %s valid=%u base=%u wait=%d\n", label, (unsigned)t.window_valid, (unsigned)t.window_base, wait);
    return 1;
  }
  // window[k] should equal (base + k) & 0xFF for k where base+k < written length
  uint8_t exp0 = (uint8_t)(base);
  uint8_t exp1 = (uint8_t)(base + 1);
  uint8_t exp2 = (uint8_t)(base + 2);
  uint8_t exp3 = (uint8_t)(base + 3);
  uint8_t exp16 = (base + 16 < 128) ? (uint8_t)(base + 16) : 0;
  uint8_t exp63 = (base + 63 < 128) ? (uint8_t)(base + 63) : 0;
  if (t.window0 != exp0 || t.window1 != exp1 || t.window2 != exp2 || t.window3 != exp3) {
    printf("FAIL %s w[0..3]=%u,%u,%u,%u exp=%u,%u,%u,%u\n", label,
      (unsigned)t.window0, (unsigned)t.window1, (unsigned)t.window2, (unsigned)t.window3,
      exp0, exp1, exp2, exp3);
    errs++;
  }
  if (t.window16 != exp16) {
    printf("FAIL %s w[16]=%u exp=%u\n", label, (unsigned)t.window16, exp16);
    errs++;
  }
  if (t.window63 != exp63) {
    printf("FAIL %s w[63]=%u exp=%u\n", label, (unsigned)t.window63, exp63);
    errs++;
  }
  return errs;
}

int main(int argc, char** argv) {
  Verilated::commandArgs(argc, argv);
  Vh264_rbsp_window_tb t;
  t.wr_clear = 0; t.wr_en = 0; t.wr_end = 0; t.wr_data = 0;
  t.req_valid = 0; t.req_offset = 0;
  t.reset = 1;
  for (int i = 0; i < 4; i++) tick(t);
  t.reset = 0; tick(t);
  t.wr_clear = 1; tick(t); t.wr_clear = 0; tick(t);

  // Write 128 bytes: value == address
  for (int i = 0; i < 128; i++) {
    t.wr_en = 1; t.wr_data = (uint8_t)i; t.wr_end = (i == 127);
    tick(t);
    t.wr_en = 0; t.wr_end = 0;
  }
  tick(t);
  int errs = 0;
  if (t.length != 128) { printf("FAIL length=%u\n", (unsigned)t.length); errs++; }

  // Aligned bases
  errs += check_base(t, 0, "base0");
  errs += check_base(t, 16, "base16");

  // Unaligned bases (cross word boundary)
  errs += check_base(t, 3, "base3");
  errs += check_base(t, 37, "base37");
  errs += check_base(t, 5, "base5");
  errs += check_base(t, 61, "base61");

  if (errs == 0) printf("OK h264_rbsp_window fill: aligned + unaligned (base0/3/5/16/37/61)\n");
  else printf("FAIL h264_rbsp_window errs=%d\n", errs);
  return errs ? 1 : 0;
}
