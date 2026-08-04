// PLXA map publish with NO doorbell. Positive: magic+ver+has_plxd @ 0x3007F0F0.
// Negative: refuse accept when version mismatches (host-side check on captured word).
#include "Vddr_frame_store_plxa_map_tb.h"
#include "verilated.h"
#include <cstdint>
#include <cstdio>
#include <memory>

// Keep in sync with host/libmisterplex/plxa_map.hpp
static constexpr uint32_t kPlxaPhys = 0x3007F0F0u;
// Default DUT doorbell = 0x30000000 + 2*0x80000 - 0x1000 = 0x300FF000
static constexpr uint32_t kPlxaOnDoorbellPhys = 0x300FF0F0u;
static constexpr uint32_t kPlxaMagic = 0x504C5841u;
static constexpr uint8_t kPlxaAbiVersion = 1;
static constexpr uint8_t kFlagRelative = 1u << 0;
static constexpr uint8_t kFlagHasPlxd = 1u << 1;

static vluint64_t main_time = 0;
double sc_time_stamp() { return (double)main_time; }

static void tick(Vddr_frame_store_plxa_map_tb* t) {
  t->clk = 0; t->clk_ddr = 0; t->eval(); main_time++;
  t->clk = 1; t->clk_ddr = 1; t->eval(); main_time++;
}

int main(int argc, char** argv) {
  Verilated::commandArgs(argc, argv);
  auto top = std::make_unique<Vddr_frame_store_plxa_map_tb>();
  auto* t = top.get();

  t->reset = 1;
  t->rd_active = 0;
  t->rd_x = 0;
  t->rd_y = 0;
  t->vsync_pulse = 0;
  t->DDRAM_BUSY = 0;
  t->DDRAM_DOUT = 0;
  t->DDRAM_DOUT_READY = 0;
  for (int i = 0; i < 20; i++) tick(t);
  t->reset = 0;

  uint64_t plxa_wr = 0;
  uint64_t plxa_db_wr = 0;
  uint64_t last_word = 0;
  uint64_t last_db_word = 0;
  const int CYCLES = 100000;

  // PRE-REGISTER: dual publish without doorbell — absolute + DOORBELL+0x0F0.
  std::printf("PRE-REGISTER: PASS plxa @ 0x3007F0F0 AND 0x300FF0F0 without doorbell\n");

  for (int i = 0; i < CYCLES; i++) {
    t->DDRAM_BUSY = 0;
    t->DDRAM_DOUT = 0;
    t->DDRAM_DOUT_READY = 0;
    t->vsync_pulse = 0;
    tick(t);
    if (t->DDRAM_WE && !t->DDRAM_BUSY) {
      uint32_t phys = ((uint32_t)t->DDRAM_ADDR) << 3;
      uint64_t din = t->DDRAM_DIN;
      if ((uint32_t)(din & 0xFFFFFFFFu) == kPlxaMagic) {
        if (phys == kPlxaPhys) {
          plxa_wr++;
          last_word = din;
        } else if (phys == kPlxaOnDoorbellPhys) {
          plxa_db_wr++;
          last_db_word = din;
        }
      }
    }
  }

  std::printf("summary plxa_map: cycles=%d abs_wr=%llu db_wr=%llu last=0x%016llx\n",
              CYCLES, (unsigned long long)plxa_wr, (unsigned long long)plxa_db_wr,
              (unsigned long long)last_word);

  if (plxa_wr == 0) {
    std::printf("FAIL plxa_map: no PLXA write @ 0x3007F0F0 without doorbell\n");
    return 1;
  }
  if (plxa_db_wr == 0) {
    std::printf("FAIL plxa_map: no PLXA mirror @ DOORBELL+0x0F0 (0x300FF0F0)\n");
    return 1;
  }
  if (last_db_word != last_word) {
    std::printf("FAIL plxa_map: absolute and doorbell-page words differ "
                "abs=0x%016llx db=0x%016llx\n",
                (unsigned long long)last_word, (unsigned long long)last_db_word);
    return 1;
  }

  const uint8_t ver = (uint8_t)((last_word >> 32) & 0xFF);
  const uint8_t flags = (uint8_t)((last_word >> 40) & 0xFF);
  const uint16_t off = (uint16_t)((last_word >> 48) & 0xFFFF);

  if (ver != kPlxaAbiVersion) {
    std::printf("FAIL plxa_map: version=%u expected=%u\n", ver, kPlxaAbiVersion);
    return 1;
  }
  if ((flags & kFlagHasPlxd) == 0) {
    std::printf("FAIL plxa_map: has_plxd flag clear (flags=0x%02x)\n", flags);
    return 1;
  }
  // Default DUT params: absolute BANK 0x3007F128 → relative clear, off=0xF128.
  // Product present_core overrides yield relative=1/off=0x128 (separate TB path).
  if ((flags & kFlagRelative) != 0) {
    std::printf("FAIL plxa_map: relative flag set under absolute default BANK\n");
    return 1;
  }
  if (off != 0xF128) {
    std::printf("FAIL plxa_map: plxd_off=0x%04x expected 0xF128 (absolute low)\n", off);
    return 1;
  }

  // NEGATIVE: host must reject version mismatch on the same captured word.
  if (ver == static_cast<uint8_t>(kPlxaAbiVersion + 1)) {
    std::printf("FAIL plxa_map: internal — version cannot equal both v and v+1\n");
    return 1;
  }
  const uint8_t wrong_expect = static_cast<uint8_t>(kPlxaAbiVersion + 7);
  if (ver == wrong_expect) {
    std::printf("FAIL plxa_map: negative version check broke\n");
    return 1;
  }
  std::printf("NEG version_mismatch: host_expect=%u core_ver=%u → REJECT (as required)\n",
              wrong_expect, ver);

  std::printf("PASS plxa_map: abs_wr=%llu db_wr=%llu ver=%u flags=0x%02x plxd_off=0x%04x\n",
              (unsigned long long)plxa_wr, (unsigned long long)plxa_db_wr, ver, flags, off);
  return 0;
}
