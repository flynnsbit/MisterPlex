#include "libmisterplex/bank_producer_order.hpp"
#include <cstdio>

using namespace misterplex;
static int fails = 0;
#define CHECK(c) do { if (!(c)) { std::fprintf(stderr,"FAIL %s:%d %s\n",__FILE__,__LINE__,#c); ++fails; } } while(0)

int main() {
    // NEG doorbell before payload
    {
        BankProducerOrder o;
        CHECK(o.beginFill(1, /*free_mask=*/0b10));
        CHECK(o.noteChunk(4096));
        CHECK(o.noteChunk(4096));
        CHECK(!o.mayRingDoorbell());
        CHECK(!o.markDoorbellRung());
        CHECK(o.markPayloadVisible(8192));
        CHECK(o.mayRingDoorbell());
        CHECK(o.markDoorbellRung());
        CHECK(o.phase() == BankProducerPhase::DoorbellRung);
    }
    // NEG incomplete mark visible
    {
        BankProducerOrder o;
        CHECK(o.beginFill(1, 0b10));
        CHECK(o.noteChunk(100));
        CHECK(!o.markPayloadVisible(1382400u));
        CHECK(o.phase() == BankProducerPhase::Failed);
    }
    // NEG no credit
    {
        BankProducerOrder o;
        CHECK(!o.beginFill(0, /*free=*/0b10)); // bank0 not free
        CHECK(o.phase() == BankProducerPhase::Failed ||
              o.phase() == BankProducerPhase::AwaitCredit);
    }
    // Fabric drain path
    {
        BankProducerOrder o;
        CHECK(o.beginFill(1, 0b10));
        CHECK(o.markFabricDrainDone());
        CHECK(o.markDoorbellRung());
        CHECK(o.markRetired());
        CHECK(o.phase() == BankProducerPhase::Idle);
    }
    // Agrees with fabric_bank_credit.hpp Option-C
    CHECK(kFabric720pPhysBase == 0x30180000u);
    CHECK(kFabric720pDoorbellPhys == 0x3047F000u);
    CHECK(fabric720pBankPhys(1) == 0x30300000u);

    if (fails) { std::fprintf(stderr,"test_bank_producer_order: %d fails\n", fails); return 1; }
    std::printf("test_bank_producer_order: OK neg_midfill=1 chunked=1 fabric_drain=1\n");
    return 0;
}
