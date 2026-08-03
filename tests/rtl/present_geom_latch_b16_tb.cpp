// B16 geometry transition atomicity (latch).
// Vectors: 624x480 -> 320x240 -> 960x540
// Commits at mid-active (no boundary) and at VS (boundary).
// Assert: live bundle is entirely old until promote, then entirely new.
// Red twin FAULT_IMMEDIATE_COMMIT: mid-active commit changes live -> rc=2 REPRO.
#include "Vpresent_geom_latch_b16_tb_top.h"
#include "verilated.h"
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>

static vluint64_t main_time = 0;
double sc_time_stamp() { return (double)main_time; }

static void tick(Vpresent_geom_latch_b16_tb_top* t) {
	t->clk = 0; t->eval(); main_time++;
	t->clk = 1; t->eval(); main_time++;
}

static uint64_t pack_q0(bool win, bool geom, uint16_t seq, uint16_t epoch) {
	uint64_t hi = 0;
	if (win) hi |= 1ull;
	if (geom) hi |= 2ull;
	hi |= (uint64_t)(epoch & 0x3FFF) << 2;
	hi |= (uint64_t)seq << 16;
	return (hi << 32) | 0x47584C50ull;
}

struct Geom {
	uint16_t cw, ch, yst, cst;
	uint16_t seq;
	uint16_t epoch;
};

static void write_geom(Vpresent_geom_latch_b16_tb_top* t, const Geom& g) {
	// q1: content_w/h
	// q2: h_de/v_de/coded_w/h
	// q3: y_stride/chroma/display_w/h
	// q4: present/crop
	uint64_t q0 = pack_q0(true, true, g.seq, g.epoch);
	uint64_t q1 = (uint64_t)g.cw | ((uint64_t)g.ch << 16);
	uint64_t q2 = (uint64_t)g.cw | ((uint64_t)g.ch << 16)
	            | ((uint64_t)g.cw << 32) | ((uint64_t)g.ch << 48);
	uint64_t q3 = (uint64_t)g.yst | ((uint64_t)g.cst << 16)
	            | ((uint64_t)g.cw << 32) | ((uint64_t)g.ch << 48);
	uint64_t q4 = 0;
	uint64_t qs[5] = {q0, q1, q2, q3, q4};
	for (int i = 0; i < 5; i++) {
		t->wr_en = 1; t->wr_idx = i; t->wr_data = qs[i];
		tick(t);
		t->wr_en = 0; tick(t);
	}
	t->commit = 1; tick(t); t->commit = 0; tick(t); tick(t);
}

static void boundary(Vpresent_geom_latch_b16_tb_top* t) {
	t->frame_boundary = 1; tick(t);
	t->frame_boundary = 0; tick(t); tick(t);
}

static int check_live(Vpresent_geom_latch_b16_tb_top* t, const Geom& g, const char* tag) {
	if (!t->live_valid || !t->geom_enable) {
		std::fprintf(stderr, "FAIL %s: live_valid/geom off\n", tag);
		return 1;
	}
	if (t->content_w != g.cw || t->content_h != g.ch ||
	    t->coded_w != g.cw || t->coded_h != g.ch ||
	    t->y_stride != g.yst || t->chroma_stride != g.cst ||
	    t->live_seq != g.seq) {
		std::fprintf(stderr,
			"FAIL %s: live cw=%u ch=%u yst=%u cst=%u seq=%u (want %ux%u y=%u c=%u seq=%u)\n",
			tag, (unsigned)t->content_w, (unsigned)t->content_h,
			(unsigned)t->y_stride, (unsigned)t->chroma_stride, (unsigned)t->live_seq,
			g.cw, g.ch, g.yst, g.cst, g.seq);
		return 1;
	}
	return 0;
}

int main(int argc, char** argv) {
	Verilated::commandArgs(argc, argv);
	const bool fault_imm = (std::getenv("FAULT_IMMEDIATE_COMMIT") != nullptr);
	auto* t = new Vpresent_geom_latch_b16_tb_top;
	t->reset = 1; t->wr_en = 0; t->commit = 0; t->frame_boundary = 0;
	t->wr_idx = 0; t->wr_data = 0;
	for (int i = 0; i < 4; i++) tick(t);
	t->reset = 0; tick(t);

	const Geom g624{624, 480, 624, 312, 1, 1};
	const Geom g320{320, 240, 320, 160, 2, 1};
	const Geom g960{960, 540, 960, 480, 3, 1};
	// 416x234 = aligned delivery for 426x240 (w-path)
	const Geom g416{416, 234, 416, 208, 4, 1};

	// Establish live 624 via commit + VS boundary.
	write_geom(t, g624);
	if (!fault_imm) {
		if (t->live_valid || !t->pending_valid) {
			std::fprintf(stderr, "FAIL: commit without boundary promoted or failed to stage\n");
			return 1;
		}
	}
	boundary(t);
	if (check_live(t, g624, "init624")) return 1;
	std::printf("live_after_624 cw=%u ch=%u yst=%u pend=%u\n",
	            (unsigned)t->content_w, (unsigned)t->content_h,
	            (unsigned)t->y_stride, (unsigned)t->pending_valid);

	// MID-ACTIVE commit of 320: product must keep live=624 entirely.
	write_geom(t, g320);
	if (fault_imm) {
		// Red twin: live already 320 mid-active — mixed-frame class.
		if (t->content_w == 320 && t->live_seq == 2) {
			std::printf("REPRO B16_IMMEDIATE_COMMIT mid-active live became 320x240\n");
			delete t;
			return 2; // REPRO expected by harness
		}
		std::fprintf(stderr, "FAIL red twin: expected immediate promote to 320, got cw=%u seq=%u\n",
		             (unsigned)t->content_w, (unsigned)t->live_seq);
		delete t;
		return 1;
	}
	if (check_live(t, g624, "mid_active_still_624")) return 1;
	if (!t->pending_valid) {
		std::fprintf(stderr, "FAIL: mid-active commit did not stage pending\n");
		return 1;
	}
	std::printf("mid_active_ok live_still_624 pend=1\n");

	// VS boundary promotes 320 atomically.
	boundary(t);
	if (check_live(t, g320, "after_vs_320")) return 1;
	if (t->pending_valid || !t->promote_pulse) {
		// promote_pulse is 1-cycle; may already be 0 after ticks in boundary()
	}
	std::printf("after_vs_320 cw=%u ch=%u yst=%u\n",
	            (unsigned)t->content_w, (unsigned)t->content_h, (unsigned)t->y_stride);

	// Mid-active 960, still 320 live.
	write_geom(t, g960);
	if (check_live(t, g320, "mid_active_still_320")) return 1;
	boundary(t);
	if (check_live(t, g960, "after_vs_960")) return 1;
	std::printf("after_vs_960 cw=%u ch=%u yst=%u cst=%u\n",
	            (unsigned)t->content_w, (unsigned)t->content_h,
	            (unsigned)t->y_stride, (unsigned)t->chroma_stride);

	// 416x234 path (aligned 426 box).
	write_geom(t, g416);
	if (check_live(t, g960, "mid_still_960")) return 1;
	boundary(t);
	if (check_live(t, g416, "after_vs_416")) return 1;

	std::printf("PASS B16 stage/promote 624->320->960->416; mid-active never mixed\n");
	delete t;
	return 0;
}
