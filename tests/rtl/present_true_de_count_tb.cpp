// Count DE-asserted pixels on the present true-DE path (beam + window + DE_LAG).
// Product: 960×540 DE @ w-clock 1182×564. Red: island beam 1280×720.
//
// true rc direct. EXECUTED before accept. Soft-skip ≠ PASS.

#include "Vpresent_true_de_count_tb.h"
#include "verilated.h"

#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <vector>

static vluint64_t main_time = 0;
double sc_time_stamp() { return double(main_time); }

static void tick(Vpresent_true_de_count_tb *top)
{
	top->clk = 0;
	top->eval();
	main_time++;
	top->clk = 1;
	top->eval();
	main_time++;
}

struct FrameStats {
	int h_total = 0;
	int v_total = 0;
	int de_w_max = 0;
	int de_lines = 0;
	int de_pixels = 0;
	int min_de_w = 100000;
	int max_de_w = 0;
	int store_id_ok = 1; // store_x==hc && store_y==vc on every DE sample (identity)
	int store_id_checked = 0;
	int store_id_fail = 0;
};

static FrameStats measure_one_frame(Vpresent_true_de_count_tb *top, int expect_ht, int expect_vt)
{
	FrameStats st;
	// Align to frame_start
	int guard = expect_ht * expect_vt * 3 + 10000;
	while (!top->frame_start && guard-- > 0)
		tick(top);
	if (guard <= 0) {
		std::fprintf(stderr, "FAIL no frame_start\n");
		std::exit(2);
	}
	// frame_start is 1-cycle at wrap; next cycles are the new frame
	tick(top);

	int line_de = 0;
	int hc_prev = -1;
	int lines = 0;
	int clks = 0;
	const int limit = expect_ht * expect_vt + expect_ht; // one frame + margin

	// content_window registers store_* one ce_pix after hc/py (see de_r <= in_content).
	// Identity check uses 1-cycle delayed beam coords vs current store_*.
	int ic_d1 = 0, hc_d1 = 0, vc_d1 = 0;

	while (clks < limit) {
		const int de = top->de_out ? 1 : 0;
		const int hc = int(top->hc);
		const int vc = int(top->vc);

		if (de) {
			line_de++;
			st.de_pixels++;
		}
		// Identity on window register cadence (not DE_LAG-shifted de_out).
		if (ic_d1) {
			st.store_id_checked++;
			if (int(top->store_x) != hc_d1 || int(top->store_y) != vc_d1) {
				st.store_id_ok = 0;
				st.store_id_fail++;
			}
		}
		ic_d1 = top->in_content_raw ? 1 : 0;
		hc_d1 = hc;
		vc_d1 = vc;

		// End of line: hc wrapped to 0
		if (hc_prev >= 0 && hc < hc_prev) {
			if (line_de > 0) {
				st.de_lines++;
				if (line_de < st.min_de_w)
					st.min_de_w = line_de;
				if (line_de > st.max_de_w)
					st.max_de_w = line_de;
			}
			line_de = 0;
			lines++;
		}
		hc_prev = hc;
		clks++;

		// Next frame_start ends the frame after V_TOTAL lines
		tick(top);
		if (top->frame_start && lines >= expect_vt - 1)
			break;
	}

	// Flush last line if needed
	if (line_de > 0) {
		st.de_lines++;
		if (line_de < st.min_de_w)
			st.min_de_w = line_de;
		if (line_de > st.max_de_w)
			st.max_de_w = line_de;
	}

	st.h_total = expect_ht;
	st.v_total = expect_vt;
	st.de_w_max = st.max_de_w;
	if (st.min_de_w > st.max_de_w)
		st.min_de_w = 0;
	return st;
}

int main(int argc, char **argv)
{
	Verilated::commandArgs(argc, argv);
	auto *top = new Vpresent_true_de_count_tb;

	// Product contract under test is always 960×540 true DE.
	// Island fault only changes the *beam*; expectations stay product so RED fails.
	const int CW = 960, CH = 540;
#ifdef PRESENT_BEAM_FAULT_ISLAND_1280
	const int H_BEAM = 1280, V_BEAM = 720, H_TOT = 1650, V_TOT = 750;
	const char *mode = "ISLAND_1280";
#else
	const int H_BEAM = 960, V_BEAM = 540, H_TOT = 1182, V_TOT = 564;
	const char *mode = "PRODUCT_960";
#endif
	(void)H_BEAM;
	(void)V_BEAM;

	// Product runtime config (w-nostub fit card)
	top->win_enable = 1;
	top->content_w = CW;
	top->content_h = CH;
	top->content_x0 = 0;
	top->content_y0 = 0;
	// Island mistake often programs canvas into win_h_de — product must use content size.
#ifdef PRESENT_BEAM_FAULT_ISLAND_1280
	// FAULT wiring: beam is 1280 DE; window told DE is 1280 (canvas) while content 960.
	top->win_h_de = 1280;
	top->win_v_de = 720;
#else
	top->win_h_de = 960;
	top->win_v_de = 540;
#endif

	top->reset = 1;
	top->clk = 0;
	for (int i = 0; i < 20; ++i)
		tick(top);
	top->reset = 0;
	for (int i = 0; i < 5; ++i)
		tick(top);

	// Discard first partial frame, measure second full frame
	(void)measure_one_frame(top, H_TOT, V_TOT);
	FrameStats st = measure_one_frame(top, H_TOT, V_TOT);

	const int de_w_uniform = (st.min_de_w == st.max_de_w && st.max_de_w > 0) ? 1 : 0;
	const int de_w = st.max_de_w;
	const int de_h = st.de_lines;
	// Load-bearing true_de: measured DE raster extent == content (ascal iauto input).
	const int de_eq_content =
	    (de_w == CW && de_h == CH && st.de_pixels == CW * CH && de_w_uniform) ? 1 : 0;
	const int true_de = de_eq_content ? 1 : 0;
	const int island_detected = (de_w != CW || de_h != CH) ? 1 : 0;

	std::printf(
	    "CASE true_de_count EXECUTED mode=%s "
	    "H_TOT=%d V_TOT=%d clks/frame=%d fps@20M=%.4f "
	    "de_w_min=%d de_w_max=%d de_lines=%d de_pixels=%d "
	    "de_uniform=%d store_id_ok=%d store_id_fail=%d/%d "
	    "true_de=%d island=%d beam=%dx%d\n",
	    mode, H_TOT, V_TOT, H_TOT * V_TOT, 20e6 / double(H_TOT * V_TOT), st.min_de_w,
	    st.max_de_w, st.de_lines, st.de_pixels, de_w_uniform, st.store_id_ok,
	    st.store_id_fail, st.store_id_checked, true_de, island_detected, H_BEAM, V_BEAM);

	int fails = 0;
#define CHECK(c, m)                                                                 \
	do {                                                                            \
		if (!(c)) {                                                                 \
			std::fprintf(stderr, "FAIL %s\n", m);                                   \
			++fails;                                                                \
		}                                                                           \
	} while (0)

	// Same product assertions always — island beam must RED these.
	CHECK(de_w == 960, "de_w==960 (true content DE width)");
	CHECK(de_h == 540, "de_h==540 (true content DE height)");
	CHECK(st.de_pixels == 960 * 540, "de_pixels==518400");
	CHECK(de_w_uniform, "uniform DE width every active line");
	CHECK(st.min_de_w == 960 && st.max_de_w == 960, "every line exactly 960 DE cycles");
	CHECK(true_de == 1, "true_de==1");
#ifndef PRESENT_BEAM_FAULT_ISLAND_1280
	CHECK(st.store_id_ok == 1, "identity store map on window cadence");
	CHECK(st.store_id_fail == 0, "zero store identity fails");
	CHECK(H_TOT == 1182 && V_TOT == 564, "w-clock primary 1182x564");
	CHECK(H_TOT * V_TOT == 666648, "clks/frame 666648");
	{
		const double fps = 20e6 / double(H_TOT * V_TOT);
		CHECK(fps > 29.95 && fps < 30.05, "fps ~30.0008");
	}
#endif

	if (fails) {
		std::printf("FAIL true_de_count fails=%d mode=%s true_de=%d de=%dx%d\n", fails,
		            mode, true_de, de_w, de_h);
		delete top;
		return 1;
	}
	std::printf("PASS true_de_count mode=%s true_de=%d de=%dx%d\n", mode, true_de, de_w,
	            de_h);
	delete top;
	return 0;
}
