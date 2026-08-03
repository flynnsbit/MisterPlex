// Integrated B20 beam island oracle (rd-duck NBA lag).
#include "Vb20_beam_island_tb_top.h"
#include "verilated.h"
#include <cstdio>
#include <cstdlib>
#include <cstring>

static vluint64_t main_time = 0;
double sc_time_stamp() { return static_cast<double>(main_time); }

static void tick(Vb20_beam_island_tb_top* t) {
	t->clk = 0; t->eval(); main_time++;
	t->clk = 1; t->eval(); main_time++;
}

static void reset_hold(Vb20_beam_island_tb_top* t, int n = 8) {
	t->reset = 1;
	t->swap_pending = 0;
	t->pending_ready = 0;
	t->pend_valid = 0;
	t->pend_hde = 624;
	t->pend_vde = 48;
	t->pend_seq = 0;
	t->app_hde_in = 624;
	t->app_vde_in = 48;
	t->applied_seq_in = 13; // already displaying N
	t->swap_applied_pulse_in = 0;
	for (int i = 0; i < n; ++i) tick(t);
	t->reset = 0;
	for (int i = 0; i < 4; ++i) tick(t);
}

// Run until frame_start observed, return hc after that cycle's posedge settle.
static int wait_frame_start(Vb20_beam_island_tb_top* t, int max_c = 200000) {
	for (int i = 0; i < max_c; ++i) {
		tick(t);
		if (t->frame_start)
			return i;
	}
	return -1;
}

int main(int argc, char** argv) {
	Verilated::commandArgs(argc, argv);
	auto* t = new Vb20_beam_island_tb_top;
	reset_hold(t);

	// Establish beam DE = 624 for generation N (applied=13, app=624).
	// Force a wrap with apply=1 (not pending).
	int w = wait_frame_start(t);
	if (w < 0) {
		std::fprintf(stderr, "FAIL no initial frame_start\n");
		return 1;
	}
	// After one more wrap, hde_act should be 624.
	w = wait_frame_start(t);
	if (t->hde_act != 624) {
		std::fprintf(stderr, "FAIL setup hde_act=%u want 624\n", t->hde_act);
		return 1;
	}
	std::fprintf(stderr, "setup_ok hde=%u applied=%u\n", t->hde_act, t->applied_seq_in);

	// Arm swap to N+1 (320) before next v_wrap — pend ready, bank will swap on
	// delayed frame_start (hc=1).
	t->swap_pending = 1;
	t->pending_ready = 1;
	t->pend_valid = 1;
	t->pend_hde = 320;
	t->pend_vde = 24;
	t->pend_seq = 17;
	// Keep app at 624 until the delayed frame_start edge (store NBA model).
	t->app_hde_in = 624;
	t->app_vde_in = 48;
	t->applied_seq_in = 13;
	t->swap_applied_pulse_in = 0;

	// Wait for v_wrap / frame_start. Beam should sample armed pend (product)
	// or old app (fault no-feedforward).
	int fs = wait_frame_start(t);
	if (fs < 0) {
		std::fprintf(stderr, "FAIL no armed frame_start\n");
		return 1;
	}
	// Same cycle frame_start is 1: hc is already 0 (wrap NBA). Store sees this
	// next tick — model store promote on the following posedge.
	const uint32_t hde_at_fs = t->hde_act;
	std::fprintf(stderr, "at_frame_start hde_act=%u armed=%u hc=%u\n",
	             hde_at_fs, t->swap_armed_o, t->hc);

	// Next clk: store swaps app/bank (hc becomes 1). live-vs-app clears.
	t->swap_applied_pulse_in = 1;
	t->app_hde_in = 320;
	t->app_vde_in = 24;
	t->applied_seq_in = 17;
	t->swap_pending = 0;
	t->pending_ready = 0;
	t->pend_valid = 0;
	tick(t);
	t->swap_applied_pulse_in = 0;

	std::fprintf(stderr, "post_swap hde_act=%u app=%u hold=%u beam_hold=%u hc=%u\n",
	             t->hde_act, t->app_hde_in, t->b20_hold, t->b20_beam_hold, t->hc);

	// Scan rest of this frame + next for island_fault while active.
	int island = 0;
	int hold_seen = 0;
	for (int i = 0; i < 20000; ++i) {
		tick(t);
		if (t->b20_hold)
			hold_seen = 1;
		if (t->island_fault)
			island = 1;
	}

#if defined(FAULT_B20_NO_BEAM_HOLD) && defined(FAULT_B20_NO_BEAM_FEEDFORWARD)
	std::fprintf(stderr, "=== FAULT no feedforward + no beam hold ===\n");
	std::fprintf(stderr, "hde_at_fs=%u island=%d hold_seen=%d\n", hde_at_fs, island, hold_seen);
	if (!island) {
		std::fprintf(stderr, "FAIL red twin did not REPRO island\n");
		return 1;
	}
	std::fprintf(stderr, "REPRO island NEW app 320 under OLD beam DE 624 hold=0\n");
	delete t;
	return 2;
#else
	std::fprintf(stderr, "=== PRODUCT integrated B20 beam ===\n");
	std::fprintf(stderr, "hde_at_fs=%u island=%d hold_seen=%d\n", hde_at_fs, island, hold_seen);
	if (island) {
		std::fprintf(stderr, "FAIL product exposed island fault\n");
		return 1;
	}
	// Product with feed-forward: hde at fs should already be 320; with hold-only,
	// may still be 624 but hold covers active.
	if (hde_at_fs != 320 && !hold_seen) {
		std::fprintf(stderr, "FAIL neither feed-forward DE nor hold covered swap\n");
		return 1;
	}
	std::fprintf(stderr, "PASS no island; hde_at_fs=%u hold_seen=%d\n", hde_at_fs, hold_seen);
	delete t;
	return 0;
#endif
}
