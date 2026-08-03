// Option-C bank alignment FACTS only (geometry).
// Parent 2026-08-03 INCIDENT: bank-copy A/B (~15 vs ~21 ms) and DMA ms figures
// were measured under a rogue remote CPU burner — RETRACTED. Do not chase.
// Clean re-measure pending; alignment facts below remain true independent of rates.
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

    CHECK(alignMod(f.bank0, 4096) == 0);
    CHECK(alignMod(f.bank1, 4096) == 0);
    CHECK(alignMod(f.bank0, 64) == 0);
    CHECK(alignMod(f.bank1, 64) == 0);
    CHECK(alignMod(f.bank0, 0x100000u) == 0x80000u);
    CHECK(alignMod(f.bank1, 0x100000u) == 0);
    CHECK(alignMod(f.bank0, 0x200000u) == 0x180000u);
    CHECK(alignMod(f.bank1, 0x200000u) == 0x100000u);

    CHECK(rangeCrossesBoundary(f.bank1, f.frame_bytes, 0x100000u));
    CHECK(rangeCrossesBoundary(f.bank0, f.frame_bytes, 0x100000u));

    CHECK(f.bank1 + f.frame_bytes <= 0x3047F000u);
    CHECK(0x30600000u >= f.bank0 + 3u * f.stride);

    if (fails) { std::fprintf(stderr,"test_optionc_bank_align: %d fails\n", fails); return 1; }
    std::printf("test_optionc_bank_align: OK facts bank0=0x%08x bank1=0x%08x\n",
                f.bank0, f.bank1);
    std::printf("  bank0_mod_1MiB=0x%x bank1_mod_1MiB=0x%x\n",
                alignMod(f.bank0, 0x100000u), alignMod(f.bank1, 0x100000u));
    std::printf("  NOTE: parent bank-rate A/B RETRACTED (rogue burner); stand down\n");
    return 0;
}
