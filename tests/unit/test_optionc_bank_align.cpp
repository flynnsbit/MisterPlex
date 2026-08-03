// Option-C bank alignment FACTS only — no causal claim about copy-rate anomaly.
// Parent measured ~15 ms @0x30200000 vs ~21 ms @0x30300000; cause unknown.
#include "libmisterplex/bank_producer_order.hpp"
#include <cstdio>

using namespace misterplex;
static int fails = 0;
#define CHECK(c) do { if (!(c)) { std::fprintf(stderr,"FAIL %s:%d %s\n",__FILE__,__LINE__,#c); ++fails; } } while(0)

int main() {
    const auto f = optionCBankAlignFacts();
    CHECK(f.bank0 == 0x30180000u);
    CHECK(f.bank1 == 0x30300000u);
    CHECK(f.stride == 0x00180000u);
    CHECK(f.frame_bytes == 1382400u);

    // Page (4 KiB) aligned
    CHECK(alignMod(f.bank0, 4096) == 0);
    CHECK(alignMod(f.bank1, 4096) == 0);
    // 64-byte (cache line / AXI) aligned
    CHECK(alignMod(f.bank0, 64) == 0);
    CHECK(alignMod(f.bank1, 64) == 0);
    // 1 MiB
    CHECK(alignMod(f.bank0, 0x100000u) == 0x80000u); // NOT 1MiB-aligned
    CHECK(alignMod(f.bank1, 0x100000u) == 0);         // IS 1MiB-aligned
    // 2 MiB
    CHECK(alignMod(f.bank0, 0x200000u) == 0x180000u);
    CHECK(alignMod(f.bank1, 0x200000u) == 0x100000u);
    // Parent comparison address 0x30200000 is 2MiB-aligned
    CHECK(alignMod(0x30200000u, 0x200000u) == 0);

    // Frame span crosses 1MiB boundary from bank1 start?
    // bank1=0x30300000, +1382400=0x30451800 — crosses 0x30400000 (1MiB)
    CHECK(rangeCrossesBoundary(f.bank1, f.frame_bytes, 0x100000u));
    CHECK(rangeCrossesBoundary(f.bank0, f.frame_bytes, 0x100000u));
    // 0x30200000 + 1382400 = 0x30351800 — also crosses 0x30300000
    CHECK(rangeCrossesBoundary(0x30200000u, f.frame_bytes, 0x100000u));

    // Doorbell page after bank1 end
    CHECK(f.bank1 + f.frame_bytes <= 0x3047F000u);
    // PL330 scratch after triple map
    CHECK(0x30600000u >= f.bank0 + 3u * f.stride);

    if (fails) { std::fprintf(stderr,"test_optionc_bank_align: %d fails\n", fails); return 1; }
    std::printf("test_optionc_bank_align: OK facts bank0=0x%08x bank1=0x%08x\n",
                f.bank0, f.bank1);
    std::printf("  bank0_mod_1MiB=0x%x bank1_mod_1MiB=0x%x addr302_mod_2MiB=0\n",
                alignMod(f.bank0, 0x100000u), alignMod(f.bank1, 0x100000u));
    std::printf("  PARENT_MEASURE: ddr_write_bench same len @ bank0, bank1, 0x30200000\n");
    std::printf("  (do not attribute 15 vs 21 ms without that A/B)\n");
    return 0;
}
