// Verilator TB: DPB DDR path, nb-cache left-edge NEG, burst-boundary NEG.
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <vector>
#include "Vh264_dpb_ddr_tb_top.h"
#include "verilated.h"

static vluint64_t main_time = 0;
double sc_time_stamp() { return (double)main_time; }

static void tick(Vh264_dpb_ddr_tb_top* top) {
	top->clk = 0;
	top->eval();
	main_time++;
	top->clk = 1;
	top->eval();
	main_time++;
}

static int fails = 0;
static void expect(bool cond, const char* msg) {
	if (!cond) {
		std::fprintf(stderr, "FAIL %s\n", msg);
		fails++;
	} else {
		std::printf("OK %s\n", msg);
	}
}

int main(int argc, char** argv) {
	Verilated::commandArgs(argc, argv);
	auto* top = new Vh264_dpb_ddr_tb_top;

	// Reset
	top->reset = 1;
	top->loc_we = 0;
	top->loc_rd = 0;
	top->ddr_we = 0;
	top->ddr_rd = 0;
	top->nb_sample_valid = 0;
	top->nb_mb_row_done = 0;
	top->lf_start = 0;
	top->lf_f_start = 0;
	top->lf_ddr_rvalid = 0;
	top->lf_f_ddr_rvalid = 0;
	for (int i = 0; i < 4; i++) tick(top);
	top->reset = 0;
	tick(top);

	std::printf("DPB_DDR_TB_EXECUTED\n");

	// ── 1. Area budget @720p ref=1 (measured product max_num_ref_frames=1) ──
	const uint32_t ref_b = top->bytes_per_ref_frame;
	const uint32_t dpb_b = top->bytes_dpb1_total;
	const uint32_t win_b = top->onchip_window_bytes;
	const uint32_t nb_b = top->onchip_nb_bytes;
	const uint32_t path_b = top->onchip_ddr_path_bytes;
	const uint32_t m10k = top->m10k_lower_bound_full_dpb;
	std::printf("BUDGET ref_frame=%u dpb1=%u win=%u nb=%u path=%u m10k_full=%u illegal=%u\n",
	            ref_b, dpb_b, win_b, nb_b, path_b, m10k, top->full_frame_onchip_illegal);
	expect(ref_b == 1280u * 720u * 3u / 2u, "720p I420 bytes/frame = 1382400");
	expect(dpb_b == 2u * ref_b, "DPB1 = cur+1ref");
	expect(top->full_frame_onchip_illegal == 1, "full-frame on-chip illegal @720p");
	expect(m10k > 553u, "full DPB M10K lower bound exceeds part (553)");
	expect(win_b == 603u, "window cache 441+81+81=603");
	expect(path_b < 20000u, "DDR-path on-chip working set << frame");
	// DELTA vs LIVE helpers (already synthesise; 0 frame storage in h264_dpb.sv)
	expect(top->live_helper_frame_storage_bytes == 0u, "LIVE helpers add 0 frame storage");
	expect(top->stub_bram_bytes_if_kept == dpb_b, "stub BRAM baseline = full DPB1");
	expect(top->ddr_path_delta_onchip_bytes == path_b, "DDR path delta onchip = path working set");
	// Publish vs prereg ≤12 M10K (~15kB): path_b bits/10240
	const uint32_t path_m10k = (path_b * 8u + 10239u) / 10240u;
	const int32_t m10k_delta = top->m10k_delta_vs_stub_bram;
	std::printf("MEASURE path_onchip_bytes=%u path_m10k_lower=%u prereg_max=12\n", path_b, path_m10k);
	std::printf("DELTA live_helper_frame_B=0 stub_bram_if_kept=%u ddr_path_add=%u m10k_delta_vs_stub=%d\n",
	            top->stub_bram_bytes_if_kept, top->ddr_path_delta_onchip_bytes, m10k_delta);
	expect(path_m10k <= 12u, "path M10K lower bound ≤ prereg 12");
	// Prereg: replacing stub@720p BRAM with DDR path saves ~full DPB M10K (delta << 0)
	expect(m10k_delta < -500, "DELTA m10k vs stub BRAM strongly negative (savings)");

	// ── 2. Product default local backend: on-chip dual bank, bank0=0 ──
	expect(top->loc_bank0 == 0u, "local bank0=0");
	expect(top->loc_onchip_bytes == 2u * (64u * 32u * 3u / 2u), "local on-chip = dual frame");
	// write/read roundtrip 1-cycle-ish
	top->loc_we = 1;
	top->loc_waddr = 10;
	top->loc_wdata = 0xA5;
	tick(top);
	top->loc_we = 0;
	top->loc_rd = 1;
	top->loc_raddr = 10;
	tick(top);
	// After this posedge: rvalid=1 and combo rdata from raddr_q=10
	expect(top->loc_rvalid == 1 && top->loc_rdata == 0xA5, "local write/read 0xA5");
	top->loc_rd = 0;
	tick(top);

	// ── 3. DDR backend: phys bases, onchip_storage=0, multi-cy read ──
	expect(top->ddr_bank0 == 0x30700000u, "DDR bank0 phys 0x30700000");
	expect(top->ddr_bank1 == 0x30880000u, "DDR bank1 phys 0x30880000");
	expect(top->ddr_onchip_bytes == 0u, "DDR path onchip frame storage = 0");
	const uint32_t pa = 0x30700000u + 100u;
	top->ddr_we = 1;
	top->ddr_waddr = pa;
	top->ddr_wdata = 0x5C;
	tick(top);
	top->ddr_we = 0;
	top->ddr_rd = 1;
	top->ddr_raddr = pa;
	tick(top);
	top->ddr_rd = 0;
	int saw = 0;
	uint8_t got = 0;
	for (int i = 0; i < 16; i++) {
		tick(top);
		if (top->ddr_rvalid) {
			saw++;
			got = top->ddr_rdata;
			break;
		}
	}
	expect(saw == 1 && got == 0x5C, "DDR multi-cy read returns 0x5C");

	// ── 4. nb cache: left OK only when mb_x!=0 ──
	// Fill right edge of MB (0,0) so have_left becomes true, then query at mb_x=0 → left_ok=0
	for (int row = 0; row < 16; row++) {
		top->nb_sample_valid = 1;
		top->nb_mb_x = 0;
		top->nb_mb_y = 0;
		top->nb_plane = 0;
		top->nb_sample_idx = (uint8_t)((row << 4) | 0xF); // x=15 right edge
		top->nb_sample = (uint8_t)(0x40 + row);
		tick(top);
	}
	top->nb_sample_valid = 0;
	tick(top);
	top->nb_left_mb_x = 0;
	top->nb_left_row = 3;
	tick(top);
	// have_left may be 1 from right-edge writes, but left_ok must be 0 at mb_x=0
	expect(top->nb_left_ok == 0, "NEG left_ok=0 at picture left (mb_x=0)");

	// Now pretend next MB x=1 — left_ok should be 1
	top->nb_left_mb_x = 1;
	tick(top);
	expect(top->nb_left_ok == 1 && top->nb_have_left == 1, "left_ok=1 for mb_x=1 after right-edge fill");
	top->nb_left_row = 3;
	tick(top);
	expect(top->nb_left_y_sample == (uint8_t)(0x40 + 3), "left col sample row3");

	// ── 5. Burst boundary line fetch POS + FAULT NEG ──
	// Model 64-bit DDR memory in C++
	std::vector<uint8_t> mem(256, 0);
	for (int i = 0; i < 256; i++) mem[i] = (uint8_t)(0x10 + i);

	auto run_fetch = [&](bool fault, uint32_t base, int nbytes, uint8_t* out8) -> bool {
		// drive either good or fault instance
		if (!fault) {
			top->lf_start = 1;
			top->lf_base = base;
			top->lf_nbytes = nbytes;
			tick(top);
			top->lf_start = 0;
		} else {
			top->lf_f_start = 1;
			top->lf_f_base = base;
			top->lf_f_nbytes = nbytes;
			tick(top);
			top->lf_f_start = 0;
		}
		bool done = false;
		for (int cyc = 0; cyc < 64 && !done; cyc++) {
			// default no data
			top->lf_ddr_rvalid = 0;
			top->lf_f_ddr_rvalid = 0;
			if (!fault && top->lf_ddr_rd) {
				uint32_t a = top->lf_ddr_raddr;
				uint64_t w = 0;
				for (int b = 0; b < 8; b++) {
					uint8_t v = (a + b < mem.size()) ? mem[a + b] : 0;
					w |= (uint64_t)v << (8 * b);
				}
				top->lf_ddr_rdata = w;
				top->lf_ddr_rvalid = 1;
			}
			if (fault && top->lf_f_ddr_rd) {
				uint32_t a = top->lf_f_ddr_raddr;
				uint64_t w = 0;
				for (int b = 0; b < 8; b++) {
					uint8_t v = (a + b < mem.size()) ? mem[a + b] : 0;
					w |= (uint64_t)v << (8 * b);
				}
				top->lf_f_ddr_rdata = w;
				top->lf_f_ddr_rvalid = 1;
			}
			tick(top);
			if (!fault && top->lf_done) {
				out8[0] = top->lf_out0;
				out8[1] = top->lf_out1;
				out8[2] = top->lf_out2;
				out8[3] = top->lf_out3;
				out8[4] = top->lf_out4;
				out8[5] = top->lf_out5;
				out8[6] = top->lf_out6;
				out8[7] = top->lf_out7;
				done = true;
			}
			if (fault && top->lf_f_done) {
				out8[0] = top->lf_f_out0;
				out8[1] = top->lf_f_out1;
				out8[2] = top->lf_f_out2;
				out8[3] = top->lf_f_out3;
				out8[4] = top->lf_f_out4;
				out8[5] = top->lf_f_out5;
				out8[6] = top->lf_f_out6;
				out8[7] = top->lf_f_out7;
				done = true;
			}
		}
		top->lf_ddr_rvalid = 0;
		top->lf_f_ddr_rvalid = 0;
		return done;
	};

	// Unaligned base=5, nbytes=8 → crosses 8-byte boundary (5..12)
	uint8_t good[8] = {};
	uint8_t bad[8] = {};
	bool dg = run_fetch(false, 5, 8, good);
	bool db = run_fetch(true, 5, 8, bad);
	expect(dg && db, "both line fetches completed");
	bool good_ok = true;
	for (int i = 0; i < 8; i++) {
		if (good[i] != mem[5 + i]) good_ok = false;
	}
	if (!good_ok) {
		std::fprintf(stderr, "good:");
		for (int i = 0; i < 8; i++) std::fprintf(stderr, " %02x", good[i]);
		std::fprintf(stderr, "\nexp :");
		for (int i = 0; i < 8; i++) std::fprintf(stderr, " %02x", mem[5 + i]);
		std::fprintf(stderr, "\nbad :");
		for (int i = 0; i < 8; i++) std::fprintf(stderr, " %02x", bad[i]);
		std::fprintf(stderr, "\n");
	}
	expect(good_ok, "POS burst-cross line fetch matches mem[5..12]");
	bool bad_differs = false;
	for (int i = 0; i < 8; i++) {
		if (bad[i] != mem[5 + i]) bad_differs = true;
	}
	expect(bad_differs, "NEG FAULT_SINGLE_BEAT corrupts cross-boundary fetch");

	std::printf("DPB_DDR_TB fails=%d\n", fails);
	delete top;
	return fails ? 1 : 0;
}
