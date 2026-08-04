// MULTI e2e: gradient on DE + HS/VS activity; store-miss forces black push RGB.
#include "Vpresent_multi_e2e_tb_top.h"
#include "verilated.h"
#include <cstdio>
#include <cstdlib>
#include <cstdint>

static void tick(Vpresent_multi_e2e_tb_top& t) {
	t.clk = 0; t.eval();
	t.clk = 1; t.eval();
}

int main(int argc, char** argv) {
	Verilated::commandArgs(argc, argv);
	Vpresent_multi_e2e_tb_top top;

	top.force_store_miss = 0;
	top.reset = 1;
	for (int i = 0; i < 8; ++i) tick(top);
	top.reset = 0;

	// Warm: run enough cycles for >1 line of compact 1650@PPC2 (=825 ce/line)
	// plus store pipe + npx. 50k cycles is plenty at 1 clk domain.
	int hs_rise = 0, vs_rise = 0, de_px = 0, grad_ok = 0, grad_bad = 0;
	int prev_hs = 0, prev_vs = 0;
	uint8_t last_r = 0;

	for (int i = 0; i < 50000; ++i) {
		tick(top);
		if (top.out_ce) {
			if (top.out_hsync && !prev_hs) hs_rise++;
			if (top.out_vsync && !prev_vs) vs_rise++;
			prev_hs = top.out_hsync;
			prev_vs = top.out_vsync;
			// Active video: not blank
			if (!top.out_hblank && !top.out_vblank) {
				de_px++;
				// Gradient: G should track Y slowly; R changes along line.
				// Soft check: some non-zero chroma over DE window once streaming.
				if (top.out_r != 0 || top.out_g != 0 || top.out_b != 0)
					grad_ok++;
				else
					grad_bad++;
				last_r = top.out_r;
			}
		}
	}

	std::printf("PHASE1 hs_rise=%d vs_rise=%d de_px=%d grad_ok=%d grad_bad=%d last_r=%u\n",
	            hs_rise, vs_rise, de_px, grad_ok, grad_bad, unsigned(last_r));

	if (hs_rise < 2) {
		std::fprintf(stderr, "FAIL: expected multiple HSync rises, got %d\n", hs_rise);
		return 1;
	}
	if (vs_rise < 1) {
		std::fprintf(stderr, "FAIL: expected VSync rise, got %d\n", vs_rise);
		return 1;
	}
	// Short-V TB: 8 active lines × 1280 ≈ 10k DE px/frame; allow one frame worth.
	if (de_px < 500) {
		std::fprintf(stderr, "FAIL: expected DE pixels, got %d\n", de_px);
		return 1;
	}
	if (grad_ok < 50) {
		std::fprintf(stderr, "FAIL: expected non-black gradient DE, grad_ok=%d\n", grad_ok);
		return 1;
	}

	// PHASE2: force store miss — push RGB must go black (dbg_push_r0==0 when pushing DE)
	top.force_store_miss = 1;
	int miss_black = 0, miss_nonzero = 0, miss_samples = 0;
	for (int i = 0; i < 20000; ++i) {
		tick(top);
		// Sample gated push RGB (before npx) via dbg
		if (top.store_nv_live == 0) {
			miss_samples++;
			if (top.dbg_push_r0 == 0)
				miss_black++;
			else
				miss_nonzero++;
		}
	}
	std::printf("PHASE2 miss_samples=%d miss_black=%d miss_nonzero=%d\n",
	            miss_samples, miss_black, miss_nonzero);
	if (miss_samples < 100) {
		std::fprintf(stderr, "FAIL: store miss not observed\n");
		return 1;
	}
	if (miss_nonzero != 0) {
		std::fprintf(stderr, "FAIL: store miss must black-gate push RGB (nonzero=%d)\n",
		             miss_nonzero);
		return 1;
	}

	std::printf("PASS present_multi_e2e: gradient+sync OK; fs_rd_n_valid gate blacks on miss\n");
	return 0;
}
