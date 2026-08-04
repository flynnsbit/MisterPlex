// Refresh measure TB: PASS @ ~24 fps, FAIL @ ~16.16 fps trap.
#include "Vplex_clk_refresh_meas_tb_top.h"
#include "verilated.h"
#include <cstdio>
#include <cstdint>
#include <memory>

static const int PASS_LO = 230, PASS_HI = 250;
static const int TRAP_LO = 150, TRAP_HI = 170;
static const int WIN = 20000; // must match -DTB_MEAS_WIN

// Measure treats WIN sys cycles as "1 second": fps_x10 = frames*10.
// Fire exactly `expect_frames` one-cycle VSync pulses inside the first WIN.
static int run_case(VerilatedContext* ctx, const char* name, int expect_frames,
                    int expect_pass) {
	auto* top = new Vplex_clk_refresh_meas_tb_top{ctx};

	top->clk = 0;
	top->reset = 1;
	top->clk_pix = 0;
	top->vsync = 0;
	for (int i = 0; i < 8; i++) {
		top->clk = 1; top->eval(); ctx->timeInc(1);
		top->clk = 0; top->eval(); ctx->timeInc(1);
	}
	top->reset = 0;

	// Pulse schedule: pulse k at cycle (k+1)*spacing, k=0..expect_frames-1
	// spacing chosen so last pulse < WIN-2
	const int spacing = (expect_frames > 0) ? (WIN / (expect_frames + 1)) : WIN;
	int next_k = 0;
	int next_pulse = spacing;

	int cycles = 0;
	const int limit = WIN * 3 + 500;
	while (cycles < limit) {
		top->clk_pix = (cycles & 1);
		int vs = 0;
		if (next_k < expect_frames && cycles == next_pulse) {
			vs = 1;
			next_k++;
			next_pulse = spacing * (next_k + 1);
		}
		// Only schedule pulses in first window; after that leave idle
		if (cycles >= WIN)
			vs = 0;
		top->vsync = vs;

		top->clk = 1;
		top->eval();
		ctx->timeInc(1);
		top->clk = 0;
		top->eval();
		ctx->timeInc(1);
		cycles++;
		if (top->meas_done && cycles > WIN + 20)
			break;
	}

	const int fps_x10 = top->meas_fps_x10;
	const int flags = top->meas_flags;
	const int valid = flags & 1;
	const int fps_ok = (flags >> 2) & 1;
	const int trap = (flags >> 4) & 1;
	const int pass_band = (fps_x10 >= PASS_LO && fps_x10 <= PASS_HI);
	const int trap_band = (fps_x10 >= TRAP_LO && fps_x10 <= TRAP_HI);

	std::printf("%s: cycles=%d fps_x10=%d flags=0x%02x frames=%u "
	            "pass_band=%d trap_band=%d fps_ok=%d trap_flag=%d\n",
	            name, cycles, fps_x10, flags, top->meas_frames,
	            pass_band, trap_band, fps_ok, trap);

	int ok;
	if (expect_pass) {
		ok = valid && pass_band && fps_ok && !trap_band;
		std::printf("%s %s: expected PASS_24 band\n", ok ? "PASS" : "FAIL", name);
	} else {
		ok = valid && trap_band && !pass_band && !fps_ok;
		std::printf("%s %s: expected FAIL_16_TRAP (predicate rejects)\n",
		            ok ? "PASS" : "FAIL", name);
	}
	top->final();
	delete top;
	return ok ? 0 : 1;
}

int main(int argc, char** argv) {
	int rc = 0;
	{
		VerilatedContext ctx;
		ctx.commandArgs(argc, argv);
		rc |= run_case(&ctx, "POS_24HZ", 24, 1);
	}
	{
		VerilatedContext ctx;
		ctx.commandArgs(argc, argv);
		rc |= run_case(&ctx, "NEG_16HZ_TRAP", 16, 0);
	}
	std::printf("%s plex_clk_refresh_meas_tb all cases\n",
	            rc == 0 ? "PASS" : "FAIL");
	return rc;
}
