// Refresh+raster measure TB (product geometry H1600×V750 @ 28.8 MHz).
// POS_240:      period→240 + CE/DE/lines OK → PASS product
// NEG_16:       ~16.67 Hz trap FAIL
// NEG_242:      fps_x10=242 MUST FAIL (retired 30 MHz/H1650 false product)
// NEG_ADV_RASTER: H1500×V800 (HT*VT=1_200_000) DE1280×720 → raster FAIL
#include "Vplex_clk_refresh_meas_tb_top.h"
#include "verilated.h"
#include <cstdio>
#include <cstdint>

static const int WIN = 20000;
static const double PIX_PER_SYS = 28.8e6 / 20.0e6; // 1.44

static const int H_TOT = 1600, V_TOT = 750, H_ACT = 1280, V_ACT = 720;
// Adversarial: same HT*VT=1_200_000, wrong shape
static const int ADV_H = 1500, ADV_V = 800;

enum Expect { EXP_PASS_240, EXP_FAIL_16, EXP_FAIL_242, EXP_FAIL_RASTER };

struct Raster { int ht, vt, ha, va; };

static int run_case(VerilatedContext* ctx, const char* name, int period_sys,
                    Expect exp, Raster rc, double pix_per_sys) {
	auto* top = new Vplex_clk_refresh_meas_tb_top{ctx};
	top->clk = 0; top->reset = 1; top->clk_pix = 0;
	top->vsync = 0; top->hsync = 0; top->ce_pix = 1; top->de = 0;
	top->underrun_count = 0;
	for (int i = 0; i < 8; i++) {
		top->clk = 1; top->eval(); ctx->timeInc(1);
		top->clk = 0; top->eval(); ctx->timeInc(1);
	}
	top->reset = 0;

	double pix_acc = 0.0;
	int cycles = 0, x = 0, y = 0, frames = 0;
	const int limit = period_sys * 5 + WIN + 1000;

	while (cycles < limit) {
		pix_acc += pix_per_sys;
		while (pix_acc >= 1.0) {
			const int de = (x < rc.ha && y < rc.va) ? 1 : 0;
			const int hs = (x == rc.ht - 1) ? 1 : 0;
			const int vs = (y == rc.vt - 1 && x >= rc.ht - 8) ? 1 : 0;
			top->clk_pix = 0; top->eval(); ctx->timeInc(1);
			top->ce_pix = 1; top->de = de; top->hsync = hs; top->vsync = vs;
			top->clk_pix = 1; top->eval(); ctx->timeInc(1);
			x++;
			if (x >= rc.ht) {
				x = 0; y++;
				if (y >= rc.vt) { y = 0; frames++; }
			}
			pix_acc -= 1.0;
		}
		top->clk = 1; top->eval(); ctx->timeInc(1);
		top->clk = 0; top->eval(); ctx->timeInc(1);
		cycles++;
		if (top->meas_done && frames >= 3 && cycles > WIN) break;
	}

	const int fps_x10 = top->meas_fps_x10;
	const int flags = top->meas_flags;
	const int valid     = flags & 1;
	const int pix_ok    = (flags >> 1) & 1;
	const int fps_ok    = (flags >> 2) & 1;
	const int trap      = (flags >> 4) & 1;
	const int ce_ok     = (flags >> 5) & 1;
	const int de_ok     = (flags >> 6) & 1;
	const int raster_ok = (flags >> 7) & 1;
	const int pass_band   = (fps_x10 >= 239 && fps_x10 <= 241);
	const int defect242   = (fps_x10 >= 242 && fps_x10 <= 244);
	const int trap_band   = (fps_x10 >= 150 && fps_x10 <= 170);

	std::printf("%s: cycles=%d frames=%d fps_x10=%d flags=0x%02x "
	            "ce_frm=%u de_frm=%u lines=%u active=%u ce_line=%u "
	            "pass=%d d242=%d trap=%d pix_ok=%d fps_ok=%d ce_ok=%d de_ok=%d raster_ok=%d\n",
	            name, cycles, frames, fps_x10, flags,
	            top->meas_ce_frame, top->meas_de_frame, top->meas_lines,
	            top->meas_active, top->meas_ce_line,
	            pass_band, defect242, trap_band, pix_ok, fps_ok, ce_ok, de_ok, raster_ok);

	int ok = 0;
	if (exp == EXP_PASS_240) {
		ok = valid && pass_band && fps_ok && pix_ok && ce_ok && de_ok && raster_ok && !trap;
		std::printf("%s %s: expected PASS_240 product+raster "
		            "(CE=1200000 lines=750 DE=921600 CE/line=1600)\n",
		            ok?"PASS":"FAIL", name);
	} else if (exp == EXP_FAIL_16) {
		ok = valid && trap_band && !pass_band && !fps_ok;
		std::printf("%s %s: expected FAIL_16_TRAP\n", ok?"PASS":"FAIL", name);
	} else if (exp == EXP_FAIL_242) {
		ok = valid && defect242 && !pass_band && !fps_ok;
		std::printf("%s %s: expected FAIL_242_DEFECT (must not PASS product)\n",
		            ok?"PASS":"FAIL", name);
	} else {
		ok = valid && !raster_ok;
		std::printf("%s %s: expected FAIL_RASTER_ADVERSARIAL (H1500×V800)\n",
		            ok?"PASS":"FAIL", name);
	}
	top->final(); delete top;
	return ok ? 0 : 1;
}

// 16.67 Hz trap: 1 pix per sys on product geometry → period=1_200_000
static int run_trap16(VerilatedContext* ctx) {
	auto* top = new Vplex_clk_refresh_meas_tb_top{ctx};
	top->clk = 0; top->reset = 1; top->clk_pix = 0;
	top->vsync = 0; top->hsync = 0; top->ce_pix = 1; top->de = 0;
	top->underrun_count = 0;
	for (int i = 0; i < 8; i++) {
		top->clk = 1; top->eval(); ctx->timeInc(1);
		top->clk = 0; top->eval(); ctx->timeInc(1);
	}
	top->reset = 0;
	int cycles = 0, x = 0, y = 0, frames = 0;
	const int limit = 1200000 * 4 + WIN + 1000;
	while (cycles < limit) {
		const int de = (x < H_ACT && y < V_ACT) ? 1 : 0;
		const int hs = (x == H_TOT - 1) ? 1 : 0;
		const int vs = (y == V_TOT - 1 && x >= H_TOT - 8) ? 1 : 0;
		top->clk_pix = 0; top->eval(); ctx->timeInc(1);
		top->ce_pix = 1; top->de = de; top->hsync = hs; top->vsync = vs;
		top->clk_pix = 1; top->eval(); ctx->timeInc(1);
		x++; if (x >= H_TOT) { x = 0; y++; if (y >= V_TOT) { y = 0; frames++; } }
		top->clk = 1; top->eval(); ctx->timeInc(1);
		top->clk = 0; top->eval(); ctx->timeInc(1);
		cycles++;
		if (top->meas_done && frames >= 3 && cycles > WIN) break;
	}
	const int fps_x10 = top->meas_fps_x10;
	const int flags = top->meas_flags;
	const int valid = flags & 1;
	const int fps_ok = (flags >> 2) & 1;
	const int trap = (flags >> 4) & 1;
	const int pass_band = (fps_x10 >= 239 && fps_x10 <= 241);
	const int trap_band = (fps_x10 >= 150 && fps_x10 <= 170);
	std::printf("NEG_16HZ_TRAP: cycles=%d frames=%d fps_x10=%d flags=0x%02x "
	            "ce_frm=%u lines=%u trap=%d pass=%d\n",
	            cycles, frames, fps_x10, flags, top->meas_ce_frame, top->meas_lines,
	            trap_band, pass_band);
	const int ok = valid && trap_band && !pass_band && !fps_ok && trap;
	std::printf("%s NEG_16HZ_TRAP: expected FAIL_16_TRAP\n", ok?"PASS":"FAIL");
	top->final(); delete top;
	return ok ? 0 : 1;
}

// Inject fps_x10=242: pad so period_sys ≈ 825000 while raster still product shape.
// period 825000 → fps_x10 = 200e6/825000 = 242. Must NOT pass product band.
static int run_defect242(VerilatedContext* ctx) {
	auto* top = new Vplex_clk_refresh_meas_tb_top{ctx};
	top->clk = 0; top->reset = 1; top->clk_pix = 0;
	top->vsync = 0; top->hsync = 0; top->ce_pix = 1; top->de = 0;
	top->underrun_count = 0;
	for (int i = 0; i < 8; i++) {
		top->clk = 1; top->eval(); ctx->timeInc(1);
		top->clk = 0; top->eval(); ctx->timeInc(1);
	}
	top->reset = 0;
	// Target period 825000 sys. Product frame 1.2e6 pix @ 1.44 = 833333 sys.
	// Faster pix rate 1.2e6/825000 = 1.454545... ≈ 30/20.625 — use 30/20.625
	// Or: run product geometry with pix_per_sys = 1200000/825000.
	const double pps = 1200000.0 / 825000.0;
	double pix_acc = 0.0;
	int cycles = 0, x = 0, y = 0, frames = 0;
	const int limit = 825000 * 5 + WIN + 1000;
	while (cycles < limit) {
		pix_acc += pps;
		while (pix_acc >= 1.0) {
			const int de = (x < H_ACT && y < V_ACT) ? 1 : 0;
			const int hs = (x == H_TOT - 1) ? 1 : 0;
			const int vs = (y == V_TOT - 1 && x >= H_TOT - 8) ? 1 : 0;
			top->clk_pix = 0; top->eval(); ctx->timeInc(1);
			top->ce_pix = 1; top->de = de; top->hsync = hs; top->vsync = vs;
			top->clk_pix = 1; top->eval(); ctx->timeInc(1);
			x++; if (x >= H_TOT) { x = 0; y++; if (y >= V_TOT) { y = 0; frames++; } }
			pix_acc -= 1.0;
		}
		top->clk = 1; top->eval(); ctx->timeInc(1);
		top->clk = 0; top->eval(); ctx->timeInc(1);
		cycles++;
		if (top->meas_done && frames >= 3 && cycles > WIN) break;
	}
	const int fps_x10 = top->meas_fps_x10;
	const int flags = top->meas_flags;
	const int valid = flags & 1;
	const int fps_ok = (flags >> 2) & 1;
	const int pass_band = (fps_x10 >= 239 && fps_x10 <= 241);
	const int defect242 = (fps_x10 >= 242 && fps_x10 <= 244);
	std::printf("NEG_242_DEFECT: cycles=%d frames=%d fps_x10=%d flags=0x%02x d242=%d pass=%d fps_ok=%d\n",
	            cycles, frames, fps_x10, flags, defect242, pass_band, fps_ok);
	const int ok = valid && defect242 && !pass_band && !fps_ok;
	std::printf("%s NEG_242_DEFECT: expected FAIL (242 must not product-PASS)\n", ok?"PASS":"FAIL");
	top->final(); delete top;
	return ok ? 0 : 1;
}

int main(int argc, char** argv) {
	int rc = 0;
	const int P_240 = 833333; // 20e6/24
	Raster good{H_TOT, V_TOT, H_ACT, V_ACT};
	Raster adv{ADV_H, ADV_V, H_ACT, V_ACT};
	std::printf("CASE EXECUTED plex_clk_refresh_meas\n");
	{
		VerilatedContext ctx; ctx.commandArgs(argc, argv);
		rc |= run_case(&ctx, "POS_240HZ", P_240, EXP_PASS_240, good, PIX_PER_SYS);
	}
	{
		VerilatedContext ctx; ctx.commandArgs(argc, argv);
		rc |= run_trap16(&ctx);
	}
	{
		VerilatedContext ctx; ctx.commandArgs(argc, argv);
		rc |= run_defect242(&ctx);
	}
	{
		VerilatedContext ctx; ctx.commandArgs(argc, argv);
		rc |= run_case(&ctx, "NEG_ADV_RASTER", P_240, EXP_FAIL_RASTER, adv, PIX_PER_SYS);
	}
	std::printf("%s plex_clk_refresh_meas_tb all cases\n", rc==0?"PASS":"FAIL");
	return rc;
}
