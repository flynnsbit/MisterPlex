// Co-sim: sticky m1_want must not starve m0 PLXD writer forever.
// Negative baseline (pre-timeout): m0_we_fire stayed at 2/5000 under sticky want.
// Positive: with M1_GRANT_TIMEOUT, m0_we_fire must exceed FLOOR.
#include "Vddr_bus_arbiter.h"
#include "verilated.h"
#include <cstdint>
#include <cstdio>
#include <memory>

static vluint64_t main_time = 0;
double sc_time_stamp() { return (double)main_time; }

static void tick(Vddr_bus_arbiter* t) {
  t->clk = 0;
  t->clk_m1 = 0;
  t->eval();
  main_time++;
  t->clk = 1;
  t->clk_m1 = 1;
  t->eval();
  main_time++;
}

int main(int argc, char** argv) {
  Verilated::commandArgs(argc, argv);
  auto top = std::make_unique<Vddr_bus_arbiter>();
  auto* t = top.get();

  t->reset = 1;
  t->m0_rd = t->m0_we = 0;
  t->m0_burstcnt = 1;
  t->m0_addr = 0x3007F128u >> 3;
  t->m0_din = 0x504C5844ull;
  t->m0_be = 0xFF;
  t->m1_rd = t->m1_we = 0;
  t->m1_burstcnt = 1;
  t->m1_addr = 0;
  t->m1_din = 0;
  t->m1_be = 0;
  t->m1_want = 1; // sticky want, never commands
  t->DDRAM_BUSY = 0;
  t->DDRAM_DOUT = 0;
  t->DDRAM_DOUT_READY = 0;
  for (int i = 0; i < 16; i++) tick(t);
  t->reset = 0;
  for (int i = 0; i < 8; i++) tick(t);

  uint64_t m0_we_fire = 0;
  uint64_t busy_cycles = 0;
  const int CYCLES = 5000;

  for (int i = 0; i < CYCLES; i++) {
    const int try_we = !t->m0_busy ? 1 : 0;
    t->m0_we = try_we;
    t->m0_rd = 0;
    t->m1_rd = 0;
    t->m1_we = 0;
    t->m1_want = 1;
    t->DDRAM_BUSY = 0;
    tick(t);
    if (t->m0_busy) busy_cycles++;
    // Count accepted writes: WE presented to DDR while not busy and m0 selected
    if (try_we && t->DDRAM_WE && !t->m0_busy) m0_we_fire++;
    t->m0_we = 0;
  }

  const uint64_t FLOOR = 50;
  std::printf("RESULT m0_we_fire=%llu busy_cycles=%llu floor=%llu\n",
              (unsigned long long)m0_we_fire,
              (unsigned long long)busy_cycles,
              (unsigned long long)FLOOR);

  if (m0_we_fire < FLOOR) {
    std::printf("FAIL: m0 PLXD path starved (fire=%llu < %llu) — sticky m1 grant\n",
                (unsigned long long)m0_we_fire, (unsigned long long)FLOOR);
    return 1;
  }
  std::printf("PASS: m0 not starved under sticky m1_want (fire=%llu)\n",
              (unsigned long long)m0_we_fire);
  return 0;
}
