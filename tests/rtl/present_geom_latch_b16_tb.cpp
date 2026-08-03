// B16 geometry transition atomicity + ABI #2 q5 DAR/fps + reserved reject.
#include "Vpresent_geom_latch_b16_tb_top.h"
#include "verilated.h"
#include <cstdint>
#include <cstdio>
#include <cstdlib>

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
	return (hi << 32) | 0x504C5847ull; // mailbox_abi kPlxgMagic
}

static uint64_t pack_q5(unsigned dar_x, unsigned dar_y, unsigned fps,
                        bool dar_v, bool fps_v, uint64_t reserved_hi = 0) {
	uint64_t w = 0;
	w |= (dar_x & 0xFFFu);
	w |= (uint64_t)(dar_y & 0xFFFu) << 12;
	w |= (uint64_t)(fps & 0xFFu) << 24;
	if (dar_v) w |= 1ull << 32;
	if (fps_v) w |= 1ull << 33;
	w |= (reserved_hi & 0x3FFFFFFFull) << 34;
	return w;
}

struct Geom {
	uint16_t cw, ch, yst, cst;
	uint16_t seq;
	uint16_t epoch;
	unsigned dar_x, dar_y, fps;
	bool dar_v, fps_v;
	uint64_t q5_reserved;
};

static void promote(Vpresent_geom_latch_b16_tb_top* t) {
	t->frame_boundary = 1; tick(t);
	t->frame_boundary = 0; tick(t); tick(t);
}

static void write_geom(Vpresent_geom_latch_b16_tb_top* t, const Geom& g) {
	uint64_t q0 = pack_q0(true, true, g.seq, g.epoch);
	uint64_t q1 = (uint64_t)g.cw | ((uint64_t)g.ch << 16);
	uint64_t q2 = (uint64_t)g.cw | ((uint64_t)g.ch << 16)
	            | ((uint64_t)g.cw << 32) | ((uint64_t)g.ch << 48);
	uint64_t q3 = (uint64_t)g.yst | ((uint64_t)g.cst << 16)
	            | ((uint64_t)g.cw << 32) | ((uint64_t)g.ch << 48);
	uint64_t q4 = 0;
	uint64_t q5 = pack_q5(g.dar_x, g.dar_y, g.fps, g.dar_v, g.fps_v, g.q5_reserved);
	uint64_t qs[6] = {q0, q1, q2, q3, q4, q5};
	for (int i = 0; i < 6; i++) {
		t->wr_en = 1; t->wr_idx = i; t->wr_data = qs[i];
		tick(t);
		t->wr_en = 0; tick(t);
	}
	t->commit = 1; tick(t); t->commit = 0; tick(t); tick(t);
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
	if (t->dar_x != g.dar_x || t->dar_y != g.dar_y || t->content_fps != g.fps ||
	    t->dar_valid != g.dar_v || t->fps_valid != g.fps_v) {
		std::fprintf(stderr,
			"FAIL %s: q5 dar=%u/%u v=%u fps=%u v=%u (want %u/%u v=%u fps=%u v=%u)\n",
			tag, (unsigned)t->dar_x, (unsigned)t->dar_y, (unsigned)t->dar_valid,
			(unsigned)t->content_fps, (unsigned)t->fps_valid,
			g.dar_x, g.dar_y, g.dar_v, g.fps, g.fps_v);
		return 1;
	}
	return 0;
}

int main(int argc, char** argv) {
	Verilated::commandArgs(argc, argv);
	const bool fault_imm = (std::getenv("FAULT_IMMEDIATE_COMMIT") != nullptr);
	const bool fault_res = (std::getenv("FAULT_IGNORE_Q5_RESERVED") != nullptr);
	auto* t = new Vpresent_geom_latch_b16_tb_top;
	t->reset = 1; t->wr_en = 0; t->commit = 0; t->frame_boundary = 0;
	t->wr_idx = 0; t->wr_data = 0;
	for (int i = 0; i < 4; i++) tick(t);
	t->reset = 0; tick(t);

	// Reserved-reject red twin path (product rejects; fault accepts).
	if (std::getenv("TEST_Q5_RESERVED") != nullptr) {
		Geom bad{624, 480, 624, 312, 1, 1, 16, 9, 24, true, true, /*reserved*/1};
		write_geom(t, bad);
		if (!fault_res) {
			// Product: must not stage/promote; sticky reject.
			if (t->pending_valid || t->live_valid) {
				std::fprintf(stderr, "FAIL product accepted nonzero q5 reserved\n");
				return 1;
			}
			if (!t->q5_reserved_reject) {
				std::fprintf(stderr, "FAIL product no q5_reserved_reject sticky\n");
				return 1;
			}
			std::printf("PASS product rejects q5 reserved nonzero sticky=%u\n",
			            (unsigned)t->q5_reserved_reject);
			delete t;
			return 0;
		}
		// Fault twin: accepts reserved (REPRO) — stage or promote ok.
		if (!(t->pending_valid || t->live_valid)) {
			std::fprintf(stderr, "FAIL red twin did not accept reserved q5\n");
			return 1;
		}
		std::printf("REPRO Q5_RESERVED_ACCEPTED pending=%u live=%u\n",
		            (unsigned)t->pending_valid, (unsigned)t->live_valid);
		delete t;
		return 2;
	}

	Geom g624{624, 480, 624, 312, 1, 1, 4, 3, 24, true, true, 0};
	Geom g320{320, 240, 320, 160, 2, 1, 4, 3, 30, true, true, 0};
	Geom g960{960, 540, 960, 480, 3, 1, 16, 9, 24, true, true, 0};
	Geom g416{416, 234, 416, 208, 4, 1, 16, 9, 0, true, false, 0};

	write_geom(t, g624);
	if (!fault_imm) {
		if (t->live_valid || !t->pending_valid) {
			std::fprintf(stderr, "FAIL: commit without boundary promoted or failed to stage\n");
			return 1;
		}
	}
	promote(t);
	if (check_live(t, g624, "init624")) return 1;
	std::printf("live_after_624 cw=%u dar=%u/%u fps=%u\n",
	            (unsigned)t->content_w, (unsigned)t->dar_x, (unsigned)t->dar_y,
	            (unsigned)t->content_fps);

	write_geom(t, g320);
	if (fault_imm) {
		if (t->content_w == 320 && t->live_seq == 2) {
			std::printf("REPRO B16_IMMEDIATE_COMMIT mid-active live became 320x240\n");
			delete t;
			return 2;
		}
		std::fprintf(stderr, "FAIL red twin: expected immediate promote to 320\n");
		delete t;
		return 1;
	}
	if (check_live(t, g624, "mid_active_still_624")) return 1;
	// DAR/fps also must stay old mid-active
	if (t->content_fps != 24 || t->dar_x != 4) {
		std::fprintf(stderr, "FAIL mid-active q5 changed fps=%u dar_x=%u\n",
		             (unsigned)t->content_fps, (unsigned)t->dar_x);
		return 1;
	}
	std::printf("mid_active_ok live_still_624+q5 pend=1\n");

	promote(t);
	if (check_live(t, g320, "after_vs_320")) return 1;
	std::printf("after_vs_320 cw=%u fps=%u dar=%u/%u\n",
	            (unsigned)t->content_w, (unsigned)t->content_fps,
	            (unsigned)t->dar_x, (unsigned)t->dar_y);

	write_geom(t, g960);
	if (check_live(t, g320, "mid_active_still_320")) return 1;
	promote(t);
	if (check_live(t, g960, "after_vs_960")) return 1;

	write_geom(t, g416);
	if (check_live(t, g960, "mid_still_960")) return 1;
	promote(t);
	if (check_live(t, g416, "after_vs_416")) return 1;

	std::printf("PASS B16+q5 stage/promote 624->320->960->416; mid-active never mixed\n");
	delete t;
	return 0;
}
