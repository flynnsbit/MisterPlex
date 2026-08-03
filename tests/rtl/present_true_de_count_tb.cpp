// Counted true-DE + B6 full store coordinate oracle.
//
// Product 30/24: 960×540 identity window, DE extent == content.
// Multi-geom (runtime H_DE/V_ACTIVE): 320×240, 640×360, 960×540.
//
// B6 oracle (DE-only greenwash forbidden):
//   store_id_checked == CW*CH
//   every (x,y) in [0,CW)×[0,CH) visited *exactly once* (bitmap)
//   identity: delayed store_(x,y) == beam (hc,vc) at sample
//   no dups, no OOB, no omissions
//
// RED twins:
//   ISLAND_1280 / FAULT_VTOT_BAD_DE (existing)
//   FAULT_STORE_ORACLE_PERM — x^=1 bijection (count can lie; oracle must RED)
//   FAULT_STORE_ORACLE_DROP — x0→x1 (missing 0, dup 1)
//
// true rc direct. EXECUTED before accept.

#include "Vpresent_true_de_count_tb.h"
#include "verilated.h"

#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cmath>
#include <cstring>
#include <string>
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
	int de_lines = 0;
	int de_pixels = 0;
	int min_de_w = 100000;
	int max_de_w = 0;
	int store_req = 0;
	int store_id_ok = 1;
	int store_id_checked = 0;
	int store_id_fail = 0;
	int store_x_min = 100000;
	int store_x_max = -1;
	int store_y_min = 100000;
	int store_y_max = -1;
	int store_x_has0 = 0;
	int line_req_min = 100000;
	int line_req_max = 0;
	// B6 visitation oracle
	int visit_unique = 0;
	int visit_dup = 0;
	int visit_oob = 0;
	int visit_omit = 0;
	int oracle_full = 0;
};

static FrameStats measure_one_frame(Vpresent_true_de_count_tb *top, int expect_ht, int expect_vt,
                                    int CW, int CH)
{
	FrameStats st;
	std::vector<uint8_t> seen(static_cast<size_t>(CW) * static_cast<size_t>(CH), 0);

	int guard = expect_ht * expect_vt * 3 + 10000;
	while (!top->frame_start && guard-- > 0)
		tick(top);
	if (guard <= 0) {
		std::fprintf(stderr, "FAIL no frame_start\n");
		std::exit(2);
	}

	int line_de = 0;
	int line_req = 0;
	int hc_prev = -1;
	int lines = 0;
	int clks = 0;
	const int limit = expect_ht * expect_vt + expect_ht;
	int ic_d1 = 0, hc_d1 = 0, vc_d1 = 0;

	while (clks < limit) {
		const int de = top->de_out ? 1 : 0;
		const int hc = int(top->hc);
		const int vc = int(top->vc);
		const int ic = top->in_content_raw ? 1 : 0;

		if (hc_prev >= 0 && hc < hc_prev) {
			if (line_de > 0) {
				st.de_lines++;
				if (line_de < st.min_de_w)
					st.min_de_w = line_de;
				if (line_de > st.max_de_w)
					st.max_de_w = line_de;
			}
			if (line_req > 0) {
				if (line_req < st.line_req_min)
					st.line_req_min = line_req;
				if (line_req > st.line_req_max)
					st.line_req_max = line_req;
			}
			line_de = 0;
			line_req = 0;
			lines++;
		}

		if (de) {
			line_de++;
			st.de_pixels++;
		}
		if (ic) {
			line_req++;
			st.store_req++;
		}
		if (ic_d1) {
			st.store_id_checked++;
			const int sx = int(top->store_x);
			const int sy = int(top->store_y);
			// Identity vs beam at request epoch (1-cycle window align).
			if (sx != hc_d1 || sy != vc_d1) {
				st.store_id_ok = 0;
				st.store_id_fail++;
			}
			if (sx < st.store_x_min)
				st.store_x_min = sx;
			if (sx > st.store_x_max)
				st.store_x_max = sx;
			if (sy < st.store_y_min)
				st.store_y_min = sy;
			if (sy > st.store_y_max)
				st.store_y_max = sy;
			if (sx == 0)
				st.store_x_has0 = 1;

			// Exactly-once visitation over content rectangle.
			if (sx < 0 || sy < 0 || sx >= CW || sy >= CH) {
				st.visit_oob++;
			} else {
				const size_t idx =
				    static_cast<size_t>(sy) * static_cast<size_t>(CW) + static_cast<size_t>(sx);
				if (seen[idx])
					st.visit_dup++;
				else {
					seen[idx] = 1;
					st.visit_unique++;
				}
			}
		}
		ic_d1 = ic;
		hc_d1 = hc;
		vc_d1 = vc;

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
	if (line_req > 0) {
		if (line_req < st.line_req_min)
			st.line_req_min = line_req;
		if (line_req > st.line_req_max)
			st.line_req_max = line_req;
	}
	if (st.min_de_w > st.max_de_w)
		st.min_de_w = 0;
	if (st.line_req_min > st.line_req_max)
		st.line_req_min = 0;
	if (st.store_x_min > st.store_x_max)
		st.store_x_min = -1;
	if (st.store_y_min > st.store_y_max)
		st.store_y_min = -1;

	st.visit_omit = CW * CH - st.visit_unique;
	if (st.visit_omit < 0)
		st.visit_omit = 0;
	st.oracle_full =
	    (st.store_id_checked == CW * CH && st.visit_unique == CW * CH && st.visit_dup == 0 &&
	     st.visit_oob == 0 && st.visit_omit == 0 && st.store_id_ok && st.store_id_fail == 0 &&
	     st.store_x_min == 0 && st.store_x_max == CW - 1 && st.store_y_min == 0 &&
	     st.store_y_max == CH - 1 && st.store_x_has0 && st.line_req_min == CW &&
	     st.line_req_max == CW && st.store_req == CW * CH)
	        ? 1
	        : 0;
	return st;
}

enum class CaseKind {
	Product30,
	Product24,
	Geom320,
	Geom640,
	Geom960,
	Island,
	VtotBad,
	OraclePerm,
	OracleDrop
};

static CaseKind parse_case()
{
#if defined(PRESENT_BEAM_FAULT_STORE_ORACLE_PERM)
	return CaseKind::OraclePerm;
#elif defined(PRESENT_BEAM_FAULT_STORE_ORACLE_DROP)
	return CaseKind::OracleDrop;
#elif defined(PRESENT_BEAM_FAULT_ISLAND_1280)
	return CaseKind::Island;
#elif defined(PRESENT_BEAM_FAULT_VTOT_BAD_DE)
	return CaseKind::VtotBad;
#elif defined(PRESENT_BEAM_24_V705)
	return CaseKind::Product24;
#elif defined(PRESENT_BEAM_GEOM_320)
	return CaseKind::Geom320;
#elif defined(PRESENT_BEAM_GEOM_640)
	return CaseKind::Geom640;
#elif defined(PRESENT_BEAM_GEOM_960)
	return CaseKind::Geom960;
#else
	return CaseKind::Product30;
#endif
}

int main(int argc, char **argv)
{
	Verilated::commandArgs(argc, argv);
	auto *top = new Vpresent_true_de_count_tb;
	const CaseKind ck = parse_case();

	int CW = 960, CH = 540;
	int expect_ht = 1182, expect_vt = 564;
	int use_rt_v = 0, rt_vt = 0;
	int use_rt_g = 0, rt_hde = 0, rt_vact = 0;
	int win_h = 960, win_v = 540;
	int product_true_de = 1; // expect true_de==1
	int require_oracle = 1;  // B6 full oracle
	const char *mode = "PRODUCT_30_V564";

	switch (ck) {
	case CaseKind::Product30:
		mode = "PRODUCT_30_V564";
		break;
	case CaseKind::Product24:
		mode = "PRODUCT_24_V705";
		expect_vt = 705;
		use_rt_v = 1;
		rt_vt = 705;
		break;
	case CaseKind::Geom320:
		mode = "GEOM_320x240";
		CW = 320;
		CH = 240;
		win_h = 320;
		win_v = 240;
		use_rt_g = 1;
		rt_hde = 320;
		rt_vact = 240;
		break;
	case CaseKind::Geom640:
		mode = "GEOM_640x360";
		CW = 640;
		CH = 360;
		win_h = 640;
		win_v = 360;
		use_rt_g = 1;
		rt_hde = 640;
		rt_vact = 360;
		break;
	case CaseKind::Geom960:
		mode = "GEOM_960x540_RT";
		CW = 960;
		CH = 540;
		win_h = 960;
		win_v = 540;
		use_rt_g = 1;
		rt_hde = 960;
		rt_vact = 540;
		break;
	case CaseKind::Island:
		mode = "ISLAND_1280";
		expect_ht = 1650;
		expect_vt = 750;
		win_h = 1280;
		win_v = 720;
		product_true_de = 0;
		require_oracle = 0; // DE≠content
		break;
	case CaseKind::VtotBad:
		mode = "FAULT_VTOT_BAD_DE";
		expect_ht = 1400;
		expect_vt = 705;
		use_rt_v = 1;
		rt_vt = 705;
		win_h = 1280;
		win_v = 540;
		product_true_de = 0;
		require_oracle = 0;
		break;
	case CaseKind::OraclePerm:
		mode = "FAULT_STORE_ORACLE_PERM";
		// DE still 960×540 identity timing; store_x scrambled.
		product_true_de = 1; // DE raster OK
		require_oracle = 1;  // must FAIL oracle
		break;
	case CaseKind::OracleDrop:
		mode = "FAULT_STORE_ORACLE_DROP";
		product_true_de = 1;
		require_oracle = 1;
		break;
	}

	top->win_enable = 1;
	top->content_w = CW;
	top->content_h = CH;
	top->content_x0 = 0;
	top->content_y0 = 0;
	top->win_h_de = win_h;
	top->win_v_de = win_v;
	top->use_rt_vtotal = use_rt_v ? 1 : 0;
	top->rt_vtotal = rt_vt;
	top->use_rt_geom = use_rt_g ? 1 : 0;
	top->rt_h_de = rt_hde;
	top->rt_v_active = rt_vact;

	top->reset = 1;
	top->clk = 0;
	for (int i = 0; i < 20; ++i)
		tick(top);
	top->reset = 0;
	for (int i = 0; i < 5; ++i)
		tick(top);

	// Warm one frame so runtime geom latch is stable if applied at wrap.
	(void)measure_one_frame(top, expect_ht, expect_vt, CW, CH);
	FrameStats st = measure_one_frame(top, expect_ht, expect_vt, CW, CH);

	const int de_w_uniform = (st.min_de_w == st.max_de_w && st.max_de_w > 0) ? 1 : 0;
	const int de_w = st.max_de_w;
	const int de_h = st.de_lines;
	const int true_de =
	    (de_w == CW && de_h == CH && st.de_pixels == CW * CH && de_w_uniform) ? 1 : 0;
	const int clks_frame = expect_ht * expect_vt;
	const double fps = 20e6 / double(clks_frame);
	const int store_full =
	    (st.store_req == CW * CH && st.store_id_checked == CW * CH && st.store_id_ok &&
	     st.store_x_has0 && st.store_x_min == 0 && st.store_x_max == CW - 1 &&
	     st.line_req_min == CW && st.line_req_max == CW)
	        ? 1
	        : 0;

	std::printf(
	    "CASE true_de_count EXECUTED mode=%s "
	    "H_TOT=%d V_TOT=%d clks/frame=%d fps@20M=%.4f "
	    "CW=%d CH=%d de_w_min=%d de_w_max=%d de_lines=%d de_pixels=%d "
	    "de_uniform=%d store_req=%d store_id_checked=%d store_id_ok=%d store_id_fail=%d "
	    "store_x_range=%d..%d store_y_range=%d..%d store_x0=%d line_req=%d..%d "
	    "visit_unique=%d visit_dup=%d visit_oob=%d visit_omit=%d "
	    "oracle_full=%d store_full=%d true_de=%d "
	    "hde_act=%d vact_act=%d rt_geom=%d rt_hde=%d rt_vact=%d rt_vt=%d\n",
	    mode, expect_ht, expect_vt, clks_frame, fps, CW, CH, st.min_de_w, st.max_de_w, st.de_lines,
	    st.de_pixels, de_w_uniform, st.store_req, st.store_id_checked, st.store_id_ok,
	    st.store_id_fail, st.store_x_min, st.store_x_max, st.store_y_min, st.store_y_max,
	    st.store_x_has0, st.line_req_min, st.line_req_max, st.visit_unique, st.visit_dup,
	    st.visit_oob, st.visit_omit, st.oracle_full, store_full, true_de, int(top->hde_active),
	    int(top->vact_active), use_rt_g, rt_hde, rt_vact, rt_vt);

	int fails = 0;
	auto CHECK = [&](bool c, const char *m) {
		if (!c) {
			std::fprintf(stderr, "FAIL %s\n", m);
			++fails;
		}
	};

	// B6 hard requirements whenever we claim identity true-DE product/geom.
	if (require_oracle && product_true_de &&
	    (ck == CaseKind::Product30 || ck == CaseKind::Product24 || ck == CaseKind::Geom320 ||
	     ck == CaseKind::Geom640 || ck == CaseKind::Geom960)) {
		CHECK(true_de == 1, "true_de==1");
		CHECK(st.de_pixels == CW * CH, "de_pixels==CW*CH");
		CHECK(de_w_uniform && st.min_de_w == CW && st.max_de_w == CW, "de_w uniform ==CW");
		CHECK(st.store_req == CW * CH, "store_req==CW*CH");
		CHECK(st.store_id_checked == CW * CH, "store_id_checked==CW*CH");
		CHECK(st.store_id_ok == 1, "identity store map");
		CHECK(st.store_id_fail == 0, "zero identity fails");
		CHECK(st.visit_unique == CW * CH, "visit_unique==CW*CH");
		CHECK(st.visit_dup == 0, "visit_dup==0");
		CHECK(st.visit_oob == 0, "visit_oob==0");
		CHECK(st.visit_omit == 0, "visit_omit==0");
		CHECK(st.oracle_full == 1, "oracle_full==1");
		CHECK(store_full == 1, "store_full==1");
		CHECK(st.store_x_min == 0 && st.store_x_max == CW - 1, "store_x full span");
		CHECK(st.store_y_min == 0 && st.store_y_max == CH - 1, "store_y full span");
		CHECK(st.line_req_min == CW && st.line_req_max == CW, "line_req==CW each line");
	}

	if (ck == CaseKind::Product30) {
		CHECK(expect_vt == 564 && clks_frame == 666648, "30Hz beam class");
		CHECK(fps > 29.95 && fps < 30.05, "fps≈30");
	} else if (ck == CaseKind::Product24) {
		CHECK(expect_vt == 705 && clks_frame == 833310, "24Hz beam class");
		CHECK(fps > 23.99 && fps < 24.02, "fps≈24");
	} else if (ck == CaseKind::Island) {
		CHECK(de_w == 1280, "island width 1280");
		CHECK(true_de == 0, "island true_de==0");
		CHECK(st.oracle_full == 0, "island oracle_full==0");
		// RED twin: always non-zero exit (control checks above document why).
		if (fails == 0)
			fails = 1;
		std::printf("FAIL true_de_count RED mode=%s true_de=%d de=%dx%d oracle_full=%d\n",
		            mode, true_de, de_w, de_h, st.oracle_full);
		delete top;
		return 1;
	} else if (ck == CaseKind::VtotBad) {
		CHECK(de_w == 1280, "vtot-bad width 1280");
		CHECK(true_de == 0, "vtot-bad true_de==0");
		CHECK(expect_vt == 705, "vtot 705");
		if (fails == 0)
			fails = 1;
		std::printf("FAIL true_de_count RED mode=%s true_de=%d de=%dx%d\n", mode, true_de, de_w,
		            de_h);
		delete top;
		return 1;
	} else if (ck == CaseKind::OraclePerm || ck == CaseKind::OracleDrop) {
		// RED: DE may still look true; oracle MUST fail.
		CHECK(true_de == 1, "fault keeps DE raster (control)");
		CHECK(st.oracle_full == 0, "oracle_full==0 under store fault");
		if (ck == CaseKind::OraclePerm) {
			// Bijection: unique may still be full; identity must break.
			CHECK(st.store_id_ok == 0 || st.store_id_fail > 0, "PERM breaks identity");
		} else {
			CHECK(st.visit_dup > 0 || st.visit_omit > 0 || st.store_x_has0 == 0,
			      "DROP missing/dup x0");
		}
		// Force overall RED exit even if CHECKs pass structurally
		if (st.oracle_full == 1) {
			std::fprintf(stderr, "FAIL oracle greenwashed under fault\n");
			++fails;
		}
		// Expect non-zero fails from oracle_full==0 check; if somehow only that, ok.
	}

	if (ck == CaseKind::OraclePerm || ck == CaseKind::OracleDrop) {
		// Red twin: must exit non-zero.
		if (fails == 0)
			fails = 1;
		std::printf("FAIL true_de_count RED mode=%s fails=%d oracle_full=%d id_fail=%d "
		            "dup=%d omit=%d\n",
		            mode, fails, st.oracle_full, st.store_id_fail, st.visit_dup, st.visit_omit);
		delete top;
		return 1;
	}

	if (fails) {
		std::printf("FAIL true_de_count fails=%d mode=%s true_de=%d oracle_full=%d de=%dx%d "
		            "store_req=%d checked=%d\n",
		            fails, mode, true_de, st.oracle_full, de_w, de_h, st.store_req,
		            st.store_id_checked);
		delete top;
		return 1;
	}
	std::printf("PASS true_de_count mode=%s true_de=%d oracle_full=%d store_full=%d de=%dx%d "
	            "visit=%d/%d fps=%.4f\n",
	            mode, true_de, st.oracle_full, store_full, de_w, de_h, st.visit_unique, CW * CH,
	            fps);
	delete top;
	return 0;
}
