// SPI-only multi-bank present: NO PLXK doorbell ever.
// Pre-reg: PASS with STRICT_YUV_DOORBELL=1 after have_seq gate removed.
// Negative: zero start_req edges → frames_done stays 0.
#include "Vddr_frame_store_spi_kick_tb.h"
#include "verilated.h"
#include <cstdint>
#include <cstdio>
#include <memory>
#include <vector>

static vluint64_t main_time = 0;
double sc_time_stamp() { return (double)main_time; }

static constexpr uint32_t kBase = 0x30000000u;
static constexpr uint32_t kStride = 65536u;
static constexpr uint32_t kPlxd = 0x3001F128u;
static constexpr uint32_t kMagicD = 0x504C5844u;
static constexpr int kW = 80, kH = 48, kDispW = 64, kPresentX = 4;
static constexpr int kActH = 40, kVBlank = 48, kHTotal = 160;
static constexpr int kYQ = kW / 8, kCQ = kW / 16;
static constexpr int kUQ = (kW * kH) / 8;
static constexpr int kVQ = kUQ + (kW * kH) / 32;

static void tick(Vddr_frame_store_spi_kick_tb* t) {
  t->clk = 0; t->clk_ddr = 0; t->eval(); main_time++;
  t->clk = 1; t->clk_ddr = 1; t->eval(); main_time++;
}

static uint64_t pack8(uint8_t v) {
  uint64_t q = 0;
  for (int i = 0; i < 8; ++i) q |= (uint64_t)v << (8 * i);
  return q;
}

int main(int argc, char** argv) {
  Verilated::commandArgs(argc, argv);
  auto top = std::make_unique<Vddr_frame_store_spi_kick_tb>();
  auto* t = top.get();

  std::vector<uint64_t> mem((2 * kStride) / 8, 0);
  auto fill = [&](int bank, uint8_t y) {
    const uint32_t base = (bank * kStride) / 8;
    for (int line = 0; line < kH; ++line)
      for (int q = 0; q < kYQ; ++q)
        mem[base + line * kYQ + q] = pack8(y);
    for (int line = 0; line < kH / 2; ++line)
      for (int q = 0; q < kCQ; ++q) {
        mem[base + kUQ + line * kCQ + q] = pack8(128);
        mem[base + kVQ + line * kCQ + q] = pack8(128);
      }
  };
  fill(0, 40);
  fill(1, 200);

  t->reset = 1;
  t->rd_active = 0; t->rd_x = 0; t->rd_y = 0;
  t->start_req = 0; t->bank_sel = 0; t->vsync_pulse = 0;
  t->DDRAM_BUSY = 0; t->DDRAM_DOUT = 0; t->DDRAM_DOUT_READY = 0;
  for (int i = 0; i < 20; i++) tick(t);
  t->reset = 0;

  int rd_delay = -1, rd_left = 0;
  uint32_t rd_base = 0;
  auto service_ddr = [&]() {
    t->DDRAM_BUSY = 0;
    t->DDRAM_DOUT_READY = 0;
    t->DDRAM_DOUT = 0;
    // Never return PLXK — pure SPI path
    if (rd_delay > 0) {
      rd_delay--;
      if (rd_delay == 0 && rd_left > 0) {
        t->DDRAM_DOUT_READY = 1;
        t->DDRAM_DOUT = mem[rd_base];
        rd_base++;
        rd_left--;
        if (rd_left > 0) rd_delay = 1;
      }
    }
    if (t->DDRAM_RD && !t->DDRAM_BUSY) {
      uint32_t phys = ((uint32_t)t->DDRAM_ADDR) << 3;
      uint32_t idx = (phys - kBase) / 8;
      int burst = t->DDRAM_BURSTCNT ? t->DDRAM_BURSTCNT : 1;
      if (idx < mem.size()) {
        rd_base = idx;
        rd_left = burst;
        rd_delay = 2;
      }
    }
  };

  auto pulse_spi = [&](int bank) {
    t->bank_sel = bank & 1;
    t->start_req = !t->start_req; // edge
    for (int i = 0; i < 4; i++) { service_ddr(); tick(t); }
  };

  auto run_frame = [&](bool with_spi, int bank) {
    // active lines
    for (int y = 0; y < kActH; y++) {
      for (int x = 0; x < kHTotal; x++) {
        t->rd_active = (x >= kPresentX && x < kPresentX + kDispW);
        t->rd_x = t->rd_active ? (x) : 0;
        t->rd_y = y;
        t->vsync_pulse = 0;
        service_ddr();
        tick(t);
      }
    }
    // vblank + one vsync at start of blank
    t->rd_active = 0;
    t->vsync_pulse = 1;
    service_ddr(); tick(t);
    t->vsync_pulse = 0;
    if (with_spi) pulse_spi(bank);
    for (int y = 0; y < kVBlank; y++) {
      for (int x = 0; x < kHTotal; x++) {
        service_ddr();
        tick(t);
      }
    }
  };

  std::printf("PRE-REGISTER: SPI-only multi-kick PASS frames_done>=4; neg no-kick fd=0\n");

  // NEGATIVE: many frames, no SPI kick
  uint16_t fd0 = 0;
  for (int f = 0; f < 8; f++) run_frame(false, 0);
  fd0 = t->frames_done;
  if (fd0 != 0) {
    std::printf("FAIL neg: frames_done=%u without SPI (expected 0)\n", fd0);
    return 1;
  }
  std::printf("NEG OK: no SPI → frames_done=0\n");

  // POSITIVE: alternate banks via SPI only
  for (int f = 0; f < 12; f++) {
    // kick early in vblank of previous was done; kick then scan
    pulse_spi(f & 1);
    run_frame(false, 0); // scan+vsync without second kick this frame
  }

  uint16_t fd = t->frames_done;
  uint64_t plxd_wr = 0, last = 0;
  // drain a bit more for mailbox
  for (int i = 0; i < 5000; i++) { service_ddr(); tick(t);
    if (t->DDRAM_WE && !t->DDRAM_BUSY) {
      uint32_t phys = ((uint32_t)t->DDRAM_ADDR) << 3;
      if (phys == kPlxd && (uint32_t)(t->DDRAM_DIN & 0xffffffffu) == kMagicD) {
        plxd_wr++;
        last = t->DDRAM_DIN;
      }
    }
  }

  std::printf("summary spi_kick: frames_done=%u has_frame=%u plxd_wr=%llu last=0x%016llx doorbell_ok=%u\n",
              fd, (unsigned)t->has_frame, (unsigned long long)plxd_wr,
              (unsigned long long)last, (unsigned)t->doorbell_ok);

  if (fd < 4) {
    std::printf("FAIL spi_kick: frames_done=%u < 4 (SPI path not consuming banks)\n", fd);
    return 1;
  }
  if (!t->has_frame) {
    std::printf("FAIL spi_kick: has_frame still 0\n");
    return 1;
  }
  if (plxd_wr == 0) {
    std::printf("FAIL spi_kick: PLXD never written\n");
    return 1;
  }
  uint16_t plxd_fd = (uint16_t)((last >> 48) & 0xffff);
  if (plxd_fd == 0) {
    std::printf("FAIL spi_kick: PLXD frames_done field still 0\n");
    return 1;
  }
  std::printf("PASS spi_kick: SPI-only multi-present fd=%u plxd_fd=%u wr=%llu\n",
              fd, plxd_fd, (unsigned long long)plxd_wr);
  return 0;
}
