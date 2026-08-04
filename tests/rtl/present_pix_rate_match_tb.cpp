// Prove Bresenham throttle averages F_PIX Mpix/s at F_SYS with PPC.
// PRE-REG (200_000 cycles, always ready):
//   fire_count ≈ cycles * F_PIX / (F_SYS * PPC) = 200000 * 29.7/40 = 148500
//   pixels     = fire_count * PPC ≈ 297000
// Tolerance ±0.5% (±743 fires).
#include "Vpresent_pix_rate_match_tb_top.h"
#include "verilated.h"
#include <cstdio>
#include <cstdlib>
#include <cmath>

int main(int argc, char** argv) {
	Verilated::commandArgs(argc, argv);
	Vpresent_pix_rate_match_tb_top top;

	const int CYCLES = 200000;
	const double F_SYS = 20e6;
	const double F_PIX = 29.7e6;
	const int PPC = 2;
	const double expect_fires = double(CYCLES) * F_PIX / (F_SYS * double(PPC));
	const int tol = int(std::lround(expect_fires * 0.005)) + 2;

	std::printf("PRE-REG: cycles=%d expect_fires≈%.1f tol=%d pixels≈%.0f\n",
	            CYCLES, expect_fires, tol, expect_fires * PPC);

	top.clk = 0;
	top.reset = 1;
	top.in_ready = 1;
	for (int i = 0; i < 4; ++i) {
		top.clk = 0; top.eval();
		top.clk = 1; top.eval();
	}
	top.reset = 0;

	long fires = 0;
	for (int i = 0; i < CYCLES; ++i) {
		top.clk = 0; top.eval();
		top.clk = 1; top.eval();
		if (top.fire)
			fires++;
	}

	const double pixels = double(fires) * PPC;
	const int d = int(std::llabs(fires - std::llround(expect_fires)));
	std::printf("RESULT fires=%ld pixels=%.0f delta_fires=%d\n", fires, pixels, d);

	if (d > tol) {
		std::fprintf(stderr, "FAIL rate_match: |fires-expect|=%d > tol=%d\n", d, tol);
		return 1;
	}
	// Pixel rate must clear CEA 24 need when scaled to 1s of clk_sys:
	// pixels_per_sec = fires/CYCLES * F_SYS * PPC
	const double pps = (double(fires) / double(CYCLES)) * F_SYS * double(PPC);
	if (pps < 29.6e6) {
		std::fprintf(stderr, "FAIL rate_match: pps=%.0f < 29.6e6\n", pps);
		return 1;
	}
	std::printf("present_pix_rate_match TB PASS fires=%ld pps=%.0f\n", fires, pps);
	return 0;
}
