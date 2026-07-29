// Execute h264_dpb_ddr BRAM_REF path: write frame, swap+load, read luma from BRAM
// with fixed +1 latency; chroma still via variable-latency DDR model.
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <vector>
#include "Vh264_dpb_bram_ref_tb_top.h"
#include "verilated.h"

static vluint64_t main_time = 0;
double sc_time_stamp() { return (double)main_time; }

static void tick(Vh264_dpb_bram_ref_tb_top* t) {
	t->clk = 0; t->eval(); main_time++;
	t->clk = 1; t->eval(); main_time++;
}

// Simple DDR model: 64-bit words, burst reads, variable first-data latency.
struct DdrModel {
	static const int WORDS = 4096;
	uint64_t mem[WORDS];
	// pending read beats
	uint64_t beat_data[16];
	int beat_lat[16];
	int beat_n = 0;
	int lat_pat = 0;
	DdrModel() { std::memset(mem, 0, sizeof(mem)); }

	void step(Vh264_dpb_bram_ref_tb_top* t) {
		t->ddr_dout_ready = 0;
		t->ddr_dout = 0;
		if (beat_n > 0) {
			for (int i = 0; i < beat_n; i++) beat_lat[i]--;
			if (beat_lat[0] <= 0) {
				t->ddr_dout_ready = 1;
				t->ddr_dout = beat_data[0];
				for (int i = 1; i < beat_n; i++) {
					beat_lat[i-1] = beat_lat[i];
					beat_data[i-1] = beat_data[i];
				}
				beat_n--;
			}
		}
		t->ddr_busy = (beat_n >= 12) ? 1 : 0;
		if (t->ddr_we && !t->ddr_busy) {
			uint32_t a = t->ddr_addr % WORDS;
			uint64_t din = t->ddr_din;
			uint8_t be = t->ddr_be;
			uint64_t old = mem[a];
			for (int b = 0; b < 8; b++) {
				if (be & (1u << b)) {
					uint64_t m = 0xFFull << (8 * b);
					old = (old & ~m) | (din & m);
				}
			}
			mem[a] = old;
		}
		if (t->ddr_rd && !t->ddr_busy && beat_n + t->ddr_burstcnt <= 16) {
			uint32_t a = t->ddr_addr % WORDS;
			lat_pat = (lat_pat % 4) + 1;
			int burst = t->ddr_burstcnt ? t->ddr_burstcnt : 1;
			for (int i = 0; i < burst; i++) {
				beat_data[beat_n] = mem[(a + i) % WORDS];
				// first beat after lat_pat; subsequent beats back-to-back
				beat_lat[beat_n] = lat_pat + i;
				beat_n++;
			}
		}
	}
};

int main(int argc, char** argv) {
	Verilated::commandArgs(argc, argv);
	auto* t = new Vh264_dpb_bram_ref_tb_top;
	DdrModel ddr;

	t->reset = 1;
	t->idr_start = 0;
	t->frame_done_req = 0;
	t->rec_wr_en = 0;
	t->ref_rd_en = 0;
	t->ddr_busy = 0;
	t->ddr_dout_ready = 0;
	t->ddr_dout = 0;
	for (int i = 0; i < 4; i++) { ddr.step(t); tick(t); }
	t->reset = 0;

	const int Y = 32 * 16; // 512
	const uint32_t DDR_BASE_WORD = 0x30400000u >> 3;

	// Write luma pattern into current bank (base 0)
	for (int i = 0; i < Y; i++) {
		int guard = 0;
		while (t->rec_wr_full && guard++ < 1000) { ddr.step(t); tick(t); }
		t->rec_wr_en = 1;
		t->rec_wr_addr = (uint32_t)i;
		t->rec_wr_data = (uint8_t)(0xA0 ^ (i * 13));
		ddr.step(t); tick(t);
		t->rec_wr_en = 0;
	}
	// Also write one chroma byte so DDR path is non-empty
	{
		int guard = 0;
		while (t->rec_wr_full && guard++ < 1000) { ddr.step(t); tick(t); }
		t->rec_wr_en = 1;
		t->rec_wr_addr = (uint32_t)Y; // first U byte
		t->rec_wr_data = 0x5C;
		ddr.step(t); tick(t);
		t->rec_wr_en = 0;
	}

	// Frame done -> drain -> BRAM load -> commit
	t->frame_done_req = 1;
	ddr.step(t); tick(t);
	t->frame_done_req = 0;
	int wait = 0;
	while (!t->frame_done_ack && wait++ < 200000) { ddr.step(t); tick(t); }
	if (!t->frame_done_ack) {
		std::printf("FAIL: frame_done_ack timeout (swap_busy=%d ref_ready=%d)\n",
			(int)t->swap_busy, (int)t->ref_ready);
		return 1;
	}
	// absorb ack cycle
	ddr.step(t); tick(t);
	if (!t->ref_ready) {
		std::printf("FAIL: ref_ready not set after ack\n");
		return 1;
	}

	// Reference base should be previous current (0)
	uint32_t ref_base = t->reference_base;
	std::printf("INFO: reference_base=0x%x current_base=0x%x\n", ref_base, (unsigned)t->current_base);

	int errs = 0;
	std::vector<uint8_t> out(Y, 0);
#ifdef BRAM_REF_FALLBACK
	// Pure-DDR fallback: one sample at a time (hold en through stall, drop after accept).
	for (int i = 0; i < Y; i++) {
		t->ref_rd_en = 1;
		t->ref_rd_addr = ref_base + (uint32_t)i;
		int accepted = 0, cvalid = 0;
		uint8_t cgot = 0;
		for (int k = 0; k < 5000 && !cvalid; k++) {
			t->eval();
			if (!accepted && t->ref_rd_en && !t->ref_rd_stall)
				accepted = 1;
			ddr.step(t);
			tick(t);
			if (accepted)
				t->ref_rd_en = 0;
			if (t->ref_rd_valid) {
				cgot = t->ref_rd_data;
				cvalid = 1;
			}
		}
		if (!accepted || !cvalid) {
			std::printf("FAIL: luma[%d] accept=%d valid=%d\n", i, accepted, cvalid);
			errs++;
			break;
		}
		out[i] = cgot;
	}
#else
	// BRAM path: stall-free pipelined reads after load.
	int got = 0;
	std::vector<int> pending;
	int idx = 0;
	wait = 0;
	while ((got < Y || !pending.empty()) && wait++ < 50000) {
		t->ref_rd_en = 0;
		if (idx < Y) {
			t->ref_rd_en = 1;
			t->ref_rd_addr = ref_base + (uint32_t)idx;
		}
		if (t->ref_rd_en && t->ref_rd_stall) {
			std::printf("FAIL: unexpected stall on luma BRAM rd idx=%d\n", idx);
			errs++;
			break;
		}
		if (t->ref_rd_en && !t->ref_rd_stall) {
			pending.push_back(idx);
			idx++;
		}
		ddr.step(t); tick(t);
		if (t->ref_rd_valid) {
			if (pending.empty()) {
				std::printf("FAIL: valid with empty pending\n");
				errs++;
				break;
			}
			int pi = pending.front();
			pending.erase(pending.begin());
			out[pi] = t->ref_rd_data;
			got++;
		}
	}
	t->ref_rd_en = 0;
#endif

	for (int i = 0; i < Y; i++) {
		uint8_t exp = (uint8_t)(0xA0 ^ (i * 13));
		if (out[i] != exp) {
			if (errs < 8)
				std::printf("FAIL: luma[%d] got 0x%02x exp 0x%02x\n", i, out[i], exp);
			errs++;
		}
	}

	// Chroma byte via DDR path (offset Y) under variable latency.
	// Hold req until accept, then wait for +1 registered valid.
	{
		t->ref_rd_en = 1;
		t->ref_rd_addr = ref_base + (uint32_t)Y;
		int accepted = 0;
		uint8_t cgot = 0;
		int cvalid = 0;
		for (int k = 0; k < 2000 && !cvalid; k++) {
			t->eval();
			if (!accepted && t->ref_rd_en && !t->ref_rd_stall) {
				accepted = 1;
				// drop en next cycle after accept (hold this cycle)
			}
			ddr.step(t);
			tick(t);
			if (accepted)
				t->ref_rd_en = 0;
			if (t->ref_rd_valid) {
				cgot = t->ref_rd_data;
				cvalid = 1;
			}
		}
		if (!accepted) {
			std::printf("FAIL: chroma never accepted (stall stuck)\n");
			errs++;
		} else if (!cvalid || cgot != 0x5C) {
			std::printf("FAIL: chroma DDR path got valid=%d data=0x%02x\n", cvalid, cgot);
			errs++;
		} else {
			std::printf("INFO: chroma DDR path OK (var latency)\n");
		}
	}

	if (errs == 0) {
#ifdef BRAM_REF_FALLBACK
		std::printf("PASS: BRAM_REF=0 fallback luma %d bytes exact via DDR, chroma OK\n", Y);
#else
		std::printf("PASS: BRAM luma %d bytes exact, chroma DDR OK, frame_done load OK\n", Y);
#endif
		delete t;
		return 0;
	}
	std::printf("FAIL: %d errors\n", errs);
	delete t;
	return 1;
}
