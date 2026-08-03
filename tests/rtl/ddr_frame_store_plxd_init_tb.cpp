// D: NO doorbell ever rung. Assert PLXD write @ 0x3007F128 with free_bank_mask!=0.
#include "Vddr_frame_store_plxd_init_tb.h"
#include "verilated.h"
#include <cstdint>
#include <cstdio>
#include <memory>

static vluint64_t main_time = 0;
double sc_time_stamp() { return (double)main_time; }

static void tick(Vddr_frame_store_plxd_init_tb* t) {
  t->clk = 0; t->clk_ddr = 0; t->eval(); main_time++;
  t->clk = 1; t->clk_ddr = 1; t->eval(); main_time++;
}

int main(int argc, char** argv) {
  Verilated::commandArgs(argc, argv);
  auto top = std::make_unique<Vddr_frame_store_plxd_init_tb>();
  auto* t = top.get();

  const uint32_t PLXD_ADDR_WORD = 0x3007F128u >> 3; // dword index on 64-bit bus
  const uint32_t MAGIC_D = 0x504C5844u;

  t->reset = 1;
  t->rd_active = 0;
  t->rd_x = 0;
  t->rd_y = 0;
  t->vsync_pulse = 0;
  t->DDRAM_BUSY = 0;
  t->DDRAM_DOUT = 0;          // never return PLXK doorbell magic
  t->DDRAM_DOUT_READY = 0;
  for (int i = 0; i < 20; i++) tick(t);
  t->reset = 0;

  uint64_t any_we = 0, plxd_main_wr = 0, doorbell_rd = 0;
  uint32_t last_free = 0, last_disp = 0, last_sp = 0, last_fd = 0;
  const int CYCLES = 200000;

  for (int i = 0; i < CYCLES; i++) {
    t->DDRAM_BUSY = 0;
    t->DDRAM_DOUT = 0;
    t->DDRAM_DOUT_READY = 0;
    t->vsync_pulse = (i % 4096 == 2000) ? 1 : 0; // visual refresh only; no doorbell
    tick(t);

    if (t->DDRAM_RD && !t->DDRAM_BUSY) {
      // Count doorbell-region reads; never satisfy with PLXK
      uint32_t phys = ((uint32_t)t->DDRAM_ADDR) << 3;
      if ((phys & 0xFFFFF000u) == 0x300FF000u) doorbell_rd++;
    }
    if (t->DDRAM_WE && !t->DDRAM_BUSY) {
      any_we++;
      uint32_t phys = ((uint32_t)t->DDRAM_ADDR) << 3;
      uint64_t din = t->DDRAM_DIN;
      uint32_t magic = (uint32_t)(din & 0xFFFFFFFFu);
      if (phys == 0x3007F128u && magic == MAGIC_D) {
        plxd_main_wr++;
        last_free = (uint32_t)((din >> 32) & 0x3u);
        last_disp = (uint32_t)((din >> 34) & 0x1u);
        last_sp   = (uint32_t)((din >> 35) & 0x1u);
        last_fd   = (uint32_t)((din >> 48) & 0xFFFFu);
      }
    }
  }

  std::printf("PRE-REGISTER was: PASS on main if unconditional PLXD publish; "
              "FAIL if only doorbell-gated\n");
  std::printf("summary plxd_init: cycles=%d any_we=%llu plxd_main_wr=%llu "
              "doorbell_rd=%llu last_free=%u last_disp=%u last_sp=%u last_fd=%u "
              "has_frame=%u\n",
              CYCLES,
              (unsigned long long)any_we,
              (unsigned long long)plxd_main_wr,
              (unsigned long long)doorbell_rd,
              last_free, last_disp, last_sp, last_fd,
              (unsigned)t->has_frame);

  // Negative: must not claim success with zero writes
  if (plxd_main_wr == 0) {
    std::printf("FAIL plxd_init: no PLXD write @ 0x3007F128 without doorbell "
                "(doorbell_rd=%llu)\n", (unsigned long long)doorbell_rd);
    return 1;
  }
  if (last_free == 0) {
    std::printf("FAIL plxd_init: free_bank_mask=0 (ARM cannot learn a free bank)\n");
    return 1;
  }
  std::printf("PASS plxd_init: unconditional PLXD @ 0x3007F128 writes=%llu free_mask=%u\n",
              (unsigned long long)plxd_main_wr, last_free);
  return 0;
}
