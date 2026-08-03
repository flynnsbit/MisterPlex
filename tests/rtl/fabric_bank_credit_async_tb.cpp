// Red-before-green: async producer must not doorbell mid-fill.
#include "Vfabric_bank_credit_async_tb_top.h"
#include "verilated.h"
#include <cstdio>

static void tick(Vfabric_bank_credit_async_tb_top* t) {
    t->clk = 0; t->eval();
    t->clk = 1; t->eval();
}

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    auto* top = new Vfabric_bank_credit_async_tb_top;
    int fails = 0;
    top->reset = 1; top->claim_req = 0; top->commit_pulse = 0;
    top->ext_payload_visible_pulse = 0; top->ext_doorbell_pulse = 0;
    top->vsync_swap = 0;
    top->commit_bank = 0; top->ext_visible_bank = 0; top->ext_doorbell_bank = 0;
    for (int i = 0; i < 4; ++i) tick(top);
    top->reset = 0;
    for (int i = 0; i < 2; ++i) tick(top);

    // free_mask should be 0b10 after reset (bank1 free)
    if (top->free_mask != 2) {
        std::fprintf(stderr, "FAIL reset free_mask=%u\n", (unsigned)top->free_mask);
        ++fails;
    }

    // Claim
    top->claim_req = 1;
    tick(top);
    top->claim_req = 0;
    if (!top->claim_ack) {
        // ack is same-cycle registered; sample next
        tick(top);
    }
    // Drain claim_ack cycle
    unsigned bank = (unsigned)top->claim_bank;
    for (int i = 0; i < 3; ++i) tick(top);
    if (top->filling_mask == 0) {
        std::fprintf(stderr, "FAIL filling_mask after claim=0 bank=%u free=%u\n",
                     bank, (unsigned)top->free_mask);
        ++fails;
    }

    // NEG: doorbell while still filling (no visible)
    top->ext_doorbell_bank = bank & 1;
    top->ext_doorbell_pulse = 1;
    tick(top);
    top->ext_doorbell_pulse = 0;
    tick(top);
    if (!top->err_doorbell_before_visible) {
        std::fprintf(stderr, "FAIL expected err_doorbell_before_visible\n");
        ++fails;
    }

    // Reset errors path: new claim after vsync not needed — use visible then doorbell
    // Re-claim: free_mask may be 0; force reset for clean POS path
    top->reset = 1;
    for (int i = 0; i < 4; ++i) tick(top);
    top->reset = 0;
    for (int i = 0; i < 2; ++i) tick(top);

    top->claim_req = 1; tick(top); top->claim_req = 0;
    for (int i = 0; i < 3; ++i) tick(top);
    bank = 1; // product free bank1 first
    if (!(top->filling_mask & 0x2)) {
        // accept whichever was claimed
        bank = (top->filling_mask & 1) ? 0 : 1;
    }

    // Chunks: stay in filling (no RTL chunk counter — host order tracks that)
    for (int i = 0; i < 5; ++i) tick(top);

    // POS: payload visible then doorbell
    top->ext_visible_bank = bank & 1;
    top->ext_payload_visible_pulse = 1;
    tick(top);
    top->ext_payload_visible_pulse = 0;
    tick(top);
    if (!(top->visible_mask & (1u << (bank & 1)))) {
        std::fprintf(stderr, "FAIL visible_mask after pulse mask=%u bank=%u\n",
                     (unsigned)top->visible_mask, bank);
        ++fails;
    }
    if (top->filling_mask & (1u << (bank & 1))) {
        std::fprintf(stderr, "FAIL still filling after visible\n");
        ++fails;
    }

    top->ext_doorbell_bank = bank & 1;
    top->ext_doorbell_pulse = 1;
    tick(top);
    top->ext_doorbell_pulse = 0;
    for (int i = 0; i < 2; ++i) tick(top);
    if (!top->swap_pending) {
        std::fprintf(stderr, "FAIL swap_pending after ordered doorbell\n");
        ++fails;
    }
    if (top->free_mask != 0) {
        std::fprintf(stderr, "FAIL free_mask after commit=%u\n", (unsigned)top->free_mask);
        ++fails;
    }

    // Vsync frees old disp
    top->vsync_swap = 1;
    for (int i = 0; i < 3; ++i) tick(top);
    top->vsync_swap = 0;
    for (int i = 0; i < 3; ++i) tick(top);
    if (top->free_mask == 0) {
        std::fprintf(stderr, "FAIL free_mask still 0 after vsync\n");
        ++fails;
    }
    if (top->frames_done < 1) {
        std::fprintf(stderr, "FAIL frames_done\n");
        ++fails;
    }

    // host_bank_ingest_credit dual-check via separate sim not required here

    if (fails) {
        std::fprintf(stderr, "fabric_bank_credit_async_tb: %d fails\n", fails);
        delete top;
        return 1;
    }
    std::printf("fabric_bank_credit_async_tb: OK neg_doorbell_midfill=1 ordered_dma=1 vsync=1\n");
    delete top;
    return 0;
}
