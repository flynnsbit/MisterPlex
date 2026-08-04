// Refresh+raster measure TB (product geometry).
// POS_242:      H1650×V750 + period→242 + CE/DE/lines OK → PASS
// NEG_16:       period→~162 FAIL trap
// NEG_EXACT24:  period→240 NOT product PASS
// NEG_ADV_RASTER: H1375×V900 (HT*VT same) DE1280×720 → fps can look OK, raster FAIL
#include "Vplex_clk_refresh_meas_tb_top.h"
#include "verilated.h"
#include <cstdio>
#include <cstdint>

static const int WIN = 20000;
static const double PIX_PER_SYS = 30.0e6 / 20.0e6;

static const int H_TOT = 1650, V_TOT = 750, H_ACT = 1280, V_ACT = 720;
// rd-duck adversarial: same HT*VT=1_237_500, wrong shape
static const int ADV_H = 1375, ADV_V = 900;

enum Expect { EXP_PASS_242, EXP_FAIL_16, EXP_EXACT24, EXP_FAIL_RASTER };

struct Raster { int ht, vt, ha, va; };

static int run_case(VerilatedContext* ctx, const char* name, int period_sys,
                    Expect exp, Raster rc) {
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
	int cycles = 0;
	int x = 0, y = 0;
	// Align vsync to raster end-of-frame; also track sys time for period.
	// Product: one frame = ht*vt pix = period_sys * (pix/sys) when rates match.
	const int limit = period_sys * 5 + WIN + 1000;
	int frames = 0;

	while (cycles < limit) {
		pix_acc += PIX_PER_SYS;
		while (pix_acc >= 1.0) {
			const int de = (x < rc.ha && y < rc.va) ? 1 : 0;
			const int hs = (x == rc.ht - 1) ? 1 : 0;
			// VSync active during last line's blanking tail (and a few clocks)
			const int vs = (y == rc.vt - 1 && x >= rc.ht - 8) ? 1 : 0;
			top->clk_pix = 0; top->eval(); ctx->timeInc(1);
			top->ce_pix = 1;
			top->de = de;
			top->hsync = hs;
			top->vsync = vs;
			top->clk_pix = 1; top->eval(); ctx->timeInc(1);
			x++;
			if (x >= rc.ht) {
				x = 0;
				y++;
				if (y >= rc.vt) { y = 0; frames++; }
			}
			pix_acc -= 1.0;
		}
		top->clk = 1; top->eval(); ctx->timeInc(1);
		top->clk = 0; top->eval(); ctx->timeInc(1);
		cycles++;
		// Need ≥2 frames for period_valid + window close
		if (top->meas_done && frames >= 3 && cycles > WIN)
			break;
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
	const int pass_band  = (fps_x10 >= 241 && fps_x10 <= 244);
	const int exact_band = (fps_x10 >= 238 && fps_x10 <= 240);
	const int trap_band  = (fps_x10 >= 150 && fps_x10 <= 170);

	std::printf("%s: cycles=%d frames=%d fps_x10=%d flags=0x%02x "
	            "ce_frm=%u de_frm=%u lines=%u active=%u ce_line=%u "
	            "pass=%d exact=%d trap=%d pix_ok=%d fps_ok=%d ce_ok=%d de_ok=%d raster_ok=%d\n",
	            name, cycles, frames, fps_x10, flags,
	            top->meas_ce_frame, top->meas_de_frame, top->meas_lines,
	            top->meas_active, top->meas_ce_line,
	            pass_band, exact_band, trap_band, pix_ok, fps_ok, ce_ok, de_ok, raster_ok);

	int ok = 0;
	if (exp == EXP_PASS_242) {
		ok = valid && pass_band && fps_ok && pix_ok && ce_ok && de_ok && raster_ok && !trap;
		std::printf("%s %s: expected PASS_242 product+raster "
		            "(CE=1237500 lines=750 DE=921600 CE/line=1650)\n",
		            ok?"PASS":"FAIL", name);
	} else if (exp == EXP_FAIL_16) {
		// 20 MHz same-clock trap: drive good raster but stretch by using
		// slower pix ratio? Here we reuse geometry; period falls out of
		// ht*vt/pix_rate. For trap, force slower effective rate via
		// half-speed pix already wrong — instead accept trap from
		// period if we run at 20 MHz equivalent by dropping PIX_PER_SYS.
		// This case is handled in main with a dedicated slow runner.
		ok = valid && trap_band && !pass_band && !fps_ok;
		std::printf("%s %s: expected FAIL_16_TRAP\n", ok?"PASS":"FAIL", name);
	} else if (exp == EXP_EXACT24) {
		ok = valid && exact_band && !pass_band && !fps_ok;
		std::printf("%s %s: expected EXACT24_NOT_PRODUCT\n", ok?"PASS":"FAIL", name);
	} else {
		ok = valid && !raster_ok;
		std::printf("%s %s: expected FAIL_RASTER_ADVERSARIAL (H1375×V900)\n",
		            ok?"PASS":"FAIL", name);
	}
	top->final(); delete top;
	return ok ? 0 : 1;
}

// 16.16 Hz trap: pix runs at 1:1 with sys (20 MHz) on same geometry →
// period_sys = 1237500, fps≈16.16. CE still 1237500 so raster geometry OK;
// product PASS must still FAIL on fps trap.
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
	const int limit = 1237500 * 4 + WIN + 1000;
	while (cycles < limit) {
		// 1 pix per sys (20 MHz same-clock mode)
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
	const int pass_band = (fps_x10 >= 241 && fps_x10 <= 244);
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

// Exact-24: need period = 20e6/24 = 833333 sys.
// Geometry CE_FRAME at 30 MHz pix gives period 825000. To get 833333, pad
// a few extra pix clocks per frame (idle) after each frame.
static int run_exact24(VerilatedContext* ctx) {
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
	int pad = 0;
	// Extra pix per frame so sys period ≈ 833333: need pix/frame = 833333*1.5 = 1250000
	// base 1237500 → pad 12500 pix after each frame
	const int PAD = 12500;
	const int limit = 833333 * 5 + WIN + 1000;
	while (cycles < limit) {
		pix_acc += PIX_PER_SYS;
		while (pix_acc >= 1.0) {
			int de = 0, hs = 0, vs = 0;
			if (pad > 0) {
				pad--;
			} else {
				de = (x < H_ACT && y < V_ACT) ? 1 : 0;
				hs = (x == H_TOT - 1) ? 1 : 0;
				vs = (y == V_TOT - 1 && x >= H_TOT - 8) ? 1 : 0;
				x++;
				if (x >= H_TOT) {
					x = 0; y++;
					if (y >= V_TOT) { y = 0; frames++; pad = PAD; }
				}
			}
			top->clk_pix = 0; top->eval(); ctx->timeInc(1);
			top->ce_pix = 1; top->de = de; top->hsync = hs; top->vsync = vs;
			top->clk_pix = 1; top->eval(); ctx->timeInc(1);
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
	const int pass_band = (fps_x10 >= 241 && fps_x10 <= 244);
	const int exact_band = (fps_x10 >= 238 && fps_x10 <= 240);
	std::printf("NEG_EXACT24: cycles=%d frames=%d fps_x10=%d flags=0x%02x exact=%d pass=%d\n",
	            cycles, frames, fps_x10, flags, exact_band, pass_band);
	const int ok = valid && exact_band && !pass_band && !fps_ok;
	std::printf("%s NEG_EXACT24: expected EXACT24_NOT_PRODUCT\n", ok?"PASS":"FAIL");
	top->final(); delete top;
	return ok ? 0 : 1;
}

int main(int argc, char** argv) {
	int rc = 0;
	const int P_242 = 825000;
	Raster good{H_TOT, V_TOT, H_ACT, V_ACT};
	Raster adv{ADV_H, ADV_V, H_ACT, V_ACT};
	std::printf("CASE EXECUTED plex_clk_refresh_meas\n");
	{
		VerilatedContext ctx; ctx.commandArgs(argc, argv);
		rc |= run_case(&ctx, "POS_242HZ", P_242, EXP_PASS_242, good);
	}
	{
		VerilatedContext ctx; ctx.commandArgs(argc, argv);
		rc |= run_trap16(&ctx);
	}
	{
		VerilatedContext ctx; ctx.commandArgs(argc, argv);
		rc |= run_exact24(&ctx);
	}
	{
		VerilatedContext ctx; ctx.commandArgs(argc, argv);
		rc |= run_case(&ctx, "NEG_ADV_RASTER", P_242, EXP_FAIL_RASTER, adv);
	}
	std::printf("%s plex_clk_refresh_meas_tb all cases\n", rc==0?"PASS":"FAIL");
	return rc;
}
