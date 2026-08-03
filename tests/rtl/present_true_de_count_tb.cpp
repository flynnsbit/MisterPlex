// Count DE-asserted pixels on the present true-DE path (beam + window + DE_LAG).
// Product 30: 960×540 @ 1182×564. Product 24: same DE @ 1182×705.
// RED: island 1280; FAULT_VTOT_BAD_DE: V_TOT=705 with DE width 1280.
// true rc direct. EXECUTED before accept.

#include "Vpresent_true_de_count_tb.h"
#include "verilated.h"

#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cmath>

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
	int de_lines = 0;
	int de_pixels = 0;
	int min_de_w = 100000;
	int max_de_w = 0;
	int store_id_ok = 1;
	int store_id_checked = 0;
	int store_id_fail = 0;
};

static FrameStats measure_one_frame(Vpresent_true_de_count_tb *top, int expect_ht, int expect_vt)
{
	FrameStats st;
	int guard = expect_ht * expect_vt * 3 + 10000;
	while (!top->frame_start && guard-- > 0)
		tick(top);
	if (guard <= 0) {
		std::fprintf(stderr, "FAIL no frame_start\n");
		std::exit(2);
	}
	tick(top);

	int line_de = 0;
	int hc_prev = -1;
	int lines = 0;
	int clks = 0;
	const int limit = expect_ht * expect_vt + expect_ht;
	int ic_d1 = 0, hc_d1 = 0, vc_d1 = 0;

	while (clks < limit) {
		const int de = top->de_out ? 1 : 0;
		const int hc = int(top->hc);
		const int vc = int(top->vc);

		if (de) {
			line_de++;
			st.de_pixels++;
		}
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
		tick(top);
		if (top->frame_start && lines >= expect_vt - 1)
			break;
	}
	if (line_de > 0) {
		st.de_lines++;
		if (line_de < st.min_de_w)
			st.min_de_w = line_de;
		if (line_de > st.max_de_w)
			st.max_de_w = line_de;
	}
	if (st.min_de_w > st.max_de_w)
		st.min_de_w = 0;
	return st;
}

int main(int argc, char **argv)
{
	Verilated::commandArgs(argc, argv);
	auto *top = new Vpresent_true_de_count_tb;

	const int CW = 960, CH = 540;
	const int H_TOT = 1182;
#if defined(PRESENT_BEAM_FAULT_ISLAND_1280)
	const char *mode = "ISLAND_1280";
	const int H_BEAM = 1280, V_BEAM = 720;
	const int expect_ht = 1650, expect_vt = 750;
	const int use_rt = 0, rt_vt = 0;
	const int win_h = 1280, win_v = 720;
	const int product_assert = 1; // still assert 960×540 → RED
#elif defined(PRESENT_BEAM_FAULT_VTOT_BAD_DE)
	const char *mode = "FAULT_VTOT_BAD_DE";
	const int H_BEAM = 1280, V_BEAM = 540;
	const int expect_ht = 1400, expect_vt = 705;
	const int use_rt = 1, rt_vt = 705;
	const int win_h = 1280, win_v = 540;
	const int product_assert = 1;
#elif defined(PRESENT_BEAM_24_V705)
	const char *mode = "PRODUCT_24_V705";
	const int H_BEAM = 960, V_BEAM = 540;
	const int expect_ht = 1182, expect_vt = 705;
	// Runtime path: param V=564 + rt_vtotal=705 (not a second elab-time V_TOTAL).
	const int use_rt = 1, rt_vt = 705;
	const int win_h = 960, win_v = 540;
	const int product_assert = 1;
#else
	const char *mode = "PRODUCT_30_V564";
	const int H_BEAM = 960, V_BEAM = 540;
	const int expect_ht = 1182, expect_vt = 564;
	const int use_rt = 0, rt_vt = 0;
	const int win_h = 960, win_v = 540;
	const int product_assert = 1;
#endif
	(void)H_BEAM;
	(void)V_BEAM;

	top->win_enable = 1;
	top->content_w = CW;
	top->content_h = CH;
	top->content_x0 = 0;
	top->content_y0 = 0;
	top->win_h_de = win_h;
	top->win_v_de = win_v;
	top->use_rt_vtotal = use_rt ? 1 : 0;
	top->rt_vtotal = rt_vt;

	top->reset = 1;
	top->clk = 0;
	for (int i = 0; i < 20; ++i)
		tick(top);
	top->reset = 0;
	for (int i = 0; i < 5; ++i)
		tick(top);

	(void)measure_one_frame(top, expect_ht, expect_vt);
	FrameStats st = measure_one_frame(top, expect_ht, expect_vt);

	const int de_w_uniform = (st.min_de_w == st.max_de_w && st.max_de_w > 0) ? 1 : 0;
	const int de_w = st.max_de_w;
	const int de_h = st.de_lines;
	const int true_de =
	    (de_w == CW && de_h == CH && st.de_pixels == CW * CH && de_w_uniform) ? 1 : 0;
	const int clks_frame = expect_ht * expect_vt;
	const double fps = 20e6 / double(clks_frame);

	std::printf(
	    "CASE true_de_count EXECUTED mode=%s "
	    "H_TOT=%d V_TOT=%d clks/frame=%d fps@20M=%.4f "
	    "de_w_min=%d de_w_max=%d de_lines=%d de_pixels=%d "
	    "de_uniform=%d store_id_ok=%d store_id_fail=%d/%d "
	    "true_de=%d beam_expect=%dx%d win_de=%dx%d rt_vt=%d\n",
	    mode, expect_ht, expect_vt, clks_frame, fps, st.min_de_w, st.max_de_w, st.de_lines,
	    st.de_pixels, de_w_uniform, st.store_id_ok, st.store_id_fail, st.store_id_checked,
	    true_de, H_BEAM, V_BEAM, win_h, win_v, rt_vt);

	int fails = 0;
#define CHECK(c, m)                                                                 \
	do {                                                                            \
		if (!(c)) {                                                                 \
			std::fprintf(stderr, "FAIL %s\n", m);                                   \
			++fails;                                                                \
		}                                                                           \
	} while (0)

	if (product_assert) {
		// Product contract always: true 960×540 DE (RED modes must fail these).
		CHECK(de_w == 960, "de_w==960");
		CHECK(de_h == 540, "de_h==540");
		CHECK(st.de_pixels == 960 * 540, "de_pixels==518400");
		CHECK(de_w_uniform, "de_uniform==1");
		CHECK(st.min_de_w == 960 && st.max_de_w == 960, "every line exactly 960");
		CHECK(true_de == 1, "true_de==1");
	}

#if defined(PRESENT_BEAM_24_V705)
	CHECK(st.store_id_ok == 1, "identity store @24");
	CHECK(st.store_id_fail == 0, "zero store fails @24");
	CHECK(expect_vt == 705 && expect_ht == 1182, "1182x705 beam");
	CHECK(clks_frame == 833310, "clks/frame 833310");
	CHECK(fps > 23.99 && fps < 24.02, "fps≈24.0007");
	CHECK(std::fabs(fps - 24.000672) < 0.001, "fps within 0.001 of 24.000672");
#elif !defined(PRESENT_BEAM_FAULT_ISLAND_1280) && !defined(PRESENT_BEAM_FAULT_VTOT_BAD_DE)
	CHECK(st.store_id_ok == 1, "identity store @30");
	CHECK(st.store_id_fail == 0, "zero store fails @30");
	CHECK(expect_vt == 564 && expect_ht == 1182, "1182x564 beam");
	CHECK(clks_frame == 666648, "clks/frame 666648");
	CHECK(fps > 29.95 && fps < 30.05, "fps≈30.0008");
#elif defined(PRESENT_BEAM_FAULT_VTOT_BAD_DE)
	// Extra pin: rate is film but width is canvas (the new failure mode).
	CHECK(de_w == 1280, "diag vtot-bad-de width 1280"); // will fail with de_w==960
	CHECK(expect_vt == 705, "diag V_TOT 705");
#endif

	if (fails) {
		std::printf("FAIL true_de_count fails=%d mode=%s true_de=%d de=%dx%d\n", fails,
		            mode, true_de, de_w, de_h);
		delete top;
		return 1;
	}
	std::printf("PASS true_de_count mode=%s true_de=%d de=%dx%d fps=%.4f\n", mode, true_de,
	            de_w, de_h, fps);
	delete top;
	return 0;
}
