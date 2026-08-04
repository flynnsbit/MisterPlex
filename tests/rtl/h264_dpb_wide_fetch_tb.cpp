#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include "Vh264_dpb_wide_fetch_tb_top.h"
#include "verilated.h"

static vluint64_t main_time = 0;
double sc_time_stamp() { return (double)main_time; }
static int fails = 0;
static void expect(bool c, const char* m) {
	if (!c) { std::fprintf(stderr, "FAIL %s\n", m); fails++; }
	else std::printf("OK %s\n", m);
}
static void tick(Vh264_dpb_wide_fetch_tb_top* t) {
	t->clk = 0; t->eval(); main_time++;
	t->clk = 1; t->eval(); main_time++;
}

int main(int argc, char** argv) {
	Verilated::commandArgs(argc, argv);
	auto* top = new Vh264_dpb_wide_fetch_tb_top;
	top->reset = 1; top->start_w = 0; top->start_f = 0;
	top->part_w = 16; top->part_h = 16;
	for (int i = 0; i < 4; i++) tick(top);
	top->reset = 0; tick(top);
	std::printf("DPB_WIDE_FETCH_TB_EXECUTED\n");

	// ── Budget arithmetic (rd-duck numbers) ──
	std::printf("BUDGET samp=%u byte_fr=%u wide_mb=%u wide_fr=%u budget=%u\n",
		top->samples_per_p16_mb, top->byte_cycles_frame_p16,
		top->wide_beats_per_p16_mb, top->wide_cycles_frame_p16,
		top->frame_budget_cycles);
	expect(top->samples_per_p16_mb == 603u, "603 samples/P16 MB");
	expect(top->byte_cycles_frame_p16 == 603u * 3600u, "byte frame cy = 2170800");
	expect(top->wide_beats_per_p16_mb == 99u, "wide beats/MB = 99");
	expect(top->wide_cycles_frame_p16 == 99u * 3600u, "wide frame cy = 356400");
	expect(top->frame_budget_cycles == 20000000u / 24u, "budget 833333 @20M/24");
	expect(top->byte_serial_meets_24fps == 0, "NEG: byte-serial CANNOT meet 24fps");
	expect(top->wide_beat_meets_24fps == 1, "wide beats meet 24fps budget");
	expect(top->i420_write_byte_cycles == 1382400u, "I420 write byte-cy");
	expect(top->i420_write_byte_meets_24fps == 0, "NEG: byte I420 write misses 24fps");

	// part window: P16=603, P8=13*13 + 2*5*5 = 169+50=219
	top->part_w = 16; top->part_h = 16; tick(top);
	expect(top->part_total_samples == 603u, "part 16x16 total 603");
	top->part_w = 8; top->part_h = 8; tick(top);
	expect(top->part_total_samples == (13u*13u + 2u*5u*5u), "part 8x8 total 219");

	// ── Wide fetch: expect 99 beats and 603 luma+chroma samples streamed ──
	int luma_n = 0;
	top->start_w = 1; tick(top); top->start_w = 0;
	for (int i = 0; i < 20000 && !top->done_w; i++) {
		tick(top);
		if (top->luma_v_w) luma_n++;
	}
	expect(top->done_w == 1, "wide fetch done");
	expect(top->beats_w == 99u, "wide issued 99 beats");
	expect(luma_n == 441, "wide delivered 441 luma samples");

	// ── FAULT byte-serial: 603 beats (NEG discrimination) ──
	top->start_f = 1; tick(top); top->start_f = 0;
	for (int i = 0; i < 20000 && !top->done_f; i++) tick(top);
	expect(top->done_f == 1, "fault fetch done");
	expect(top->beats_f == 603u, "NEG FAULT_BYTE_SERIAL issues 603 beats");

	std::printf("DPB_WIDE_FETCH_TB fails=%d\n", fails);
	delete top;
	return fails ? 1 : 0;
}
