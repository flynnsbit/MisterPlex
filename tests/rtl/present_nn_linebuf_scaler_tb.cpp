// Verilator TB: present_nn_linebuf_scaler NN H-scale + M10K accounting.
// POSITIVE: 640→1280 identity ramp; glass samples match NN reference.
// NEGATIVE (PRESENT_NN_LB_FAULT_FLOOR_SCALE): force sx>>1 → must DIVERGE.
#include "Vpresent_nn_linebuf_scaler_tb_top.h"
#include "verilated.h"
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <vector>

static vluint64_t main_time = 0;
double sc_time_stamp() { return (double)main_time; }

static void tick(Vpresent_nn_linebuf_scaler_tb_top& top) {
	top.clk = 0;
	top.eval();
	main_time++;
	top.clk = 1;
	top.eval();
	main_time++;
}

static uint32_t nn_x(uint32_t rd_x, uint32_t cw, uint32_t dw) {
	// floor(rd_x * cw / dw) via Q16 like RTL
	uint32_t sx = (cw * 65536u) / dw;
	uint32_t prod = rd_x * sx;
	uint32_t x = prod >> 16;
	if (x >= cw)
		x = cw - 1;
	return x;
}

int main(int argc, char** argv) {
	Verilated::commandArgs(argc, argv);
	Vpresent_nn_linebuf_scaler_tb_top top{};

	const uint32_t cw = 640;
	const uint32_t dw = 1280;

	top.reset = 1;
	top.ce_pix = 1;
	top.content_w = cw;
	top.de_w = dw;
	top.wr_valid = 0;
	top.wr_line_done = 0;
	top.rd_en = 0;
	top.rd_use_prev = 0;
	for (int i = 0; i < 4; i++)
		tick(top);
	top.reset = 0;
	// let geom settle
	for (int i = 0; i < 4; i++)
		tick(top);

	if (!top.cfg_ok) {
		std::fprintf(stderr, "FAIL cfg_ok=0 m10k_bit=%u naive=%u\n", top.m10k_ideal_c, top.m10k_naive_x8_c);
		return 1;
	}
	// Bit-ideal lower bound: LINE_HOLD=2, 1280*24*2/10240 = 6
	// Naive 1K×8 RGB: 2 * 3 * ceil(1280/1024) = 12
	if (top.m10k_ideal_c != 6) {
		std::fprintf(stderr, "FAIL m10k_bit_ideal want 6 got %u\n", top.m10k_ideal_c);
		return 1;
	}
	if (top.m10k_naive_x8_c != 12) {
		std::fprintf(stderr, "FAIL m10k_naive_x8 want 12 got %u\n", top.m10k_naive_x8_c);
		return 1;
	}
	std::printf("OK m10k bit_ideal=%u naive_x8=%u cfg_ok=1 "
	            "(handbook: 1K×8=1024B; 1280 line needs 2 M10K/plane)\n",
	            top.m10k_ideal_c, top.m10k_naive_x8_c);

	// Write one content line: pixel = (x, x^0x55, 255-x) in low 24b
	for (uint32_t x = 0; x < cw; x++) {
		top.wr_valid = 1;
		top.wr_x = x;
		uint8_t r = (uint8_t)x;
		uint8_t g = (uint8_t)(x ^ 0x55u);
		uint8_t b = (uint8_t)(255u - x);
		top.wr_pix = (r << 16) | (g << 8) | b;
		tick(top);
	}
	top.wr_valid = 0;
	top.wr_line_done = 1;
	tick(top);
	top.wr_line_done = 0;
	tick(top);

	// Read full DE width
	int mism = 0;
	int checked = 0;
	for (uint32_t gx = 0; gx < dw; gx++) {
		top.rd_en = 1;
		top.rd_x = gx;
		tick(top);
		if (!top.rd_valid) {
			std::fprintf(stderr, "FAIL rd_valid=0 at gx=%u\n", gx);
			return 1;
		}
		uint32_t src = nn_x(gx, cw, dw);
#ifdef PRESENT_NN_LB_FAULT_FLOOR_SCALE
		// naive wrong: half scale → wrong source index
		src = nn_x(gx, cw / 2, dw);
#endif
		uint8_t er = (uint8_t)src;
		uint8_t eg = (uint8_t)(src ^ 0x55u);
		uint8_t eb = (uint8_t)(255u - src);
		uint32_t exp = (er << 16) | (eg << 8) | eb;
		uint32_t got = top.rd_pix & 0xFFFFFFu;
		if (got != exp) {
			if (mism < 8)
				std::fprintf(stderr, "mism gx=%u got=%06x exp=%06x src=%u\n", gx, got, exp,
				             src);
			mism++;
		}
		checked++;
	}
	top.rd_en = 0;

#ifdef PRESENT_NN_LB_FAULT_FLOOR_SCALE
	if (mism == 0) {
		std::fprintf(stderr, "FAIL NEGATIVE: FLOOR_SCALE did not diverge\n");
		return 1;
	}
	std::printf("NEGATIVE PASS FLOOR_SCALE mism=%d checked=%d\n", mism, checked);
	return 0; // red-proof path: divergence is success for the wrapper script
#else
	if (mism != 0) {
		std::fprintf(stderr, "FAIL positive mism=%d/%d\n", mism, checked);
		return 1;
	}
	// BW counters: 1 content line, dw glass hits
	if (top.rd_bw_content_lines != 1) {
		std::fprintf(stderr, "FAIL content_lines=%u want 1\n", top.rd_bw_content_lines);
		return 1;
	}
	if (top.rd_bw_glass_hits != dw) {
		std::fprintf(stderr, "FAIL glass_hits=%u want %u\n", top.rd_bw_glass_hits, dw);
		return 1;
	}
	std::printf("PASS present_nn_linebuf_scaler checked=%d lines=1 hits=%u "
	            "m10k_bit=%u naive=%u\n",
	            checked, top.rd_bw_glass_hits, top.m10k_ideal_c, top.m10k_naive_x8_c);
	return 0;
#endif
}
