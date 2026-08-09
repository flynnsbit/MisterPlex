#include "Vh264_rbsp_window_tb.h"
#include "verilated.h"
#include <cstdio>
#include <cstdint>

static void tick(Vh264_rbsp_window_tb& t) {
  t.clk = 0; t.eval();
  t.clk = 1; t.eval();
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

  for (int i = 0; i < 80; i++) {
    t.wr_en = 1; t.wr_data = (uint8_t)i; t.wr_end = (i == 79);
    tick(t);
    t.wr_en = 0; t.wr_end = 0;
  }
  tick(t);
  int errs = 0;
  if (t.length != 80) { printf("FAIL length=%u\n", t.length); errs++; }

  t.req_valid = 1; t.req_offset = 0; tick(t); t.req_valid = 0;
  int wait = 0;
  while (!t.window_valid && wait < 40) { tick(t); wait++; }
  if (!t.window_valid || t.window_base != 0) {
    printf("FAIL base0 valid=%u base=%u wait=%d\n", t.window_valid, t.window_base, wait);
    errs++;
  }
  if (t.window0 != 0 || t.window1 != 1 || t.window16 != 16 || t.window63 != 63) {
    printf("FAIL base0 bytes %u %u %u %u\n", t.window0, t.window1, t.window16, t.window63);
    errs++;
  }

  t.req_valid = 1; t.req_offset = 16; tick(t); t.req_valid = 0;
  wait = 0;
  while (!(t.window_valid && t.window_base == 16) && wait < 40) { tick(t); wait++; }
  if (!(t.window_valid && t.window_base == 16)) {
    printf("FAIL base16 valid=%u base=%u wait=%d\n", t.window_valid, t.window_base, wait);
    errs++;
  }
  if (t.window0 != 16 || t.window1 != 17 || t.window16 != 32 || t.window63 != 79) {
    printf("FAIL base16 bytes %u %u %u %u\n", t.window0, t.window1, t.window16, t.window63);
    errs++;
  }

  if (errs == 0) printf("OK h264_rbsp_window sequential fill base0/base16\n");
  else printf("FAIL h264_rbsp_window errs=%d\n", errs);
  return errs ? 1 : 0;
}
