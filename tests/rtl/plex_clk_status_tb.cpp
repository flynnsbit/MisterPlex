// Verilator TB: product-default clock stamp must report the 20 MHz wall.
#include "Vplex_clk_status_tb_top.h"
#include "verilated.h"
#include <cstdint>
#include <cstdio>
#include <cstdlib>

static void tick(Vplex_clk_status_tb_top* top) {
	top->clk = 0; top->eval();
	top->clk = 1; top->eval();
}

int main(int argc, char** argv) {
	Verilated::commandArgs(argc, argv);
	auto* top = new Vplex_clk_status_tb_top;
	top->reset = 1;
	for (int i = 0; i < 4; i++) tick(top);
	top->reset = 0;
	for (int i = 0; i < 4; i++) tick(top);

	int fails = 0;
	auto expect_u32 = [&](const char* n, uint32_t got, uint32_t exp) {
		if (got != exp) {
			std::printf("FAIL %s got=%u exp=%u\n", n, got, exp);
			fails++;
		}
	};
	auto expect_u8 = [&](const char* n, uint8_t got, uint8_t exp) {
		if (got != exp) {
			std::printf("FAIL %s got=%u exp=%u\n", n, got, exp);
			fails++;
		}
	};

	// Product default predictions (PRE-REG):
	// sys=20e6, pix=20e6, ppc=1, cea_pf=1237500, l4_pf=999744
	// cea_needs_faster=1, l4_needs_faster=1 (20e6 < 23994336), peak_x10=200
	expect_u32("clk_sys_hz", top->clk_sys_hz, 20000000u);
	expect_u32("clk_pix_hz", top->clk_pix_hz, 20000000u);
	expect_u8("present_ppc", top->present_ppc, 1);
	expect_u32("cea_pix_frame", top->cea_pix_frame, 1650u * 750u);
	expect_u32("l4_pix_frame", top->l4_pix_frame, 1312u * 762u);
	if (!top->cea_24_needs_faster_pix) {
		std::printf("FAIL cea_24_needs_faster_pix got=0 exp=1\n");
		fails++;
	}
	if (!top->l4_24_needs_faster_sys) {
		std::printf("FAIL l4_24_needs_faster_sys got=0 exp=1\n");
		fails++;
	}
	expect_u32("peak_mpix_s_x10", top->peak_mpix_s_x10, 200u);
	if (!top->kit_id_valid) {
		std::printf("FAIL kit_id_valid\n");
		fails++;
	}

	// Negative: wrong frame size must not match
	if (top->cea_pix_frame == 1280u * 720u) {
		std::printf("FAIL cea_pix_frame is active-only (missing blanking)\n");
		fails++;
	}

	if (fails) {
		std::printf("plex_clk_status TB FAIL fails=%d\n", fails);
		delete top;
		return 1;
	}
	std::printf("plex_clk_status TB PASS sys=%u pix=%u ppc=%u peak_x10=%u cea_fast=%u l4_fast=%u\n",
		top->clk_sys_hz, top->clk_pix_hz, top->present_ppc, top->peak_mpix_s_x10,
		top->cea_24_needs_faster_pix, top->l4_24_needs_faster_sys);
	delete top;
	return 0;
}
