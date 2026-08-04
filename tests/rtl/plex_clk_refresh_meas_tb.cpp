// Gray-counter refresh measure TB.
// POS: ~24 fps + real pix rate → PASS band + pix_ok
// NEG: ~16 fps trap → FAIL band (predicate rejects)
#include "Vplex_clk_refresh_meas_tb_top.h"
#include "verilated.h"
#include <cstdio>
#include <cstdint>

static const int PASS_LO = 230, PASS_HI = 250;
static const int TRAP_LO = 150, TRAP_HI = 170;
static const int WIN = 20000; // -DTB_MEAS_WIN
// Product ratio (PRESENT_CLK_PIX_PLL): 29.7e6 / 20e6
static const double PIX_PER_SYS = 29.7e6 / 20.0e6;
// DE duty ≈ H_ACTIVE*V_ACTIVE / (H_TOTAL*V_TOTAL)
static const double DE_DUTY = (1280.0 * 720.0) / (1650.0 * 750.0);

static int run_case(VerilatedContext* ctx, const char* name, int expect_frames,
                    int expect_pass) {
	auto* top = new Vplex_clk_refresh_meas_tb_top{ctx};

	top->clk = 0;
	top->reset = 1;
	top->clk_pix = 0;
	top->vsync = 0;
	top->ce_pix = 1;
	top->de = 0;
	for (int i = 0; i < 8; i++) {
		top->clk = 1; top->eval(); ctx->timeInc(1);
		top->clk = 0; top->eval(); ctx->timeInc(1);
	}
	top->reset = 0;

	double pix_acc = 0.0;
	uint64_t pix_edges = 0;

	const int spacing = (expect_frames > 0) ? (WIN / (expect_frames + 1)) : WIN;
	int next_k = 0;
	int next_pulse = spacing;

	int cycles = 0;
	const int limit = WIN * 3 + 800;
	while (cycles < limit) {
		// Source-domain free-run: may exceed 1 edge per sys cycle (Gray path)
		pix_acc += PIX_PER_SYS;
		while (pix_acc >= 1.0) {
			top->clk_pix = 0;
			top->eval();
			ctx->timeInc(1);
			top->ce_pix = 1;
			top->de = ((pix_edges % 1000) < int(DE_DUTY * 1000.0)) ? 1 : 0;
			top->clk_pix = 1;
			top->eval();
			ctx->timeInc(1);
			pix_edges++;
			pix_acc -= 1.0;
		}

		int vs = 0;
		if (next_k < expect_frames && cycles == next_pulse) {
			vs = 1;
			next_k++;
			next_pulse = spacing * (next_k + 1);
		}
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
		if (top->meas_done && cycles > WIN + 40)
			break;
	}

	const int fps_x10 = top->meas_fps_x10;
	const int flags = top->meas_flags;
	const int valid  = (flags >> 0) & 1;
	const int pix_ok = (flags >> 1) & 1;
	const int fps_ok = (flags >> 2) & 1;
	const int trap   = (flags >> 4) & 1;
	const int ce_ok  = (flags >> 5) & 1;
	const int de_ok  = (flags >> 6) & 1;
	const int pass_band = (fps_x10 >= PASS_LO && fps_x10 <= PASS_HI);
	const int trap_band = (fps_x10 >= TRAP_LO && fps_x10 <= TRAP_HI);

	std::printf("%s: cycles=%d fps_x10=%d flags=0x%02x frames=%u "
	            "meas_pix=%u meas_ce=%u meas_de=%u driven_pix=%llu "
	            "pass_band=%d trap_band=%d pix_ok=%d fps_ok=%d ce_ok=%d de_ok=%d trap=%d\n",
	            name, cycles, fps_x10, flags, top->meas_frames,
	            top->meas_pix, top->meas_ce, top->meas_de,
	            (unsigned long long)pix_edges,
	            pass_band, trap_band, pix_ok, fps_ok, ce_ok, de_ok, trap);

	int ok;
	if (expect_pass) {
		ok = valid && pass_band && fps_ok && pix_ok && !trap_band;
		std::printf("%s %s: expected PASS_24 band + pix_ok (Gray)\n",
		            ok ? "PASS" : "FAIL", name);
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
