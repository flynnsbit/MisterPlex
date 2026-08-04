// Refresh measure TB — product 30 MHz / 24.242 Hz path.
// POS_242: period → fps_x10≈242 PASS product band
// NEG_16:  period → ~162 FAIL trap
// NEG_EXACT24: period → 240 is NOT product PASS (distinguishable)
#include "Vplex_clk_refresh_meas_tb_top.h"
#include "verilated.h"
#include <cstdio>
#include <cstdint>

static const int WIN = 20000;
// Product macros: SYS=20e6 PIX=30e6 under PRESENT_CLK_PIX_PLL
static const double PIX_PER_SYS = 30.0e6 / 20.0e6;
static const double DE_DUTY = (1280.0 * 720.0) / (1650.0 * 750.0);

// Period in sys cycles for target fps: SYS/fps (SYS from macros = 20e6)
// Scaled TB: period_tb = WIN_equiv... We drive vsync every `period` sys cycles.
// fps_x10 = (SYS_HZ*10)/period with SYS_HZ=20e6 from RTL macros.
// For TB we need actual periods matching real SYS_HZ in the module (20e6).
// So period_24_242 = 20000000/24.242424 = 825000 — too long for short TB.
// Instead: override is not available; use real periods but short window still
// closes after WIN cycles once period_valid is set from ≥2 vsyncs.

enum Expect { EXP_PASS_242, EXP_FAIL_16, EXP_EXACT24 };

static int run_case(VerilatedContext* ctx, const char* name, int period_sys,
                    Expect exp) {
	auto* top = new Vplex_clk_refresh_meas_tb_top{ctx};
	top->clk = 0; top->reset = 1; top->clk_pix = 0; top->vsync = 0;
	top->ce_pix = 1; top->de = 0;
	for (int i = 0; i < 8; i++) {
		top->clk = 1; top->eval(); ctx->timeInc(1);
		top->clk = 0; top->eval(); ctx->timeInc(1);
	}
	top->reset = 0;

	double pix_acc = 0.0;
	uint64_t pix_edges = 0;
	int cycles = 0;
	int next_vs = period_sys; // first rise after one period
	// Need enough cycles for ≥2 vsyncs (period valid) + one WIN close
	const int limit = period_sys * 4 + WIN + 500;

	while (cycles < limit) {
		pix_acc += PIX_PER_SYS;
		while (pix_acc >= 1.0) {
			top->clk_pix = 0; top->eval(); ctx->timeInc(1);
			top->ce_pix = 1;
			top->de = ((pix_edges % 1000) < int(DE_DUTY * 1000.0)) ? 1 : 0;
			top->clk_pix = 1; top->eval(); ctx->timeInc(1);
			pix_edges++; pix_acc -= 1.0;
		}
		int vs = (cycles == next_vs) ? 1 : 0;
		if (vs) next_vs += period_sys;
		top->vsync = vs;

		top->clk = 1; top->eval(); ctx->timeInc(1);
		top->clk = 0; top->eval(); ctx->timeInc(1);
		cycles++;
		if (top->meas_done && cycles > period_sys * 2 + WIN)
			break;
	}

	const int fps_x10 = top->meas_fps_x10;
	const int flags = top->meas_flags;
	const int valid  = flags & 1;
	const int pix_ok = (flags >> 1) & 1;
	const int fps_ok = (flags >> 2) & 1;
	const int trap   = (flags >> 4) & 1;
	const int pass_band = (fps_x10 >= 241 && fps_x10 <= 244);
	const int exact_band = (fps_x10 >= 238 && fps_x10 <= 240);
	const int trap_band = (fps_x10 >= 150 && fps_x10 <= 170);

	std::printf("%s: cycles=%d fps_x10=%d flags=0x%02x period=%d "
	            "meas_pix=%u pass=%d exact=%d trap=%d pix_ok=%d fps_ok=%d\n",
	            name, cycles, fps_x10, flags, period_sys, top->meas_pix,
	            pass_band, exact_band, trap_band, pix_ok, fps_ok);

	int ok = 0;
	if (exp == EXP_PASS_242) {
		ok = valid && pass_band && fps_ok && pix_ok && !trap_band;
		std::printf("%s %s: expected PASS_242 product\n", ok?"PASS":"FAIL", name);
	} else if (exp == EXP_FAIL_16) {
		ok = valid && trap_band && !pass_band && !fps_ok;
		std::printf("%s %s: expected FAIL_16_TRAP\n", ok?"PASS":"FAIL", name);
	} else {
		// exact-24 must NOT be product PASS
		ok = valid && exact_band && !pass_band && !fps_ok;
		std::printf("%s %s: expected EXACT24_NOT_PRODUCT (not PASS_242)\n",
		            ok?"PASS":"FAIL", name);
	}
	top->final(); delete top;
	return ok ? 0 : 1;
}

int main(int argc, char** argv) {
	int rc = 0;
	// Real periods @ SYS=20e6
	const int P_242 = 825000;   // 20e6/24.242424…
	const int P_240 = 833333;   // 20e6/24.0
	const int P_162 = 1237500;  // 20e6/16.1616… = HT*VT
	std::printf("CASE EXECUTED plex_clk_refresh_meas\n");
	{
		VerilatedContext ctx; ctx.commandArgs(argc, argv);
		rc |= run_case(&ctx, "POS_242HZ", P_242, EXP_PASS_242);
	}
	{
		VerilatedContext ctx; ctx.commandArgs(argc, argv);
		rc |= run_case(&ctx, "NEG_16HZ_TRAP", P_162, EXP_FAIL_16);
	}
	{
		VerilatedContext ctx; ctx.commandArgs(argc, argv);
		rc |= run_case(&ctx, "NEG_EXACT24", P_240, EXP_EXACT24);
	}
	std::printf("%s plex_clk_refresh_meas_tb all cases\n", rc==0?"PASS":"FAIL");
	return rc;
}
