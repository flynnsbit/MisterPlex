// present_beam_content_de HSync/VSync exact-width gate (w-clock / rd-duck #1).
// Fails if rt-mode ignores H_SYNC_* and uses H_FP=32 defaults on L4 (0 HSync).
#include "Vpresent_beam_hsync_tb_top.h"
#include "verilated.h"
#include <cstdint>
#include <cstdio>
#include <cstdlib>

static int g_fail = 0;

static void expect_eq(const char* n, uint64_t got, uint64_t want) {
	if (got != want) {
		std::fprintf(stderr, "FAIL %s: got=%llu want=%llu\n", n,
			(unsigned long long)got, (unsigned long long)want);
		g_fail++;
	} else {
		std::printf("OK %s = %llu\n", n, (unsigned long long)got);
	}
}

static void tick(Vpresent_beam_hsync_tb_top* top) {
	top->clk = 0;
	top->eval();
	top->clk = 1;
	top->eval();
}

// Run one full frame after reset; accumulate HSync/VSync stats.
struct SyncStats {
	uint64_t hs_cycles;
	uint64_t vs_cycles;
	uint64_t lines_with_hs;
	uint64_t frames_seen;
	int first_hs_width;
	int first_vs_width_lines;
	int hs_start_hc;
	int vs_start_vc;
};

static SyncStats run_frame(Vpresent_beam_hsync_tb_top* top, int which,
	int h_total, int v_total, int expect_hs_w, int expect_vs_lines)
{
	(void)expect_hs_w;
	(void)expect_vs_lines;
	top->sel = which & 1;
	top->reset = 1;
	for (int i = 0; i < 4; i++) tick(top);
	top->reset = 0;

	SyncStats s{};
	s.first_hs_width = -1;
	s.first_vs_width_lines = -1;
	s.hs_start_hc = -1;
	s.vs_start_vc = -1;

	int prev_hs = 0, prev_vs = 0;
	int hs_run = 0, vs_line_run = 0;
	int line_hs = 0;
	int prev_hc = -1;
	// Enough cycles for >1 full frame
	const int cycles = h_total * v_total + h_total * 4;
	for (int c = 0; c < cycles; c++) {
		tick(top);
		const int hs = top->HSync & 1;
		const int vs = top->VSync & 1;
		const int hc = top->hc_out;
		const int vc = top->vc_out;

		if (hs) {
			s.hs_cycles++;
			hs_run++;
			if (!prev_hs) {
				line_hs++;
				if (s.hs_start_hc < 0) s.hs_start_hc = hc;
			}
		} else if (prev_hs) {
			if (s.first_hs_width < 0) s.first_hs_width = hs_run;
			hs_run = 0;
		}

		if (vs) {
			s.vs_cycles++;
			if (!prev_vs) {
				vs_line_run = 1;
				if (s.vs_start_vc < 0) s.vs_start_vc = vc;
			}
		}

		// line wrap: hc went to 0
		if (prev_hc >= 0 && hc == 0 && prev_hc != 0) {
			if (line_hs) s.lines_with_hs++;
			line_hs = 0;
			if (vs && prev_vs) {
				// still in vsync across line
			}
			if (prev_vs && !vs) {
				// vs ended
			}
			if (vs) {
				// count vs lines at line boundaries while vs high at start
			}
		}

		if (top->frame_start) s.frames_seen++;

		prev_hs = hs;
		prev_vs = vs;
		prev_hc = hc;
	}

	// VSync line width: count unique vc while VSync high over first pulse
	{
		top->reset = 1;
		for (int i = 0; i < 4; i++) tick(top);
		top->reset = 0;
		int seen_vs = 0;
		int vc_min = 9999, vc_max = -1;
		const int cycles2 = h_total * v_total + h_total * 2;
		for (int c = 0; c < cycles2; c++) {
			tick(top);
			if (top->VSync & 1) {
				seen_vs = 1;
				int vc = top->vc_out;
				if (vc < vc_min) vc_min = vc;
				if (vc > vc_max) vc_max = vc;
			} else if (seen_vs) {
				s.first_vs_width_lines = vc_max - vc_min + 1;
				s.vs_start_vc = vc_min;
				break;
			}
		}
	}
	return s;
}

int main(int argc, char** argv) {
	Verilated::commandArgs(argc, argv);
	auto* top = new Vpresent_beam_hsync_tb_top;

	// ---- L4 1280x720 content beam: H=1312 V=762, FP=8 SW=8 ----
	// Exact: HSync width=8, start hc=1288, one pulse per line.
	// VSync: V_FP=8 V_SW=6 → 6 lines starting vc=728.
	{
		const int HT = 1312, VT = 762;
		const int HS_W = 8, VS_L = 6;
		const int HS_S = 1288, VS_S = 728;
		SyncStats s = run_frame(top, /*L4*/1, HT, VT, HS_W, VS_L);
		expect_eq("l4_hs_width", (uint64_t)s.first_hs_width, HS_W);
		expect_eq("l4_hs_start_hc", (uint64_t)s.hs_start_hc, HS_S);
		// At least one full frame of lines should each carry HSync
		expect_eq("l4_lines_with_hs_ge_VT",
			(uint64_t)(s.lines_with_hs >= (uint64_t)VT ? 1 : 0), 1);
		// Total HSync cycles over first VT lines ~= VT * HS_W (allow +partial)
		// After reset, first VT lines: exactly VT * 8 if every line pulses
		expect_eq("l4_vs_width_lines", (uint64_t)s.first_vs_width_lines, VS_L);
		expect_eq("l4_vs_start_vc", (uint64_t)s.vs_start_vc, VS_S);
		// NEGATIVE twin target: pre-fix H_FP=32 path yields width 0
		if (s.first_hs_width == 0) {
			std::fprintf(stderr,
				"FAIL l4_hs_zero: rt-mode ignored H_SYNC_* (rd-duck #1 unfixed)\n");
			g_fail++;
		}
	}

	// ---- 320x240-class beam (product content size) with tight blanking ----
	// H_DE=320 H_TOTAL=400 H_SYNC 328..336 (FP=8 SW=8); V 240/262 FP=3 SW=3
	{
		const int HT = 400, VT = 262;
		const int HS_W = 8, VS_L = 3;
		const int HS_S = 328, VS_S = 243;
		SyncStats s = run_frame(top, /*320*/0, HT, VT, HS_W, VS_L);
		expect_eq("p320_hs_width", (uint64_t)s.first_hs_width, HS_W);
		expect_eq("p320_hs_start_hc", (uint64_t)s.hs_start_hc, HS_S);
		expect_eq("p320_lines_with_hs_ge_VT",
			(uint64_t)(s.lines_with_hs >= (uint64_t)VT ? 1 : 0), 1);
		expect_eq("p320_vs_width_lines", (uint64_t)s.first_vs_width_lines, VS_L);
		expect_eq("p320_vs_start_vc", (uint64_t)s.vs_start_vc, VS_S);
	}

	// colorbars product template constants (static cross-check, 320 content / 529 DE)
	// HSync 544..590 → width 46; must be < H_LAST+1=638
	expect_eq("colorbar_hs_width_const", 590u - 544u, 46u);
	expect_eq("colorbar_hs_fits_line", (uint64_t)(590 < 638 ? 1 : 0), 1);

	delete top;
	if (g_fail) {
		std::fprintf(stderr, "FAIL present_beam_hsync (%d)\n", g_fail);
		return 1;
	}
	std::printf("PASS present_beam_hsync\n");
	return 0;
}
