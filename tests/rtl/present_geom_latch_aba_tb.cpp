// B4 red twin + product: FPGA reset last_seq=0 + retained seq=N epoch=0 ABA.
// B16: promote only after frame_boundary.
#include "Vpresent_geom_latch_aba_tb_top.h"
#include "verilated.h"
#include <cstdint>
#include <cstdio>
#include <cstdlib>

static vluint64_t main_time = 0;
double sc_time_stamp() { return (double)main_time; }

static void tick(Vpresent_geom_latch_aba_tb_top* t) {
	t->clk = 0; t->eval(); main_time++;
	t->clk = 1; t->eval(); main_time++;
}

static uint64_t pack_q0(bool win, bool geom, uint16_t seq, uint16_t epoch) {
	uint64_t hi = 0;
	if (win) hi |= 1ull;
	if (geom) hi |= 2ull;
	hi |= (uint64_t)(epoch & 0x3FFF) << 2;
	hi |= (uint64_t)seq << 16;
	return (hi << 32) | 0x504C5847ull;
}

static void promote(Vpresent_geom_latch_aba_tb_top* t) {
	t->frame_boundary = 1; tick(t);
	t->frame_boundary = 0; tick(t); tick(t);
}

static void write_record(Vpresent_geom_latch_aba_tb_top* t, uint64_t q0,
                         bool geom_on, bool do_promote = true) {
	uint64_t q[5] = {
		q0,
		/*q1*/ (960ull) | (540ull << 16),
		/*q2*/ (960ull) | (540ull << 16) | (960ull << 32) | (540ull << 48),
		/*q3*/ (960ull) | (480ull << 16) | (960ull << 32) | (540ull << 48),
		/*q4*/ 0
	};
	if (!geom_on) {
		q[1] = q[2] = q[3] = q[4] = 0;
	}
	for (int i = 0; i < 5; i++) {
		t->wr_en = 1; t->wr_idx = i; t->wr_data = q[i];
		tick(t);
		t->wr_en = 0; tick(t);
	}
	// q5 DAR/fps unspecified, reserved=0
	t->wr_en = 1; t->wr_idx = 5; t->wr_data = 0;
	tick(t); t->wr_en = 0; tick(t);
	t->commit = 1; tick(t); t->commit = 0; tick(t); tick(t);
	if (do_promote)
		promote(t);
}

int main(int argc, char** argv) {
	Verilated::commandArgs(argc, argv);
	const bool fault = (std::getenv("FAULT_NO_EPOCH") != nullptr);
	auto* t = new Vpresent_geom_latch_aba_tb_top;
	t->reset = 1; t->wr_en = 0; t->commit = 0; t->wr_idx = 0; t->wr_data = 0;
	t->frame_boundary = 0;
	for (int i = 0; i < 4; i++) tick(t);
	t->reset = 0; tick(t);

	// Retained-style record: seq=7, epoch=0 (pre-epoch host / stale DDR).
	write_record(t, pack_q0(true, true, 7, 0), true);

	const int accepted = t->live_valid ? 1 : 0;
	const unsigned seq = t->live_seq;
	const unsigned ep = t->live_epoch;

	std::printf("B4_ABA fault=%d accepted=%d live_seq=%u live_epoch=%u geom=%u pend=%u\n",
	            (int)fault, accepted, seq, ep, (unsigned)t->geom_enable,
	            (unsigned)t->pending_valid);

	if (fault) {
		if (!accepted || seq != 7) {
			std::fprintf(stderr, "FAIL red twin: expected ABA accept seq=7 got acc=%d seq=%u\n",
			             accepted, seq);
			return 2;
		}
		std::printf("REPRO B4_ABA_NO_EPOCH accepted retained seq after reset\n");
		delete t;
		return 0;
	}

	// Product MUST reject epoch=0 after reset (no pending either).
	if (accepted || t->pending_valid) {
		std::fprintf(stderr, "FAIL product: epoch=0 seq=7 accepted/staged after reset (ABA open)\n");
		return 1;
	}

	// Product accepts epoch=1 seq=7 after promote.
	write_record(t, pack_q0(true, true, 7, 1), true);
	if (!t->live_valid || t->live_seq != 7 || t->live_epoch != 1 || !t->geom_enable) {
		std::fprintf(stderr, "FAIL product: epoch=1 seq=7 not committed valid=%u seq=%u ep=%u geom=%u\n",
		             (unsigned)t->live_valid, (unsigned)t->live_seq,
		             (unsigned)t->live_epoch, (unsigned)t->geom_enable);
		return 1;
	}

	// Same (epoch,seq) rejected.
	write_record(t, pack_q0(false, false, 7, 1), false);
	if (!t->geom_enable || t->live_seq != 7) {
		std::fprintf(stderr, "FAIL product: same pair should not replace live\n");
		return 1;
	}

	// New seq same epoch accepted (mode disable).
	write_record(t, pack_q0(false, false, 8, 1), false);
	if (t->geom_enable || t->live_seq != 8) {
		std::fprintf(stderr, "FAIL product: seq bump disable not committed geom=%u seq=%u\n",
		             (unsigned)t->geom_enable, (unsigned)t->live_seq);
		return 1;
	}

	// B16: commit without boundary must NOT promote live.
	write_record(t, pack_q0(true, true, 9, 1), true, /*do_promote=*/false);
	if (t->live_seq == 9 || !t->pending_valid) {
		std::fprintf(stderr, "FAIL B16: commit promoted without frame_boundary seq=%u pend=%u\n",
		             (unsigned)t->live_seq, (unsigned)t->pending_valid);
		return 1;
	}
	if (t->live_seq != 8) {
		std::fprintf(stderr, "FAIL B16: live moved before promote live_seq=%u\n",
		             (unsigned)t->live_seq);
		return 1;
	}
	promote(t);
	if (t->live_seq != 9 || t->pending_valid || !t->geom_enable) {
		std::fprintf(stderr, "FAIL B16: promote failed seq=%u pend=%u geom=%u\n",
		             (unsigned)t->live_seq, (unsigned)t->pending_valid,
		             (unsigned)t->geom_enable);
		return 1;
	}

	std::printf("PASS B4 product epoch rejects ABA; B16 stage-then-promote ok\n");
	delete t;
	return 0;
}
