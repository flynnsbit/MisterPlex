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
	int store_id_ok = 1; // store_x==hc && store_y==vc on every store sample (identity)
	int store_id_checked = 0;
	int store_id_fail = 0;
	int store_oracle_ok = 1; // every content (x,y) requested exactly once
	int store_oracle_hit = 0;
	int store_x_min = 100000;
	int store_x_max = -1;
};

static void note_store_sample(FrameStats &st, Vpresent_true_de_count_tb *top, int hc_d1,
                              int vc_d1, int content_w, int content_h,
                              std::vector<uint8_t> &hit, int area)
{
	st.store_id_checked++;
	const int sx = int(top->store_x);
	const int sy = int(top->store_y);
	if (sx != hc_d1 || sy != vc_d1) {
		st.store_id_ok = 0;
		st.store_id_fail++;
	}
	if (sx < st.store_x_min)
		st.store_x_min = sx;
	if (sx > st.store_x_max)
		st.store_x_max = sx;
	// Coordinate oracle: full content grid x0..CW-1, y0..CH-1 (rd-duck).
	if (sx >= 0 && sy >= 0 && sx < content_w && sy < content_h && area > 0) {
		const size_t idx = size_t(sy) * size_t(content_w) + size_t(sx);
		if (hit[idx])
			st.store_oracle_ok = 0; // duplicate request
		else {
			hit[idx] = 1;
			st.store_oracle_hit++;
		}
	} else {
		st.store_oracle_ok = 0;
	}
}

static FrameStats measure_one_frame(Vpresent_true_de_count_tb *top, int expect_ht, int expect_vt,
                                    int content_w, int content_h)
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
	// frame_start is 1-cycle at wrap; next cycle is hc=0,vc=0 of the new frame.
	tick(top);

	int line_de = 0;
	int hc_prev = -1;
	int clks = 0;
	// Exactly one raster of clocks + one flush for content_window store_* NBA.
	const int frame_clks = expect_ht * expect_vt;
	const int area = content_w * content_h;
	std::vector<uint8_t> hit((area > 0) ? size_t(area) : size_t(1), 0);

	// content_window registers store_* one ce_pix after hc/py (see de_r <= in_content).
	// Identity check uses 1-cycle delayed beam coords vs current store_*.
	int ic_d1 = 0, hc_d1 = 0, vc_d1 = 0;

	while (clks < frame_clks) {
		const int de = top->de_out ? 1 : 0;
		const int hc = int(top->hc);
		const int vc = int(top->vc);

		if (de) {
			line_de++;
			st.de_pixels++;
		}
		if (ic_d1)
			note_store_sample(st, top, hc_d1, vc_d1, content_w, content_h, hit, area);
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
		}
		hc_prev = hc;
		clks++;
		tick(top);
	}

	// Flush window delay for the last in_content of the frame.
	if (ic_d1)
		note_store_sample(st, top, hc_d1, vc_d1, content_w, content_h, hit, area);
	tick(top);

	// Flush last line DE tally if needed
	if (line_de > 0) {
		st.de_lines++;
		if (line_de < st.min_de_w)
			st.min_de_w = line_de;
		if (line_de > st.max_de_w)
			st.max_de_w = line_de;
	}

	if (st.store_oracle_hit != area || area <= 0)
		st.store_oracle_ok = 0;

	st.h_total = expect_ht;
	st.v_total = expect_vt;
	st.de_w_max = st.max_de_w;
	if (st.min_de_w > st.max_de_w)
		st.min_de_w = 0;
	if (st.store_x_max < st.store_x_min) {
		st.store_x_min = -1;
		st.store_x_max = -1;
	}
	return st;
}

int main(int argc, char **argv)
{
	Verilated::commandArgs(argc, argv);
	auto *top = new Vpresent_true_de_count_tb;

	// Content raster: fit-release gate may override via -DFIT_GATE_CW/CH from QSF.
	// Default remains product 960×540. Island fault only changes the *beam*.
#if defined(FIT_GATE_CW)
	const int CW = FIT_GATE_CW;
#else
	const int CW = 960;
#endif
#if defined(FIT_GATE_CH)
	const int CH = FIT_GATE_CH;
#else
	const int CH = 540;
#endif
#ifdef PRESENT_BEAM_FAULT_ISLAND_1280
	const int H_BEAM = 1280, V_BEAM = 720, H_TOT = 1650, V_TOT = 750;
	const char *mode = "ISLAND_1280";
#else
	const int H_BEAM = CW, V_BEAM = CH, H_TOT = 1182, V_TOT = 564;
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
	// FAULT wiring: beam is 1280 DE; window told DE is 1280 (canvas) while content stays CW×CH.
	top->win_h_de = 1280;
	top->win_v_de = 720;
#else
	top->win_h_de = CW;
	top->win_v_de = CH;
#endif

	top->reset = 1;
	top->clk = 0;
	for (int i = 0; i < 20; ++i)
		tick(top);
	top->reset = 0;
	for (int i = 0; i < 5; ++i)
		tick(top);

	// Discard first partial frame, measure second full frame
	(void)measure_one_frame(top, H_TOT, V_TOT, CW, CH);
	FrameStats st = measure_one_frame(top, H_TOT, V_TOT, CW, CH);

	const int de_w_uniform = (st.min_de_w == st.max_de_w && st.max_de_w > 0) ? 1 : 0;
	const int de_w = st.max_de_w;
	const int de_h = st.de_lines;
	const int content_area = CW * CH;
	// Load-bearing true_de: measured DE raster extent == content (ascal iauto input).
	const int de_eq_content =
	    (de_w == CW && de_h == CH && st.de_pixels == content_area && de_w_uniform) ? 1 : 0;
	// Store path must request every content pixel (DE-only greenwash is not enough).
	const int store_full =
	    (st.store_id_checked == content_area && st.store_id_ok == 1 &&
	     st.store_oracle_ok == 1 && st.store_x_min == 0 && st.store_x_max == CW - 1)
	        ? 1
	        : 0;
	const int true_de = (de_eq_content && store_full) ? 1 : 0;
	const int island_detected = (de_w != CW || de_h != CH) ? 1 : 0;

	std::printf(
	    "CASE true_de_count EXECUTED mode=%s "
	    "H_TOT=%d V_TOT=%d clks/frame=%d fps@20M=%.4f "
	    "de_w_min=%d de_w_max=%d de_lines=%d de_pixels=%d "
	    "de_uniform=%d store_id_ok=%d store_id_fail=%d/%d "
	    "store_req=%d store_full=%d store_oracle=%d store_x_range=%d..%d "
	    "true_de=%d island=%d beam=%dx%d\n",
	    mode, H_TOT, V_TOT, H_TOT * V_TOT, 20e6 / double(H_TOT * V_TOT), st.min_de_w,
	    st.max_de_w, st.de_lines, st.de_pixels, de_w_uniform, st.store_id_ok,
	    st.store_id_fail, st.store_id_checked, st.store_id_checked, store_full,
	    st.store_oracle_ok, st.store_x_min, st.store_x_max, true_de, island_detected,
	    H_BEAM, V_BEAM);

	int fails = 0;
#define CHECK(c, m)                                                                 \
	do {                                                                            \
		if (!(c)) {                                                                 \
			std::fprintf(stderr, "FAIL %s\n", m);                                   \
			++fails;                                                                \
		}                                                                           \
	} while (0)

	// Assert measured DE == configured content (CW×CH). Island beam must RED these.
	CHECK(de_w == CW, "de_w==content_w (true content DE width)");
	CHECK(de_h == CH, "de_h==content_h (true content DE height)");
	CHECK(st.de_pixels == content_area, "de_pixels==content area");
	CHECK(de_w_uniform, "uniform DE width every active line");
	CHECK(st.min_de_w == CW && st.max_de_w == CW, "every line exactly content_w DE cycles");
#ifndef PRESENT_BEAM_FAULT_ISLAND_1280
	// rd-duck: DE count alone was greenwash — require full store request grid.
	CHECK(st.store_id_checked == content_area,
	      "store_req_count==content area (not 959*H shortfall)");
	CHECK(st.store_id_ok == 1, "identity store map on window cadence");
	CHECK(st.store_id_fail == 0, "zero store identity fails");
	CHECK(st.store_oracle_ok == 1, "store coordinate oracle full x0..CW-1 y0..CH-1");
	CHECK(st.store_x_min == 0 && st.store_x_max == CW - 1, "store_x range 0..CW-1");
	CHECK(store_full == 1, "store_full==1");
	CHECK(true_de == 1, "true_de==1 (DE extent + full store oracle)");
	if (CW == 960 && CH == 540) {
		CHECK(H_TOT == 1182 && V_TOT == 564, "w-clock primary 1182x564");
		CHECK(H_TOT * V_TOT == 666648, "clks/frame 666648");
		const double fps = 20e6 / double(H_TOT * V_TOT);
		CHECK(fps > 29.95 && fps < 30.05, "fps ~30.0008");
		CHECK(st.store_id_checked == 518400, "store_req==518400 product");
	}
#else
	// Island: true_de must stay 0; store shortfall class is still informative.
	CHECK(true_de == 0, "island true_de==0");
#endif

	if (fails) {
		std::printf(
		    "FAIL true_de_count fails=%d mode=%s true_de=%d de=%dx%d store_req=%d\n",
		    fails, mode, true_de, de_w, de_h, st.store_id_checked);
		delete top;
		return 1;
	}
	std::printf("PASS true_de_count mode=%s true_de=%d de=%dx%d store_req=%d\n", mode,
	            true_de, de_w, de_h, st.store_id_checked);
	delete top;
	return 0;
}
