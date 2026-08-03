// Verilator TB for plex_chrome_ddr_loader — seqlock + concurrent + retained.
#include "Vplex_chrome_ddr_loader_tb.h"
#include "verilated.h"

#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <vector>

static vluint64_t main_time = 0;
double sc_time_stamp() { return static_cast<double>(main_time); }

static void tick(Vplex_chrome_ddr_loader_tb* t) {
    t->clk = 0;
    t->eval();
    main_time++;
    t->clk = 1;
    t->eval();
    main_time++;
}

static void mem_wr(Vplex_chrome_ddr_loader_tb* t, uint32_t byte_off, uint64_t data) {
    t->mem_we_host = 1;
    t->mem_we32_host = 0;
    t->mem_addr_host = byte_off >> 3;
    t->mem_wdata_host = data;
    tick(t);
    t->mem_we_host = 0;
    tick(t);
}

// One 32-bit half of a qword (LE: half0=lo/magic, half1=hi).
static void mem_wr32(Vplex_chrome_ddr_loader_tb* t, uint32_t byte_off, uint32_t data) {
    t->mem_we_host = 0;
    t->mem_we32_host = 1;
    t->mem_addr_host = byte_off >> 3;
    t->mem_half_hi = (byte_off & 4) ? 1 : 0;
    t->mem_wdata32_host = data;
    tick(t);
    t->mem_we32_host = 0;
    tick(t);
}

static uint64_t pack_ctrl(bool en, unsigned count, uint16_t seq) {
    uint64_t w = 0x504C5843ull;
    if (en)
        w |= 1ull << 32;
    w |= (uint64_t)(count & 0x3FFF) << 34;
    w |= (uint64_t)seq << 48;
    return w;
}

static uint64_t glyph(char c, int x, int y) {
    return 2ull | ((uint64_t)x << 8) | ((uint64_t)y << 24) | ((uint64_t)(uint8_t)c << 40);
}

// Product: invalidate → body → ctrl hi → magic lo LAST.
static void publish_seqlock(Vplex_chrome_ddr_loader_tb* t, const std::vector<uint64_t>& cmds,
                            uint16_t seq) {
    mem_wr(t, 0x130, 0);
    for (size_t i = 0; i < cmds.size(); ++i)
        mem_wr(t, 0x140 + (uint32_t)i * 8, cmds[i]);
    const uint64_t ctrl = pack_ctrl(true, (unsigned)cmds.size(), seq);
    mem_wr32(t, 0x134, static_cast<uint32_t>(ctrl >> 32)); // hi first
    mem_wr32(t, 0x130, static_cast<uint32_t>(ctrl));       // magic LAST
}

static void wait_idle(Vplex_chrome_ddr_loader_tb* t, int max_cyc = 400) {
    for (int i = 0; i < max_cyc; ++i) {
        tick(t);
        if (!t->busy_on)
            break;
    }
}

static bool wait_last_seq(Vplex_chrome_ddr_loader_tb* t, uint16_t seq, int max_cyc = 800) {
    for (int i = 0; i < max_cyc; ++i) {
        tick(t);
        if (t->last_seq_on == seq)
            return true;
    }
    return t->last_seq_on == seq;
}

// TB top fixes POLL_DIV=4. Deterministic window: idle, then enough cycles for
// several full poll → RD_CTRL → (optional push) round-trips. No "maybe missed".
static void force_poll_window(Vplex_chrome_ddr_loader_tb* t, int n_polls = 4) {
    wait_idle(t, 400);
    // ~POLL_DIV + grant/rdata + worst-case list/ctrl2/push + plxo steal.
    const int per = 48;
    for (int i = 0; i < n_polls * per; ++i)
        tick(t);
    wait_idle(t, 400);
}

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    int fails = 0;
    auto fail = [&](const char* m) {
        std::fprintf(stderr, "FAIL %s\n", m);
        ++fails;
    };
    auto pass = [&](const char* m) { std::fprintf(stderr, "PASS %s\n", m); };

    auto* t = new Vplex_chrome_ddr_loader_tb;
    t->reset = 1;
    t->clk = 0;
    t->mem_we_host = 0;
    t->mem_we32_host = 0;
    t->mem_half_hi = 0;
    t->mem_wdata32_host = 0;
    t->mem_addr_host = 0;
    t->mem_wdata_host = 0;
    t->run_tick = 0;
    for (int i = 0; i < 4; ++i)
        tick(t);
    t->reset = 0;
    for (int i = 0; i < 4; ++i)
        tick(t);

    // --- ENABLE=0 quiet ---
    std::fprintf(stderr, "=== ENABLE=0 quiet ===\n");
    std::fprintf(stderr, "EXECUTED quiet\n");
    for (int i = 0; i < 64; ++i) {
        tick(t);
        if (t->host_we_off || t->m_req_off)
            fail("off not quiet");
    }
    if (fails == 0)
        pass("quiet");

    // --- Seqlock load ---
    std::fprintf(stderr, "=== load list then ctrl (seqlock host) ===\n");
    std::fprintf(stderr, "EXECUTED load\n");
    const uint64_t g0 = glyph('#', 64, 64);
    publish_seqlock(t, {g0}, 5);
    if (!wait_last_seq(t, 5))
        fail("load seq5");
    else {
        // spot-check host path already exercised by last_seq
        if (t->cnt_loads_on < 1)
            fail("cnt_loads");
        else
            pass("load");
    }

    // --- same seq ---
    std::fprintf(stderr, "=== same seq no reload ===\n");
    std::fprintf(stderr, "EXECUTED same_seq\n");
    const uint32_t loads0 = t->cnt_loads_on;
    for (int i = 0; i < 200; ++i)
        tick(t);
    if (t->cnt_loads_on != loads0)
        fail("reloaded same seq");
    else
        pass("same-seq");

    // --- PLXO ---
    std::fprintf(stderr, "=== PLXO chrome_hw ===\n");
    std::fprintf(stderr, "EXECUTED plxo\n");
    for (int i = 0; i < 500 && t->cnt_plxo_on == 0; ++i)
        tick(t);
    if (t->cnt_plxo_on < 1)
        fail("no plxo wr");
    else if (static_cast<uint32_t>(t->mem_plxo_q) != 0x504C584Fu)
        fail("plxo magic");
    else if (((t->mem_plxo_q >> 32) & 1ull) == 0)
        fail("plxo chrome_hw bit");
    else
        pass("plxo");

    // --- bad magic ---
    std::fprintf(stderr, "=== bad magic ===\n");
    std::fprintf(stderr, "EXECUTED bad_magic\n");
    mem_wr(t, 0x130, 0xDEADBEEFull);
    const uint32_t bad0 = t->cnt_bad_on;
    for (int i = 0; i < 200; ++i)
        tick(t);
    if (t->cnt_bad_on <= bad0)
        fail("bad magic not counted");
    else
        pass("bad-magic");

    // --- Concurrent / torn: long list, tear magic once list RD starts ---
    std::fprintf(stderr, "=== concurrent/torn mid-list invalidate ===\n");
    std::fprintf(stderr, "EXECUTED concurrent\n");
    wait_idle(t);
    // Build 16-cmd list so body RD takes many cycles
    std::vector<uint64_t> long_list;
    for (int i = 0; i < 16; ++i)
        long_list.push_back(glyph('A' + (i % 26), i * 8, 10));
    const uint32_t torn0 = t->cnt_torn_on;
    const uint32_t loads_b = t->cnt_loads_on;
    publish_seqlock(t, long_list, 20);

    // Wait until loader leaves idle (poll→ctrl→list). m_req is 1-cycle; do not
    // rely on sampling it. After busy for ~12 cyc, ctrl snap is done and list RD
    // is in flight for a 16-beat body — then invalidate magic (torn window).
    int busy_cyc = 0;
    int tore = 0;
    for (int i = 0; i < 2000; ++i) {
        tick(t);
        if (t->busy_on)
            busy_cyc++;
        if (!tore && busy_cyc == 12) {
            mem_wr(t, 0x130, 0); // mid-body invalidate
            tore = 1;
        }
        if (tore && !t->busy_on && busy_cyc > 20)
            break;
    }
    std::fprintf(stderr, "concurrent tore=%d busy_cyc=%d torn=%u->%u loads=%u->%u last=%u\n",
                 tore, busy_cyc, (unsigned)torn0, (unsigned)t->cnt_torn_on,
                 (unsigned)loads_b, (unsigned)t->cnt_loads_on, (unsigned)t->last_seq_on);

    if (!tore)
        fail("concurrent never entered busy to tear");
    // Must not commit seq20 after mid-body invalidate
    if (t->last_seq_on == 20)
        fail("concurrent committed seq20 after tear");
    if (t->cnt_torn_on <= torn0)
        fail("concurrent expected cnt_torn bump");
    // Recover with clean seqlock publish
    publish_seqlock(t, {glyph('Z', 1, 1)}, 21);
    if (!wait_last_seq(t, 21))
        fail("concurrent recover seq21");
    else
        pass("concurrent");

    std::fprintf(stderr, "EXECUTED torn_mid\n");
    if (t->cnt_torn_on > torn0 && t->last_seq_on == 21)
        pass("torn_mid");
    else
        fail("torn_mid");

    // --- Reset retained coherent ---
    std::fprintf(stderr, "=== reset retained coherent ===\n");
    std::fprintf(stderr, "EXECUTED retained\n");
    publish_seqlock(t, {glyph('R', 5, 5)}, 42);
    if (!wait_last_seq(t, 42))
        fail("retained setup 42");
    wait_idle(t);
    t->reset = 1;
    for (int i = 0; i < 8; ++i)
        tick(t);
    t->reset = 0;
    for (int i = 0; i < 4; ++i)
        tick(t);
    if (t->last_seq_on != 0)
        fail("reset did not clear last_seq");
    else if (!wait_last_seq(t, 42))
        fail("retained coherent not reloaded");
    else
        pass("retained");

    // --- Retained invalidated ---
    std::fprintf(stderr, "=== reset retained invalidated ===\n");
    std::fprintf(stderr, "EXECUTED retained_inv\n");
    mem_wr(t, 0x130, 0);
    mem_wr(t, 0x140, glyph('Q', 1, 1));
    t->reset = 1;
    for (int i = 0; i < 8; ++i)
        tick(t);
    t->reset = 0;
    const uint32_t loads_ri = t->cnt_loads_on;
    for (int i = 0; i < 400; ++i)
        tick(t);
    if (t->cnt_loads_on != loads_ri)
        fail("retained_inv loaded without magic");
    else if (t->last_seq_on != 0)
        fail("retained_inv last_seq");
    else
        pass("retained_inv");

    // --- Half-word ctrl order (rd-duck hole 1) ---
    // Observations that MUST fail under wrong order:
    //   PRODUCT: after HI-only (magic still 0), loads/last_seq must not change.
    //            Reverse half order (magic first) → seq0 empty commit → FAIL.
    //   FAULT magic-first: with last_seq!=0, magic-only+hi=0 MUST commit seq0.
    //            (was tautological when either wrong_accept OR stayed passed)
    std::fprintf(stderr, "=== halfword ctrl publish order ===\n");
    std::fprintf(stderr, "EXECUTED halfword\n");
    {
        // Nonzero baseline so magic+zero-hi is distinguishable (seq0 != baseline).
        publish_seqlock(t, {glyph('B', 2, 2)}, 50);
        if (!wait_last_seq(t, 50)) {
            fail("halfword baseline seq50");
        } else {
            wait_idle(t);
            const uint64_t g = glyph('H', 8, 8);
            mem_wr(t, 0x130, 0); // invalidate both halves
            mem_wr(t, 0x140, g);
            const uint64_t ctrl = pack_ctrl(true, 1, 77);
            const uint16_t seq_b = t->last_seq_on;
            const uint32_t loads_b = t->cnt_loads_on;
#if defined(HALFWORD_PRODUCT_MAGIC_FIRST)
            // Product mutation twin: reverse half order — gate must go RED.
            mem_wr32(t, 0x130, static_cast<uint32_t>(ctrl)); // magic FIRST
            std::fprintf(stderr, "halfword PRODUCT_MUTATION magic_first\n");
#else
            // Product: HI first while magic=0.
            mem_wr32(t, 0x134, static_cast<uint32_t>(ctrl >> 32));
#endif
            force_poll_window(t, 6);
            // Hard observation: incomplete ctrl must not commit.
            if (t->last_seq_on != seq_b || t->cnt_loads_on != loads_b) {
                std::fprintf(stderr,
                             "halfword incomplete-half commit seq=%u loads_delta=%u "
                             "(must stay seq=%u)\n",
                             (unsigned)t->last_seq_on,
                             (unsigned)(t->cnt_loads_on - loads_b), (unsigned)seq_b);
                fail("halfword accepted after incomplete ctrl half");
            } else {
#if defined(HALFWORD_PRODUCT_MAGIC_FIRST)
                // Mutation path should have failed above; if not, hole closed/missed.
                fail("halfword mutation: expected incomplete-half commit");
#else
                mem_wr32(t, 0x130, static_cast<uint32_t>(ctrl)); // magic LAST
                if (!wait_last_seq(t, 77))
                    fail("halfword product magic-last did not commit seq77");
                else
                    pass("halfword");
#endif
            }
        }
    }

    std::fprintf(stderr, "EXECUTED halfword_magic_first\n");
#if defined(HALFWORD_PRODUCT_MAGIC_FIRST)
    // Mutation binary only proves product gate; skip fault arm.
    std::fprintf(stderr, "SKIP halfword_magic_first under PRODUCT_MUTATION\n");
#else
    {
        // Require last_seq != 0 so seq0 empty is a real wrong commit.
        if (t->last_seq_on == 0) {
            publish_seqlock(t, {glyph('S', 3, 3)}, 66);
            if (!wait_last_seq(t, 66))
                fail("halfword_magic_first seed");
        }
        wait_idle(t);
        const uint16_t seed_seq = t->last_seq_on;
        mem_wr(t, 0x130, 0);
        mem_wr(t, 0x140, glyph('Z', 1, 1));
        const uint64_t ctrl = pack_ctrl(true, 1, 88);
        const uint32_t loads_b = t->cnt_loads_on;
        // FAULT host order: magic FIRST, hi still 0 → valid magic + seq=0 empty.
        mem_wr32(t, 0x130, static_cast<uint32_t>(ctrl));
        force_poll_window(t, 6);
        // MUST observe wrong seq0 commit (not optional).
        const bool saw_wrong =
            (t->last_seq_on == 0 && t->cnt_loads_on > loads_b && seed_seq != 0);
        std::fprintf(stderr,
                     "halfword_magic_first seed_seq=%u after_seq=%u loads_delta=%u "
                     "wrong_accept=%d\n",
                     (unsigned)seed_seq, (unsigned)t->last_seq_on,
                     (unsigned)(t->cnt_loads_on - loads_b), saw_wrong ? 1 : 0);
        if (!saw_wrong) {
            fail("halfword_magic_first: expected wrong seq0 commit after magic-only");
        } else {
            mem_wr32(t, 0x134, static_cast<uint32_t>(ctrl >> 32));
            if (!wait_last_seq(t, 88))
                fail("halfword_magic_first final seq88");
            else
                pass("halfword_magic_first");
        }
    }
#endif

    delete t;
    if (fails) {
        std::fprintf(stderr, "plex_chrome_ddr_loader_tb: %d FAIL(s)\n", fails);
        return 1;
    }
    std::fprintf(stderr, "plex_chrome_ddr_loader_tb: PASS\n");
    return 0;
}
