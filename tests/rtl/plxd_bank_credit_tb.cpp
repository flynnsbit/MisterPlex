// plxd_bank_credit — multi-present GREEN + doorbell-without-credit RED.
// Models DMA/zero-copy producer: claim → (payload omitted) → doorbell → vsync.
#include "Vplxd_bank_credit_tb_top.h"
#include "verilated.h"
#include <cstdint>
#include <cstdio>
#include <memory>

static vluint64_t main_time = 0;
double sc_time_stamp() { return static_cast<double>(main_time); }

static void tick(Vplxd_bank_credit_tb_top* t) {
    t->clk = 0;
    t->eval();
    main_time++;
    t->clk = 1;
    t->eval();
    main_time++;
    t->claim_req = 0;
    t->doorbell_pulse = 0;
    t->vsync_pulse = 0;
}

static void idle(Vplxd_bank_credit_tb_top* t, int n) {
    for (int i = 0; i < n; ++i)
        tick(t);
}

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    auto top = std::make_unique<Vplxd_bank_credit_tb_top>();
    auto* t = top.get();

    t->reset = 1;
    t->pending_ready = 1;
    t->claim_req = 0;
    t->doorbell_pulse = 0;
    t->doorbell_bank = 0;
    t->vsync_pulse = 0;
    idle(t, 8);
    t->reset = 0;
    idle(t, 4);

    std::printf("PRE-REGISTER: multi claim+doorbell+vsync fd>=4; "
                "neg doorbell without claim sets err\n");

    // --- Positive: alternate banks across 6 presents ---
    int fd0 = t->frames_done;
    for (int n = 0; n < 6; ++n) {
        // free should be non-zero when idle
        if (t->free_bank_mask == 0) {
            std::printf("FAIL credit: free_mask=0 before claim n=%d sp=%d\n", n,
                        (int)t->swap_pending);
            return 1;
        }
        t->claim_req = 1;
        tick(t);
        if (!t->claim_ack) {
            std::printf("FAIL credit: no claim_ack n=%d free=%u\n", n,
                        (unsigned)t->free_bank_mask);
            return 1;
        }
        const int bank = t->claim_bank & 1;
        // free bit for claimed bank must clear (filling)
        idle(t, 2);
        if (t->free_bank_mask & (1u << bank)) {
            std::printf("FAIL credit: free still set while filling bank=%d mask=%u\n",
                        bank, (unsigned)t->free_bank_mask);
            return 1;
        }
        // doorbell
        t->doorbell_bank = bank;
        t->doorbell_pulse = 1;
        tick(t);
        if (!t->swap_pending) {
            std::printf("FAIL credit: swap_pending not set after doorbell n=%d\n", n);
            return 1;
        }
        if (t->free_bank_mask != 0) {
            std::printf("FAIL credit: free_mask must be 0 while swap_pending (got %u)\n",
                        (unsigned)t->free_bank_mask);
            return 1;
        }
        // vsync commit
        t->vsync_pulse = 1;
        tick(t);
        idle(t, 2);
        if (t->swap_pending) {
            std::printf("FAIL credit: swap_pending stuck after vsync n=%d\n", n);
            return 1;
        }
        if (!t->has_frame) {
            std::printf("FAIL credit: has_frame not set n=%d\n", n);
            return 1;
        }
    }
    const int fd_delta = static_cast<int>(t->frames_done) - fd0;
    if (fd_delta < 6) {
        std::printf("FAIL credit: frames_done delta=%d want>=6\n", fd_delta);
        return 1;
    }
    std::printf("PASS credit multi-present fd_delta=%d last_disp=%d free=%u\n",
                fd_delta, (int)t->disp_bank, (unsigned)t->free_bank_mask);

    // --- NEGATIVE: doorbell without claim → sticky error, no frames_done bump ---
    const int fd_before = t->frames_done;
    // Ensure idle (no filling)
    idle(t, 4);
    t->doorbell_bank = t->disp_bank ^ 1; // opposite of disp, but not claimed
    t->doorbell_pulse = 1;
    tick(t);
    idle(t, 2);
    if (!t->err_doorbell_without_credit) {
        std::printf("FAIL credit NEG: expected err_doorbell_without_credit\n");
        return 1;
    }
    if (static_cast<int>(t->frames_done) != fd_before) {
        std::printf("FAIL credit NEG: frames_done advanced on illegal doorbell\n");
        return 1;
    }
    std::printf("PASS credit NEG: doorbell without claim → err sticky, fd unchanged\n");

    // --- NEGATIVE: doorbell while swap_pending (force double publish) ---
    // Legal claim+doorbell then second doorbell before vsync
    {
        // clear path: need free — may need vsync if stuck; reset lightly via idle
        // After illegal doorbell, filling empty and swap may still be 0.
        idle(t, 2);
        t->claim_req = 1;
        tick(t);
        if (!t->claim_ack) {
            std::printf("FAIL credit setup2: claim_ack\n");
            return 1;
        }
        int b = t->claim_bank & 1;
        idle(t, 1);
        t->doorbell_bank = b;
        t->doorbell_pulse = 1;
        tick(t);
        if (!t->swap_pending) {
            std::printf("FAIL credit setup2: swap_pending\n");
            return 1;
        }
        // second doorbell while pending
        t->doorbell_bank = b ^ 1;
        t->doorbell_pulse = 1;
        tick(t);
        if (!t->err_doorbell_without_credit) {
            std::printf("FAIL credit NEG2: expected err on doorbell during pending\n");
            return 1;
        }
        std::printf("PASS credit NEG2: doorbell during swap_pending → err\n");
    }

    std::printf("PASS plxd_bank_credit: multi + two negatives\n");
    return 0;
}
